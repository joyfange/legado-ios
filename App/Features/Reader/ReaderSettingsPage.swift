import AVFoundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers
#if SWIFT_PACKAGE
import LegadoCore
#endif

// MARK: - 阅读设置（主题 / 显示 / 朗读）

/// 参考应用的「阅读设置」：顶部「主题 / 显示 / 朗读」分段 +「完成」，每项是一张跟随外观主题的卡片
/// （系统 / 透明 / 毛玻璃）。所有设置与阅读页共用同一组存储键，改动立即作用在正文上。
/// 「我的 › 阅读设置」直接推入；阅读页里的「外观」「阅读设置」以半屏面板打开，并带上只在阅读页才有的项目。
struct ReaderSettingsPage: View {
    enum Tab: Int, CaseIterable {
        case theme, display, speech
        var title: String {
            switch self {
            case .theme: "主题"
            case .display: "显示"
            case .speech: "朗读"
            }
        }
    }

    /// 阅读页打开时额外提供：本书的翻页模式、只在阅读页才有的操作、关闭面板。
    struct ReaderContext {
        var pageAnimation: Binding<Int>
        var displayExtras: AnyView
        var speechExtras: AnyView
        var close: () -> Void
    }

    let context: ReaderContext?
    @State private var tab: Tab
    @Environment(\.dismiss) private var dismiss

    init(initialTab: Tab = .theme, context: ReaderContext? = nil) {
        self.context = context
        _tab = State(initialValue: initialTab)
    }

    var body: some View {
        if context != nil {
            ReadingNavigationStack { page }
        } else {
            page
        }
    }

    private var page: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                switch tab {
                case .theme: ReaderThemeSettingsTab(pageAnimation: context?.pageAnimation)
                case .display: ReaderDisplaySettingsTab(extras: context?.displayExtras)
                case .speech: ReaderSpeechSettingsTab(extras: context?.speechExtras)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 48)
        }
        .background { AppThemeCanvas().ignoresSafeArea() }
        .navigationTitle("阅读设置")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("阅读设置", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
                .accessibilityIdentifier("reader.settings.tabs")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") {
                    if let context { context.close() } else { dismiss() }
                }
            }
        }
    }
}

// MARK: - 通用小组件

