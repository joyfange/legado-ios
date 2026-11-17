import Foundation
import SwiftUI
#if SWIFT_PACKAGE
import LegadoCore
#endif

final class LocalBookImportFile: @unchecked Sendable {
    let url: URL
    private let hasSecurityScope: Bool

    init(url: URL) {
        self.url = url
        hasSecurityScope = url.startAccessingSecurityScopedResource()
    }

    deinit {
        if hasSecurityScope { url.stopAccessingSecurityScopedResource() }
    }
}

enum AppBookChapterRepository {
    static func live() -> any BookChapterRepository {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Legado", isDirectory: true)
        guard let database = try? LegadoDatabase(url: base.appendingPathComponent("legado.sqlite3")) else {
            return FileBookChapterRepository.live()
        }
        return SQLiteBookChapterRepository(
            database: database,
            legacyDirectory: base.appendingPathComponent("Chapters", isDirectory: true)
        )
    }
}

@MainActor
final class BookLibraryModel: ObservableObject {
    @Published private(set) var books: [Book] = []
    /// 首次从数据库读完书架后为 true。读完之前书架不显示「空书架」占位，避免启动时闪一下。
    @Published private(set) var hasLoaded = false
    @Published private(set) var groups: [BookGroup] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var updateMessage: String?
    @Published private(set) var isCheckingUpdates = false
    /// 章节已全部缓存（下载完）的书，供「已下载」书架使用。
    @Published private(set) var downloadedURLs: Set<String> = []

    private let repository: any BookRepository
    private let localDirectory: URL
    let localFiles: LocalFileService
    private let localService = LocalBookService.live()
    private let updateCoordinator: BookUpdateCoordinator
    private let chapterRepository: any BookChapterRepository
    private let groupRepository: any BookGroupRepository
    private let pendingProgressKey = "pendingBookReadingProgress"
    private let progressDefaults: UserDefaults
    private var pendingProgress: [String: BookProgress]
    private var bookSaveTask: Task<Bool, Never>?
    private var bookSaveGeneration = 0
    private var persistedBooks: [Book] = []
    private var groupSaveTask: Task<Bool, Never>?
    private var groupSaveGeneration = 0
    private var persistedGroups: [BookGroup] = []
    private var deletingGroupIDs: Set<Int64> = []
    /// 只有正式书架（live）补默认智能书架；测试和演示用的模型保持原来的分组。
    private var seedsSmartShelves = false

    init(
        repository: any BookRepository,
        localDirectory: URL? = nil,
        updateCoordinator: BookUpdateCoordinator = .init(),
        chapterRepository: any BookChapterRepository = FileBookChapterRepository.live(),
        groupRepository: any BookGroupRepository = InMemoryBookGroupRepository(),
        progressDefaults: UserDefaults = .standard
    ) {
        self.repository = repository
        self.localDirectory = localDirectory ?? FileManager.default.temporaryDirectory.appendingPathComponent("LegadoLocalBooks")
        localFiles = LocalFileService(directory: self.localDirectory)
        self.updateCoordinator = updateCoordinator
        self.chapterRepository = chapterRepository
        self.groupRepository = groupRepository
        self.progressDefaults = progressDefaults
        pendingProgress = (progressDefaults.data(forKey: pendingProgressKey)
            .flatMap { try? JSONDecoder().decode([String: BookProgress].self, from: $0) }) ?? [:]
    }

    static func live() -> BookLibraryModel {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Legado", isDirectory: true)
        let legacyBooks = base.appendingPathComponent("books.json")
        guard let database = try? LegadoDatabase(url: base.appendingPathComponent("legado.sqlite3")) else {
            let model = BookLibraryModel(
                repository: FileBookRepository(fileURL: legacyBooks),
                localDirectory: base.appendingPathComponent("LocalBooks", isDirectory: true),
                groupRepository: FileBookGroupRepository(fileURL: base.appendingPathComponent("book-groups.json"))
            )
            model.seedsSmartShelves = true
            return model
        }
        let chapters = SQLiteBookChapterRepository(
            database: database,
            legacyDirectory: base.appendingPathComponent("Chapters", isDirectory: true)
        )
        let model = BookLibraryModel(
            repository: SQLiteBookRepository(database: database, legacyFileURL: legacyBooks),
            localDirectory: base.appendingPathComponent("LocalBooks", isDirectory: true),
            updateCoordinator: BookUpdateCoordinator(repository: chapters),
            chapterRepository: chapters,
            groupRepository: SQLiteBookGroupRepository(
                database: database,
                legacyFileURL: base.appendingPathComponent("book-groups.json")
            )
        )
        model.seedsSmartShelves = true
        return model
    }

