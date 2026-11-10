import SwiftUI
#if SWIFT_PACKAGE
import LegadoCore
#endif

struct ReaderParagraph: Identifiable, Equatable {
    let id: Int
    let text: String
}

struct ReaderScrollChapter: Identifiable, Equatable {
    let id: Int
    let title: String
    let content: String
    var error: String? = nil
}

enum ReaderPositionResolver {
    static func renderedLocation(position: Int, prefixLength: Int, renderedLength: Int) -> Int {
        let lastLocation = max(renderedLength, 1) - 1
        let prefix = min(max(prefixLength, 0), lastLocation)
        return prefix + min(max(position, 0), lastLocation - prefix)
    }
}

@MainActor
final class ReaderViewModel: ObservableObject {
    @Published private(set) var isLoading = false
    @Published private(set) var title: String
    @Published private(set) var content = ""
    @Published private(set) var diagnostics: [RuleDiagnostic] = []
    @Published private(set) var currentIndex: Int
    @Published private(set) var chapterLoadGeneration = 0
    @Published private(set) var paragraphs: [ReaderParagraph] = []
    @Published private(set) var requestedPosition: Int
    @Published private(set) var loadedFromCache = false
    @Published private(set) var hasLoadedCurrentChapter = false
    @Published private(set) var previousTitle = ""
    @Published private(set) var previousContent = ""
    @Published private(set) var continuationTitle = ""
    @Published private(set) var continuationContent = ""
    @Published private(set) var isPreviousWindowReady = false
    @Published private(set) var isContinuationWindowReady = false
    @Published private(set) var scrollChapters: [ReaderScrollChapter] = []
    @Published private(set) var scrollRevision = 0
    @Published private(set) var isLoadingScrollAhead = false
    @Published private(set) var isLoadingScrollBehind = false

    @Published private(set) var book: Book
    private(set) var chapters: [BookChapter]
    private var source: BookSource?
    private let localService: LocalBookService
    private let sanitizer = ContentSanitizer()
    private let contentCoordinator: ChapterContentCoordinator
    private var preloadTask: Task<Void, Never>?
    private var preloadAnchor: Int?
    /// Indices the current preload window covers, for tests and diagnostics.
    private(set) var preloadWindow: [Int] = []
    private var demoChapterContent: String?
    private var previousLoadedIndex: Int?
    private var continuationLoadedIndex: Int?
    @Published private(set) var scrollRetries: Set<Int> = []
    private var sourceCacheNeedsInvalidation = false
    private var pendingSourceContent: ChapterContentReport?
    /// Processed text of the chapters right before and after the current one,
    /// kept in memory so a page turn across chapters swaps in the next page
    /// at once instead of flashing the "正在打开本章" screen.
    private struct ReadyChapter {
        let url: String
        let title: String
        let content: String
        let usesReplaceRules: Bool
        let fromCache: Bool
    }
    private var readyChapters: [Int: ReadyChapter] = [:]
    private var neighborTask: Task<Void, Never>?
    private var neighborRules: [ReplaceRule] = []

    func bookmarks(at position: Int, in bookmarks: [Bookmark], pageRange: NSRange? = nil) -> [Bookmark] {
        bookmarks.filter { bookmark in
            guard bookmark.bookName == book.name, bookmark.bookAuthor == book.author,
                  bookmark.resolvedChapterIndex(in: chapters) == currentIndex else { return false }
            if bookmark.chapterPosition == max(position, 0) { return true }
            if let pageRange, pageRange.length > 0 {
                return NSLocationInRange(bookmark.chapterPosition, pageRange)
            }
            return false
        }
    }

    func prepareContinuousReading(rules: [ReplaceRule]) async {
        guard hasLoadedCurrentChapter else { return }
        if scrollChapters.isEmpty {
            scrollChapters = [scrollChapterForCurrentContent()]
        }
        async let ahead: Void = extendContinuousReading(direction: 1, rules: rules)
        async let behind: Void = extendContinuousReading(direction: -1, rules: rules)
        _ = await (ahead, behind)
    }

