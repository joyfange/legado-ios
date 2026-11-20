import UIKit
import XCTest
@testable import Legado

/// 段评气泡：模板、SVG 渲染、样式存储与导入导出。
@MainActor
final class ReviewBubbleTests: XCTestCase {
    func testTemplatesAndTheirSVGRender() {
        XCTAssertEqual(BubbleTemplate.all.map(\.name), ["气泡", "方泡", "白色糖果"])
        for template in BubbleTemplate.all {
            XCTAssertNil(BubbleSVG.validate(template.svg), template.name)
            var style = BubbleStyle()
            style.mode = "template"
            style.template = template.id
            let image = BubbleStyleRenderer.image(style: style, label: "42", fontSize: 23, color: .black)
            XCTAssertEqual(image.size.width, 109.0 / 3, accuracy: 0.01)
            XCTAssertEqual(image.size.height, 85.0 / 3, accuracy: 0.01)
            style.mode = "svg"
            style.svg = template.svg
            XCTAssertNil(BubbleStyleStore.validate(style), template.name)
        }
    }

    func testSVGPathCommands() {
        XCTAssertNotNil(BubbleSVG.path("M10 10 L20 20 H30 V40 C40 40 50 50 60 60 S80 80 90 90 Q100 100 110 110 T120 120 A10 5 30 1 0 130 130 Z"))
        XCTAssertNotNil(BubbleSVG.path("m10,10l5-5h10v10c1.5.5 2 2 3 3s1 1 2 2q1 1 2 2t3 3a5 5 0 0 1 10 0z"))
        XCTAssertNil(BubbleSVG.path("L10 10"), "必须以 M 开头")
        XCTAssertNil(BubbleSVG.path("M0 0Z 5"), "Z 后直接跟数字无效")
        XCTAssertNil(BubbleSVG.path("M0 0 X 5"))
        let arc = BubbleSVG.path("M0 50 A50 50 0 0 1 100 50")
        XCTAssertEqual(arc?.boundingBoxOfPath.minY ?? 99, 0, accuracy: 0.5, "半圆弧的顶点在 y=0")
    }

    func testSVGValidationAndTextColour() {
        let svg = "<svg viewBox='0 0 40 30'><g fill='none'><rect x='2' y='2' width='36' height='26' rx='9' stroke='__TEXT__' stroke-width='3' stroke-linecap='round' stroke-linejoin='round'/><circle cx='20' cy='15' r='3' fill='TEXT'/><ellipse cx='5' cy='5' rx='2' ry='1' fill='#f00'/></g></svg>"
        XCTAssertNil(BubbleSVG.validate(svg))
        XCTAssertNotNil(BubbleSVG.validate("<svg viewBox='0 0 10 10'><script/></svg>"))
        XCTAssertNotNil(BubbleSVG.validate("<svg viewBox='0 0 10 10'><rect width='5' height='5' transform='rotate(4)'/></svg>"))
        XCTAssertNotNil(BubbleSVG.validate("<svg><rect width='5' height='5'/></svg>"), "缺 viewBox")
        XCTAssertNotNil(BubbleSVG.validate(""))
        XCTAssertTrue(BubbleSVG.isTextColor("__TEXT__"))
        XCTAssertTrue(BubbleSVG.isTextColor("currentColor"))
        let red = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 30)).image { _ in
            BubbleSVG.draw("<svg viewBox='0 0 40 30'><rect width='40' height='30' fill='__TEXT__'/></svg>",
                           in: CGRect(x: 0, y: 0, width: 40, height: 30), color: .red)
        }
        XCTAssertGreaterThan(red.size.width, 0)
    }

    func testLabelFormatAndValidation() {
        var style = BubbleStyle()
        XCTAssertEqual(style.label("42"), "42")
        style.format = ""
        XCTAssertEqual(style.label("42"), "42")
        style.format = "{n}条"
        XCTAssertEqual(style.label("42"), "42条")
        style.mode = "image"
        XCTAssertEqual(BubbleStyleStore.validate(style), "请先选择一张 PNG 或透明背景图片。")
        style.mode = "template"
        style.scale = 3
        XCTAssertNotNil(BubbleStyleStore.validate(style))
    }

    func testStoreSelectionSizesImportAndExport() throws {
        let suite = "bubble-store-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = BubbleStyleStore(defaults: defaults, runtime: false)
        XCTAssertEqual(store.effectiveSelectedID, "builtin.bubble")
        XCTAssertEqual(store.selectedName, "气泡")
        try store.select("builtin.candy")
        XCTAssertEqual(store.selectedName, "白色糖果")
        try store.setCurrentScale(1.4)
        XCTAssertEqual(store.currentScale, 1.4, accuracy: 0.001)
        XCTAssertEqual(store.resolvedStyle.template, "candy")
        try store.setNumberScale(0.6)
        try store.setPreferSource(true)

        var custom = BubbleStyle()
        custom.name = "我的方泡"
        custom.mode = "svg"
        custom.svg = BubbleTemplate.square.svg
        try store.save(custom)
        try store.select(custom.id)
        try store.setCurrentScale(0.8)
        XCTAssertEqual(store.selectedStyle?.scale ?? 0, 0.8, accuracy: 0.001)

        let reloaded = BubbleStyleStore(defaults: defaults, runtime: false)
        XCTAssertEqual(reloaded.selectedID, custom.id)
        XCTAssertEqual(reloaded.numberScale, 0.6, accuracy: 0.001)
        XCTAssertTrue(reloaded.preferSource)
        XCTAssertEqual(reloaded.builtinScales["candy"] ?? 0, 1.4, accuracy: 0.001)

        let exported = try XCTUnwrap(store.exportCurrentData())
        XCTAssertEqual(try store.importStyles(exported), 1)
        XCTAssertEqual(store.styles.count, 2)
        XCTAssertEqual(store.selectedName, "我的方泡")
        XCTAssertThrowsError(try store.importStyles(Data("{\"format\":\"legado.ios.highlightRules\",\"version\":1,\"rules\":[]}".utf8)))
        try store.delete(store.selectedID ?? "")
        XCTAssertEqual(store.styles.count, 1)
        XCTAssertEqual(store.effectiveSelectedID, "builtin.bubble")
    }

    func testOldDocumentsStillLoad() throws {
        let suite = "bubble-old-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let old = """
        {"styles":[{"id":"a","name":"旧样式","mode":"template","template":"square","showNumber":true,"format":"{n}","followText":true,"colorHex":"#555555","scale":1.2,"aspect":1.8,"svg":""}],"selectedID":"a"}
        """
        defaults.set(Data(old.utf8), forKey: "reader.bubble.styles.v1")
        let store = BubbleStyleStore(defaults: defaults, runtime: false)
        XCTAssertEqual(store.selectedName, "旧样式")
        XCTAssertEqual(store.numberScale, BubbleStyleStore.defaultNumberScale)
        XCTAssertFalse(store.preferSource)
    }

    func testDefaultBubbleKeepsReferenceSize() {
        let bounds = CommentBubble.attachmentBounds(fontSize: 23)
        XCTAssertGreaterThan(bounds.width, 0)
        let image = CommentBubble.image(label: "12", fontSize: 23, color: .black)
        XCTAssertEqual(image.size.height, bounds.height, accuracy: 0.01)
    }
}