    static func demo(books: [Book]) -> BookLibraryModel {
        BookLibraryModel(repository: InMemoryBookRepository(books: books))
    }

    func load() async {
        do {
            async let storedBooks = repository.load()
            async let storedGroups = groupRepository.load()
            books = try await storedBooks
            persistedBooks = books
            hasLoaded = true
            groups = try await storedGroups
            persistedGroups = groups
            if groups.isEmpty {
                await persistGroups([.init(groupId: BookGroup.idAll, groupName: "全部", order: 0)])
            }
            await seedSmartShelves()
            await refreshDownloaded()
            for book in books where book.origin == "local" && book.coverUrl?.isEmpty != false {
                guard !Task.isCancelled, let url = URL(string: book.bookUrl),
                      url.isFileURL, url.pathExtension.lowercased() == "epub" else { continue }
                if let cover = try? await Task.detached(priority: .utility, operation: { [localService] in
                    try localService.loadCover(at: url)
                }).value {
                    await restoreLocalCover(for: book, dataURL: "data:image/png;base64,\(cover.base64EncodedString())")
                }
            }
        } catch {
            hasLoaded = true
            errorMessage = error.localizedDescription
        }
    }

    func contains(_ book: Book) -> Bool {
        books.contains { $0.bookUrl == book.bookUrl }
    }

    func addOrUpdate(_ book: Book) async {
        var book = book
        if let existing = books.first(where: { $0.bookUrl == book.bookUrl }),
           existing.durChapterTime > book.durChapterTime {
            applyProgress(BookProgress(book: existing), to: &book)
        }
        let pending = pendingProgress[book.bookUrl]
        if let pending {
            if pending.durChapterTime > book.durChapterTime {
                applyProgress(pending, to: &book)
            }
        }
        var updated = books
        if let index = updated.firstIndex(where: { $0.bookUrl == book.bookUrl }) {
            updated[index] = book
        } else {
            updated.append(book)
        }
        if await persist(updated), let pending, pendingProgress[book.bookUrl] == pending {
            pendingProgress[book.bookUrl] = nil
            persistPendingProgress()
        }
    }

    func replace(oldBookURL: String, with book: Book) async {
        guard books.contains(where: { $0.bookUrl == oldBookURL }) else {
            await addOrUpdate(book)
            return
        }
        var updated = books.filter { $0.bookUrl == oldBookURL || $0.bookUrl != book.bookUrl }
        guard let index = updated.firstIndex(where: { $0.bookUrl == oldBookURL }) else { return }
        updated[index] = book
        if await persist(updated), oldBookURL != book.bookUrl {
            await cleanupRemovedBooks([oldBookURL])
        }
    }

    func updateProgress(for book: Book, chapter: BookChapter, position: Int = 0, epubLocation: String? = nil) async {
        guard let index = books.firstIndex(where: { $0.bookUrl == book.bookUrl }) else {
            var reading = book
            if epubLocation != nil, reading.readConfig == nil { reading.readConfig = BookReadConfig() }
            reading.readConfig?.epubLocation = epubLocation
            reading.durChapterIndex = chapter.index
            reading.durChapterTitle = chapter.title
            reading.durChapterPos = max(position, 0)
            reading.durChapterTime = Int64(Date().timeIntervalSince1970 * 1_000)
            pendingProgress[book.bookUrl] = BookProgress(book: reading)
            persistPendingProgress()
            return
        }
        var updated = books
        if epubLocation != nil, updated[index].readConfig == nil { updated[index].readConfig = BookReadConfig() }
        updated[index].readConfig?.epubLocation = epubLocation
        updated[index].durChapterIndex = chapter.index
        updated[index].durChapterTitle = chapter.title
        updated[index].durChapterPos = max(position, 0)
        updated[index].durChapterTime = Int64(Date().timeIntervalSince1970 * 1_000)
        updated[index].lastCheckCount = 0
        updated[index].totalChapterNum = max(updated[index].totalChapterNum, chapter.index + 1)
        await persist(updated)
    }

