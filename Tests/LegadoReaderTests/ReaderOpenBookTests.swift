import SwiftUI
import UIKit
import XCTest
@testable import Legado

/// 打开书籍的回归测试：在真实窗口里挂上完整的阅读页（ReaderView），分别用默认设置、
/// 旧版本留下的设置（旧主题 id、缺字段 / 损坏的存档）以及开启正则高亮（含渐变、圆角、波浪线规则），
/// 在翻页模式和滚动模式下打开同一本书，并把正文真正画一遍。任何一步闪退都会让整个测试进程失败。
@MainActor
final class ReaderOpenBookTests: XCTestCase {
    /// 测试会改动的设置键：测试前记下原值，测试后原样恢复。
    private static let touchedKeys = [
        "pageAnim", "readerPageAnimation", "readerTheme", "readerPreviousDayTheme", "readerDarkTheme",
        "readerFollowSystemDark", "readerUseBackgroundImage", "readerCustomBackgroundHex", "readerCustomForegroundHex",
        "readerCustomDarkBackgroundHex", "readerCustomDarkForegroundHex",
        "textFont", "textSize", "textBold", "paragraphIndent", "readerParagraphBlankLines", "readerTextCenter",
        "readerTipCustomFont", "titleColorHex", "themeMode", "showsReviewBubbles",
        ReaderHighlightStore.storageKey, ReaderThemeStore.storageKey
    ]
    static let dialogueText = """
    “你回来了？”她站在门口，声音很轻。
    ‘先别说话。’他把伞收起来，「外面还在下雨」，『灯塔第三次亮了』。
    【提示】潮水会在天亮前退去。“这一句没有结束引号，跨页补偿会高亮到段尾
    雨落在旧城的瓦檐上，细密得像一封迟到了许多年的信。林深推开阁楼的窗，远处的灯塔正越过雾气。
    """