/// 卡片下方的灰色说明文字。
struct ReaderSettingsFootnote: View {
    @ThemePalette private var palette
    let text: String
    var body: some View {
        Text(text)
            .font(AppFontStyle.footnote.themed)
            .foregroundStyle(palette.secondary)
            .padding(.horizontal, 6)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// 一排主题色块（文字「文」 + 名称），选中时强调色描边。
private struct ReaderThemeSwatch: View {
    @ThemePalette private var palette
    let name: String
    let background: UIColor
    let foreground: UIColor
    let selected: Bool
    var image: UIImage? = nil
    /// 右下角小图标（「自定义」色块用来提示可以编辑）。
    var badge: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(uiColor: background))
                    .frame(width: 50, height: 50)
                    .overlay {
                        if let image {
                            Image(uiImage: image).resizable().scaledToFill()
                                .frame(width: 50, height: 50)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if let badge {
                            Image(systemName: badge)
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(Color(uiColor: background))
                                .frame(width: 15, height: 15)
                                .background(Circle().fill(Color(uiColor: foreground).opacity(0.75)))
                                .padding(3)
                        }
                    }
                    .overlay {
                        Text("文")
                            .font(.system(size: 19, weight: .medium))
                            .foregroundStyle(Color(uiColor: foreground))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(selected ? palette.accent : Color(uiColor: foreground).opacity(0.14),
                                          lineWidth: selected ? 2 : 0.75)
                    }
                Text(name)
                    .font(AppFontStyle.caption.themed)
                    .foregroundStyle(selected ? palette.primary : palette.secondary)
                    .lineLimit(1)
            }
            .frame(width: 62)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// 页眉页脚的字体：开启「组件使用自定义字体」时用阅读正文字体（同一字体文件只读一次）。
@MainActor
enum ReaderTipFont {
    private static var cachedPath = ""
    private static var cachedFont: UIFont?

    private static var readerFonts: [String: UIFont] = [:]

    /// 阅读字体文件按「路径 / 字号 / 字重」缓存，设置页拖动字号时不反复读文件。
    static func readerFont(path: String, size: CGFloat, weight: Int) -> UIFont? {
        guard !path.isEmpty else { return nil }
        let key = "\(path)|\(size)|\(weight)"
        if let cached = readerFonts[key] { return cached }
        guard let font = ReaderFontStore.font(at: path, size: size, weight: weight) else { return nil }
        if readerFonts.count > 24 { readerFonts.removeAll() }
        readerFonts[key] = font
        return font
    }

    static func font(path: String, enabled: Bool) -> Font {
        guard enabled, !path.isEmpty else { return .system(size: 12) }
        if cachedPath != path {
            cachedPath = path
            cachedFont = ReaderFontStore.font(at: path, size: 12, weight: 0)
        }
        guard let cachedFont else { return .system(size: 12) }
        return Font(cachedFont as CTFont)
    }
}

// MARK: - 主题

private struct ReaderThemeSettingsTab: View {
    let pageAnimation: Binding<Int>?
    @ThemePalette private var palette
    @ObservedObject private var highlights = ReaderHighlightStore.shared
    @ObservedObject private var bubbleStyles = BubbleStyleStore.shared
    @ObservedObject private var themes = ReaderThemeStore.shared

    @AppStorage("pageAnim") private var storedPageAnimation = 0
    @AppStorage("readerFullScreenTurn") private var fullScreenTurn = false
    @AppStorage("readerSwipeUpExit") private var swipeUpExit = false
    @AppStorage("readerTheme") private var theme = "wechat"
    @AppStorage("readerPreviousDayTheme") private var previousDayTheme = "wechat"
    @AppStorage("readerDarkTheme") private var darkTheme = "night"
    @AppStorage("readerFollowSystemDark") private var followSystemDark = false
    @AppStorage("readerUseBackgroundImage") private var useBackgroundImage = false
    @AppStorage("readerBackgroundRevision") private var backgroundRevision = 0
    @AppStorage(ReaderStylePreset.customBackgroundKey) private var customBackgroundHex = ReaderStylePreset.defaultCustomBackground
    @AppStorage(ReaderStylePreset.customForegroundKey) private var customForegroundHex = ReaderStylePreset.defaultCustomForeground
    @AppStorage(ReaderStylePreset.customDarkBackgroundKey) private var customDarkBackgroundHex = ReaderStylePreset.defaultCustomDarkBackground
    @AppStorage(ReaderStylePreset.customDarkForegroundKey) private var customDarkForegroundHex = ReaderStylePreset.defaultCustomDarkForeground
    @AppStorage(ReaderCustomThemeImage.lightUseKey) private var customUsesImage = false
    @AppStorage(ReaderCustomThemeImage.darkUseKey) private var customDarkUsesImage = false
    @AppStorage("themeMode") private var themeMode = "0"
    @AppStorage("textSize") private var fontSize = 20.0
    @AppStorage("textBold") private var fontWeight = 0
    @AppStorage("textFont") private var fontPath = ""
    @AppStorage("underlineMode") private var underlineMode = 0
    @AppStorage("letterSpacing") private var letterSpacing = 0.1
    @AppStorage("lineSpacingExtra") private var lineSpacing = 12.0
    @AppStorage("paragraphSpacing") private var paragraphSpacing = 2.0
    @AppStorage("paragraphIndent") private var paragraphIndent = "　　"
    @AppStorage("paddingLeft") private var paddingLeft = 16.0
    @AppStorage("paddingRight") private var paddingRight = 16.0
    @AppStorage("paddingTop") private var paddingTop = 6.0
    @AppStorage("paddingBottom") private var paddingBottom = 6.0
    @AppStorage("titleMode") private var titleMode = 0
    @AppStorage("titleSize") private var titleSize = 0.0
    @AppStorage("titleTopSpacing") private var titleTopSpacing = 0.0
    @AppStorage("titleBottomSpacing") private var titleBottomSpacing = 0.0
    @AppStorage("titleColorHex") private var titleColorHex = ""
    @AppStorage("titleBold") private var titleBold = true
    @AppStorage("readerFullJustify") private var fullJustify = true
    @AppStorage("readerTextCenter") private var centerText = false
    @AppStorage("readerParagraphBlankLines") private var paragraphBlankLines = 0
    @AppStorage("headerMode") private var headerMode = 0
    @AppStorage("footerMode") private var footerMode = 0
    @AppStorage("tipHeaderLeft") private var tipHeaderLeft = 2
    @AppStorage("tipHeaderMiddle") private var tipHeaderMiddle = 0
    @AppStorage("tipHeaderRight") private var tipHeaderRight = 3
    @AppStorage("tipFooterLeft") private var tipFooterLeft = 1
    @AppStorage("tipFooterMiddle") private var tipFooterMiddle = 0
    @AppStorage("tipFooterRight") private var tipFooterRight = 6
    @AppStorage("showHeaderLine") private var showHeaderLine = false
    @AppStorage("showFooterLine") private var showFooterLine = true
    @AppStorage("readerTipCustomFont") private var tipCustomFont = false
    @AppStorage("showsReviewBubbles") private var showsReviewBubbles = true

    @State private var backgroundImage: UIImage?
    @State private var darkBackgroundImage: UIImage?
    /// 正在编辑的自定义主题：false 浅色、true 深色。
    @State private var customEditorDark: Bool?
    @State private var showsBackgroundPicker = false
    /// 字体文件与主题包共用一个文件选择器（同一页面上多个 fileImporter 在旧系统上会互相抢）。
    @State private var showsImporter = false
    @State private var importsFont = false
    @State private var showsSaveTheme = false
    @State private var confirmsReset = false
    @State private var confirmsTipReset = false
    @State private var exportURL: URL?
    @State private var message: String?
    @State private var fontMessage: String?
    @State private var newThemeName = ""

    private var animationBinding: Binding<Int> { pageAnimation ?? $storedPageAnimation }

    /// 阅读页当前用的主题（与阅读页一致：开启「跟随系统深色模式」时按系统明暗取浅色 / 深色主题）。
    private var currentStyle: ReaderStylePreset {
        _ = (customBackgroundHex, customForegroundHex, customDarkBackgroundHex, customDarkForegroundHex)
        if followSystemDark {
            if systemPrefersDark {
                return ReaderStylePreset.resolve(ReaderStylePreset.darkIDs.contains(darkTheme) ? darkTheme : "night")
            }
            if ReaderStylePreset.darkIDs.contains(theme) {
                return ReaderStylePreset.resolve(ReaderStylePreset.darkIDs.contains(previousDayTheme) ? "wechat" : previousDayTheme)
            }
        }
        return .resolve(theme)
    }

    private var systemPrefersDark: Bool {
        switch themeMode {
        case "2": return true
        case "1", "3": return false
        default:
            let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
            return (scene?.traitCollection.userInterfaceStyle ?? .light) == .dark
        }
    }

    var body: some View {
        Group {
            pageTurnSection
            AppearanceGroup("手势", prominent: true) {
                AppearanceToggleRow(title: "上滑退出阅读", isOn: $swipeUpExit)
                ReaderSettingsFootnote(text: "按页翻的模式下，在正文上快速向上滑动返回；上下滚动模式里上滑仍是滚动。")
            }
            themeSection
            backgroundSection
            fontSection
        }
        .onAppear {
            // 旧版「使用背景图」（任何主题都铺图）并入当前一侧的自定义主题，外观不变。
            ReaderCustomThemeImage.migrateLegacyBackground(current: currentStyle)
            reloadBackgroundImages()
        }
        .sheet(isPresented: Binding(get: { customEditorDark != nil }, set: { if !$0 { customEditorDark = nil } })) {
            if let dark = customEditorDark {
                ReaderCustomThemeEditor(dark: dark) { saved in
                    customEditorDark = nil
                    if saved {
                        reloadBackgroundImages()
                        selectCustom(dark: dark)
                        backgroundRevision &+= 1
                    }
                }
            }
        }
        Group {
            AppearanceGroup("底线设置", prominent: true) {
                AppearanceSegmentedCard(title: "文字底线", options: [(0, "关闭"), (1, "实线"), (2, "虚线")], selection: $underlineMode)
                ReaderSettingsFootnote(text: "开启后在正文每一行文字下方画线，像横格纸一样辅助阅读。")
            }
            tipSection
            spacingSection
            titleSection
            layoutSection
        }
        Group {
        AppearanceGroup("高亮设置", prominent: true) {
            SwiftUI.NavigationLink {
                ReaderHighlightSettingsView()
            } label: {
                AppearanceRowLabel(title: "正则高亮", icon: "highlighter",
                                   value: highlights.enabled ? "已启用 \(highlights.enabledCount) 条" : "已关闭", chevron: true)
            }
            .buttonStyle(.plain)
            ReaderSettingsFootnote(text: "按正则给对话、提示等文字上色，可用 CSS 做底色、圆角、渐变和下划线。")
        }
        bubbleSection
        themeFileSection
        }
    }

    // MARK: 翻页

    private static let pageModes: [(Int, String)] = [(2, "仿真"), (1, "滑动"), (0, "覆盖"), (4, "无动画"), (3, "上下滚动")]

    private var pageModeDescription: String {
        switch animationBinding.wrappedValue {
        case 2: "模拟真实翻书效果，页面卷曲翻转。"
        case 1: "整页从侧边推入，像左右滑动翻页。"
        case 4: "直接换页，没有过渡动画，最省电。"
        case 3: "上下连续滚动阅读，章节之间无缝衔接。"
        default: "整页平滑移到下一页。"
        }
    }

    private var pageTurnSection: some View {
        Group {
            AppearanceGroup("翻页模式", prominent: true) {
                AppearanceSegmentedCard(options: Self.pageModes, selection: animationBinding)
                ReaderSettingsFootnote(text: pageModeDescription)
            }
            AppearanceGroup {
                AppearanceToggleRow(title: "全屏翻页", isOn: $fullScreenTurn)
                ReaderSettingsFootnote(text: "开启后点屏幕左侧也翻到下一页（中间仍打开菜单），适合单手阅读。")
            }
        }
    }

    // MARK: 主题色

    private var themeSection: some View {
        Group {
            AppearanceGroup("浅色主题", prominent: true) {
                swatchCard(ReaderStylePreset.lightPresets, dark: false, includesCustom: true)
            }
            AppearanceGroup("深色主题", prominent: true) {
                swatchCard(ReaderStylePreset.darkPresets, dark: true, includesCustom: true)
            }
            if !themes.themes.isEmpty {
                AppearanceGroup("我的主题", prominent: true) {
                    savedThemesCard
                    ReaderSettingsFootnote(text: "轻点使用；长按可导出或删除。")
                }
            }
            AppearanceGroup("自动切换", prominent: true) {
                AppearanceToggleRow(title: "跟随系统深色模式", isOn: $followSystemDark)
                ReaderSettingsFootnote(text: "系统切到深色时自动换成上面选中的深色主题（含自定义），切回浅色时恢复选中的浅色主题。")
            }
        }
    }

    private func isSelected(_ preset: ReaderStylePreset, dark: Bool) -> Bool {
        isSelected(id: preset.id, dark: dark)
    }

    /// 选中状态：开启「跟随系统深色模式」时两排各自显示所选的浅色 / 深色主题。
    private func isSelected(id: String, dark: Bool) -> Bool {
        if useBackgroundImage && backgroundImage != nil { return false }
        if followSystemDark {
            if dark { return darkTheme == id || (theme == id && ReaderStylePreset.darkIDs.contains(id)) }
            return ReaderStylePreset.darkIDs.contains(theme) ? previousDayTheme == id : theme == id
        }
        return currentStyle.id == id
    }

    private func swatchCard(_ presets: [ReaderStylePreset], dark: Bool, includesCustom: Bool) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(presets) { preset in
                    ReaderThemeSwatch(name: preset.name, background: preset.background, foreground: preset.foreground,
                                      selected: isSelected(preset, dark: dark)) {
                        select(preset.id, dark: dark)
                    }
                }
                if includesCustom {
                    // 「自定义」：轻点打开编辑器（文字颜色、背景颜色、背景图、实时预览），保存后作为这一侧的自定义主题使用。
                    let custom = ReaderStylePreset.custom(dark: dark)
                    let usesImage = dark ? customDarkUsesImage : customUsesImage
                    ReaderThemeSwatch(name: "自定义", background: custom.background, foreground: custom.foreground,
                                      selected: isSelected(id: custom.id, dark: dark),
                                      image: usesImage ? (dark ? darkBackgroundImage : backgroundImage) : nil,
                                      badge: "slider.horizontal.3") {
                        UISelectionFeedbackGenerator().selectionChanged()
                        customEditorDark = dark
                    }
                    .accessibilityIdentifier(dark ? "reader.theme.customDark" : "reader.theme.customLight")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { ThemeCardSurface(radius: 14) }
    }

    /// 选中某一侧的自定义主题（关闭旧版全局背景图开关，背景图由自定义主题自己决定）。
    private func selectCustom(dark: Bool) {
        useBackgroundImage = false
        let id = dark ? ReaderStylePreset.customDarkID : ReaderStylePreset.customID
        if dark { darkTheme = id } else { previousDayTheme = id }
        theme = id
    }

    private func reloadBackgroundImages() {
        backgroundImage = ReaderBackgroundStore.load()
        darkBackgroundImage = ReaderCustomThemeImage.load(dark: true)
    }

    private func select(_ id: String, dark: Bool) {
        UISelectionFeedbackGenerator().selectionChanged()
        useBackgroundImage = false
        if dark {
            darkTheme = id
        } else {
            previousDayTheme = id
        }
        theme = id
    }

    private var savedThemesCard: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(themes.themes) { item in
                    ReaderThemeSwatch(name: item.name, background: item.previewBackground, foreground: item.previewForeground,
                                      selected: false) {
                        themes.apply(item)
                        reloadBackgroundImages()
                        backgroundRevision &+= 1
                        message = "已使用「\(item.name)」"
                    }
                    .contextMenu {
                        Button { exportURL = themes.exportURL(item) } label: { Label("导出", systemImage: "square.and.arrow.up") }
                        Button(role: .destructive) { themes.delete(item.id) } label: { Label("删除", systemImage: "trash") }
                    }
                }
            }
            .padding(12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { ThemeCardSurface(radius: 14) }
    }

    // MARK: 背景

    /// 背景设置作用在「当前一侧」：当前是深色主题就改深色的自定义主题，否则改浅色的自定义主题。
    private var editsDarkSide: Bool { currentStyle.isDark }

    private var sideImage: UIImage? { editsDarkSide ? darkBackgroundImage : backgroundImage }

    private var sideUsesImage: Bool { editsDarkSide ? customDarkUsesImage : customUsesImage }

    /// 阅读页现在是否铺着背景图（旧版全局开关或当前自定义主题带图）。
    private var usesImage: Bool {
        if useBackgroundImage { return backgroundImage != nil }
        return currentStyle.isCustom && sideUsesImage && sideImage != nil
    }

    private var backgroundSection: some View {
        AppearanceGroup("背景设置", prominent: true) {
            backgroundPreview
            if sideImage != nil {
                AppearanceToggleRow(title: "使用背景图", isOn: Binding(
                    get: { currentStyle.isCustom && sideUsesImage },
                    set: { value in
                        startCustomizing()
                        setSideUsesImage(value)
                        backgroundRevision &+= 1
                    }
                ))
            }
            Button { showsBackgroundPicker = true } label: {
                AppearanceRowLabel(title: sideImage == nil ? "选择背景图片" : "更换背景图片", icon: "photo", chevron: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("选择背景图片")
            if sideImage != nil {
                Button {
                    try? FileManager.default.removeItem(at: ReaderCustomThemeImage.url(dark: editsDarkSide))
                    setSideUsesImage(false)
                    reloadBackgroundImages()
                    backgroundRevision &+= 1
                } label: {
                    AppearanceRowLabel(title: "删除背景图片", icon: "trash")
                }
                .buttonStyle(.plain)
            }
            AppearanceColorRow(title: "文字颜色", hex: currentStyle.foreground.readerHex) { hex in
                customize(foreground: hex)
            }
            AppearanceColorRow(title: "背景颜色", hex: currentStyle.background.readerHex) { hex in
                customize(background: hex)
            }
            Button { customEditorDark = editsDarkSide } label: {
                AppearanceRowLabel(title: editsDarkSide ? "编辑深色自定义主题" : "编辑浅色自定义主题",
                                   icon: "slider.horizontal.3", chevron: true)
            }
            .buttonStyle(.plain)
            ReaderSettingsFootnote(text: editsDarkSide
                ? "当前是深色主题：改文字颜色、背景颜色或背景图会保存到深色的「自定义」主题并立即使用；选择上面的主题色块可换回预设。"
                : "当前是浅色主题：改文字颜色、背景颜色或背景图会保存到浅色的「自定义」主题并立即使用；选择上面的主题色块可换回预设。")
        }
        .readingPhotoPicker(isPresented: $showsBackgroundPicker) { data in
                do {
                    let dark = editsDarkSide
                    startCustomizing()
                    _ = try ReaderBackgroundStore.save(data, to: ReaderCustomThemeImage.url(dark: dark))
                    if dark { customDarkUsesImage = true } else { customUsesImage = true }
                    reloadBackgroundImages()
                    selectCustom(dark: dark)
                    backgroundRevision &+= 1
                    message = nil
                } catch {
                    message = error.localizedDescription
                }
            } onError: { error in
                message = error.localizedDescription
            }
    }

    private func setSideUsesImage(_ value: Bool) {
        if editsDarkSide { customDarkUsesImage = value } else { customUsesImage = value }
    }

    private var backgroundPreview: some View {
        let style = currentStyle
        let image = useBackgroundImage ? backgroundImage : (usesImage ? sideImage : nil)
        return VStack(alignment: .leading, spacing: 4) {
            Text("背景预览").font(.system(size: 17, weight: .semibold))
            Text(usesImage ? "当前使用背景图" : "当前使用纯色背景").font(.system(size: 12))
                .opacity(0.7)
            Spacer(minLength: 18)
            Text("春风又绿江南岸，明月何时照我还。")
                .font(previewFont(size: 18))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .foregroundStyle(Color(uiColor: style.foreground))
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 150, maxHeight: 150, alignment: .topLeading)
        .background {
            // 背景图放在 background 里：按卡片大小铺满裁切，不会把卡片撑宽。
            ZStack {
                Color(uiColor: style.background)
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color(uiColor: style.foreground).opacity(0.1), lineWidth: 0.75)
        }
        .accessibilityElement(children: .combine)
    }

    /// 从预设开始改时，先把预设的颜色抄进这一侧的自定义主题（之后只改用户动的那一项），并切到自定义主题。
    private func startCustomizing() {
        let style = currentStyle
        let dark = style.isDark
        if !style.isCustom {
            if dark {
                customDarkBackgroundHex = style.background.readerHex
                customDarkForegroundHex = style.foreground.readerHex
                customDarkUsesImage = false
            } else {
                customBackgroundHex = style.background.readerHex
                customForegroundHex = style.foreground.readerHex
                customUsesImage = false
            }
        }
        selectCustom(dark: dark)
    }

    private func customize(foreground: String? = nil, background: String? = nil) {
        let dark = editsDarkSide
        startCustomizing()
        if let foreground, !foreground.isEmpty {
            if dark { customDarkForegroundHex = foreground } else { customForegroundHex = foreground }
        }
        if let background, !background.isEmpty {
            if dark { customDarkBackgroundHex = background } else { customBackgroundHex = background }
        }
    }

    // MARK: 字体

    private func previewFont(size: Double) -> Font {
        if let font = ReaderTipFont.readerFont(path: fontPath, size: CGFloat(size), weight: fontWeight) {
            return Font(font as CTFont)
        }
        let weight: Font.Weight = fontWeight == 1 ? .bold : (fontWeight == 2 ? .light : .regular)
        return .system(size: CGFloat(size), weight: weight, design: .serif)
    }

    private var fontTitle: String {
        fontPath.isEmpty ? "系统默认" : (URL(fileURLWithPath: fontPath).deletingPathExtension().lastPathComponent)
    }

    private var fontSection: some View {
        AppearanceGroup("字体样式", prominent: true) {
            AppearanceCard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("字号").font(AppFontStyle.body.themed).foregroundStyle(palette.primary)
                        Spacer()
                        Text("\(Int(fontSize))").font(AppFontStyle.subheadline.themed.monospacedDigit())
                            .foregroundStyle(palette.secondary)
                    }
                    HStack(spacing: 10) {
                        Button { fontSize = max(5, fontSize - 1) } label: {
                            Image(systemName: "textformat.size.smaller").frame(width: 30, height: 30)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(palette.accent)
                        .accessibilityLabel("字号减小")
                        AppearanceSlider(value: $fontSize, range: 5...50, step: 1)
                        Button { fontSize = min(50, fontSize + 1) } label: {
                            Image(systemName: "textformat.size.larger").frame(width: 30, height: 30)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(palette.accent)
                        .accessibilityLabel("字号增大")
                    }
                    Text("预览文字 \(Int(fontSize))pt")
                        .font(previewFont(size: fontSize))
                        .foregroundStyle(palette.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 4)
                }
            }
            AppearanceSegmentedCard(title: "字重", options: [(2, "细体"), (0, "正常"), (1, "粗体")], selection: $fontWeight)
            Menu {
                Button { fontPath = "" } label: {
                    Label("系统默认", systemImage: fontPath.isEmpty ? "checkmark" : "textformat")
                }
                ForEach(ReaderHighlighter.importedFonts(), id: \.self) { file in
                    let path = ReaderFontStore.directory.appendingPathComponent(file).path
                    Button { fontPath = path } label: {
                        Label((file as NSString).deletingPathExtension, systemImage: fontPath == path ? "checkmark" : "textformat")
                    }
                }
                Divider()
                Button { importsFont = true; showsImporter = true } label: { Label("导入字体文件…", systemImage: "square.and.arrow.down") }
            } label: {
                AppearanceRowLabel(title: "字体", icon: "textformat", value: fontTitle, chevron: true)
            }
            .buttonStyle(.plain)
            if let fontMessage {
                ReaderSettingsFootnote(text: fontMessage)
            }
        }
    }

    // MARK: 页眉页脚

    private static let tipChoices: [(Int, String)] = [
        (0, "无"), (7, "书名"), (1, "标题"), (2, "时间"), (3, "电量"),
        (10, "电量%"), (4, "页数"), (5, "进度(%)"), (11, "进度(xx/yyy)"),
        (6, "页数及进度"), (8, "时间及电量"), (9, "时间及电量%")
    ]

    private var tipSection: some View {
        AppearanceGroup("页眉页脚", prominent: true) {
            Group {
                AppearancePickerRow(title: "页眉显示", options: [(0, "状态栏显示时隐藏"), (1, "显示"), (2, "隐藏")], selection: $headerMode)
                AppearancePickerRow(title: "页脚显示", options: [(0, "显示"), (1, "隐藏")], selection: $footerMode)
                AppearancePickerRow(title: "页眉左", options: Self.tipChoices, selection: $tipHeaderLeft)
                AppearancePickerRow(title: "页眉中", options: Self.tipChoices, selection: $tipHeaderMiddle)
                AppearancePickerRow(title: "页眉右", options: Self.tipChoices, selection: $tipHeaderRight)
            }
            Group {
                AppearancePickerRow(title: "页脚左", options: Self.tipChoices, selection: $tipFooterLeft)
                AppearancePickerRow(title: "页脚中", options: Self.tipChoices, selection: $tipFooterMiddle)
                AppearancePickerRow(title: "页脚右", options: Self.tipChoices, selection: $tipFooterRight)
                AppearanceToggleRow(title: "页眉分隔线", isOn: $showHeaderLine)
                AppearanceToggleRow(title: "页脚分隔线", isOn: $showFooterLine)
                AppearanceToggleRow(title: "组件使用自定义字体", isOn: $tipCustomFont)
            }
            SwiftUI.NavigationLink {
                ReaderTipPaddingPage()
            } label: {
                AppearanceRowLabel(title: "页眉页脚边距", icon: "rectangle.topthird.inset.filled", chevron: true)
            }
            .buttonStyle(.plain)
            Button { confirmsTipReset = true } label: {
                Text("恢复默认设置")
                    .font(AppFontStyle.subheadline.themed)
                    .foregroundStyle(palette.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
            .confirmationDialog("页眉页脚恢复默认？", isPresented: $confirmsTipReset, titleVisibility: .visible) {
                Button("恢复默认设置", role: .destructive) { ReaderThemeStore.resetTipSettings() }
                Button("取消", role: .cancel) {}
            }
            ReaderSettingsFootnote(text: "「组件使用自定义字体」开启后，页眉页脚的文字也用阅读正文的字体。")
        }
    }

    // MARK: 间距

    private var spacingSection: some View {
        AppearanceGroup("间距设置", prominent: true) {
            AppearanceSliderRow(title: "行间距", value: $lineSpacing, range: 0...50, step: 1) { "\(Int($0))" }
            AppearanceSliderRow(title: "段间距", value: $paragraphSpacing, range: 0...50, step: 0.5) { String(format: "%.1f", $0) }
            AppearanceSliderRow(title: "左边距", value: $paddingLeft, range: 0...100, step: 1) { "\(Int($0))" }
            AppearanceSliderRow(title: "右边距", value: $paddingRight, range: 0...100, step: 1) { "\(Int($0))" }
            AppearanceSliderRow(title: "上边距", value: $paddingTop, range: 0...100, step: 1) { "\(Int($0))" }
            AppearanceSliderRow(title: "下边距", value: $paddingBottom, range: 0...100, step: 1) { "\(Int($0))" }
        }
    }

    // MARK: 章节标题

    private var titleSection: some View {
        AppearanceGroup("章节标题样式", prominent: true) {
            AppearanceSegmentedCard(title: "标题位置", options: [(0, "左对齐"), (1, "居中"), (2, "隐藏")], selection: $titleMode)
            AppearanceSliderRow(title: "标题字号增量", value: $titleSize, range: -10...30, step: 1) { String(format: "%+.0f", $0) }
            AppearanceToggleRow(title: "标题加粗", isOn: $titleBold)
            AppearanceColorRow(title: "标题颜色", hex: titleColorHex.isEmpty ? currentStyle.foreground.readerHex : titleColorHex) { hex in
                titleColorHex = hex
            }
            if !titleColorHex.isEmpty {
                Button { titleColorHex = "" } label: {
                    AppearanceRowLabel(title: "标题颜色跟随正文", icon: "arrow.uturn.backward")
                }
                .buttonStyle(.plain)
            }
            AppearanceSliderRow(title: "标题上间距", value: $titleTopSpacing, range: 0...100, step: 1) { "\(Int($0))" }
            AppearanceSliderRow(title: "标题下间距", value: $titleBottomSpacing, range: 0...100, step: 1) { "\(Int($0))" }
        }
    }

    // MARK: 排版

    private var indentBinding: Binding<Int> {
        Binding(
            get: { ParagraphIndentControl.characterCount(of: paragraphIndent) },
            set: { paragraphIndent = ParagraphIndentControl.indentString(characters: $0) }
        )
    }

    private var alignmentBinding: Binding<Int> {
        Binding(
            get: { centerText ? 2 : (fullJustify ? 1 : 0) },
            set: { value in
                centerText = value == 2
                fullJustify = value == 1
            }
        )
    }

    private var layoutSection: some View {
        AppearanceGroup("排版设置", prominent: true) {
            AppearanceSegmentedCard(title: "首行缩进", options: [(0, "无"), (1, "1字符"), (2, "2字符"), (3, "3字符"), (4, "4字符")],
                                    selection: indentBinding)
            AppearanceSliderRow(title: "字间距", value: $letterSpacing, range: -0.5...0.5, step: 0.01) { String(format: "%.2f", $0) }
            AppearanceSegmentedCard(title: "对齐方式", options: [(0, "左对齐"), (1, "两端对齐"), (2, "居中")], selection: alignmentBinding)
            AppearanceSegmentedCard(title: "段落间空行", options: [(0, "无"), (1, "1行"), (2, "2行"), (3, "3行")],
                                    selection: $paragraphBlankLines)
            ReaderSettingsFootnote(text: "段落间空行按整行高度加在段落之间，不改动正文内容，阅读进度不受影响。")
        }
    }

    // MARK: 气泡

    private var bubbleSection: some View {
        AppearanceGroup("气泡设置", prominent: true) {
            SwiftUI.NavigationLink {
                BubbleStyleSettingsView()
            } label: {
                AppearanceRowLabel(title: "气泡", value: bubbleStyles.selectedName, chevron: true)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("reader.settings.bubble")
            AppearanceToggleRow(title: "显示段评气泡", isOn: $showsReviewBubbles)
            ReaderSettingsFootnote(text: "书源提供段评时，气泡显示在段落末尾，轻点打开段评页。")
        }
    }


    // MARK: 主题文件

    private var themeFileSection: some View {
        AppearanceGroup {
            Button {
                newThemeName = ""
                showsSaveTheme = true
            } label: { AppearanceRowLabel(title: "保存为自定义主题", icon: "square.and.arrow.down.on.square") }
            .buttonStyle(.plain)
            .disabled(themes.themes.count >= ReaderThemeStore.maximumThemes)
            Button { exportURL = themes.exportURL(themes.snapshot(name: "阅读主题 · \(currentStyle.name)")) } label: {
                AppearanceRowLabel(title: "导出当前主题", icon: "square.and.arrow.up")
            }
            .buttonStyle(.plain)
            Button { importsFont = false; showsImporter = true } label: {
                AppearanceRowLabel(title: "导入主题包", icon: "square.and.arrow.down")
            }
            .buttonStyle(.plain)
            Button { confirmsReset = true } label: {
                AppearanceRowLabel(title: "恢复默认设置", icon: "arrow.counterclockwise")
            }
            .buttonStyle(.plain)
            if let message {
                ReaderSettingsFootnote(text: message)
            }
            ReaderSettingsFootnote(text: "主题包含配色、背景图、字号字重、间距、标题、排版和页眉页脚；字体文件和翻页方式不包含在内。")
        }
        .fileImporter(isPresented: $showsImporter,
                      allowedContentTypes: importsFont ? [.font, .data] : [.json],
                      allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else {
                if case .failure(let error) = result { message = error.localizedDescription }
                return
            }
            if importsFont {
                do {
                    fontPath = try ReaderFontStore.install(from: url)
                    fontMessage = nil
                } catch {
                    fontMessage = "字体导入失败：\(error.localizedDescription)"
                }
                return
            }
            do {
                let pack = try themes.importPack(from: url)
                reloadBackgroundImages()
                backgroundRevision &+= 1
                message = "已导入并使用「\(pack.name)」"
            } catch {
                message = "无法导入这个主题包。"
            }
        }
        .confirmationDialog("阅读主题恢复默认？", isPresented: $confirmsReset, titleVisibility: .visible) {
            Button("恢复默认设置", role: .destructive) {
                ReaderThemeStore.resetToDefaults()
                backgroundRevision &+= 1
                message = "已恢复默认阅读主题"
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("配色、字号、间距、标题、排版和页眉页脚恢复为默认值；已保存的自定义主题和背景图片保留。")
        }
        .sheet(isPresented: $showsSaveTheme) {
            ReaderThemeNameSheet(name: $newThemeName) { name in
                let saved = themes.save(name: name)
                message = saved ? "已保存「\(name)」" : "保存失败"
                showsSaveTheme = false
            } onCancel: {
                showsSaveTheme = false
            }
            .readingPresentationDetents([.medium])
        }
        .sheet(isPresented: Binding(get: { exportURL != nil }, set: { if !$0 { exportURL = nil } })) {
            if let exportURL { AppearanceActivityView(items: [exportURL]) }
        }
    }
}

/// 「保存为自定义主题」：输入名称。
private struct ReaderThemeNameSheet: View {
    @Binding var name: String
    let onSave: (String) -> Void
    let onCancel: () -> Void
    @FocusState private var focused: Bool

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        ReadingNavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    AppearanceCard {
                        TextField("主题名称", text: $name)
                            .focused($focused)
                            .submitLabel(.done)
                            .onSubmit { if !trimmed.isEmpty { onSave(String(trimmed.prefix(20))) } }
                    }
                    ReaderSettingsFootnote(text: "保存当前的配色、背景图、字体样式、间距、标题、排版和页眉页脚。")
                }
                .padding(16)
            }
            .background { AppThemeCanvas().ignoresSafeArea() }
            .navigationTitle("保存为自定义主题")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消", action: onCancel) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { onSave(String(trimmed.prefix(20))) }.disabled(trimmed.isEmpty)
                }
            }
            .onAppear { focused = true }
        }
    }
}

