import Foundation
import Testing
@testable import LegadoCore

// Opt-in only: point LEGADO_SOURCE_PROBE_FILE at a downloaded JSON source pack.
// No remote source or response is included in the application or normal test run.
struct BookSourceRemoteProbe {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LEGADO_SOURCE_CHAIN_FILE"] != nil))
    func sampleReadingPipelines() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["LEGADO_SOURCE_CHAIN_FILE"])
        let sources = try BookSourceImporter().decode(Data(contentsOf: URL(fileURLWithPath: path)))
        var reports: [BookSourceDebugReport] = []
        let transport = ProbeTransport()
        let keyword = ProcessInfo.processInfo.environment["LEGADO_SOURCE_PROBE_KEYWORD"] ?? "斗罗大陆"
        for source in sources {
            var report = await BookSourceDebugger(transport: transport).run(source: source, keyword: keyword)
            report.contentPreview = nil
            reports.append(report)
            print("SOURCE_CHAIN \(source.bookSourceName) " + String(decoding: try JSONEncoder().encode(report), as: UTF8.self))
        }
        if let output = ProcessInfo.processInfo.environment["LEGADO_SOURCE_CHAIN_OUTPUT"] {
            try JSONEncoder().encode(reports).write(to: URL(fileURLWithPath: output))
            try JSONEncoder().encode(await transport.records()).write(to: URL(fileURLWithPath: output + ".requests.json"))
        }
        #expect(reports.count == sources.count)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LEGADO_EXPLORE_PROBE_FILE"] != nil))
    func sampleExplore() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["LEGADO_EXPLORE_PROBE_FILE"])
        let sources = try BookSourceImporter().decode(Data(contentsOf: URL(fileURLWithPath: path)))
        let transport = ProbeTransport()
        let service = BookExploreService(transport: transport)
        for source in sources {
            let kinds = await service.kinds(for: source)
            print("EXPLORE_KINDS \(source.bookSourceName) count=\(kinds.kinds.count) diag=\(kinds.diagnostics.map { "\($0.code): \($0.message)" })")
            for kind in kinds.kinds.filter({ !($0.url ?? "").isEmpty }).prefix(2) {
                let outcome = await service.explore(source: source, kind: kind, page: 1)
                print("EXPLORE \(source.bookSourceName) [\(kind.title)] url=\((kind.url ?? "").replacingOccurrences(of: "\n", with: " ").prefix(120)) books=\(outcome.books.count) first=\(outcome.books.first.map { "\($0.name)/\($0.author)/\($0.bookURL)" } ?? "-")")
                for diagnostic in outcome.diagnostics { print("EXPLORE_DIAG \(diagnostic.code): \(diagnostic.message.prefix(400)) rule=\(diagnostic.rule.prefix(160))") }
            }
        }
        for record in await transport.records() { print("EXPLORE_REQ " + record.stringValue.prefix(600)) }
        let search = BookSearchService(transport: transport, networkPolicy: .init(), history: .init())
        let keyword = ProcessInfo.processInfo.environment["LEGADO_SOURCE_PROBE_KEYWORD"] ?? "斗罗大陆"
        for await outcome in search.searchOutcomes(keyword: keyword, page: 1, sources: sources, maximumConcurrentSources: 3, includeDisabled: true) {
            print("SEARCH \(outcome.sourceID) books=\(outcome.books.count) first=\(outcome.books.first.map { "\($0.name)/\($0.bookURL)" } ?? "-")")
            for diagnostic in outcome.diagnostics { print("SEARCH_DIAG \(diagnostic.code): \(diagnostic.message.prefix(400))") }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LEGADO_SOURCE_PROBE_FILE"] != nil))
    func sampleSearches() async throws {
        guard let path = ProcessInfo.processInfo.environment["LEGADO_SOURCE_PROBE_FILE"] else { return }
        let sources = try BookSourceImporter().decode(Data(contentsOf: URL(fileURLWithPath: path)))
        let transport = ProbeTransport()
        let service = BookSearchService(transport: transport, networkPolicy: .init(), history: .init())
        let keyword = ProcessInfo.processInfo.environment["LEGADO_SOURCE_PROBE_KEYWORD"] ?? "斗罗大陆"
        let page = Int(ProcessInfo.processInfo.environment["LEGADO_SOURCE_PROBE_PAGE"] ?? "1") ?? 1
        var rows: [[String: JSONValue]] = []
        for await outcome in service.searchOutcomes(keyword: keyword, page: page, sources: sources, maximumConcurrentSources: 3, includeDisabled: true) {
            let source = try #require(sources.first { $0.id == outcome.sourceID })
            let row: [String: JSONValue] = [
                "name": .string(source.bookSourceName), "source": .string(source.id),
                "count": .number(Double(outcome.books.count)),
                "books": .array(outcome.books.prefix(3).map { .object([
                    "name": .string($0.name), "url": .string($0.bookURL), "author": .string($0.author),
                    "cover": .string($0.coverURL ?? ""), "wordCount": .string($0.wordCount ?? "")
                ]) }),
                "diagnostics": .array(outcome.diagnostics.map { .object(["code": .string($0.code), "message": .string($0.message), "rule": .string($0.rule)]) })
            ]
            rows.append(row)
            print("SOURCE_PROBE " + JSONValue.object(row).stringValue)
        }
        let report = JSONValue.object(["keyword": .string(keyword), "page": .number(Double(page)), "outcomes": .array(rows.map(JSONValue.object)), "requests": .array(await transport.records())])
        if let output = ProcessInfo.processInfo.environment["LEGADO_SOURCE_PROBE_OUTPUT"] {
            try JSONEncoder().encode(report).write(to: URL(fileURLWithPath: output))
        }
        #expect(rows.count == Set(sources.map(\.id)).count)
    }
}

