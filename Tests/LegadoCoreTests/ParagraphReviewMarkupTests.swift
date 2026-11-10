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
}