/// 页眉、页脚的四边边距。
private struct ReaderTipPaddingPage: View {
    @AppStorage("headerPaddingBottom") private var headerPaddingBottom = 0.0
    @AppStorage("headerPaddingLeft") private var headerPaddingLeft = 16.0
    @AppStorage("headerPaddingRight") private var headerPaddingRight = 16.0
    @AppStorage("headerPaddingTop") private var headerPaddingTop = 0.0
    @AppStorage("footerPaddingBottom") private var footerPaddingBottom = 6.0
    @AppStorage("footerPaddingLeft") private var footerPaddingLeft = 16.0
    @AppStorage("footerPaddingRight") private var footerPaddingRight = 16.0
    @AppStorage("footerPaddingTop") private var footerPaddingTop = 6.0

    var body: some View {
        AppearancePage(title: "页眉页脚边距") {
            AppearanceGroup("页眉边距", prominent: true) {
                AppearanceSliderRow(title: "左边距", value: $headerPaddingLeft, range: 0...100, step: 1) { "\(Int($0))" }
                AppearanceSliderRow(title: "右边距", value: $headerPaddingRight, range: 0...100, step: 1) { "\(Int($0))" }
                AppearanceSliderRow(title: "上边距", value: $headerPaddingTop, range: -40...100, step: 1) { "\(Int($0))" }
                AppearanceSliderRow(title: "下边距", value: $headerPaddingBottom, range: 0...100, step: 1) { "\(Int($0))" }
            }
            AppearanceGroup("页脚边距", prominent: true) {
                AppearanceSliderRow(title: "左边距", value: $footerPaddingLeft, range: 0...100, step: 1) { "\(Int($0))" }
                AppearanceSliderRow(title: "右边距", value: $footerPaddingRight, range: 0...100, step: 1) { "\(Int($0))" }
                AppearanceSliderRow(title: "上边距", value: $footerPaddingTop, range: 0...100, step: 1) { "\(Int($0))" }
                AppearanceSliderRow(title: "下边距", value: $footerPaddingBottom, range: -40...100, step: 1) { "\(Int($0))" }
                ReaderSettingsFootnote(text: "调到负数可让页脚继续往屏幕底边靠，进入底部安全区。")
            }
        }
    }
}

