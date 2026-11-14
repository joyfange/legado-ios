import Foundation

public protocol ChapterListLoading: Sendable {
    func loadChapters(book: Book, source: BookSource, maxPages: Int) async -> ChapterListReport
}

extension NetworkBookService: ChapterListLoading {}

public struct BookUpdateReport: Sendable {
    public var book: Book
    public var chapters: [BookChapter]
    public var addedChapterCount: Int
    public var diagnostics: [RuleDiagnostic]
    public var refreshed: Bool

    public init(
        book: Book,
        chapters: [BookChapter],
        addedChapterCount: Int,
        diagnostics: [RuleDiagnostic] = [],
        refreshed: Bool = true
    ) {
        self.book = book
        self.chapters = chapters
        self.addedChapterCount = addedChapterCount
        self.diagnostics = diagnostics
        self.refreshed = refreshed
    }
}

public struct BookUpdateMerger: Sendable {
    public init() {}

    public func merge(book: Book, oldChapters: [BookChapter], newChapters: [BookChapter], now: Int64) -> BookUpdateReport {
        guard !newChapters.isEmpty else {
            return .init(book: book, chapters: oldChapters, addedChapterCount: 0, refreshed: false)
        }
        var normalized = newChapters
        // 目录里可能出现重复的「序号+标题」，uniqueKeysWithValues 遇到重复键会直接崩溃。
        let metadata = Dictionary(oldChapters.map {
            ("\($0.index)\u{0}\($0.title)", ($0.wordCount, $0.variable, $0.imageURL))
        }, uniquingKeysWith: { first, _ in first })
        for index in normalized.indices {
            normalized[index].index = index
            normalized[index].bookUrl = book.bookUrl
            if let old = metadata["\(index)\u{0}\(normalized[index].title)"] {
                if let wordCount = old.0 { normalized[index].wordCount = wordCount }
                if let variable = old.1 { normalized[index].variable = variable }
                if let imageURL = old.2 { normalized[index].imageURL = imageURL }
            }
        }

        var updated = book
        let previousTotal = max(book.totalChapterNum, oldChapters.count)
        let added = max(normalized.count - previousTotal, 0)
        if added > 0 {
            updated.lastCheckCount = added
            updated.latestChapterTime = now
        }
        updated.lastCheckTime = now
        updated.totalChapterNum = normalized.count
        updated.latestChapterTitle = normalized.last(where: { !$0.isVolume })?.title ?? normalized.last?.title
        let newReadIndex = resolveReadIndex(book: book, chapters: normalized)
        updated.durChapterIndex = newReadIndex
        if let oldTitle = book.durChapterTitle, !oldTitle.isEmpty,
           normalized.indices.contains(newReadIndex),
           normalize(normalized[newReadIndex].title) != normalize(oldTitle) {
            updated.durChapterPos = 0
        }
        updated.durChapterTitle = normalized.indices.contains(newReadIndex) ? normalized[newReadIndex].title : updated.durChapterTitle
        return .init(book: updated, chapters: normalized, addedChapterCount: added)
    }

    private func resolveReadIndex(book: Book, chapters: [BookChapter]) -> Int {
        if let title = book.durChapterTitle, !title.isEmpty {
            // 同名章节（如分卷里重复的「第一章」）取离原阅读位置最近的一个。
            let anchor = book.durChapterIndex
            if let exact = nearest(in: chapters, to: anchor, where: { $0.title == title }) { return exact }
            let normalizedTitle = normalize(title)
            if let close = nearest(in: chapters, to: anchor, where: { normalize($0.title) == normalizedTitle }) { return close }
        }
        return min(max(book.durChapterIndex, 0), max(chapters.count - 1, 0))
    }

    private func nearest(in chapters: [BookChapter], to anchor: Int, where match: (BookChapter) -> Bool) -> Int? {
        var best: Int?
        for index in chapters.indices where match(chapters[index]) {
            guard let current = best else { best = index; continue }
            if abs(index - anchor) < abs(current - anchor) { best = index }
        }
        return best
    }

    private func normalize(_ title: String) -> String {
        String(title.unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.punctuationCharacters.contains($0)
        }).lowercased()
    }
}

public actor BookUpdateCoordinator {
    private let repository: any BookChapterRepository
    private let loader: any ChapterListLoading
    private let merger: BookUpdateMerger

    public init(
        repository: any BookChapterRepository = FileBookChapterRepository.live(),
        loader: any ChapterListLoading = NetworkBookService(),
        merger: BookUpdateMerger = .init()
    ) {
        self.repository = repository
        self.loader = loader
        self.merger = merger
    }

    public func storedChapters(bookURL: String) async -> [BookChapter] {
        (try? await repository.load(bookURL: bookURL)) ?? []
    }

    public func refresh(book: Book, source: BookSource, now: Int64? = nil, maxPages: Int = 300) async -> BookUpdateReport {
        let old = (try? await repository.load(bookURL: book.bookUrl)) ?? []
        let loaded = await loader.loadChapters(book: book, source: source, maxPages: maxPages)
        // 有报错（如翻页上限、某一页失败）时：已有更完整的旧目录就保留旧的；
        // 新书没有旧目录，则采用已解析到的章节，不能整份丢掉（否则详情页会先
        // 显示“当前源不可用”再换回同一源）。
        let partial = loaded.diagnostics.contains(where: { $0.severity == .error })
        guard !Task.isCancelled, !loaded.chapters.isEmpty,
              !(partial && old.count > loaded.chapters.count) else {
            return .init(
                book: book,
                chapters: old,
                addedChapterCount: 0,
                diagnostics: loaded.diagnostics,
                refreshed: false
            )
        }
        var result = merger.merge(
            book: book,
            oldChapters: old,
            newChapters: loaded.chapters,
            now: now ?? Int64(Date().timeIntervalSince1970 * 1_000)
        )
        result.diagnostics = loaded.diagnostics
        do {
            try await repository.save(result.chapters, bookURL: result.book.bookUrl)
        } catch {
            result.diagnostics.append(.init(
                severity: .error,
                code: "toc.persistence",
                message: "目录保存失败：\(error.localizedDescription)",
                rule: book.bookUrl
            ))
        }
        return result
    }
}
