import Foundation
import Testing
@testable import LegadoCore

struct LegadoURLBuilderTests {
    @Test func canDisableCookieHandlingPerSourceRequest() throws {
        let prepared = try LegadoURLBuilder().prepare("https://example.test/books")
        #expect(prepared.urlRequest(handleCookies: false).httpShouldHandleCookies == false)
        #expect(prepared.urlRequest().httpShouldHandleCookies)
    }
    private let builder = LegadoURLBuilder()

    @Test func relativeRequestOptionsAndHeaderCasingSurviveResolution() throws {
        let base = try #require(URL(string: "https://example.test/book/1"))
        let resolved = LegadoURLBuilder.resolve(#"../chapter,{"method":"POST","headers":{"referer":"custom"},"body":"id=1"}"#, against: base)
        let request = try builder.prepare(resolved, defaultHeaders: ["Referer": "old"])
        #expect(request.url.absoluteString == "https://example.test/chapter")
        #expect(request.method == .post)
        #expect(request.headers.filter { $0.key.lowercased() == "referer" }.count == 1)
        #expect(request.headers["referer"] == "custom")
        #expect(String(decoding: try #require(request.body), as: UTF8.self) == "id=1")
    }

    @Test func rendersKeywordPageAndRequestOptions() throws {
        let template = """
        /search?q={{key}}&page=<0,1,2>, {"method":"POST","headers":{"X-Test":"yes"},"body":"token={{token}}","retry":2}
        """
        let prepared = try builder.prepare(
            template,
            context: .init(key: "三体", page: 2, variables: ["token": "abc"]),
            baseURL: URL(string: "https://example.test/base/"),
            defaultHeaders: ["User-Agent": "Legado-iOS"]
        )

        #expect(prepared.url.absoluteString.contains("q=%E4%B8%89%E4%BD%93"))
        #expect(prepared.url.absoluteString.contains("page=1"))
        #expect(prepared.method == .post)
        #expect(prepared.headers["X-Test"] == "yes")
        #expect(prepared.headers["User-Agent"] == "Legado-iOS")
        #expect(String(decoding: try #require(prepared.body), as: UTF8.self) == "token=abc")
        #expect(prepared.retry == 2)
    }

    @Test func clampsUnboundedRetryOption() throws {
        let prepared = try builder.prepare(#"https://example.test/a,{"retry":1000000000}"#)
        #expect(prepared.retry == 10)
        let negative = try builder.prepare(#"https://example.test/a,{"retry":-3}"#)
        #expect(negative.retry == 0)
    }

    @Test func evaluatesInlineJavaScriptWithSearchBindings() throws {
        let prepared = try builder.prepare(
            "https://example.test/{{key.toUpperCase()}}?page={{page + 1}}",
            context: .init(key: "swift", page: 2)
        )

        #expect(prepared.url.absoluteString == "https://example.test/SWIFT?page=3")
    }

    @Test func evaluatesWholeURLAndOptionJavaScriptWhileCarryingVariables() throws {
        let wholeScript = try builder.prepare(
            "@js:'/search?q=' + key",
            context: .init(key: "book", page: 4),
            baseURL: URL(string: "https://example.test")
        )
        let prepared = try builder.prepare(
            #"/search?q=book, {"js":"java.put('signature', 's-' + page); result + '&sig=' + java.get('signature')"}"#,
            context: .init(key: "book", page: 4),
            baseURL: URL(string: "https://example.test")
        )

        #expect(wholeScript.url.absoluteString == "https://example.test/search?q=book")
        #expect(prepared.url.absoluteString == "https://example.test/search?q=book&sig=s-4")
        #expect(prepared.variables["signature"] == "s-4")
    }

    @Test func supportsLegacySearchTokensAndJSONObjectBody() throws {
        let prepared = try builder.prepare(
            "https://example.test/search, {\"method\":\"POST\",\"body\":{\"title\":\"searchKey\",\"page\":{{searchPage}}}}",
            context: .init(key: "三体", page: 3)
        )

        #expect(prepared.method == .post)
        let body = try #require(prepared.body)
        let json = try JSONValue.decode(data: body)
        #expect(json["title"]?.stringValue == "三体")
        #expect(json["page"]?.stringValue == "3")
    }

    @Test func encodesLegacyCharsetQueryAndFormBody() throws {
        let query = try builder.prepare(
            #"https://example.test/search?q={{key}}, {"charset":"gb18030"}"#,
            context: .init(key: "旧城")
        )
        let form = try builder.prepare(
            #"https://example.test/search, {"method":"POST","charset":"gb18030","body":"q={{key}}&tag=中文 空格"}"#,
            context: .init(key: "旧城")
        )

        #expect(query.url.absoluteString.contains("q=%BE%C9%B3%C7"))
        #expect(String(decoding: try #require(form.body), as: UTF8.self) == "q=%BE%C9%B3%C7&tag=%D6%D0%CE%C4+%BF%D5%B8%F1")
        #expect(form.headers["Content-Type"] == "application/x-www-form-urlencoded; charset=gb18030")
    }

    @Test func parsesGsonLenientStyleOptions() throws {
        let prepared = try builder.prepare(
            #"https://example.test/search?q={{key}}, {'method':'POST', body:'key={{key}}', charset:'utf-8',}"#,
            context: .init(key: "三体")
        )

        #expect(prepared.method == .post)
        #expect(prepared.charset == "utf-8")
        #expect(String(decoding: try #require(prepared.body), as: UTF8.self) == "key=%E4%B8%89%E4%BD%93")
    }

    @Test func keepsJsonInQueryWhenLaterSplitParses() throws {
        let prepared = try builder.prepare(
            #"https://example.test/search?data={"q":"{{key}}"}, {"method":"POST","body":"key={{key}}"}"#,
            context: .init(key: "剑来")
        )

        #expect(prepared.method == .post)
        #expect(prepared.url.absoluteString.contains("data="))
        #expect(String(decoding: try #require(prepared.body), as: UTF8.self) == "key=%E5%89%91%E6%9D%A5")
    }

    @Test func appliesDefaultBrowserUserAgentWhenMissing() throws {
        let prepared = try builder.prepare("https://example.test/books")
        #expect(prepared.headers["User-Agent"] == LegadoURLBuilder.defaultUserAgent)
        #expect(prepared.headers["User-Agent"]?.contains("Chrome/128.0.0.0") == true)
        let explicit = try builder.prepare(
            "https://example.test/books",
            defaultHeaders: ["User-Agent": "Custom/1.0"]
        )
        #expect(explicit.headers["User-Agent"] == "Custom/1.0")
    }

    @Test func nullUserAgentSuppressesDefaultHeader() throws {
        let prepared = try builder.prepare(
            "https://example.test/books",
            defaultHeaders: ["user-agent": "null"]
        )

        #expect(prepared.headers.keys.allSatisfy { $0.caseInsensitiveCompare("User-Agent") != .orderedSame })
        #expect(prepared.urlRequest().value(forHTTPHeaderField: "User-Agent") == nil)
    }

    @Test func preservesTypeDnsServerAndProxyOptions() throws {
        let prepared = try builder.prepare(
            #"https://example.test/file, {"type":"image","dnsIp":"1.1.1.1,8.8.8.8","serverID":12}"#,
            defaultHeaders: ["proxy": "http://127.0.0.1:7890", "X-Test": "yes"]
        )

        #expect(prepared.responseType == "image")
        #expect(prepared.dnsIP == "1.1.1.1,8.8.8.8")
        #expect(prepared.serverID == 12)
        #expect(prepared.proxy == "http://127.0.0.1:7890")
        #expect(prepared.headers["proxy"] == nil)
        #expect(prepared.headers["X-Test"] == "yes")
    }

    @Test func rendersPostFormAndIgnoresBodyForGetAndHead() throws {
        let post = try builder.prepare(
            #"https://example.test/search, {"method":"POST","body":"q={{key}}&space=空 格"}"#,
            context: .init(key: "三体")
        )
        let emptyPost = try builder.prepare(#"https://example.test/search, {"method":"POST"}"#)
        let get = try builder.prepare(#"https://example.test/search, {"body":"ignored=1"}"#)
        let head = try builder.prepare(#"https://example.test/search, {"method":"HEAD","body":"ignored=1"}"#)

        #expect(String(decoding: try #require(post.body), as: UTF8.self) == "q=%E4%B8%89%E4%BD%93&space=%E7%A9%BA+%E6%A0%BC")
        #expect(emptyPost.body == Data())
        #expect(post.headers["Content-Type"] == "application/x-www-form-urlencoded; charset=utf-8")
        #expect(get.urlRequest().httpBody == nil)
        #expect(head.urlRequest().httpBody == nil)
    }

    @Test func explicitContentTypeKeepsRawPostBody() throws {
        let prepared = try builder.prepare(
            #"https://example.test/raw, {"method":"POST","headers":{"content-type":"text/plain; charset=utf-8"},"body":"原始 空格"}"#
        )

        #expect(String(decoding: try #require(prepared.body), as: UTF8.self) == "原始 空格")
        #expect(prepared.headers["content-type"] == "text/plain; charset=utf-8")
    }
}