// MARK: - 显示

private struct ReaderDisplaySettingsTab: View {
    let extras: AnyView?
    @AppStorage("screenOrientation") private var screenOrientation = "0"
    @AppStorage("readerKeepScreenOn") private var keepScreenOn = false
    @AppStorage("readerHideHomeIndicator") private var hideHomeIndicator = false
    @AppStorage("readerHideStatusBar") private var hideStatusBar = false
    @AppStorage("readerShowBrightness") private var showBrightness = true

    var body: some View {
        if let extras { extras }
        AppearanceGroup("屏幕", prominent: true) {
            AppearancePickerRow(title: "屏幕方向", options: [
                ("0", "跟随系统"), ("1", "竖向"), ("2", "横向"), ("3", "跟随传感器"), ("4", "反向竖屏"), ("5", "反向横屏")
            ], selection: $screenOrientation)
            AppearanceToggleRow(title: "阅读时不自动锁屏", isOn: $keepScreenOn)
            if #available(iOS 16.0, *) {
                AppearanceToggleRow(title: "阅读时隐藏小横条", isOn: $hideHomeIndicator)
            }
            AppearanceToggleRow(title: "隐藏状态栏", isOn: $hideStatusBar)
            AppearanceToggleRow(title: "显示亮度调节", isOn: $showBrightness)
        }
    }
}