    /// 记下设置和正则高亮规则，返回恢复用的闭包（测试结束时调用）。
    private func preserveSettings() -> () -> Void {
        let defaults = UserDefaults.standard
        var saved: [String: Any] = [:]
        for key in Self.touchedKeys { saved[key] = defaults.object(forKey: key) }
        let store = ReaderHighlightStore.shared
        let enabled = store.enabled, rules = store.rules
        return {
            for key in Self.touchedKeys {
                if let value = saved[key] { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
            store.restoreForTesting(enabled: enabled, rules: rules)
        }
    }

    // MARK: - 打开书籍

    func testOpenBookWithDefaultSettingsInPagedAndScrollMode() async throws {
        let restore = preserveSettings()
        defer { restore() }
        resetReaderSettings()
        ReaderHighlightStore.shared.restoreForTesting(enabled: true, rules: ReaderHighlightRule.builtIns)
        for mode in [0, 1, 2, 4, 3] {
            try await openBook(pageAnimation: mode)
        }
    }

    func testOpenBookWithLegacyPersistedSettings() async throws {
        let restore = preserveSettings()
        defer { restore() }
        resetReaderSettings()
        let defaults = UserDefaults.standard
        // 旧版本只存了 readerPageAnimation；主题 id 是旧的 "dark"；各种值超出现在的范围或已不存在。
        defaults.removeObject(forKey: "pageAnim")
        defaults.set(1, forKey: "readerPageAnimation")
        defaults.set("dark", forKey: "readerTheme")
        defaults.set("night", forKey: "readerPreviousDayTheme")
        defaults.set("removed-theme", forKey: "readerDarkTheme")
        defaults.set(true, forKey: "readerFollowSystemDark")
        defaults.set(true, forKey: "readerUseBackgroundImage")
        defaults.set("not-a-colour", forKey: "readerCustomBackgroundHex")
        defaults.set("#12", forKey: "readerCustomForegroundHex")
        defaults.set("/nonexistent/font.ttf", forKey: "textFont")
        defaults.set(9, forKey: "readerParagraphBlankLines")
        defaults.set(true, forKey: "readerTipCustomFont")
        defaults.set("zzzzzz", forKey: "titleColorHex")
        // 旧 / 损坏的存档：解码失败时必须回到默认值。
        defaults.set(Data("{\"version\":1,\"rules\":[{\"id\":\"builtin.double\"}]".utf8), forKey: ReaderHighlightStore.storageKey)
        defaults.set(Data("[{\"name\":1}]".utf8), forKey: ReaderThemeStore.storageKey)
        try await openBook(pageAnimation: nil)
        defaults.set("night", forKey: "readerTheme")
        defaults.set(3, forKey: "pageAnim")
        try await openBook(pageAnimation: nil)
        defaults.set(ReaderStylePreset.customID, forKey: "readerTheme")
        defaults.set(0, forKey: "pageAnim")
        try await openBook(pageAnimation: nil)
    }

    func testOpenBookWithRegexHighlightRulesInPagedAndScrollModeLightAndDark() async throws {
        let restore = preserveSettings()
        defer { restore() }
        resetReaderSettings()
        var rules = ReaderHighlightRule.builtIns.map { rule -> ReaderHighlightRule in
            var value = rule
            value.enabled = true
            return value
        }
        rules[0].lightCSS = ReaderHighlightCSSPreset.all[1].light
        rules[0].darkCSS = ReaderHighlightCSSPreset.all[1].dark
        rules[1].lightCSS = "color: currentColor; background: #FFD70080; border-radius: 999px; text-decoration: underline wavy #f00;"
        rules[2].lightCSS = "text-decoration: line-through double rgba(0,0,0,.5); background-color: rgb(255 0 0 / 30%);"
        rules[2].fontName = "rounded"
        rules[2].fontSize = 26
        rules[2].fontWeight = 7
        var custom = ReaderHighlightRule(id: "custom.test", name: "测试", pattern: "灯塔", lightColor: "E5483D", darkColor: "FF6961")
        custom.lightCSS = "color: linear-gradient(90deg, #f00, #00f); background: linear-gradient(to right, #fff8, transparent); text-decoration: line-through wavy;"
        custom.paddingHorizontal = 3
        custom.paddingVertical = 2
        custom.fontName = "/missing-font.ttf"
        var broken = ReaderHighlightRule(id: "custom.broken", name: "无效正则", pattern: "([未闭合")
        broken.lightCSS = "color: ;;; background: url(x); border-radius: abc"
        rules += [custom, broken]
        ReaderHighlightStore.shared.restoreForTesting(enabled: true, rules: rules)
        for theme in ["wechat", "night"] {
            UserDefaults.standard.set(theme, forKey: "readerTheme")
            for mode in [0, 3] {
                try await openBook(pageAnimation: mode, expectHighlight: true)
            }
        }
    }

    /// 阅读页的正文视图必须一开始就用正则高亮的排版器（不能事后替换系统文本视图的排版器）。
    func testPagedTextViewIsBuiltWithHighlightLayoutManager() {
        let view = ReaderLayoutTextView.makeTextKit1()
        XCTAssertTrue(view.layoutManager is ReaderHighlightLayoutManager)
        XCTAssertTrue(view.textContainer.layoutManager === view.layoutManager)
        XCTAssertNotNil(view.layoutManager.textStorage)
        XCTAssertTrue(view.textStorage === view.layoutManager.textStorage)
        let text = NSMutableAttributedString(string: Self.dialogueText, attributes: [.font: UIFont.systemFont(ofSize: 18), .foregroundColor: UIColor.black])
        ReaderHighlighter.apply(rules: ReaderHighlightRule.builtIns, to: text, in: NSRange(location: 0, length: text.length), foreground: .black, dark: false)
        view.frame = CGRect(x: 0, y: 0, width: 390, height: 600)
        view.attributedText = text
        view.layoutManager.ensureLayout(for: view.textContainer)
        XCTAssertGreaterThan(view.layoutManager.numberOfGlyphs, 0)
        let image = UIGraphicsImageRenderer(bounds: view.bounds).image { context in view.layer.render(in: context.cgContext) }
        XCTAssertGreaterThan(image.size.width, 0)
    }

    // MARK: - 辅助

    private func resetReaderSettings() {
        let defaults = UserDefaults.standard
        for key in Self.touchedKeys where key != ReaderHighlightStore.storageKey && key != ReaderThemeStore.storageKey {
            defaults.removeObject(forKey: key)
        }
        defaults.set(false, forKey: "readerUseBackgroundImage")
    }

    private func openBook(pageAnimation: Int?, expectHighlight: Bool = false,
                          file: StaticString = #filePath, line: UInt = #line) async throws {
        if let pageAnimation { UserDefaults.standard.set(pageAnimation, forKey: "pageAnim") }
        let book = DemoContent.books[0]
        let reader = ReaderView(demoBook: book, chapters: DemoContent.readerChapters, initialIndex: 0,
                                content: Self.dialogueText + DemoContent.readerText)
            .environmentObject(BookLibraryModel.demo(books: DemoContent.books))
            .environmentObject(SourceLibraryModel.demo(sources: DemoContent.sources))
            .environmentObject(ReplaceRuleLibraryModel.demo())
            .environmentObject(ReadingActivityModel.demo())
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            window.windowScene = scene
        }
        let host = UIHostingController(rootView: ReadingNavigationStack { reader })
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        let mode = pageAnimation ?? UserDefaults.standard.integer(forKey: "pageAnim")
        var found = false
        for _ in 0..<40 {
            try await Task.sleep(nanoseconds: 100_000_000)
            host.view.layoutIfNeeded()
            if mode == 3 {
                if let scroll = Self.find(ReaderScrollCollectionView.self, in: host.view), !scroll.visibleCells.isEmpty { found = true; break }
            } else if let text = Self.find(ReaderLayoutTextView.self, in: host.view), text.textStorage.length > 0 {
                found = true
                break
            }
        }
        XCTAssertTrue(found, "阅读页正文没有出现（翻页模式 \(mode)）", file: file, line: line)
        // 把整个阅读页画一遍：高亮背景、渐变文字、波浪线都走自绘排版器。
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        XCTAssertGreaterThan(image.size.height, 0, file: file, line: line)
        if mode != 3, let text = Self.find(ReaderLayoutTextView.self, in: host.view) {
            XCTAssertTrue(text.layoutManager is ReaderHighlightLayoutManager, file: file, line: line)
            XCTAssertTrue(text.textContainer.layoutManager === text.layoutManager, file: file, line: line)
            _ = UIGraphicsImageRenderer(bounds: text.bounds).image { context in text.layer.render(in: context.cgContext) }
            if expectHighlight {
                var highlighted = false
                text.textStorage.enumerateAttribute(.readerHighlight, in: NSRange(location: 0, length: text.textStorage.length)) { value, _, stop in
                    if value != nil { highlighted = true; stop.pointee = true }
                }
                XCTAssertTrue(highlighted, "正则高亮没有作用到正文（翻页模式 \(mode)）", file: file, line: line)
            }
        }
        if mode == 3, let scroll = Self.find(ReaderScrollCollectionView.self, in: host.view) {
            _ = UIGraphicsImageRenderer(bounds: scroll.bounds).image { context in scroll.layer.render(in: context.cgContext) }
        }
    }

    static func find<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let match = find(type, in: subview) { return match }
        }
        return nil
    }
}

