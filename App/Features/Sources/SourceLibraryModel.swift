#if SWIFT_PACKAGE
import LegadoCore
#endif
import Foundation
import SwiftUI

final class SourceImportFile: @unchecked Sendable {
    let url: URL
    private let hasSecurityScope: Bool

    init(url: URL) {
        self.url = url
        hasSecurityScope = url.startAccessingSecurityScopedResource()
    }

    deinit {
        if hasSecurityScope { url.stopAccessingSecurityScopedResource() }
    }

    func read() throws -> Data {
        var coordinationError: NSError?
        var result: Result<Data, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readableURL in
            result = Result {
                guard try readableURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory != true else {
                    throw BookSourceImportError.invalidDocument("请选择书源 JSON 文件，而不是文件夹。")
                }
                return try Data(contentsOf: readableURL)
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw CocoaError(.fileReadUnknown) }
        return try result.get()
    }
}

@MainActor
final class SourceLibraryModel: ObservableObject {
    @Published private(set) var sources: [BookSource] = []
    @Published private(set) var isWorking = false
    @Published var notice: Notice?
    @Published var pendingImport: PendingImport?

    struct PendingImport: Identifiable, Sendable {
        struct Item: Identifiable, Sendable {
            let source: BookSource
            let existing: BookSource?
            var id: String { source.id }

            var state: String {
                guard let existing else { return "新增" }
                return source.lastUpdateTime > existing.lastUpdateTime ? "更新" : "已有"
            }
        }

        struct InvalidItem: Identifiable, Sendable {
            let id = UUID()
            let source: BookSource
            let issues: [BookSourceIssue]
        }

        let id = UUID()
        let items: [Item]
        let invalidItems: [InvalidItem]

        var validCount: Int { items.count }
        var invalidCount: Int { invalidItems.count }
        var totalCount: Int { validCount + invalidCount }
    }

    struct Notice: Identifiable {
        enum Kind { case success, error }

        let id = UUID()
        let kind: Kind
        let title: String
        let detail: String
    }

    private let repository: any BookSourceRepository
    private let importer = BookSourceImporter()
    private let importTransport: any HTTPTransport
    private var saveTask: Task<Result<Void, Error>, Never>?
    private var saveGeneration = 0
    private var persistedSources: [BookSource] = []

    /// 用户手动建立的分组（可以暂时没有书源）与被隐藏的分组，保存在本机。
    @Published private(set) var customGroups: [String] = SourceGroupPreferences.customGroups
    @Published private(set) var hiddenGroups: Set<String> = SourceGroupPreferences.hiddenGroups