    func extendContinuousReading(direction: Int, rules: [ReplaceRule]) async {
        let initialEdge = direction > 0 ? scrollChapters.last?.id : scrollChapters.first?.id
        guard let initialEdge, readableIndex(from: initialEdge, direction: direction) != nil else { return }
        if direction > 0 {
            guard !isLoadingScrollAhead else { return }
            isLoadingScrollAhead = true
        } else {
            guard !isLoadingScrollBehind else { return }
            isLoadingScrollBehind = true
        }
        let revision = scrollRevision
        defer {
            if revision == scrollRevision {
                if direction > 0 { isLoadingScrollAhead = false }
                else { isLoadingScrollBehind = false }
            }
        }
        for _ in 0..<2 {
            let edge = direction > 0 ? scrollChapters.last?.id : scrollChapters.first?.id
            guard let edge, let index = readableIndex(from: edge, direction: direction) else { return }
            let value = await loadAdjacentChapter(chapters[index], rules: rules)
            guard revision == scrollRevision, !Task.isCancelled else { return }
            // The viewport may have recycled this edge while the request was
            // in flight. Installing its result now would create a chapter gap.
            guard scrollChapters.contains(where: { $0.id == edge }) else { return }
            let chapter = ReaderScrollChapter(
                id: index, title: value.title, content: value.content, error: value.error
            )
            if !scrollChapters.contains(where: { $0.id == index }) {
                scrollChapters.append(chapter)
                scrollChapters.sort { $0.id < $1.id }
            }
        }
    }

    func retryContinuousChapter(index: Int, rules: [ReplaceRule]) async {
        guard chapters.indices.contains(index), !scrollRetries.contains(index) else { return }
        let revision = scrollRevision
        scrollRetries.insert(index)
        defer { if revision == scrollRevision { scrollRetries.remove(index) } }
        let value = await loadAdjacentChapter(chapters[index], rules: rules, forceRefresh: true)
        guard revision == scrollRevision, !Task.isCancelled,
              let slot = scrollChapters.firstIndex(where: { $0.id == index }) else { return }
        scrollChapters[slot] = .init(id: index, title: value.title, content: value.content, error: value.error)
        if currentIndex == index { setContinuousChapter(scrollChapters[slot]) }
    }

    @discardableResult
    func updateContinuousPosition(chapter index: Int) -> Bool {
        guard index != currentIndex,
              let chapter = scrollChapters.first(where: { $0.id == index }) else { return false }
        setContinuousChapter(chapter)
        return true
    }

    func retainContinuousChapters(_ indices: Set<Int>) {
        guard indices.contains(currentIndex) else { return }
        scrollChapters.removeAll { !indices.contains($0.id) }
    }

    private func setContinuousChapter(_ chapter: ReaderScrollChapter) {
        if let source, demoChapterContent == nil { schedulePreload(after: chapter.id, source: source) }
        currentIndex = chapter.id
        title = chapter.title
        content = chapter.content
        paragraphs = Self.makeParagraphs(chapter.content)
        diagnostics = []
        hasLoadedCurrentChapter = true
    }

    private func scrollChapterForCurrentContent() -> ReaderScrollChapter {
        .init(id: currentIndex, title: title, content: content,
              error: currentChapterError)
    }

    private func clearContinuousReading() {
        scrollRevision &+= 1
        scrollChapters = []
        isLoadingScrollAhead = false
        isLoadingScrollBehind = false
        scrollRetries = []
    }

    init(
        book: Book,
        chapters: [BookChapter],
        initialIndex: Int,
        source: BookSource,
        service: any ChapterContentLoading = NetworkBookService(),
        cache: ChapterContentCache = .live()
    ) {
        let resolvedIndex = Self.validIndex(initialIndex, chapters: chapters)
        self.book = book
        self.chapters = chapters
        currentIndex = resolvedIndex
        self.source = source
        localService = .init()
        contentCoordinator = .init(loader: service, cache: cache)
        requestedPosition = resolvedIndex == book.durChapterIndex ? max(book.durChapterPos, 0) : 0
        title = chapters.indices.contains(resolvedIndex) ? chapters[resolvedIndex].title : book.name
    }

