import UIKit
import XCTest
@testable import Legado

/// 正则高亮：CSS 解析、CSS 预设、规则匹配。
@MainActor
final class ReaderHighlightCSSTests: XCTestCase {
    private func rgba(_ color: UIColor?) -> [Int] {
        guard let color else { return [] }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return [r, g, b, a].map { Int(($0 * 255).rounded()) }
    }

    func testColorFormats() {
        XCTAssertEqual(rgba(ReaderHighlightCSS.color("#f60")), [255, 102, 0, 255])
        XCTAssertEqual(rgba(ReaderHighlightCSS.color("#f608")), [255, 102, 0, 136])
        XCTAssertEqual(rgba(ReaderHighlightCSS.color("#1F6FEB")), [31, 111, 235, 255])
        XCTAssertEqual(rgba(ReaderHighlightCSS.color("#1f6feb80")), [31, 111, 235, 128])
        XCTAssertEqual(rgba(ReaderHighlightCSS.color("rgb(255, 0, 0)")), [255, 0, 0, 255])
        XCTAssertEqual(rgba(ReaderHighlightCSS.color("rgba(255, 217, 61, .58)")), [255, 217, 61, 148])
        XCTAssertEqual(rgba(ReaderHighlightCSS.color("rgb(255 0 0 / 50%)")), [255, 0, 0, 128])
        XCTAssertEqual(ReaderHighlightCSS.color("transparent")?.cgColor.alpha, 0)
        XCTAssertNil(ReaderHighlightCSS.color("#12"))
        XCTAssertNil(ReaderHighlightCSS.color("url(x)"))
        XCTAssertEqual(ReaderHighlightCSS.paint("currentColor"), .current)
    }

    func testGradientsRadiusAndDecorations() {
        let css = ReaderHighlightCSS.parse("""
        mark {
          color: linear-gradient(90deg, #ffffff, #fff176);
          background: linear-gradient(to right, rgba(255, 48, 86, .46), rgba(126, 87, 194, .30));
          border-radius: 999px;
          text-decoration: underline dotted;
        }
        """)
        XCTAssertTrue(css.warnings.isEmpty, css.warnings.joined(separator: ","))
        guard case .gradient(let angle, let colors)? = css.color else { return XCTFail("color gradient") }
        XCTAssertEqual(angle, 90)
        XCTAssertEqual(colors.count, 2)
        guard case .gradient(let backgroundAngle, _)? = css.background else { return XCTFail("background gradient") }
        XCTAssertEqual(backgroundAngle, 90)
        XCTAssertEqual(css.radius, 999)
        XCTAssertTrue(css.underline)
        XCTAssertEqual(css.decorationStyle, .dotted)

        let strike = ReaderHighlightCSS.parse("text-decoration: line-through wavy #f00; background-color: #FFD70080;")
        XCTAssertTrue(strike.lineThrough)
        XCTAssertEqual(strike.decorationStyle, .wavy)
        XCTAssertNotNil(strike.decorationColor)
        XCTAssertNotNil(strike.background)

        for style in ["solid", "double", "dotted", "dashed", "wavy"] {
            XCTAssertEqual(ReaderHighlightCSS.parse("text-decoration: underline \(style);").decorationStyle.rawValue, style)
        }
        let none = ReaderHighlightCSS.parse("text-decoration: underline; text-decoration: none;")
        XCTAssertFalse(none.underline)
        XCTAssertTrue(none.decorationNone)

        let invalid = ReaderHighlightCSS.parse("color: ;;; background: url(x); border-radius: abc; font-size: 3px")
        XCTAssertNil(invalid.background)
        XCTAssertNil(invalid.radius)
        XCTAssertFalse(invalid.warnings.isEmpty)
    }