    private func applyProgress(_ progress: BookProgress, to book: inout Book) {
        if progress.epubLocation != nil, book.readConfig == nil { book.readConfig = BookReadConfig() }
        book.readConfig?.epubLocation = progress.epubLocation
        book.durChapterIndex = progress.durChapterIndex
        book.durChapterTitle = progress.durChapterTitle
        book.durChapterPos = progress.durChapterPos
        book.durChapterTime = progress.durChapterTime
    }

    func restoreLocalCover(for book: Book, dataURL: String) async {
        guard let index = books.firstIndex(where: { $0.bookUrl == book.bookUrl }),
              books[index].origin == "local", books[index].coverUrl?.isEmpty != false else { return }
        var updated = books
        updated[index].coverUrl = dataURL
        await persist(updated)
    }

    private func persistPendingProgress() {
        if pendingProgress.isEmpty {
            progressDefaults.removeObject(forKey: pendingProgressKey)
        } else if let data = try? JSONEncoder().encode(pendingProgress) {
            progressDefaults.set(data, forKey: pendingProgressKey)
        }
    }

    func checkForUpdates(sources: [BookSource], onlyRead: Bool = false) async {
        guard !isCheckingUpdates else { return }
        isCheckingUpdates = true
        updateMessage = nil
        defer { isCheckingUpdates = false }

        let sourceByURL = Dictionary(sources.map { ($0.bookSourceUrl, $0) }, uniquingKeysWith: { _, latest in latest })
        let requestedBooks = books.filter { $0.canUpdate && $0.origin != "local" && (!onlyRead || $0.durChapterTime > 0) }
        var checked = 0
        var added = 0
        var failed = 0
        for requestedBook in requestedBooks {
            guard let source = sourceByURL[requestedBook.origin], source.enabled else {
                failed += 1
                continue
            }
            let report = await updateCoordinator.refresh(book: requestedBook, source: source)
            checked += 1
            if report.refreshed {
                // Network requests suspend this actor. Merge the new directory
                // into the current shelf, including any progress or edits made
                // while the request was running, and never resurrect removals.
                guard let index = books.firstIndex(where: {
                    $0.bookUrl == requestedBook.bookUrl && $0.origin == requestedBook.origin
                }) else { continue }
                var updated = books
                updated[index] = BookUpdateMerger().merge(
                    book: updated[index],
                    oldChapters: [],
                    newChapters: report.chapters,
                    now: report.book.lastCheckTime
                ).book
                added += report.addedChapterCount
                await persist(updated)
            } else {
                failed += 1
            }
        }

        if checked == 0 && failed == 0 {
            updateMessage = "书架里暂时没有可更新的网络书籍。"
        } else if failed > 0 {
            updateMessage = "已检查 \(checked) 本，发现 \(added) 个新章节；另有 \(failed) 本因书源不可用或解析失败未更新。"
        } else {
            updateMessage = added > 0 ? "更新完成，共发现 \(added) 个新章节。" : "更新完成，已是最新目录。"
        }
    }

    func remove(at offsets: IndexSet) async {
        var updated = books
        updated.remove(atOffsets: offsets)
        let removed = Set(books.map(\.bookUrl)).subtracting(updated.map(\.bookUrl))
        if await persist(updated) { await cleanupRemovedBooks(removed) }
    }

    /// 默认书架：正在读 / 想读 / 已读完 / 全部 / 已下载 / 本地。只在第一次补齐一次，
    /// 之后用户隐藏、改名、排序都保留（智能书架不能删除，只能隐藏）。
    private func seedSmartShelves() async {
        let key = "bookshelf.smartShelvesSeeded.v1"
        guard seedsSmartShelves, !progressDefaults.bool(forKey: key) else { return }
        let defaults: [(Int64, String)] = [
            (BookGroup.idReading, "正在读"), (BookGroup.idWantToRead, "想读"), (BookGroup.idFinished, "已读完"),
            (BookGroup.idAll, "全部"), (BookGroup.idDownloaded, "已下载"), (BookGroup.idLocal, "本地")
        ]
        var updated = groups
        for (order, item) in defaults.enumerated() {
            if let index = updated.firstIndex(where: { $0.groupId == item.0 }) {
                updated[index].order = order
                updated[index].show = true
            } else {
                updated.append(.init(groupId: item.0, groupName: item.1, order: order))
            }
        }
        // 自定义书架排在默认书架后面，保持原来的先后。
        let custom = updated.filter { !defaults.map(\.0).contains($0.groupId) }.sorted { $0.order < $1.order }
        for (offset, group) in custom.enumerated() {
            if let index = updated.firstIndex(where: { $0.groupId == group.groupId }) {
                updated[index].order = defaults.count + offset
            }
        }
        if await persistGroups(updated) { progressDefaults.set(true, forKey: key) }
    }