    convenience init(demoBook book: Book, chapters: [BookChapter], initialIndex: Int, content: String) {
        self.init(book: book, chapters: chapters, initialIndex: initialIndex)
        self.content = content
        demoChapterContent = content
        paragraphs = Self.makeParagraphs(content)
        hasLoadedCurrentChapter = true
    }

    init(
        book: Book,
        chapters: [BookChapter],
        initialIndex: Int,
        localService: LocalBookService = .init(),
        cache: ChapterContentCache = .live()
    ) {
        let resolvedIndex = Self.validIndex(initialIndex, chapters: chapters)
        self.book = book
        self.chapters = chapters
        currentIndex = resolvedIndex
        source = nil
        self.localService = localService
        contentCoordinator = .init(cache: cache)
        requestedPosition = resolvedIndex == book.durChapterIndex ? max(book.durChapterPos, 0) : 0
        title = chapters.indices.contains(resolvedIndex) ? chapters[resolvedIndex].title : book.name
    }

    var currentChapter: BookChapter? { chapters.indices.contains(currentIndex) ? chapters[currentIndex] : nil }
    var nextChapter: BookChapter? { nextReadableChapter(after: currentIndex) }
    var canGoPrevious: Bool { navigationIndex(direction: -1) != nil }
    var canGoNext: Bool { navigationIndex(direction: 1) != nil }
    var hasPreviousWindow: Bool { previousLoadedIndex != nil }
    var hasContinuationWindow: Bool { continuationLoadedIndex != nil }
    /// 执行书源的段评点击回调（如 showCmt(...)），拿到段评页地址。
    func resolveReviewClick(_ script: String) async -> JavaScriptRuleEvaluator.ClickResolution {
        guard let source else {
            return .init(url: nil, title: nil, error: "这本书没有关联书源，无法执行段评回调")
        }
        let chapter = currentChapter
        let context = RuleExecutionContext(
            baseURL: chapter?.url ?? book.bookUrl,
            source: source,
            book: book,
            chapter: chapter
        )
        return await JavaScriptRuleEvaluator().resolveClick(script, executionContext: context)
    }