    func testEveryPresetParsesWithoutWarnings() {
        XCTAssertEqual(ReaderHighlightCSSPreset.all.map(\.title), ["柔和标记", "提示底色", "蓝色下划线", "删除线批注", "只用颜色选择器"])
        for preset in ReaderHighlightCSSPreset.all {
            XCTAssertTrue(ReaderHighlightCSS.parse(preset.light).warnings.isEmpty, preset.title)
            XCTAssertTrue(ReaderHighlightCSS.parse(preset.dark).warnings.isEmpty, preset.title)
        }
    }

    /// 每个 CSS 预设套到规则上后，正文里命中的文字都带上预设的效果（试一下预览与阅读页用的是同一段代码）。
    func testPresetsTakeEffectOnMatchedText() {
        let base = ReaderHighlightRule(id: "custom.p", name: "预设", pattern: ReaderHighlightStore.defaultCustomPattern,
                                       lightColor: "E5483D", darkColor: "FF6961")
        for dark in [false, true] {
            for preset in ReaderHighlightCSSPreset.all {
                var rule = base
                rule.lightCSS = preset.light
                rule.darkCSS = preset.dark
                let text = attributed("前文“这是第一句对白。”后文")
                let count = ReaderHighlighter.apply(rules: [rule], to: text, in: NSRange(location: 0, length: text.length),
                                                    foreground: dark ? .white : .black, dark: dark)
                XCTAssertEqual(count, 1, preset.title)
                let location = 3
                let attributes = text.attributes(at: location, effectiveRange: nil)
                switch preset.id {
                case "soft":
                    let drawing = attributes[.readerHighlight] as? ReaderHighlightDrawing
                    XCTAssertNotNil(drawing?.background, preset.title)
                    XCTAssertGreaterThan(drawing?.radius ?? 0, 100)
                case "notice":
                    let drawing = attributes[.readerHighlight] as? ReaderHighlightDrawing
                    XCTAssertNotNil(drawing?.textGradient, preset.title)
                    XCTAssertNotNil(drawing?.background, preset.title)
                    XCTAssertEqual(attributes[.underlineStyle] as? Int, NSUnderlineStyle([.single, .patternDot]).rawValue)
                case "underline":
                    XCTAssertEqual(attributes[.underlineStyle] as? Int, NSUnderlineStyle.single.rawValue)
                    XCTAssertEqual(rgba(attributes[.foregroundColor] as? UIColor), rgba(ReaderHighlightCSS.color(dark ? "#79c0ff" : "#1f6feb")))
                case "strike":
                    XCTAssertEqual(attributes[.strikethroughStyle] as? Int, NSUnderlineStyle([.single, .patternDash]).rawValue)
                case "plain":
                    XCTAssertNil(attributes[.readerHighlight])
                    XCTAssertEqual(rgba(attributes[.foregroundColor] as? UIColor), rgba(UIColor(readerHex: dark ? "FF6961" : "E5483D")))
                default:
                    XCTFail("unknown preset \(preset.id)")
                }
                // 命中外的文字不受影响。
                XCTAssertNil(text.attribute(.readerHighlight, at: 0, effectiveRange: nil))
            }
        }
    }

    private func attributed(_ string: String) -> NSMutableAttributedString {
        NSMutableAttributedString(string: string, attributes: [.font: UIFont.systemFont(ofSize: 18), .foregroundColor: UIColor.black])
    }
}

@MainActor
final class ReaderHighlightMatchingTests: XCTestCase {
    private func apply(_ rules: [ReaderHighlightRule], _ string: String, dark: Bool = false) -> (NSMutableAttributedString, Int) {
        let black = UIColor(red: 0, green: 0, blue: 0, alpha: 1), white = UIColor(red: 1, green: 1, blue: 1, alpha: 1)
        let text = NSMutableAttributedString(string: string, attributes: [.font: UIFont.systemFont(ofSize: 18), .foregroundColor: black])
        let count = ReaderHighlighter.apply(rules: rules, to: text, in: NSRange(location: 0, length: text.length),
                                            foreground: dark ? white : black, dark: dark)
        return (text, count)
    }