    /// 全部分组：书源里出现过的分组 + 手动建立的空分组。
    var groups: [String] {
        var seen = Set<String>()
        let all = (sources.flatMap(\.groups) + customGroups).filter { !$0.isEmpty && seen.insert($0).inserted }
        return all.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// 未隐藏的分组，用于书源页分组栏和搜索范围。
    var visibleGroups: [String] { groups.filter { !hiddenGroups.contains($0) } }

    func sourceCount(inGroup group: String) -> Int {
        sources.filter { $0.hasGroup(group) }.count
    }

    /// 新建一个空分组；之后可以手动把书源移进来。
    @discardableResult
    func createGroup(_ name: String) -> String? {
        guard let value = BookSource.parseGroups(name).first else { return nil }
        if !groups.contains(value) {
            customGroups.append(value)
            SourceGroupPreferences.customGroups = customGroups
        }
        notice = .init(kind: .success, title: "已创建分组 \(value)", detail: "")
        return value
    }

    func setGroupHidden(_ group: String, hidden: Bool) {
        if hidden { hiddenGroups.insert(group) } else { hiddenGroups.remove(group) }
        SourceGroupPreferences.hiddenGroups = hiddenGroups
    }

    /// 把书源移到某个分组（每个书源只属于一个分组）；nil 表示移出分组。
    func moveSources(_ sourceIDs: Set<String>, toGroup group: String?) async {
        guard !sourceIDs.isEmpty else { return }
        let value = group.flatMap { BookSource.parseGroups($0).first }
        if let value, !groups.contains(value) {
            customGroups.append(value)
            SourceGroupPreferences.customGroups = customGroups
        }
        var updated = sources
        for index in updated.indices where sourceIDs.contains(updated[index].id) {
            updated[index].bookSourceGroup = value
        }
        await persist(updated, successTitle: value.map { "已移到分组 \($0)" } ?? "已移出分组")
    }

    /// 导入的书源只保留分组里的第一个词（如「书旗,小说,APP,AI」只建「书旗」分组）。
    nonisolated static func primaryGroupOnly(_ source: BookSource) -> BookSource {
        var value = source
        value.bookSourceGroup = BookSource.parseGroups(source.bookSourceGroup).first
        return value
    }

    /// 一次性整理已导入的书源：多标签分组只保留第一个词。
    private func migratePrimaryGroupsIfNeeded() async {
        let key = "sourceGroups.primaryOnly.v1"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        guard sources.contains(where: { $0.groups.count > 1 }) else { return }
        await persist(sources.map(Self.primaryGroupOnly), successTitle: nil)
    }

    init(repository: any BookSourceRepository, importTransport: any HTTPTransport = URLSessionHTTPTransport.shared) {
        self.repository = repository
        self.importTransport = importTransport
    }

    static func live() -> SourceLibraryModel {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Legado", isDirectory: true)
        let legacy = base.appendingPathComponent("book-sources.json")
        guard let database = try? LegadoDatabase(url: base.appendingPathComponent("legado.sqlite3")) else {
            return SourceLibraryModel(repository: FileBookSourceRepository(fileURL: legacy))
        }
        return SourceLibraryModel(repository: SQLiteBookSourceRepository(database: database, legacyFileURL: legacy))
    }

    static func demo(sources: [BookSource]) -> SourceLibraryModel {
        SourceLibraryModel(repository: InMemoryBookSourceRepository(sources: sources))
    }

    func load() async {
        guard sources.isEmpty else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            sources = try await repository.load()
            persistedSources = sources
            await migratePrimaryGroupsIfNeeded()
        } catch {
            notice = .init(kind: .error, title: "无法读取书源", detail: error.localizedDescription)
        }
    }

    func importFiles(_ urls: [URL]) async {
        isWorking = true
        defer { isWorking = false }
        var combined = sources
        var inserted = 0
        var replaced = 0
        var warnings = 0
        do {
            for url in urls {
                let granted = url.startAccessingSecurityScopedResource()
                defer { if granted { url.stopAccessingSecurityScopedResource() } }
                let result = try await Task.detached(priority: .userInitiated) { [importer, existing = combined] in
                    try importer.prepare(data: Data(contentsOf: url), existing: existing, duplicatePolicy: .replace)
                }.value
                combined = result.sources.map(Self.primaryGroupOnly)
                inserted += result.inserted
                replaced += result.replaced
                warnings += result.warnings.count
            }
            try await saveSources(combined)
            notice = .init(
                kind: .success,
                title: "书源导入完成",
                detail: "新增 \(inserted) 个，覆盖 \(replaced) 个，警告 \(warnings) 条"
            )
        } catch {
            notice = .init(kind: .error, title: "书源导入失败", detail: error.localizedDescription)
        }
    }

    func importText(_ text: String) async { await importRemoteURL(text) }

    func importRemoteURL(_ value: String) async {
        isWorking = true
        defer { isWorking = false }
        do {
            var budget = 100
            let batch = try await resolveImport(value, depth: 0, visited: [], budget: &budget)
            guard batch.invalidItems.isEmpty else {
                throw BookSourceImportError.invalidSources(batch.invalidItems.flatMap(\.issues))
            }
            try await applyImport(JSONEncoder().encode(batch.sources), successTitle: "书源导入完成")
        } catch {
            notice = .init(kind: .error, title: "书源导入失败", detail: error.localizedDescription)
        }
    }

    func remove(at offsets: IndexSet) async {
        var updated = sources
        updated.remove(atOffsets: offsets)
        await persist(updated, successTitle: "已删除书源")
    }

    func remove(sourceIDs: Set<String>) async {
        guard !sourceIDs.isEmpty else { return }
        await persist(sources.filter { !sourceIDs.contains($0.id) }, successTitle: "已删除 \(sourceIDs.count) 个书源")
    }