    /// 读完：有目录、读到了最后一章。
    static func isFinished(_ book: Book) -> Bool {
        let started = book.durChapterIndex > 0 || book.durChapterPos > 0 || book.durChapterTime > 0
        return started && book.totalChapterNum > 0 && book.durChapterIndex >= book.totalChapterNum - 1
    }

    static func isReading(_ book: Book) -> Bool {
        let started = book.durChapterIndex > 0 || book.durChapterPos > 0 || book.durChapterTime > 0
        return started && !isFinished(book)
    }

    static func isWantToRead(_ book: Book) -> Bool {
        !(book.durChapterIndex > 0 || book.durChapterPos > 0 || book.durChapterTime > 0)
    }

    /// 重新统计已下载的书（网络书的章节缓存数达到目录章数）。
    func refreshDownloaded() async {
        let candidates = books.filter { $0.origin != "local" && $0.totalChapterNum > 0 }
        let urls = candidates.map(\.bookUrl)
        let counts = (try? await ChapterContentCache.live().cachedChapterCounts(bookURLs: urls)) ?? [:]
        let done = Set(candidates.filter { counts[$0.bookUrl, default: 0] >= $0.totalChapterNum }.map(\.bookUrl))
        if done != downloadedURLs { downloadedURLs = done }
    }

    /// 把书标记为「正在读」：没开始读的书记一个阅读时间，就会从「想读」移到「正在读」。
    func markReading(_ book: Book) async {
        guard let index = books.firstIndex(where: { $0.bookUrl == book.bookUrl }) else { return }
        var updated = books
        if Self.isWantToRead(updated[index]) {
            updated[index].durChapterTime = Int64(Date().timeIntervalSince1970 * 1_000)
        }
        await persist(updated)
    }

    /// 「移至书架」里切换正在读 / 想读：想读的书清掉开始阅读的标记（回到第一章），正在读的书记上阅读时间。
    func setReadingStatus(_ book: Book, reading: Bool) async {
        guard let index = books.firstIndex(where: { $0.bookUrl == book.bookUrl }) else { return }
        let isWant = Self.isWantToRead(books[index])
        if reading {
            if isWant { await markReading(book) }
        } else if !isWant {
            var updated = books
            updated[index].durChapterIndex = 0
            updated[index].durChapterPos = 0
            updated[index].durChapterTime = 0
            await persist(updated)
        }
    }

    func count(in group: BookGroup) -> Int { books(in: group).count }

    var visibleGroups: [BookGroup] {
        groups.filter(\.show).sorted {
            $0.order == $1.order ? $0.groupId < $1.groupId : $0.order < $1.order
        }
    }

    func books(in group: BookGroup) -> [Book] {
        switch group.groupId {
        case BookGroup.idAll: return books
        case BookGroup.idLocal: return books.filter { $0.origin == "local" }
        case BookGroup.idNetNone: return books.filter { $0.origin != "local" && $0.group == 0 }
        case BookGroup.idLocalNone: return books.filter { $0.origin == "local" && $0.group == 0 }
        case BookGroup.idReading: return books.filter(Self.isReading)
        case BookGroup.idWantToRead: return books.filter(Self.isWantToRead)
        case BookGroup.idFinished: return books.filter(Self.isFinished)
        case BookGroup.idDownloaded: return books.filter { downloadedURLs.contains($0.bookUrl) }
        default:
            return group.groupId > 0
                ? books.filter { ($0.group & group.groupId) != 0 }
                : books
        }
    }

    func createGroup(name: String) async {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !groups.contains(where: { $0.groupName == name }) else { return }
        let used = groups.filter { $0.groupId > 0 }.reduce(Int64(0)) { $0 | $1.groupId }
            | books.reduce(Int64(0)) { $0 | $1.group }
            | deletingGroupIDs.reduce(Int64(0), |)
        guard let nextID = (0..<63).map({ Int64(1) << $0 }).first(where: { used & $0 == 0 }) else {
            errorMessage = "自定义分组已达到上限（63 个），请先删除不再使用的分组。"
            return
        }
        await persistGroups(groups + [.init(groupId: nextID, groupName: name, order: groups.count)])
    }