private actor ProbeTransport: HTTPTransport {
    private var values: [JSONValue] = []
    private let transport = URLSessionHTTPTransport()

    func data(for request: URLRequest) async throws -> HTTPResponse {
        do {
            let response = try await transport.data(for: request)
            var record: [String: JSONValue] = [
                "url": .string(request.url?.absoluteString ?? ""),
                "finalURL": .string(response.finalURL.absoluteString),
                "status": .number(Double(response.statusCode)),
                "bytes": .number(Double(response.data.count)),
                "preview": .string(String(response.decodedText.prefix(240)))
            ]
            if let directory = ProcessInfo.processInfo.environment["LEGADO_SOURCE_PROBE_SNAPSHOT_DIR"] {
                let folder = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let file = folder.appendingPathComponent(UUID().uuidString + ".response")
                try response.data.write(to: file)
                record["snapshot"] = .string(file.path)
            }
            values.append(.object(record))
            return response
        } catch {
            values.append(.object(["url": .string(request.url?.absoluteString ?? ""), "error": .string(error.localizedDescription)]))
            throw error
        }
    }

    func records() -> [JSONValue] { values }
    /// 段评全链路：打开书源的评论开关，取一章正文，统计气泡标记并执行第一个气泡的点击回调。
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LEGADO_REVIEW_PROBE_FILE"] != nil))
    func sampleParagraphReviews() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["LEGADO_REVIEW_PROBE_FILE"])
        let sources = try BookSourceImporter().decode(Data(contentsOf: URL(fileURLWithPath: path)))
        let transport = ProbeTransport()
        let keyword = ProcessInfo.processInfo.environment["LEGADO_SOURCE_PROBE_KEYWORD"] ?? "斗罗大陆"
        let service = NetworkBookService(transport: transport)
        for source in sources {
            let on = ["段评开关", "神评开关", "本章说", "书评开关", "热门评论"].reduce(into: [String: String]()) { $0[$1] = "✅" }
            let info = String(decoding: try JSONSerialization.data(withJSONObject: on), as: UTF8.self)
            BookSourceRuntimeStore.shared.put(sourceID: source.id, key: "loginInfo", value: info)
            let search = await BookSearchService(transport: transport).search(keyword: keyword, page: 1, source: source)
            guard let first = search.books.first else { print("REVIEW \(source.bookSourceName) no search"); continue }
            let detail = await service.loadDetail(searchBook: first, source: source)
            let toc = await service.loadChapters(book: detail.book, source: source, maxPages: 3)
            print("REVIEW_TOC \(toc.chapters.count) diag=\(toc.diagnostics.map { "\($0.severity):\($0.code):\($0.message.prefix(160))" })")
            let readable = toc.chapters.filter { !$0.isVolume }
            guard readable.count > 3 else { continue }
            let chapter = readable[3]
            let content = await service.loadContent(book: detail.book, chapter: chapter, source: source, maxPages: 2)
            let text = content.content
            let markers = text.components(separatedBy: "<img").count - 1
            print("REVIEW_CONTENT \(chapter.title) len=\(text.count) imgs=\(markers) diag=\(content.diagnostics.map { "\($0.code):\($0.message.prefix(160))" })")
            let tags = text.components(separatedBy: "<img").dropFirst().prefix(3).map { String($0.prefix(400)) }
            for tag in tags { print("REVIEW_TAG <img" + tag) }
            if let tag = tags.first, let range = tag.range(of: "js=") {
                let encoded = tag[range.upperBound...].prefix { $0 != "\"" && $0 != "&" }
                let script = String(encoded).removingPercentEncoding ?? ""
                print("REVIEW_SCRIPT \(script.prefix(300))")
                let started = Date()
                let resolution = await JavaScriptRuleEvaluator().resolveClick(script, executionContext: .init(baseURL: chapter.url, source: source, book: detail.book, chapter: chapter))
                print("REVIEW_CLICK \(Date().timeIntervalSince(started))s url=\(resolution.url ?? "-") html=\(resolution.html?.count ?? 0) error=\(resolution.error ?? "-")")
                if let html = resolution.html, let state = html.range(of: "var state=") {
                    print("REVIEW_STATE " + String(html[state.upperBound...].prefix(600)))
                }
            }
        }
    }

}