    func setEnabled(_ enabled: Bool, for sourceID: String) async {
        var updated = sources
        guard let index = updated.firstIndex(where: { $0.id == sourceID }) else { return }
        updated[index].enabled = enabled
        await persist(updated, successTitle: nil)
    }

    func applySilentSubscription(_ data: Data) async throws {
        let incoming = try await Task.detached(priority: .userInitiated) { [importer] in
            try importer.decode(data)
        }.value
        var updated = sources
        for var source in incoming {
            if let index = updated.firstIndex(where: { $0.bookSourceUrl == source.bookSourceUrl }) {
                guard updated[index].lastUpdateTime < source.lastUpdateTime else { continue }
                source.bookSourceGroup = updated[index].bookSourceGroup
                updated[index] = source
            } else { updated.append(source) }
        }
        try await saveSources(updated)
    }

    func previewFiles(_ urls: [URL]) async {
        await previewPickedFiles(urls.map { SourceImportFile(url: $0) })
    }

    func previewPickedFiles(_ files: [SourceImportFile]) async {
        isWorking = true
        defer { isWorking = false }
        do {
            var incoming: [String: BookSource] = [:]
            var invalidItems: [PendingImport.InvalidItem] = []
            for file in files {
                let data = try await Task.detached(priority: .userInitiated) { [importer] in
                    try importer.normalizedData(file.read())
                }.value
                var budget = 100
                let batch = try await resolveImport(String(decoding: data, as: UTF8.self), depth: 0, visited: [], budget: &budget)
                invalidItems.append(contentsOf: batch.invalidItems)
                for source in batch.sources {
                    incoming[source.id] = source
                }
            }
            stage(Array(incoming.values), invalidItems: invalidItems)
        } catch {
            notice = .init(kind: .error, title: "书源导入失败", detail: error.localizedDescription)
        }
    }

    func previewText(_ text: String) async { await previewInput(text) }

    func previewRemoteURL(_ value: String) async { await previewInput(value) }

    func previewInput(_ value: String) async {
        isWorking = true
        defer { isWorking = false }
        do {
            var budget = 100
            let batch = try await resolveImport(value, depth: 0, visited: [], budget: &budget)
            stage(batch.sources, invalidItems: batch.invalidItems)
        } catch {
            notice = .init(kind: .error, title: "书源导入失败", detail: error.localizedDescription)
        }
    }

    private nonisolated func resolveImport(_ value: String, depth: Int, visited: Set<String>, budget: inout Int) async throws -> (
        sources: [BookSource], invalidItems: [PendingImport.InvalidItem]
    ) {
        guard depth < 8 else { throw BookSourceImportError.invalidDocument("订阅清单嵌套过深") }
        let input = try RuleImportInput.parse(value)
        let data: Data
        var visited = visited
        switch input {
        case .json(let json): data = Data(json.utf8)
        case .remote(let url, _):
            guard budget > 0 else { throw BookSourceImportError.invalidDocument("订阅清单的总链接数超过 100") }
            budget -= 1
            guard visited.insert(url.absoluteString).inserted else {
                throw BookSourceImportError.invalidDocument("订阅清单出现循环链接")
            }
            let response = try await importTransport.data(for: input.request()!)
            guard (200...299).contains(response.statusCode) else {
                throw BookSourceImportError.invalidDocument("服务器返回 HTTP \(response.statusCode)")
            }
            data = response.data
        }
        let normalized = try importer.normalizedData(data)
        if case .array(let urls) = (try JSONValue.decode(data: normalized))["sourceUrls"] {
            guard !urls.isEmpty, urls.count <= 100 else { throw BookSourceImportError.invalidDocument("订阅清单需包含 1–100 个链接") }
            var sources: [BookSource] = []
            var invalid: [PendingImport.InvalidItem] = []
            for item in urls {
                guard case .string(let url) = item else { throw BookSourceImportError.invalidDocument("sourceUrls 必须是链接数组") }
                let batch = try await resolveImport(url, depth: depth + 1, visited: visited, budget: &budget)
                sources += batch.sources
                invalid += batch.invalidItems
            }
            return (sources, invalid)
        }
        return try validatedSources(from: normalized)
    }