// MARK: - 朗读

private struct ReaderSpeechSettingsTab: View {
    let extras: AnyView?
    @AppStorage("appTtsEngine") private var appTTSEngine = ""
    @AppStorage("systemTtsVoice") private var systemTTSVoice = ""
    @AppStorage("ttsFollowSys") private var ttsFollowSystem = true
    @AppStorage("ttsSpeechRate") private var ttsSpeechRate = 5
    @AppStorage("readAloudByPage") private var readAloudByPage = false
    @AppStorage("streamReadAloudAudio") private var streamReadAloudAudio = true
    @AppStorage("readAloudWakeLock") private var readAloudWakeLock = false
    @AppStorage("ignoreAudioFocus") private var ignoreAudioFocus = false
    @AppStorage("pauseReadAloudWhilePhoneCalls") private var pauseReadAloudWhilePhoneCalls = false
    @AppStorage("mediaButtonPerNext") private var mediaButtonPerNext = false
    @AppStorage("ttsTimer") private var ttsTimer = 0
    @State private var engines: [HttpTTS] = []

    private var voices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("zh") }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var rateBinding: Binding<Double> {
        Binding(get: { Double(ttsSpeechRate) }, set: { ttsSpeechRate = Int($0.rounded()) })
    }

    private var timerBinding: Binding<Double> {
        Binding(get: { Double(ttsTimer) }, set: { ttsTimer = Int($0.rounded()) })
    }

    var body: some View {
        if let extras { extras }
        AppearanceGroup("朗读引擎", prominent: true) {
            AppearancePickerRow(title: "全局朗读引擎",
                                options: [("", "系统 TTS")] + engines.map { (String($0.id), $0.name) },
                                selection: $appTTSEngine)
            AppearancePickerRow(title: "系统声音",
                                options: [("", "系统默认中文声音")] + voices.map { ($0.identifier, "\($0.name)（\($0.language)）") },
                                selection: $systemTTSVoice)
        }
        AppearanceGroup("语速", prominent: true) {
            AppearanceToggleRow(title: "跟随系统语速", isOn: $ttsFollowSystem)
            if !ttsFollowSystem {
                AppearanceSliderRow(title: "朗读语速", value: rateBinding, range: 0...45, step: 1) { "\(Int($0))" }
            }
        }
        AppearanceGroup("朗读方式", prominent: true) {
            AppearanceToggleRow(title: "按页朗读", isOn: $readAloudByPage)
            AppearanceToggleRow(title: "流式播放在线音频", isOn: $streamReadAloudAudio)
            AppearanceToggleRow(title: "朗读时保持亮屏", isOn: $readAloudWakeLock)
            AppearanceToggleRow(title: "忽略音频焦点", isOn: $ignoreAudioFocus)
            AppearanceToggleRow(title: "忽略焦点时仍在来电时暂停", isOn: $pauseReadAloudWhilePhoneCalls, disabled: !ignoreAudioFocus)
            AppearanceToggleRow(title: "媒体上一首/下一首切换章节", isOn: $mediaButtonPerNext)
            AppearanceSliderRow(title: "默认定时", value: timerBinding, range: 0...180, step: 5) {
                $0 < 1 ? "关闭" : "\(Int($0)) 分钟"
            }
        }
        .task { await loadEngines() }
    }

    private func loadEngines() async {
        guard engines.isEmpty, let database = try? LegadoDatabase(url: LegadoDatabase.defaultURL()) else { return }
        let repository = SQLiteConfigurationRepository(database: database)
        var values = (try? await repository.loadHttpTTS()) ?? []
        if values.isEmpty,
           let url = Bundle.main.url(forResource: "httpTTS", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let defaults = try? JSONDecoder().decode([HttpTTS].self, from: data) {
            values = defaults
        }
        engines = values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

// MARK: - 阅读主题（保存 / 导出 / 导入）

/// 一套阅读主题：一组阅读设置的值（只包含外观与排版，不含翻页方式、字体文件和朗读）。
// MARK: - 自定义主题编辑器

/// 「自定义」色块打开的编辑器：文字颜色、背景颜色、可选背景图，上方实时预览。
/// 浅色、深色各有一套，保存后作为这一侧的「自定义」主题并立即用在阅读页。
private struct ReaderCustomThemeEditor: View {
    let dark: Bool
    let onFinish: (Bool) -> Void

    @ThemePalette private var palette
    @State private var foregroundHex: String
    @State private var backgroundHex: String
    @State private var usesImage: Bool
    @State private var image: UIImage?
    /// 新选的图片先放在临时文件里，保存时才替换正式文件。
    @State private var pickedImageURL: URL?
    @State private var removesImage = false
    @State private var picksImage = false
    @State private var errorMessage: String?

    private static let lightSuggestions: [(String, String, String)] = [
        ("米黄", "F5EFDF", "2E2A24"), ("纸白", "FBFAF7", "1F1F1F"), ("豆沙绿", "CCE8CF", "1F3322"),
        ("浅粉", "F8E8EA", "4A2F35"), ("雾蓝", "E3EBF3", "26313D"), ("燕麦", "EDE3D1", "3B3226")
    ]
    private static let darkSuggestions: [(String, String, String)] = [
        ("暖黑", "1C1B19", "B9B2A6"), ("纯黑", "000000", "9A9A9A"), ("石墨", "2B2B2D", "C9C9CC"),
        ("夜蓝", "0E1726", "9FB0C7"), ("松绿", "10201A", "9EBFAE"), ("咖啡", "241C16", "C2B09A")
    ]

    init(dark: Bool, onFinish: @escaping (Bool) -> Void) {
        self.dark = dark
        self.onFinish = onFinish
        let style = ReaderStylePreset.custom(dark: dark)
        _foregroundHex = State(initialValue: style.foreground.readerHex)
        _backgroundHex = State(initialValue: style.background.readerHex)
        _usesImage = State(initialValue: ReaderCustomThemeImage.usesImage(dark: dark))
        _image = State(initialValue: ReaderCustomThemeImage.load(dark: dark))
    }

    private var foreground: Color { AppThemeColor.color(foregroundHex) }
    private var background: Color { AppThemeColor.color(backgroundHex) }
    private var showsImage: Bool { usesImage && image != nil }

    var body: some View {
        ReadingNavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    preview
                    AppearanceGroup("颜色", prominent: true) {
                        AppearanceColorRow(title: "文字颜色", hex: foregroundHex) { foregroundHex = $0 }
                        AppearanceColorRow(title: "背景颜色", hex: backgroundHex) { backgroundHex = $0 }
                        suggestions
                        if AppThemeColor.contrast(foregroundHex, backgroundHex) < 3 {
                            ReaderSettingsFootnote(text: "文字和背景颜色太接近，阅读时可能看不清。")
                        }
                    }
                    AppearanceGroup("背景图片", prominent: true) {
                        if image != nil {
                            AppearanceToggleRow(title: "使用背景图", isOn: $usesImage)
                        }
                        Button { picksImage = true } label: {
                            AppearanceRowLabel(title: image == nil ? "从相册选择背景图" : "更换背景图", icon: "photo", chevron: true)
                        }
                        .buttonStyle(.plain)
                        if image != nil {
                            Button {
                                image = nil
                                usesImage = false
                                pickedImageURL = nil
                                removesImage = true
                            } label: {
                                AppearanceRowLabel(title: "移除背景图", icon: "trash")
                            }
                            .buttonStyle(.plain)
                        }
                        if let errorMessage {
                            ReaderSettingsFootnote(text: errorMessage)
                        }
                        ReaderSettingsFootnote(text: "背景图铺满阅读页，文字颜色仍按上面的设置；不用背景图时显示背景颜色。")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 48)
            }
            .background { AppThemeCanvas().ignoresSafeArea() }
            .navigationTitle(dark ? "自定义深色主题" : "自定义浅色主题")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        if let pickedImageURL { try? FileManager.default.removeItem(at: pickedImageURL) }
                        onFinish(false)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .accessibilityIdentifier("reader.customTheme.save")
                }
            }
        }
        .readingPhotoPicker(isPresented: $picksImage) { data in
            do {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("reader-custom-\(UUID().uuidString).jpg")
                image = try ReaderBackgroundStore.save(data, to: url)
                if let pickedImageURL { try? FileManager.default.removeItem(at: pickedImageURL) }
                pickedImageURL = url
                usesImage = true
                removesImage = false
                errorMessage = nil
            } catch {
                errorMessage = "无法读取这张图片。"
            }
        } onError: { error in
            errorMessage = error.localizedDescription
        }
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("第一章 · 雨夜").font(.system(size: 19, weight: .semibold))
            Text("　　雨落在旧城的瓦檐上，细密得像一封迟到了许多年的信。")
                .font(.system(size: 16, design: .serif))
            Text("　　“灯塔第三次亮起时，就沿着潮声出发。”")
                .font(.system(size: 16, design: .serif))
            Spacer(minLength: 0)
            Text(showsImage ? "预览 · 背景图" : "预览 · 纯色背景")
                .font(.system(size: 11))
                .opacity(0.6)
        }
        .foregroundStyle(foreground)
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 190, maxHeight: 190, alignment: .topLeading)
        .background {
            ZStack {
                background
                if showsImage, let image {
                    Image(uiImage: image).resizable().scaledToFill()
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(foreground.opacity(0.12), lineWidth: 0.75)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("reader.customTheme.preview")
    }

    private var suggestions: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(dark ? Self.darkSuggestions : Self.lightSuggestions, id: \.0) { item in
                    ReaderThemeSwatch(name: item.0, background: UIColor(readerHex: item.1) ?? .white,
                                      foreground: UIColor(readerHex: item.2) ?? .black,
                                      selected: backgroundHex == item.1 && foregroundHex == item.2) {
                        backgroundHex = item.1
                        foregroundHex = item.2
                    }
                }
            }
            .padding(12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { ThemeCardSurface(radius: 14) }
    }

    private func save() {
        let defaults = UserDefaults.standard
        let keys = ReaderStylePreset.customKeys(dark: dark)
        if UIColor(readerHex: backgroundHex) != nil { defaults.set(backgroundHex, forKey: keys.background) }
        if UIColor(readerHex: foregroundHex) != nil { defaults.set(foregroundHex, forKey: keys.foreground) }
        let target = ReaderCustomThemeImage.url(dark: dark)
        if let pickedImageURL {
            do {
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
                try FileManager.default.moveItem(at: pickedImageURL, to: target)
            } catch {
                errorMessage = "背景图保存失败：\(error.localizedDescription)"
                return
            }
        } else if removesImage {
            try? FileManager.default.removeItem(at: target)
        }
        defaults.set(usesImage && image != nil, forKey: keys.useImage)
        onFinish(true)
    }
}

