import Foundation
import Testing
@testable import LegadoCore

struct ParagraphReviewMarkupTests {
    @Test func reviewBubblesStayInlineAndImagesGetOwnLine() throws {
        let base = try #require(URL(string: "https://example.com/book/1.html"))
        let html = "<p>第一段正文<img src=\"dp:12\"></p><p>第二段</p><img src=\"/pic/a.jpg\"><p>第三段</p>"
        let output = ChapterHTMLFormatter().format(html, baseURL: base)
        let lines = output.components(separatedBy: "\n")
        #expect(lines.contains("第一段正文<img src=\"dp:12\">"))
        #expect(lines.contains("<img src=\"https://example.com/pic/a.jpg\">"))
    }

    @Test func detectsReviewMarkers() {
        #expect(ChapterHTMLFormatter.isParagraphReviewMarker("dp:3"))
        #expect(ChapterHTMLFormatter.isParagraphReviewMarker("bubble://paragraph?num=3"))
        #expect(ChapterHTMLFormatter.isParagraphReviewMarker("https://h/r.png,{\"style\":\"TEXT\",\"type\":\"cmt\"}"))
        #expect(!ChapterHTMLFormatter.isParagraphReviewMarker("https://h/a.png"))
    }

    @Test func commentTagBecomesBubbleWithCountAndLink() throws {
        let base = try #require(URL(string: "https://example.com/c/1"))
        let html = "<p>段落一<comment count=\"23\" onClick=\"java.startBrowser('https://r.example.com/p?a=1&b=2','段评')\"/></p><p>段落二</p>"
        let output = ChapterHTMLFormatter().format(html, baseURL: base)
        let first = try #require(output.components(separatedBy: "\n").first)
        #expect(first.hasPrefix("段落一<img src=\"bubble://paragraph?num=23&amp;url=https%3A%2F%2Fr.example.com"))
        #expect(output.contains("段落二"))
    }

    @Test func inlineSVGBubbleReadsCountAndHotCommentBecomesText() throws {
        let base = try #require(URL(string: "https://example.com/c/1"))
        let bubbleSVG = Data("<svg><text>8</text></svg>".utf8).base64EncodedString()
        let hotSVG = Data("<svg><text>热评</text><text>写得真好</text></svg>".utf8).base64EncodedString()
        let html = "<p>甲段<img src=\"data:image/svg+xml;base64,\(bubbleSVG),{\"style\":\"text\"}\"></p>"
            + "<img src=\"data:image/svg+xml;base64,\(hotSVG)\"><p>乙段</p>"
        let output = ChapterHTMLFormatter().format(html, baseURL: base)
        let lines = output.components(separatedBy: "\n")
        #expect(lines.contains("甲段<img src=\"bubble://paragraph?num=8\">"))
        #expect(lines.contains("【热评】写得真好"))
        #expect(lines.contains("乙段"))
    }

    @Test func sourceCallbackIsKeptForTheReaderToRun() throws {
        let base = try #require(URL(string: "https://example.com/c/1"))
        let html = "<p>丙段<img src=\"data:image/svg+xml;base64,,{\"style\":\"text\",\"click\":\"showCmt('1','2','3','4')\"}\"></p>"
        let output = ChapterHTMLFormatter().format(html, baseURL: base)
        #expect(output.hasPrefix("丙段<img src=\"bubble://paragraph?num=4&amp;js=showCmt%28"))
    }

    @Test func clickResolutionCapturesStartBrowser() async throws {
        let resolution = await JavaScriptRuleEvaluator().resolveClick(
            "java.startBrowser('https://r.example.com/p?id=' + (2 + 3), '段评')",
            executionContext: RuleExecutionContext()
        )
        #expect(resolution.url == "https://r.example.com/p?id=5")
        #expect(resolution.title == "段评")
    }

    @Test func largeSourceLibraryStillRuns() throws {
        var source = BookSource(bookSourceUrl: "https://lib.example.com", bookSourceName: "大库")
        let padding = "var pad = '" + String(repeating: "x", count: 200_000) + "';\n"
        source.jsLib = padding + "function showCmt(a){ return 'https://lib.example.com/c?id=' + a; } var e = eval('1+1');"
        let result = try JavaScriptRuleEvaluator().evaluate(
            script: "showCmt(7)",
            result: .string(""),
            executionContext: RuleExecutionContext(source: source)
        )
        #expect(result.value.stringValue == "https://lib.example.com/c?id=7")
    }

    @Test func androidJavaShimsUsedByQimaoSourcesWork() throws {
        let script = """
        var md5 = String(Packages.cn.hutool.crypto.digest.DigestUtil.md5Hex('abc'));
        var uuid = String(Packages.java.util.UUID.randomUUID().toString()).replace(/-/g, '');
        var map = new Packages.java.util.HashMap(); map.put('k', 'v');
        var bytes = new Packages.java.lang.String('héllo').getBytes('UTF-8');
        var latin = String(new Packages.java.lang.String(bytes, 0, 1, 'ISO-8859-1'));
        var cached = (cache.putMemory('x', 'y'), String(cache.getFromMemory('x')));
        java.longToast('ok');
        [md5, uuid.length, map.get('k'), map.size(), latin, cached].join('|')
        """
        let result = try JavaScriptRuleEvaluator().evaluate(script: script, result: .string(""), executionContext: RuleExecutionContext())
        #expect(result.value.stringValue == "900150983cd24fb0d6963f7d28e17f72|32|v|1|h|y")
    }

    @Test func gzipBodyIsInflatedEvenWithoutContentEncoding() {
        let bytes: [UInt8] = [31,139,8,0,0,0,0,0,2,3,171,86,74,84,178,50,172,5,0,175,172,27,86,7,0,0,0]
        let response = HTTPResponse(data: Data(bytes), statusCode: 200, headers: [:], finalURL: URL(string: "https://example.com")!)
        #expect(response.decodedText == "{\"a\":1}")
    }
}