    func cancelPendingImport() { pendingImport = nil }

    func commitPendingImport(
        selectedIDs: Set<String>,
        keepOriginalName: Bool,
        keepOriginalGroup: Bool,
        keepOriginalEnabled: Bool,
        customGroup: String?,
        addCustomGroup: Bool
    ) async {
        guard let pendingImport else { return }
        var updated = sources
        var inserted = 0
        var replaced = 0
        for item in pendingImport.items where selectedIDs.contains(item.id) {
            var source = Self.primaryGroupOnly(item.source)
            if let existing = item.existing {
                if keepOriginalName { source.bookSourceName = existing.bookSourceName }
                if keepOriginalGroup { source.bookSourceGroup = existing.bookSourceGroup }
                if keepOriginalEnabled {
                    source.enabled = existing.enabled
                    source.enabledExplore = existing.enabledExplore
                }
                source.customOrder = existing.customOrder
            }
            if let customGroup, let value = BookSource.parseGroups(customGroup).first {
                // 每个书源只进一个分组：填写了自定义分组就直接放进该分组。
                source.bookSourceGroup = value
            }
            if let index = updated.firstIndex(where: { $0.id == source.id }) {
                updated[index] = source
                replaced += 1
            } else {
                updated.append(source)
                inserted += 1
            }
        }
        do {
            try await saveSources(updated)
            self.pendingImport = nil
            notice = .init(
                kind: .success,
                title: "书源导入完成",
                detail: "新增 \(inserted) 个，更新 \(replaced) 个"
            )
        } catch {
            notice = .init(kind: .error, title: "保存失败", detail: error.localizedDescription)
            return
        }
    }

    func setExploreEnabled(_ enabled: Bool, for sourceID: String) async {
        var updated = sources
        guard let index = updated.firstIndex(where: { $0.id == sourceID }) else { return }
        updated[index].enabledExplore = enabled
        await persist(updated, successTitle: nil)
    }

    func saveSource(_ source: BookSource, replacing oldSourceID: String? = nil) async -> Bool {
        let errors = BookSourceValidator.validate(source).filter { $0.severity == .error }
        guard errors.isEmpty else {
            notice = .init(kind: .error, title: "书源无效", detail: errors.map(\.message).joined(separator: "；"))
            return false
        }
        let oldSourceID = oldSourceID ?? source.id
        var updated = sources
        if updated.contains(where: { $0.id == oldSourceID }) {
            if source.id != oldSourceID, updated.contains(where: { $0.id == source.id }) {
                notice = .init(kind: .error, title: "地址冲突", detail: "该地址已有书源，请使用导入预览选择更新。")
                return false
            }
            guard let replacement = updated.firstIndex(where: { $0.id == oldSourceID }) else { return false }
            updated[replacement] = source
        } else if let index = updated.firstIndex(where: { $0.id == source.id }) {
            updated[index] = source
        } else {
            updated.append(source)
        }
        return await persist(updated, successTitle: "书源已保存")
    }

    func setEnabled(_ enabled: Bool, for sourceIDs: Set<String>) async {
        guard !sourceIDs.isEmpty else { return }
        var updated = sources
        for index in updated.indices where sourceIDs.contains(updated[index].id) {
            updated[index].enabled = enabled
        }
        await persist(updated, successTitle: enabled ? "已批量启用" : "已批量停用")
    }

    func addGroup(_ group: String, to sourceIDs: Set<String>) async {
        let values = BookSource.parseGroups(group)
        guard !values.isEmpty, !sourceIDs.isEmpty else { return }
        var updated = sources
        for index in updated.indices where sourceIDs.contains(updated[index].id) {
            updated[index].addGroups(values.joined(separator: ","))
        }
        await persist(updated, successTitle: "已加入分组 \(values.joined(separator: "、"))")
    }

    func removeGroup(_ group: String, from sourceIDs: Set<String>) async {
        guard !sourceIDs.isEmpty else { return }
        var updated = sources
        for index in updated.indices where sourceIDs.contains(updated[index].id) {
            updated[index].removeGroups(group)
        }
        await persist(updated, successTitle: "已移出分组")
    }