@MainActor
final class ReaderLegacySettingsDecodingTests: XCTestCase {
    func testHighlightStoreFallsBackToDefaultsForCorruptOrOldData() throws {
        let suite = "reader-highlight-legacy-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("not json".utf8), forKey: ReaderHighlightStore.storageKey)
        let corrupt = ReaderHighlightStore(defaults: defaults)
        XCTAssertTrue(corrupt.enabled)
        XCTAssertEqual(corrupt.builtInRules.map(\.id), ReaderHighlightRule.builtIns.map(\.id))

        // 只有部分字段的旧存档：缺的字段取默认值，内置规则的名称和正则用当前定义。
        let old = """
        {"version":1,"enabled":false,"rules":[{"id":"builtin.double","name":"旧名字","pattern":"x","lightColor":"112233"},
        {"id":"custom.a","pattern":"灯塔"},{"id":"custom.b"}]}
        """
        defaults.set(Data(old.utf8), forKey: ReaderHighlightStore.storageKey)
        let store = ReaderHighlightStore(defaults: defaults)
        XCTAssertFalse(store.enabled)
        XCTAssertEqual(store.rule(id: "builtin.double")?.name, "“对话”")
        XCTAssertEqual(store.rule(id: "builtin.double")?.lightColor, "112233")
        XCTAssertEqual(store.rule(id: "custom.a")?.name, "规则")
        XCTAssertEqual(store.customRules.count, 2)
    }

    func testThemeIDsFromOlderVersionsResolve() {
        XCTAssertEqual(ReaderStylePreset.resolve("dark").id, "night")
        XCTAssertEqual(ReaderStylePreset.resolve("light").id, "preset1")
        XCTAssertEqual(ReaderStylePreset.resolve("paper").id, "preset2")
        XCTAssertEqual(ReaderStylePreset.resolve("removed").id, "wechat")
        XCTAssertTrue(ReaderStylePreset.resolve("dark").isDark)
    }
}