struct ReaderThemePack: Codable, Identifiable, Equatable {
    struct Value: Codable, Equatable {
        var i: Int?
        var d: Double?
        var s: String?
        var b: Bool?
    }

    static let formatID = "legado.ios.readerTheme"
    var format: String = ReaderThemePack.formatID
    var version: Int = 1
    var id: String = UUID().uuidString.lowercased()
    var name: String
    var values: [String: Value]
    /// 导出文件里的背景图（JPEG，base64）。
    var backgroundImage: String?
    /// 本机保存的主题：背景图文件名。
    var backgroundFile: String?
    /// 深色自定义主题的背景图（导出文件里 base64 / 本机文件名）；旧版主题包没有这两项。
    var darkBackgroundImage: String?
    var darkBackgroundFile: String?

    var previewBackground: UIColor { color(for: true) }
    var previewForeground: UIColor { color(for: false) }

    private func color(for background: Bool) -> UIColor {
        let themeID = values["readerTheme"]?.s ?? "wechat"
        if themeID == ReaderStylePreset.customID {
            let key = background ? ReaderStylePreset.customBackgroundKey : ReaderStylePreset.customForegroundKey
            let fallback = background ? ReaderStylePreset.defaultCustomBackground : ReaderStylePreset.defaultCustomForeground
            return UIColor(readerHex: values[key]?.s ?? fallback) ?? .white
        }
        if themeID == ReaderStylePreset.customDarkID {
            let key = background ? ReaderStylePreset.customDarkBackgroundKey : ReaderStylePreset.customDarkForegroundKey
            let fallback = background ? ReaderStylePreset.defaultCustomDarkBackground : ReaderStylePreset.defaultCustomDarkForeground
            return UIColor(readerHex: values[key]?.s ?? fallback) ?? .black
        }
        let preset = ReaderStylePreset.resolve(themeID)
        return background ? preset.background : preset.foreground
    }
}