    /// 书源网页（showBrowser 打开的段评页）通过 run 桥接回调书源 JS。
    func runSourceBridge(_ script: String) async -> String {
        guard let source else { return #"{"ok":false,"error":"这本书没有关联书源"}"# }
        let chapter = currentChapter
        let context = RuleExecutionContext(
            baseURL: chapter?.url ?? book.bookUrl,
            source: source,
            book: book,
            chapter: chapter
        )
        return await JavaScriptRuleEvaluator().runBridgeCall(script, executionContext: context)
    }

    var canEditContent: Bool { source != nil }
    var usesReplaceRules: Bool { book.readConfig?.useReplaceRule ?? true }
    var currentChapterError: String? {
        guard hasLoadedCurrentChapter, !isLoading,
              currentChapter?.isVolume != true else { return nil }
        return scrollChapters.first(where: { $0.id == currentIndex })?.error
            ?? diagnostics.first(where: { $0.severity == .error })?.message
            ?? (source != nil && content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "当前书源没有返回正文。" : nil)
    }

    func bookForSourceSwitch(position: Int) -> Book {
        var current = book
        current.durChapterIndex = currentIndex
        current.durChapterTitle = currentChapter?.title
        current.durChapterPos = max(position, 0)
        current.totalChapterNum = chapters.count
        return current
    }

    func applySourceSwitch(_ report: BookSourceSwitchReport, source: BookSource) {
        book = report.book
        chapters = report.chapters
        self.source = source
        demoChapterContent = nil
        sourceCacheNeedsInvalidation = true
        discardReadyChapters()
        select(index: Self.validIndex(report.book.durChapterIndex, chapters: chapters), position: report.book.durChapterPos)
        pendingSourceContent = report.verifiedContent
    }

    func load(rules: [ReplaceRule], forceRefresh: Bool = false, prefetchNextChapter: Bool = true) async {
        guard (content.isEmpty || forceRefresh), !isLoading else { return }
        guard let chapter = currentChapter else { return }
        let requestedIndex = currentIndex
        let requestedGeneration = chapterLoadGeneration
        if forceRefresh {
            pendingSourceContent = nil
            discardReadyChapters()
            clearContinuousReading()
            content = ""
            paragraphs = []
            diagnostics = []
            hasLoadedCurrentChapter = false
        }
        isLoading = true
        defer {
            if requestedGeneration == chapterLoadGeneration { isLoading = false }
        }
        let report: ChapterContentReport
        let fromCache: Bool
        if sourceCacheNeedsInvalidation {
            await contentCoordinator.invalidate(bookURL: book.bookUrl)
            guard requestedGeneration == chapterLoadGeneration, !Task.isCancelled else { return }
            sourceCacheNeedsInvalidation = false
        }
        if let demoChapterContent {
            fromCache = true
            report = .init(title: chapter.title, content: demoChapterContent)
        } else if let verified = pendingSourceContent, let source, !forceRefresh {
            pendingSourceContent = nil
            fromCache = false
            report = verified
            await contentCoordinator.saveContent(verified, book: book, chapter: chapter, source: source)
        } else if let source {
            let nextURL = nextReadableChapter(after: requestedIndex)?.url
            let result = await contentCoordinator.load(
                book: book,
                chapter: chapter,
                source: source,
                nextChapterURL: nextURL,
                forceRefresh: forceRefresh
            )
            fromCache = result.loadedFromCache
            report = result.report
        } else {
            fromCache = false
            do {
                report = try await Task.detached { [localService, book, chapter] in
                    try localService.loadContent(book: book, chapter: chapter)
                }.value
            } catch {
                report = .init(diagnostics: [
                    .init(severity: .error, code: "local.read", message: error.localizedDescription, rule: book.bookUrl)
                ])
            }
        }
        guard requestedGeneration == chapterLoadGeneration, !Task.isCancelled else { return }
        loadedFromCache = fromCache
        // Prefetch whether or not this chapter itself came from the cache;
        // otherwise reading a cached chapter stalls on every later one.
        if prefetchNextChapter, demoChapterContent == nil, let source { schedulePreload(after: requestedIndex, source: source) }
        hasLoadedCurrentChapter = true
        var effectiveChapter = chapter
        if let resolvedTitle = report.title { effectiveChapter.title = resolvedTitle }
        let processed = sanitizer.process(
            book: book,
            chapter: effectiveChapter,
            content: report.content,
            rules: usesReplaceRules ? rules : []
        )
        title = processed.title
        content = processed.content
        paragraphs = Self.makeParagraphs(processed.content)
        diagnostics = report.diagnostics + processed.diagnostics
        neighborRules = rules
        prepareNeighborChapters()
    }

    /// Whether the chapter at `index` can be shown without waiting.
    func isChapterReady(_ index: Int) -> Bool {
        guard let ready = readyChapters[index], chapters.indices.contains(index) else { return false }
        return ready.url == chapters[index].url && ready.usesReplaceRules == usesReplaceRules
    }

    private func discardReadyChapters() {
        neighborTask?.cancel()
        neighborTask = nil
        readyChapters = [:]
    }

    /// Loads the previous and next readable chapters into memory (from the
    /// on-disk cache when they are there, the source otherwise).
    func prepareNeighborChapters() {
        guard demoChapterContent == nil else { return }
        let targets = [
            readableIndex(from: currentIndex, direction: 1),
            readableIndex(from: currentIndex, direction: -1)
        ].compactMap { $0 }
        readyChapters = readyChapters.filter { targets.contains($0.key) && isChapterReady($0.key) }
        let missing = targets.filter { readyChapters[$0] == nil }
        guard !missing.isEmpty else { return }
        neighborTask?.cancel()
        let rules = neighborRules
        neighborTask = Task { [weak self] in
            for index in missing {
                guard let self, !Task.isCancelled, self.chapters.indices.contains(index) else { return }
                let chapter = self.chapters[index]
                let usesRules = self.usesReplaceRules
                var fromCache = false
                let value: (title: String, content: String, error: String?)
                if let source = self.source {
                    let result = await self.contentCoordinator.load(
                        book: self.book,
                        chapter: chapter,
                        source: source,
                        nextChapterURL: self.nextReadableChapter(after: chapter.index)?.url,
                        forceRefresh: false
                    )
                    fromCache = result.loadedFromCache
                    var effectiveChapter = chapter
                    if let resolvedTitle = result.report.title { effectiveChapter.title = resolvedTitle }
                    let processed = self.sanitizer.process(
                        book: self.book,
                        chapter: effectiveChapter,
                        content: result.report.content,
                        rules: usesRules ? rules : []
                    )
                    let error = (result.report.diagnostics + processed.diagnostics).first(where: { $0.severity == .error })?.message
                    value = (processed.title, processed.content, error)
                } else {
                    value = await self.loadAdjacentChapter(chapter, rules: rules)
                }
                guard !Task.isCancelled,
                      value.error == nil,
                      !value.content.isEmpty,
                      self.chapters.indices.contains(index),
                      self.chapters[index].url == chapter.url,
                      self.usesReplaceRules == usesRules else { continue }
                self.readyChapters[index] = ReadyChapter(
                    url: chapter.url,
                    title: value.title,
                    content: value.content,
                    usesReplaceRules: usesRules,
                    fromCache: fromCache
                )
            }
        }
    }

    func prepareAdjacentWindows() {
        let previousIndex = navigationIndex(direction: -1)
        if previousLoadedIndex != previousIndex {
            previousLoadedIndex = previousIndex
            previousTitle = previousIndex.map { chapters[$0].title } ?? ""
            previousContent = ""
            isPreviousWindowReady = false
        }
        let nextIndex = navigationIndex(direction: 1)
        if continuationLoadedIndex != nextIndex {
            continuationLoadedIndex = nextIndex
            continuationTitle = nextIndex.map { chapters[$0].title } ?? ""
            continuationContent = ""
            isContinuationWindowReady = false
        }
    }

    func loadAdjacentChapters(rules: [ReplaceRule]) async {
        prepareAdjacentWindows()
        let requestedIndex = currentIndex
        let requestedGeneration = chapterLoadGeneration
        let previousIndex = previousLoadedIndex
        let nextIndex = continuationLoadedIndex
        let needsPrevious = previousIndex != nil && !isPreviousWindowReady
        let needsNext = nextIndex != nil && !isContinuationWindowReady

        async let previousValue: (title: String, content: String, error: String?)? = needsPrevious
            ? loadAdjacentChapter(chapters[previousIndex!], rules: rules)
            : nil
        async let nextValue: (title: String, content: String, error: String?)? = needsNext
            ? loadAdjacentChapter(chapters[nextIndex!], rules: rules)
            : nil
        let resolvedNext = await nextValue
        guard requestedGeneration == chapterLoadGeneration, requestedIndex == currentIndex, !Task.isCancelled else { return }
        if continuationLoadedIndex == nextIndex, needsNext {
            continuationTitle = resolvedNext?.title ?? nextIndex.map { chapters[$0].title } ?? ""
            continuationContent = resolvedNext?.content ?? ""
            isContinuationWindowReady = true
        }
        let resolvedPrevious = await previousValue
        guard requestedGeneration == chapterLoadGeneration, requestedIndex == currentIndex, !Task.isCancelled else { return }
        if previousLoadedIndex == previousIndex, needsPrevious {
            previousTitle = resolvedPrevious?.title ?? previousIndex.map { chapters[$0].title } ?? ""
            previousContent = resolvedPrevious?.content ?? ""
            isPreviousWindowReady = true
        }
    }

    private func loadAdjacentChapter(
        _ chapter: BookChapter,
        rules: [ReplaceRule],
        forceRefresh: Bool = false
    ) async -> (title: String, content: String, error: String?) {
        let report: ChapterContentReport
        if let demoChapterContent {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-uiScrollRegression") {
                try? await Task.sleep(nanoseconds: 80_000_000)
            }
            #endif
            report = .init(title: chapter.title, content: demoChapterContent)
        } else if let source {
            report = await contentCoordinator.load(
                book: book,
                chapter: chapter,
                source: source,
                nextChapterURL: nextReadableChapter(after: chapter.index)?.url,
                forceRefresh: forceRefresh
            ).report
        } else {
            do {
                report = try await Task.detached { [localService, book, chapter] in
                    try localService.loadContent(book: book, chapter: chapter)
                }.value
            } catch {
                return (chapter.title, "", error.localizedDescription)
            }
        }
        var effectiveChapter = chapter
        if let resolvedTitle = report.title { effectiveChapter.title = resolvedTitle }
        let processed = sanitizer.process(
            book: book,
            chapter: effectiveChapter,
            content: report.content,
            rules: usesReplaceRules ? rules : []
        )
        let error = (report.diagnostics + processed.diagnostics).first(where: { $0.severity == .error })?.message
            ?? (processed.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && source != nil && !chapter.isVolume
                ? "当前书源没有返回正文。" : nil)
        return (processed.title, processed.content, error)
    }