    func testBuiltInQuoteRulesMatchTheirQuotes() {
        let sample = "“双引号”‘单引号’「直角」『白直角』【提示】"
        for rule in ReaderHighlightRule.builtIns {
            let (_, count) = apply([rule], sample)
            XCTAssertEqual(count, 1, rule.name)
            XCTAssertNotNil(rule.quotePair, rule.name)
        }
        XCTAssertEqual(ReaderHighlightRule.builtIns.map(\.name), ["“对话”", "‘对话’", "「对话」", "『对话』", "【提示】"])
    }

    func testPageCompensationAndNoCrossParagraph() {
        var rule = ReaderHighlightRule.builtIns[0]
        rule.pageCompensation = true
        let (text, count) = apply([rule], "她说：“没有结束引号\n下一段")
        XCTAssertEqual(count, 1)
        XCTAssertEqual(rgbaHex(text.attribute(.foregroundColor, at: 5, effectiveRange: nil) as? UIColor), rule.lightColor)
        rule.pageCompensation = false
        XCTAssertEqual(apply([rule], "她说：“没有结束引号\n下一段").1, 0)

        var custom = ReaderHighlightRule(id: "custom.x", name: "跨段", pattern: "开始[\\s\\S]*结束")
        custom.noCrossParagraph = true
        let (crossed, crossedCount) = apply([custom], "开始一段\n另一段结束")
        XCTAssertEqual(crossedCount, 1)
        let afterBreak = (crossed.string as NSString).range(of: "另").location
        XCTAssertEqual(rgbaHex(crossed.attribute(.foregroundColor, at: afterBreak, effectiveRange: nil) as? UIColor), "000000")
        custom.noCrossParagraph = false
        let (whole, _) = apply([custom], "开始一段\n另一段结束")
        XCTAssertNotEqual(rgbaHex(whole.attribute(.foregroundColor, at: afterBreak, effectiveRange: nil) as? UIColor), "000000")
    }

    func testLightAndDarkColoursAndCSS() {
        var rule = ReaderHighlightRule(id: "custom.c", name: "颜色", pattern: "灯塔", lightColor: "112233", darkColor: "AABBCC")
        XCTAssertEqual(rgbaHex(apply([rule], "灯塔").0.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor), "112233")
        XCTAssertEqual(rgbaHex(apply([rule], "灯塔", dark: true).0.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor), "AABBCC")
        rule.lightCSS = "color: #ff0000;"
        XCTAssertEqual(rgbaHex(apply([rule], "灯塔", dark: true).0.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor), "FF0000",
                       "深色 CSS 留空时沿用浅色 CSS")
        rule.darkCSS = "color: currentColor;"
        XCTAssertEqual(rgbaHex(apply([rule], "灯塔", dark: true).0.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor), "FFFFFF")
        XCTAssertTrue(ReaderHighlighter.isDark(foreground: UIColor(red: 0.68, green: 0.68, blue: 0.68, alpha: 1)))
        XCTAssertFalse(ReaderHighlighter.isDark(foreground: UIColor(red: 0.2, green: 0.18, blue: 0.15, alpha: 1)))
    }

    func testLaterRulesOverrideEarlierOnesAndFontsApply() {
        let first = ReaderHighlightRule(id: "custom.1", name: "一", pattern: "灯塔", lightColor: "111111")
        var second = ReaderHighlightRule(id: "custom.2", name: "二", pattern: "塔", lightColor: "222222")
        second.fontSize = 30
        second.fontWeight = 7
        let (text, count) = apply([first, second], "灯塔")
        XCTAssertEqual(count, 2)
        XCTAssertEqual(rgbaHex(text.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor), "111111")
        XCTAssertEqual(rgbaHex(text.attribute(.foregroundColor, at: 1, effectiveRange: nil) as? UIColor), "222222")
        XCTAssertEqual((text.attribute(.font, at: 1, effectiveRange: nil) as? UIFont)?.pointSize, 30)
        XCTAssertEqual((text.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)?.pointSize, 18)
        for choice in ReaderHighlighter.fontChoices {
            var rule = second
            rule.fontName = choice.id
            XCTAssertEqual(ReaderHighlighter.font(for: rule, base: .systemFont(ofSize: 18)).pointSize, 30, choice.title)
        }
    }

