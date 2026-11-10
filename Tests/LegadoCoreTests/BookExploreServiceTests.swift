import Foundation
import Testing
@testable import LegadoCore

private struct ExploreMockTransport: HTTPTransport {
    let pages: [String: String]

    func data(for request: URLRequest) async throws -> HTTPResponse {
        let url = try #require(request.url)
        let body = try #require(pages[url.absoluteString])
        return .init(data: Data(body.utf8), statusCode: 200, headers: [:], finalURL: url)
    }
}

struct BookExploreServiceTests {
    @Test func parsesLegacyAndJavaScriptExploreKinds() async {
        var legacy = BookSource(bookSourceUrl: "https://example.test", bookSourceName: "传统发现")
        legacy.exploreUrl = "热门::/hot?page={{page}}&&完结::/finished?page={{page}}\n新书::/new"
        let service = BookExploreService()

        let legacyReport = await service.kinds(for: legacy)

        #expect(legacyReport.kinds.map(\.title) == ["热门", "完结", "新书"])
        #expect(legacyReport.kinds[0].url == "/hot?page={{page}}")
        #expect(legacyReport.diagnostics.isEmpty)

        var scripted = legacy
        scripted.exploreUrl = "@js:JSON.stringify([{title:'科幻',url:'/sci?page={{page}}'},{title:'文学',url:'/lit'}])"
        let scriptedReport = await service.kinds(for: scripted)

        #expect(scriptedReport.kinds.map(\.title) == ["科幻", "文学"])
        #expect(scriptedReport.kinds.first?.url == "/sci?page={{page}}")
        #expect(scriptedReport.diagnostics.isEmpty)
    }

    @Test func distinguishesExploreDestinationsFromDynamicControlsAndPlaceholders() async {
        var source = BookSource(bookSourceUrl: "https://example.test", bookSourceName: "动态发现")
        source.exploreUrl = #"[{"title":"关键词","type":"text"},{"title":"刷新","type":"button","action":"refresh()"},{"title":"占位"},{"title":"热门","url":"  /hot?page={{page}}  "}]"#

        let report = await BookExploreService().kinds(for: source)

        #expect(report.kinds.count == 4)
        #expect(report.kinds[0].navigableURL == nil)
        #expect(report.kinds[1].navigableURL == nil)
        #expect(report.kinds[2].navigableURL == nil)
        #expect(report.kinds[3].navigableURL == "/hot?page={{page}}")
        #expect(report.diagnostics.isEmpty)
    }

    @Test func toleratesGsonStyleScalarValuesInExploreJSON() async {
        var source = BookSource(bookSourceUrl: "https://example.test", bookSourceName: "宽松分类")
        source.exploreUrl = #"[{"title":2026,"url":123,"type":true,"action":7,"chars":["全部",2,false,null],"default":0}]"#

        let report = await BookExploreService().kinds(for: source)

        #expect(report.kinds.count == 1)
        #expect(report.kinds[0].title == "2026")
        #expect(report.kinds[0].url == "123")
        #expect(report.kinds[0].type == "true")
        #expect(report.kinds[0].action == "7")
        #expect(report.kinds[0].chars == ["全部", "2", "false", nil])
        #expect(report.kinds[0].defaultValue == "0")
        #expect(report.diagnostics.isEmpty)
    }

    @Test func toleratesLegacyJSON5ExploreSyntaxAcceptedByGson() async {
        var source = BookSource(bookSourceUrl: "https://example.test", bookSourceName: "旧式分类")
        source.exploreUrl = "[{title:'热门', url:'/hot',}, // old source comment\n]"

        let report = await BookExploreService().kinds(for: source)

        #expect(report.kinds.map(\.title) == ["热门"])
        #expect(report.kinds.first?.url == "/hot")
        #expect(report.diagnostics.isEmpty)
    }

    @Test func loadsPaginatedJSONExploreBooksAndFallsBackToSearchRules() async throws {
        let transport = ExploreMockTransport(pages: [
            "https://example.test/hot?page=2": #"{"data":[{"id":2,"name":"第二页新书","author":"作者乙","cover":"/2.jpg"}]}"#
        ])
        var source = BookSource(bookSourceUrl: "https://example.test", bookSourceName: "发现源")
        source.exploreUrl = "热门::/hot?page={{page}}"
        source.ruleSearch = SearchRule(
            bookList: "$.data",
            name: "$.name",
            author: "$.author",
            bookUrl: "$.id@js:'/book/' + result",
            coverUrl: "$.cover"
        )
        let kind = ExploreKind(title: "热门", url: "/hot?page={{page}}")

        let outcome = await BookExploreService(transport: transport).explore(source: source, kind: kind, page: 2)

        let book = try #require(outcome.books.first)
        #expect(book.name == "第二页新书")
        #expect(book.bookURL == "https://example.test/book/2")
        #expect(book.coverURL == "https://example.test/2.jpg")
        #expect(outcome.diagnostics.isEmpty)
    }
}