@MainActor
final class ReaderThemeStore: ObservableObject {
    static let shared = ReaderThemeStore()
    static let storageKey = "readerCustomThemes.v1"
    static let maximumThemes = 30

    enum Kind { case int, double, string, bool }

    /// 主题包含的设置。
    static let keys: [(String, Kind)] = styleKeys + tipKeys

    static let styleKeys: [(String, Kind)] = [
        ("readerTheme", .string), ("readerPreviousDayTheme", .string), ("readerDarkTheme", .string),
        ("readerFollowSystemDark", .bool), ("readerUseBackgroundImage", .bool),
        (ReaderStylePreset.customBackgroundKey, .string), (ReaderStylePreset.customForegroundKey, .string),
        (ReaderStylePreset.customDarkBackgroundKey, .string), (ReaderStylePreset.customDarkForegroundKey, .string),
        (ReaderCustomThemeImage.lightUseKey, .bool), (ReaderCustomThemeImage.darkUseKey, .bool),
        ("textSize", .double), ("textBold", .int), ("underlineMode", .int),
        ("letterSpacing", .double), ("lineSpacingExtra", .double), ("paragraphSpacing", .double), ("paragraphIndent", .string),
        ("paddingLeft", .double), ("paddingRight", .double), ("paddingTop", .double), ("paddingBottom", .double),
        ("titleMode", .int), ("titleSize", .double), ("titleTopSpacing", .double), ("titleBottomSpacing", .double),
        ("titleColorHex", .string), ("titleBold", .bool),
        ("readerFullJustify", .bool), ("readerTextCenter", .bool), ("readerParagraphBlankLines", .int)
    ]

    static let tipKeys: [(String, Kind)] = [
        ("headerMode", .int), ("footerMode", .int),
        ("tipHeaderLeft", .int), ("tipHeaderMiddle", .int), ("tipHeaderRight", .int),
        ("tipFooterLeft", .int), ("tipFooterMiddle", .int), ("tipFooterRight", .int),
        ("showHeaderLine", .bool), ("showFooterLine", .bool), ("readerTipCustomFont", .bool),
        ("headerPaddingBottom", .double), ("headerPaddingLeft", .double), ("headerPaddingRight", .double), ("headerPaddingTop", .double),
        ("footerPaddingBottom", .double), ("footerPaddingLeft", .double), ("footerPaddingRight", .double), ("footerPaddingTop", .double)
    ]

