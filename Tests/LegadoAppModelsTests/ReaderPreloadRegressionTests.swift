import Foundation
import Testing
import LegadoCore
@testable import LegadoAppModels

@MainActor
struct ReaderPreloadRegressionTests {
    private func makeChapters(count: Int, volumeAt: Set<Int> = []) -> [BookChapter] {
        (0..<count).map { index in
            var chapter = BookChapter(url: "chapter\(index)", title: "第\(index)章", bookUrl: "book", index: index)
            chapter.isVolume = volumeAt.contains(index)
            return chapter
        }
    }

    @Test func cachedChapterStillPrefetchesFollowingChapters() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ChapterContentCache(directory: directory)
        let book = Book(bookUrl: "book", name: "书", origin: "source")
        let chapters = makeChapters(count: 6)
        try await cache.save(.init(bookURL: "book", chapterURL: "chapter0", content: "已缓存正文", sourceID: "source"))
        let loader = RecordingPreloadLoader()
        let model = ReaderViewModel(book: book, chapters: chapters, initialIndex: 0,
                                    source: .init(bookSourceUrl: "source", bookSourceName: "源"),
                                    service: loader, cache: cache)
        await model.load(rules: [])
        #expect(model.loadedFromCache)
        #expect(model.content == "已缓存正文")
        try await loader.waitForRequests(atLeast: 1)
        let requested = await loader.requestedURLs
        #expect(requested.contains("chapter1"))
        #expect(!requested.contains("chapter0"))
    }

    @Test func preloadWindowSkipsVolumesAndShrinksNearBookEnd() async throws {
        let chapters = makeChapters(count: 30, volumeAt: [3, 8])
        let jobs = ChapterCachePlanner.plan(chapters: chapters, startIndex: 1, limit: 10)
        #expect(jobs.count == 10)
        #expect(!jobs.contains { $0.chapter.isVolume })
        #expect(jobs.map(\.chapter.url).contains("chapter12"))
        let tail = ChapterCachePlanner.plan(chapters: chapters, startIndex: 27, limit: 10)
        #expect(tail.map(\.chapter.url) == ["chapter27", "chapter28", "chapter29"])
    }

    @Test func jumpingElsewhereCancelsOldPreloadWindow() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let book = Book(bookUrl: "book", name: "书", origin: "source")
        let loader = RecordingPreloadLoader()
        let model = ReaderViewModel(book: book, chapters: makeChapters(count: 40), initialIndex: 0,
                                    source: .init(bookSourceUrl: "source", bookSourceName: "源"),
                                    service: loader, cache: .init(directory: directory))
        await model.load(rules: [])
        #expect(!model.preloadWindow.isEmpty)
        model.select(index: 30)
        #expect(model.preloadWindow.isEmpty)
        model.cancelPreload()
        #expect(model.preloadWindow.isEmpty)
    }
}

private actor RecordingPreloadLoader: ChapterContentLoading {
    private(set) var requestedURLs: [String] = []

    func loadContent(book: Book, chapter: BookChapter, source: BookSource, nextChapterURL: String?, maxPages: Int) async -> ChapterContentReport {
        requestedURLs.append(chapter.url)
        return .init(title: chapter.title, content: "正文\(chapter.index)")
    }

    func waitForRequests(atLeast count: Int) async throws {
        for _ in 0..<200 {
            if requestedURLs.count >= count { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