    func saveEditedContent(_ value: String) async throws {
        guard let chapter = currentChapter, source != nil else { return }
        try await contentCoordinator.saveEditedContent(book: book, chapter: chapter, title: title, content: value)
        content = value
        paragraphs = Self.makeParagraphs(value)
        loadedFromCache = true
        if let slot = scrollChapters.firstIndex(where: { $0.id == currentIndex }) {
            scrollChapters[slot] = scrollChapterForCurrentContent()
        }
    }

    func nextSpeechContent(rules: [ReplaceRule]) async -> String? {
        guard let chapter = nextReadableChapter(after: currentIndex) else { return nil }
        let report: ChapterContentReport
        if let source {
            report = await contentCoordinator.load(
                book: book,
                chapter: chapter,
                source: source,
                nextChapterURL: nextReadableChapter(after: chapter.index)?.url
            ).report
        } else {
            do {
                report = try await Task.detached { [localService, book, chapter] in
                    try localService.loadContent(book: book, chapter: chapter)
                }.value
            } catch {
                return nil
            }
        }
        var effectiveChapter = chapter
        if let resolvedTitle = report.title { effectiveChapter.title = resolvedTitle }
        let value = sanitizer.process(
            book: book,
            chapter: effectiveChapter,
            content: report.content,
            rules: usesReplaceRules ? rules : []
        ).content
        return value.isEmpty ? nil : value
    }

