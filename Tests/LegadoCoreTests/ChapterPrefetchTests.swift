import Foundation
import Testing
@testable import LegadoCore

struct ChapterPrefetchTests {
    @Test func defaultPrefetchIsTenReadableChapters() {
        #expect(ApplicationSettings().prefetchChapters == 10)
    }

    @Test func legacyDefaultMigratesOnceAndKeepsCustomValues() throws {
        let suite = "prefetch-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ApplicationSettingsStore(defaults: defaults)
        var legacy = ApplicationSettings()
        legacy.prefetchChapters = 1
        try store.save(legacy)
        #expect(store.settings.prefetchChapters == 10)
        // After migration the user may choose 1 deliberately; keep it.
        legacy.prefetchChapters = 1
        try store.save(legacy)
        #expect(store.settings.prefetchChapters == 1)
    }

    @Test func offAndCustomValuesAreNotMigrated() throws {
        for value in [0, 3] {
            let suite = "prefetch-\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = ApplicationSettingsStore(defaults: defaults)
            var settings = ApplicationSettings()
            settings.prefetchChapters = value
            try store.save(settings)
            #expect(store.settings.prefetchChapters == value)
        }
    }

    @Test func foregroundAndPrefetchShareOneRequest() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let loader = GatedLoader()
        let coordinator = ChapterContentCoordinator(loader: loader, cache: .init(directory: directory))
        let book = Book(bookUrl: "book", name: "书", origin: "source")
        let chapter = BookChapter(url: "c1", title: "一", bookUrl: "book", index: 0)
        let source = BookSource(bookSourceUrl: "source", bookSourceName: "源")
        async let prefetch = coordinator.prefetch(book: book, chapter: chapter, source: source)
        await loader.waitUntilStarted()
        async let foreground = coordinator.load(book: book, chapter: chapter, source: source)
        try await Task.sleep(nanoseconds: 50_000_000)
        await loader.release()
        let result = await foreground
        _ = await prefetch
        #expect(result.report.content == "正文")
        #expect(await loader.calls == 1)
    }
}

private actor GatedLoader: ChapterContentLoading {
    private(set) var calls = 0
    private var gate: CheckedContinuation<Void, Never>?
    private var started = false

    func loadContent(book: Book, chapter: BookChapter, source: BookSource, nextChapterURL: String?, maxPages: Int) async -> ChapterContentReport {
        calls += 1
        started = true
        await withCheckedContinuation { gate = $0 }
        return .init(title: chapter.title, content: "正文")
    }

    func waitUntilStarted() async {
        while !started { try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    func release() {
        gate?.resume()
        gate = nil
    }
}