    func renameGroup(_ oldValue: String, to newValue: String) async {
        guard let renamed = BookSource.parseGroups(newValue).first else { return }
        customGroups = customGroups.map { $0 == oldValue ? renamed : $0 }
        SourceGroupPreferences.customGroups = customGroups
        if hiddenGroups.remove(oldValue) != nil {
            hiddenGroups.insert(renamed)
            SourceGroupPreferences.hiddenGroups = hiddenGroups
        }
        var updated = sources
        for index in updated.indices where updated[index].hasGroup(oldValue) {
            updated[index].replaceGroup(oldValue, with: newValue)
        }
        await persist(updated, successTitle: "分组已重命名")
    }

    func deleteGroup(_ group: String) async {
        customGroups.removeAll { $0 == group }
        SourceGroupPreferences.customGroups = customGroups
        if hiddenGroups.remove(group) != nil { SourceGroupPreferences.hiddenGroups = hiddenGroups }
        var updated = sources
        for index in updated.indices where updated[index].hasGroup(group) {
            updated[index].removeGroups(group)
        }
        await persist(updated, successTitle: "已删除分组 \(group)")
    }

    func handleDeepLink(_ url: URL) async {
        if url.isFileURL {
            await previewFiles([url])
            return
        }
        await previewInput(url.absoluteString)
    }

    @discardableResult
    private func persist(_ updated: [BookSource], successTitle: String?) async -> Bool {
        do {
            try await saveSources(updated)
            if let successTitle {
                notice = .init(kind: .success, title: successTitle, detail: "")
            }
            return true
        } catch {
            notice = .init(kind: .error, title: "保存失败", detail: error.localizedDescription)
            return false
        }
    }

    private func applyImport(_ data: Data, successTitle: String) async throws {
        let result = try await Task.detached(priority: .userInitiated) { [importer, existing = sources] in
            try importer.prepare(data: data, existing: existing, duplicatePolicy: .replace)
        }.value
        try await saveSources(result.sources.map(Self.primaryGroupOnly))
        notice = .init(
            kind: .success,
            title: successTitle,
            detail: "新增 \(result.inserted) 个，覆盖 \(result.replaced) 个，警告 \(result.warnings.count) 条"
        )
    }

    private func saveSources(_ updated: [BookSource]) async throws {
        sources = updated
        saveGeneration &+= 1
        let generation = saveGeneration
        let previousSave = saveTask
        let task = Task { @MainActor [weak self, repository] () -> Result<Void, Error> in
            _ = await previousSave?.value
            do {
                try await repository.save(updated)
                self?.persistedSources = updated
                return .success(())
            } catch {
                if let self, saveGeneration == generation { sources = persistedSources }
                return .failure(error)
            }
        }
        saveTask = task
        let result = await task.value
        if saveGeneration == generation { saveTask = nil }
        try result.get()
    }

    private nonisolated func validatedSources(from data: Data) throws -> (
        sources: [BookSource],
        invalidItems: [PendingImport.InvalidItem]
    ) {
        let result = try importer.inspect(data)
        return (result.sources, result.rejected.map { .init(source: $0.source, issues: $0.issues) })
    }

    private func stage(
        _ incoming: [BookSource],
        invalidItems: [PendingImport.InvalidItem] = []
    ) {
        let existingByID = Dictionary(sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let unique = incoming.reduce(into: [String: BookSource]()) { $0[$1.id] = $1 }
        pendingImport = .init(items: Array(unique.values)
            .sorted { $0.bookSourceName.localizedStandardCompare($1.bookSourceName) == .orderedAscending }
            .map { .init(source: $0, existing: existingByID[$0.id]) },
            invalidItems: invalidItems)
    }
}


/// 书源分组的本机偏好：手动建立的分组与隐藏的分组。
enum SourceGroupPreferences {
    private static let customKey = "sourceGroups.custom.v1"
    private static let hiddenKey = "sourceGroups.hidden.v1"

    static var customGroups: [String] {
        get { UserDefaults.standard.stringArray(forKey: customKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: customKey) }
    }

    static var hiddenGroups: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: hiddenKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: hiddenKey) }
    }
}