    @discardableResult
    func toggleReplaceRules(position: Int? = nil) -> Book {
        var config = book.readConfig ?? BookReadConfig()
        config.useReplaceRule = !usesReplaceRules
        book.readConfig = config
        discardReadyChapters()
        content = ""
        pendingSourceContent = nil
        paragraphs = []
        diagnostics = []
        loadedFromCache = false
        hasLoadedCurrentChapter = false
        clearAdjacentChapters()
        if let position { requestedPosition = max(position, 0) }
        isLoading = false
        chapterLoadGeneration &+= 1
        return book
    }

    @discardableResult
    func useGlobalPageAnimation() -> Book {
        var config = book.readConfig ?? BookReadConfig()
        config.pageAnim = -1
        book.readConfig = config
        return book
    }

    @discardableResult
    func setTTSEngine(_ value: String?) -> Book {
        var config = book.readConfig ?? BookReadConfig()
        config.ttsEngine = value
        book.readConfig = config
        return book
    }

    func goPrevious(position: Int = 0) { if let value = navigationIndex(direction: -1) { select(index: value, position: position) } }
    func goNext(position: Int = 0) { if let value = navigationIndex(direction: 1) { select(index: value, position: position) } }

    func promoteContinuation(position: Int) {
        guard let value = navigationIndex(direction: 1), hasContinuationWindow else {
            return
        }
        let oldIndex = currentIndex
        let oldTitle = title
        let oldContent = content
        let promotedContentResolved = isContinuationWindowReady
        if let source, demoChapterContent == nil { schedulePreload(after: value, source: source) }
        currentIndex = value
        title = continuationTitle.isEmpty ? chapters[value].title : continuationTitle
        content = continuationContent
        paragraphs = Self.makeParagraphs(continuationContent)
        diagnostics = []
        requestedPosition = max(position, 0)
        loadedFromCache = promotedContentResolved
        hasLoadedCurrentChapter = promotedContentResolved
        previousLoadedIndex = oldIndex
        previousTitle = oldTitle
        previousContent = oldContent
        isPreviousWindowReady = true
        continuationLoadedIndex = nil
        continuationTitle = ""
        continuationContent = ""
        isContinuationWindowReady = false
        isLoading = false
        chapterLoadGeneration &+= 1
    }