    func renameGroup(_ group: BookGroup, name: String) async {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = groups.firstIndex(where: { $0.id == group.id }) else { return }
        var updated = groups
        updated[index].groupName = name
        await persistGroups(updated)
    }

    func setGroupVisible(_ group: BookGroup, visible: Bool) async {
        guard let index = groups.firstIndex(where: { $0.id == group.id }) else { return }
        var updated = groups
        updated[index].show = visible
        await persistGroups(updated)
    }

    func moveGroups(from offsets: IndexSet, to destination: Int) async {
        var editable = groups.filter { $0.groupId > 0 }.sorted { $0.order < $1.order }
        editable.move(fromOffsets: offsets, toOffset: destination)
        var updated = groups
        for (order, group) in editable.enumerated() {
            if let index = updated.firstIndex(where: { $0.id == group.id }) {
                updated[index].order = order + 1
            }
        }
        await persistGroups(updated)
    }

    /// 按给定顺序重排全部书架（含系统书架）。
    func reorderGroups(_ ids: [Int64]) async {
        var updated = groups
        for (order, id) in ids.enumerated() {
            if let index = updated.firstIndex(where: { $0.groupId == id }) { updated[index].order = order }
        }
        guard updated != groups else { return }
        _ = await persistGroups(updated)
    }

    func deleteGroup(_ group: BookGroup) async {
        guard group.groupId > 0, !deletingGroupIDs.contains(group.id),
              let stored = groups.first(where: { $0.id == group.id }) else { return }
        deletingGroupIDs.insert(group.id)
        defer { deletingGroupIDs.remove(group.id) }
        guard await persistGroups(groups.filter { $0.id != group.id }) else { return }
        var updated = books
        for index in updated.indices { updated[index].group &= ~group.groupId }
        if !(await persist(updated)) {
            let saveError = errorMessage
            await persistGroups(groups + [stored])
            errorMessage = saveError
        }
    }

    func setBook(_ book: Book, in group: BookGroup, included: Bool) async {
        guard group.groupId > 0, let index = books.firstIndex(where: { $0.id == book.id }) else { return }
        var updated = books
        if included { updated[index].group |= group.groupId }
        else { updated[index].group &= ~group.groupId }
        await persist(updated)
    }

    func setBook(_ book: Book, groupIDs: Set<Int64>) async {
        guard let index = books.firstIndex(where: { $0.id == book.id }) else { return }
        let customMask = groups.reduce(Int64(0)) { value, group in
            group.groupId > 0 ? value | group.groupId : value
        }
        let selectedMask = groupIDs.reduce(Int64(0), |)
        var updated = books
        updated[index].group = (updated[index].group & ~customMask) | selectedMask
        await persist(updated)
    }

    func remove(bookURL: String) async {
        if await persist(books.filter { $0.bookUrl != bookURL }) {
            await cleanupRemovedBooks([bookURL])
        }
    }

    private func cleanupRemovedBooks(_ urls: Set<String>) async {
        for url in urls where !books.contains(where: { $0.bookUrl == url }) {
            pendingProgress[url] = nil
            try? await chapterRepository.remove(bookURL: url)
        }
        persistPendingProgress()
    }

    func importLocalFiles(_ urls: [URL]) async {
        await importPickedLocalFiles(urls.map { LocalBookImportFile(url: $0) })
    }

    func importPickedLocalFiles(_ files: [LocalBookImportFile]) async {
        // Keep the picker grants alive through the review and asynchronous copy.
        defer { withExtendedLifetime(files) {} }
        var failures: [String] = []
        for file in files {
            let url = file.url
            do {
                let stored = try await localFiles.importFile(from: url)
                do {
                    try await addLocalFile(at: stored)
                } catch {
                    if let staged = try? await localFiles.stageRemoval(stored) {
                        try? await localFiles.finishRemoval(staged)
                    }
                    throw error
                }
            } catch {
                failures.append("\(url.lastPathComponent)：\(error.localizedDescription)")
            }
        }
        errorMessage = failures.isEmpty ? nil : failures.joined(separator: "\n")
    }