    @Published private(set) var themes: [ReaderThemePack] = []
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([ReaderThemePack].self, from: data) {
            themes = decoded
        }
    }

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Legado/reader-themes", isDirectory: true)
    }

    /// 当前设置的快照。
    func snapshot(name: String) -> ReaderThemePack {
        var values: [String: ReaderThemePack.Value] = [:]
        for (key, kind) in Self.keys where defaults.object(forKey: key) != nil {
            switch kind {
            case .int: values[key] = .init(i: defaults.integer(forKey: key))
            case .double: values[key] = .init(d: defaults.double(forKey: key))
            case .string: values[key] = defaults.string(forKey: key).map { .init(s: $0) }
            case .bool: values[key] = .init(b: defaults.bool(forKey: key))
            }
        }
        return ReaderThemePack(name: name, values: values)
    }

    /// 应用一套主题：主题里没有的设置恢复默认值，这样换主题后外观完全一致。
    func apply(_ pack: ReaderThemePack) {
        for (key, kind) in Self.keys {
            guard let value = pack.values[key] else {
                defaults.removeObject(forKey: key)
                continue
            }
            switch kind {
            case .int: if let v = value.i { defaults.set(v, forKey: key) } else { defaults.removeObject(forKey: key) }
            case .double: if let v = value.d { defaults.set(v, forKey: key) } else { defaults.removeObject(forKey: key) }
            case .string: if let v = value.s { defaults.set(v, forKey: key) } else { defaults.removeObject(forKey: key) }
            case .bool: if let v = value.b { defaults.set(v, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        var imageData: Data?
        if let file = pack.backgroundFile {
            imageData = try? Data(contentsOf: Self.directory.appendingPathComponent(file))
        } else if let encoded = pack.backgroundImage {
            imageData = Data(base64Encoded: encoded)
        }
        if let imageData, (try? ReaderBackgroundStore.save(imageData)) != nil {
            // 背景图已换成主题里的图片。
        } else {
            // 主题里要求用背景图但没带图片：关掉，避免沿用一张不相干的旧图。
            if pack.values["readerUseBackgroundImage"]?.b == true { defaults.set(false, forKey: "readerUseBackgroundImage") }
            if pack.values[ReaderCustomThemeImage.lightUseKey]?.b == true { defaults.set(false, forKey: ReaderCustomThemeImage.lightUseKey) }
        }
        var darkData: Data?
        if let file = pack.darkBackgroundFile {
            darkData = try? Data(contentsOf: Self.directory.appendingPathComponent(file))
        } else if let encoded = pack.darkBackgroundImage {
            darkData = Data(base64Encoded: encoded)
        }
        if let darkData, (try? ReaderBackgroundStore.save(darkData, to: ReaderCustomThemeImage.darkURL)) != nil {
            // 深色自定义主题的背景图已换成主题里的图片。
        } else if pack.values[ReaderCustomThemeImage.darkUseKey]?.b == true {
            defaults.set(false, forKey: ReaderCustomThemeImage.darkUseKey)
        }
    }

    /// 保存当前设置为自定义主题（使用背景图时一并保存图片）。
    func save(name: String) -> Bool {
        guard themes.count < Self.maximumThemes else { return false }
        var pack = snapshot(name: name)
        if Self.usesLightImage(defaults.bool(forKey: "readerUseBackgroundImage"), defaults.bool(forKey: ReaderCustomThemeImage.lightUseKey)),
           let data = try? Data(contentsOf: ReaderBackgroundStore.url) {
            let file = pack.id + ".jpg"
            do {
                try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
                try data.write(to: Self.directory.appendingPathComponent(file), options: .atomic)
                pack.backgroundFile = file
            } catch {
                pack.values["readerUseBackgroundImage"] = .init(b: false)
                pack.values[ReaderCustomThemeImage.lightUseKey] = .init(b: false)
            }
        }
        if defaults.bool(forKey: ReaderCustomThemeImage.darkUseKey),
           let data = try? Data(contentsOf: ReaderCustomThemeImage.darkURL) {
            let file = pack.id + "-dark.jpg"
            do {
                try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
                try data.write(to: Self.directory.appendingPathComponent(file), options: .atomic)
                pack.darkBackgroundFile = file
            } catch {
                pack.values[ReaderCustomThemeImage.darkUseKey] = .init(b: false)
            }
        }
        themes.append(pack)
        persist()
        return true
    }

    func delete(_ id: String) {
        guard let index = themes.firstIndex(where: { $0.id == id }) else { return }
        for file in [themes[index].backgroundFile, themes[index].darkBackgroundFile].compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: Self.directory.appendingPathComponent(file))
        }
        themes.remove(at: index)
        persist()
    }

    /// 导出成一个 JSON 文件（带背景图）。
    func exportURL(_ pack: ReaderThemePack) -> URL? {
        var value = pack
        var imageData: Data?
        if let file = pack.backgroundFile {
            imageData = try? Data(contentsOf: Self.directory.appendingPathComponent(file))
        } else if Self.usesLightImage(pack.values["readerUseBackgroundImage"]?.b == true,
                                      pack.values[ReaderCustomThemeImage.lightUseKey]?.b == true) {
            imageData = try? Data(contentsOf: ReaderBackgroundStore.url)
        }
        value.backgroundFile = nil
        value.backgroundImage = imageData?.base64EncodedString()
        var darkData: Data?
        if let file = pack.darkBackgroundFile {
            darkData = try? Data(contentsOf: Self.directory.appendingPathComponent(file))
        } else if pack.values[ReaderCustomThemeImage.darkUseKey]?.b == true {
            darkData = try? Data(contentsOf: ReaderCustomThemeImage.darkURL)
        }
        value.darkBackgroundFile = nil
        value.darkBackgroundImage = darkData?.base64EncodedString()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return nil }
        let name = pack.name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).json")
        do { try data.write(to: url, options: .atomic); return url } catch { return nil }
    }

    /// 导入主题包：保存为自定义主题并立即使用。
    @discardableResult
    func importPack(from url: URL) throws -> ReaderThemePack {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        guard data.count <= 40_000_000 else { throw CocoaError(.fileReadTooLarge) }
        var pack = try JSONDecoder().decode(ReaderThemePack.self, from: data)
        guard pack.format == ReaderThemePack.formatID else { throw CocoaError(.fileReadCorruptFile) }
        // 导入文件只认内嵌的图片，不认本机文件名。
        pack.backgroundFile = nil
        pack.darkBackgroundFile = nil
        pack.id = UUID().uuidString.lowercased()
        if pack.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { pack.name = "导入的主题" }
        // 只接受已知设置，未知键忽略。
        let known = Set(Self.keys.map(\.0))
        pack.values = pack.values.filter { known.contains($0.key) }
        if let encoded = pack.backgroundImage, let image = Data(base64Encoded: encoded) {
            let file = pack.id + ".jpg"
            try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            if (try? image.write(to: Self.directory.appendingPathComponent(file), options: .atomic)) != nil {
                pack.backgroundFile = file
            }
        }
        pack.backgroundImage = nil
        if let encoded = pack.darkBackgroundImage, let image = Data(base64Encoded: encoded) {
            let file = pack.id + "-dark.jpg"
            try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            if (try? image.write(to: Self.directory.appendingPathComponent(file), options: .atomic)) != nil {
                pack.darkBackgroundFile = file
            }
        }
        pack.darkBackgroundImage = nil
        if themes.count < Self.maximumThemes {
            themes.append(pack)
            persist()
        }
        apply(pack)
        return pack
    }

    /// 主题是否带浅色背景图（旧版全局背景图与浅色自定义主题的背景图是同一个文件）。
    static func usesLightImage(_ legacy: Bool, _ custom: Bool) -> Bool { legacy || custom }

    static func resetToDefaults(_ defaults: UserDefaults = .standard) {
        for (key, _) in keys where key != "readerUseBackgroundImage" { defaults.removeObject(forKey: key) }
        defaults.set(false, forKey: "readerUseBackgroundImage")
    }

    static func resetTipSettings(_ defaults: UserDefaults = .standard) {
        for (key, _) in tipKeys { defaults.removeObject(forKey: key) }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(themes) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }
}