    func promotePrevious(position: Int) {
        guard let value = navigationIndex(direction: -1), hasPreviousWindow else { return }
        let oldIndex = currentIndex
        let oldTitle = title
        let oldContent = content
        let promotedContentResolved = isPreviousWindowReady
        if let source, demoChapterContent == nil { schedulePreload(after: value, source: source) }
        currentIndex = value
        title = previousTitle.isEmpty ? chapters[value].title : previousTitle
        content = previousContent
        paragraphs = Self.makeParagraphs(previousContent)
        diagnostics = []
        requestedPosition = max(position, 0)
        loadedFromCache = promotedContentResolved
        hasLoadedCurrentChapter = promotedContentResolved
        continuationLoadedIndex = oldIndex
        continuationTitle = oldTitle
        continuationContent = oldContent
        isContinuationWindowReady = true
        previousLoadedIndex = nil
        previousTitle = ""
        previousContent = ""
        isPreviousWindowReady = false
        isLoading = false
        chapterLoadGeneration &+= 1
    }

    func select(index: Int, position: Int = 0) {
        guard chapters.indices.contains(index), !chapters[index].isVolume else { return }
        if index != currentIndex {
            cancelPreload()
            // Keep the chapter being left in memory so turning straight back
            // is an instant, animated page turn rather than a reload.
            if hasLoadedCurrentChapter, !content.isEmpty, pendingSourceContent == nil,
               chapters.indices.contains(currentIndex) {
                readyChapters[currentIndex] = ReadyChapter(
                    url: chapters[currentIndex].url,
                    title: title,
                    content: content,
                    usesReplaceRules: usesReplaceRules,
                    fromCache: loadedFromCache
                )
            }
        }
        let ready = isChapterReady(index) && pendingSourceContent == nil ? readyChapters[index] : nil
        currentIndex = index
        pendingSourceContent = nil
        requestedPosition = max(position, 0)
        clearAdjacentChapters()
        isLoading = false
        chapterLoadGeneration &+= 1
        if let ready {
            // Swap in the prepared chapter in the same update: the reader
            // never shows an empty "loading" page between two chapters.
            title = ready.title
            content = ready.content
            paragraphs = Self.makeParagraphs(ready.content)
            diagnostics = []
            loadedFromCache = ready.fromCache
            hasLoadedCurrentChapter = true
            if let source { schedulePreload(after: index, source: source) }
            prepareNeighborChapters()
            return
        }
        title = chapters[index].title
        content = ""
        paragraphs = []
        diagnostics = []
        loadedFromCache = false
        hasLoadedCurrentChapter = false
    }