    func addLocalFile(at url: URL) async throws {
        guard !books.contains(where: { $0.bookUrl == url.absoluteString }) else { return }
        let report = try await Task.detached { [localService] in try localService.openFile(at: url) }.value
        guard !books.contains(where: { $0.bookUrl == url.absoluteString }) else { return }
        guard await persist(books + [report.book]) else {
            throw LocalFileError.saveFailed(errorMessage ?? "无法写入数据库")
        }
    }

    func renameLocalFile(at url: URL, to name: String) async throws {
        let target = try await localFiles.rename(url, to: name)
        guard target != url else { return }
        var updated = books
        for index in updated.indices where updated[index].origin == "local" && updated[index].bookUrl == url.absoluteString {
            updated[index].bookUrl = target.absoluteString
            updated[index].originName = target.lastPathComponent
        }
        guard await persist(updated) else {
            _ = try await localFiles.rename(target, to: url.lastPathComponent)
            throw LocalFileError.saveFailed(errorMessage ?? "无法写入数据库")
        }
        if let progress = pendingProgress.removeValue(forKey: url.absoluteString) {
            pendingProgress[target.absoluteString] = progress
            persistPendingProgress()
        }
        try? await chapterRepository.remove(bookURL: url.absoluteString)
    }

    func deleteLocalFile(at url: URL) async throws {
        let staged: StagedLocalFile?
        if url.isFileURL,
           books.contains(where: { $0.origin == "local" && $0.bookUrl == url.absoluteString }),
           !FileManager.default.fileExists(atPath: url.path) {
            // Stale shelf paths can belong to a previous app container. Only
            // remove their metadata; existing files still require containment.
            staged = nil
        } else {
            staged = try await localFiles.stageRemoval(url)
        }
        guard await persist(books.filter { $0.bookUrl != url.absoluteString }) else {
            if let staged { try await localFiles.restore(staged) }
            throw LocalFileError.saveFailed(errorMessage ?? "无法写入数据库")
        }
        pendingProgress[url.absoluteString] = nil
        persistPendingProgress()
        try? await chapterRepository.remove(bookURL: url.absoluteString)
        if let staged { try await localFiles.finishRemoval(staged) }
    }

    func clearError() { errorMessage = nil }

    func clearUpdateMessage() { updateMessage = nil }

    func reportError(_ error: Error) { errorMessage = error.localizedDescription }

    @discardableResult
    private func persist(_ updated: [Book]) async -> Bool {
        // Publish before suspending so the next mutation sees the latest
        // shelf. Serialize disk writes to keep their order identical to it.
        books = updated
        bookSaveGeneration &+= 1
        let generation = bookSaveGeneration
        let previousSave = bookSaveTask
        let save = Task { @MainActor [weak self, repository] in
            _ = await previousSave?.value
            do {
                try await repository.save(updated)
                self?.persistedBooks = updated
                if self?.bookSaveGeneration == generation { self?.errorMessage = nil }
                return true
            } catch {
                if let self, bookSaveGeneration == generation {
                    books = persistedBooks
                    errorMessage = error.localizedDescription
                }
                return false
            }
        }
        bookSaveTask = save
        let succeeded = await save.value
        if bookSaveGeneration == generation { bookSaveTask = nil }
        return succeeded
    }

    @discardableResult
    private func persistGroups(_ updated: [BookGroup]) async -> Bool {
        groups = updated
        groupSaveGeneration &+= 1
        let generation = groupSaveGeneration
        let previousSave = groupSaveTask
        let save = Task { @MainActor [weak self, groupRepository] in
            _ = await previousSave?.value
            do {
                try await groupRepository.save(updated)
                self?.persistedGroups = updated
                if self?.groupSaveGeneration == generation { self?.errorMessage = nil }
                return true
            } catch {
                if let self, groupSaveGeneration == generation {
                    groups = persistedGroups
                    errorMessage = error.localizedDescription
                }
                return false
            }
        }
        groupSaveTask = save
        let succeeded = await save.value
        if groupSaveGeneration == generation { groupSaveTask = nil }
        return succeeded
    }
}

extension Book {
    /// 用户在「编辑书籍信息」里换过的封面优先，其次书源封面。
    var displayCoverUrl: String? {
        if let custom = customCoverUrl?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty { return custom }
        return coverUrl
    }

    /// 用户改过的简介优先。
    var displayIntro: String? {
        if let custom = customIntro?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty { return custom }
        return intro
    }
}
