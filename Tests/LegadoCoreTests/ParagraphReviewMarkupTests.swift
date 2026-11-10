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
}