    private func clearAdjacentChapters() {
        clearContinuousReading()
        previousLoadedIndex = nil
        previousTitle = ""
        previousContent = ""
        isPreviousWindowReady = false
        continuationLoadedIndex = nil
        continuationTitle = ""
        continuationContent = ""
        isContinuationWindowReady = false
    }

    func paragraphID(at position: Int) -> Int? {
        paragraphs.last(where: { $0.id <= position })?.id ?? paragraphs.first?.id
    }

    /// Whether the chapter a page turn in `direction` lands on is in memory.
    func isNeighborReady(direction: Int) -> Bool {
        navigationIndex(direction: direction).map(isChapterReady) ?? false
    }

    /// Waits (briefly) for the neighbouring chapter to be prepared, so the
    /// chapter change can animate like any other page turn.
    func waitForNeighbor(direction: Int, timeout: TimeInterval = 4) async -> Bool {
        guard let index = navigationIndex(direction: direction) else { return false }
        if isChapterReady(index) { return true }
        if neighborTask == nil || readyChapters[index] == nil { prepareNeighborChapters() }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 40_000_000)
            if Task.isCancelled { return false }
            if isChapterReady(index) { return true }
        }
        return false
    }

    private func navigationIndex(direction: Int) -> Int? {
        readableIndex(from: currentIndex, direction: direction)
    }

    private func readableIndex(from index: Int, direction: Int) -> Int? {
        var value = index + direction
        while chapters.indices.contains(value) {
            if !chapters[value].isVolume { return value }
            value += direction
        }
        return nil
    }

    private func nextReadableChapter(after index: Int) -> BookChapter? {
        var value = index + 1
        while chapters.indices.contains(value) {
            if !chapters[value].isVolume { return chapters[value] }
            value += 1
        }
        return nil
    }

    /// Stops the running preload window (leaving the reader or jumping
    /// elsewhere). A chapter request already shared with the foreground
    /// keeps running for the foreground.
    func cancelPreload() {
        preloadTask?.cancel()
        preloadTask = nil
        preloadAnchor = nil
        preloadWindow = []
    }

    private func schedulePreload(after index: Int, source: BookSource) {
        let count = ApplicationSettingsStore.shared.settings.prefetchChapters
        // Readable chapters only: volume headings are skipped by the planner,
        // and the window shrinks naturally near the end of the book.
        let jobs = ChapterCachePlanner.plan(chapters: chapters, startIndex: index + 1, limit: count)
        guard count > 0, index + 1 < chapters.count, !jobs.isEmpty else {
            cancelPreload()
            return
        }
        guard preloadAnchor != index || preloadTask == nil else { return }
        preloadTask?.cancel()
        preloadAnchor = index
        let urls = jobs.map(\.chapter.url)
        preloadWindow = urls.compactMap { url in chapters.firstIndex(where: { $0.url == url }) }
        preloadTask = Task { [book, contentCoordinator] in
            for job in jobs {
                guard !Task.isCancelled else { return }
                await contentCoordinator.prefetch(book: book, chapter: job.chapter, source: source, nextChapterURL: job.nextChapterURL)
            }
        }
    }

    private static func makeParagraphs(_ content: String) -> [ReaderParagraph] {
        var position = 0
        var output: [ReaderParagraph] = []
        for line in content.components(separatedBy: .newlines) {
            if !line.isEmpty { output.append(.init(id: position, text: line)) }
            position += line.utf16.count + 1
        }
        if output.isEmpty, !content.isEmpty { output.append(.init(id: 0, text: content)) }
        return output
    }

    private static func validIndex(_ requested: Int, chapters: [BookChapter]) -> Int {
        if chapters.indices.contains(requested), !chapters[requested].isVolume { return requested }
        return chapters.firstIndex(where: { !$0.isVolume }) ?? 0
    }
}