    func testPaddingImageAndSliceProduceDrawing() throws {
        var rule = ReaderHighlightRule(id: "custom.i", name: "图", pattern: "灯塔")
        rule.paddingHorizontal = 4
        rule.paddingVertical = 2
        rule.lightCSS = "background: #ff000033; border-radius: 6px;"
        let drawing = try XCTUnwrap(apply([rule], "灯塔").0.attribute(.readerHighlight, at: 0, effectiveRange: nil) as? ReaderHighlightDrawing)
        XCTAssertEqual(drawing.paddingX, 4)
        XCTAssertEqual(drawing.paddingY, 2)
        XCTAssertEqual(drawing.radius, 6)
        // 可安全归档（正文选中复制时系统会归档富文本属性）。
        XCTAssertNoThrow(try NSKeyedArchiver.archivedData(withRootObject: drawing, requiringSecureCoding: true))
    }

    func testInvalidOrEmptyPatternIsSkippedNotCrashing() {
        let broken = ReaderHighlightRule(id: "custom.b", name: "坏", pattern: "([未闭合")
        let empty = ReaderHighlightRule(id: "custom.e", name: "空", pattern: "")
        XCTAssertNotNil(broken.regexError)
        XCTAssertNotNil(empty.regexError)
        XCTAssertEqual(apply([broken, empty], "“对白”").1, 0)
    }

    func testStoreOperations() throws {
        let suite = "reader-highlight-store-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ReaderHighlightStore(defaults: defaults)
        let revision = store.revision
        let created = store.newCustomRule()
        XCTAssertNil(created.regexError, "新建规则带可用的默认正则")
        store.save(created)
        XCTAssertGreaterThan(store.revision, revision)
        XCTAssertEqual(store.customRules.count, 1)
        store.setRuleEnabled(created.id, false)
        XCTAssertEqual(store.rule(id: created.id)?.enabled, false)
        let copy = try XCTUnwrap(store.duplicate(created))
        XCTAssertEqual(store.customRules.map(\.id), [created.id, copy.id])
        store.moveCustom(from: IndexSet(integer: 1), to: 0)
        XCTAssertEqual(store.customRules.map(\.id), [copy.id, created.id])
        // 内置规则名称和正则改不了，但颜色能改；恢复内置默认后复原。
        var builtIn = try XCTUnwrap(store.rule(id: "builtin.double"))
        builtIn.name = "改名"
        builtIn.pattern = "x"
        builtIn.lightColor = "000000"
        store.save(builtIn)
        XCTAssertEqual(store.rule(id: "builtin.double")?.name, "“对话”")
        XCTAssertEqual(store.rule(id: "builtin.double")?.lightColor, "000000")
        store.setEnabled(false)
        store.resetAllBuiltIns()
        XCTAssertTrue(store.enabled)
        XCTAssertEqual(store.rule(id: "builtin.double")?.lightColor, ReaderHighlightRule.builtIns[0].lightColor)
        // 导出再导入。
        let data = try XCTUnwrap(store.exportData())
        XCTAssertEqual(try store.importRules(data), 2)
        XCTAssertEqual(store.customRules.count, 4)
        store.delete(created.id)
        XCTAssertNil(store.rule(id: created.id))
        store.delete("builtin.double")
        XCTAssertNotNil(store.rule(id: "builtin.double"), "内置规则不能删除")
        // 重新读取存档。
        let reloaded = ReaderHighlightStore(defaults: defaults)
        XCTAssertEqual(reloaded.customRules.map(\.id), store.customRules.map(\.id))
    }

    private func rgbaHex(_ color: UIColor?) -> String { color?.readerHex ?? "" }
}
