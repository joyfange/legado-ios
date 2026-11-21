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
    /// 只显示「主题」里的某一组（阅读页「大小」面板的标题样式、页眉页脚、排版直接打开这一组）。
    let focus: ReaderThemeSettingsSection?
    @State private var tab: Tab
    @Environment(\.dismiss) private var dismiss

    init(initialTab: Tab = .theme, focus: ReaderThemeSettingsSection? = nil, context: ReaderContext? = nil) {
        self.context = context
        self.focus = focus
        _tab = State(initialValue: focus == nil ? initialTab : .theme)
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
                case .theme: ReaderThemeSettingsTab(pageAnimation: context?.pageAnimation, only: focus)
                case .display: ReaderDisplaySettingsTab(extras: context?.displayExtras)
                case .speech: ReaderSpeechSettingsTab(extras: context?.speechExtras)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 48)
        }
        .background { AppThemeCanvas().ignoresSafeArea() }
        .navigationTitle(focus?.title ?? "阅读设置")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                if let focus {
                    Text(focus.title).font(.headline)
                } else {
                    Picker("阅读设置", selection: $tab) {
                        ForEach(Tab.allCases, id: \.self) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 200)
                    .accessibilityIdentifier("reader.settings.tabs")
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") {
                    if let context { context.close() } else { dismiss() }
                }
            }
        }
    }
}

/// 「主题」里可以单独打开的一组设置。
enum ReaderThemeSettingsSection: String, Identifiable {
    case titleStyle, headerFooter, spacing, layout
    var id: String { rawValue }
    var title: String {
        switch self {
        case .titleStyle: "章节标题样式"
        case .headerFooter: "页眉页脚"
        case .spacing: "间距设置"
        case .layout: "排版设置"
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
    var only: ReaderThemeSettingsSection? = nil
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
    /// 当前主题自己的背景图（预设、自定义、新建主题都可以有）。
    @State private var currentThemeImage: UIImage?
    /// 各色块的背景图缩略（按 id）。
    @State private var swatchImages: [String: UIImage] = [:]
    /// 正在编辑的主题（预设 / 新建 / 已有的自定义主题）。
    @State private var themeEditor: ReaderThemeEditorTarget?
    @State private var showsThemeManager = false
    @AppStorage(ReaderThemeLibrary.overridesKey) private var presetOverridesData = Data()
    @AppStorage(ReaderThemeLibrary.userThemesKey) private var userThemesData = Data()
    @AppStorage(ReaderThemeLibrary.hiddenKey) private var hiddenThemes = ""
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
        _ = (customBackgroundHex, customForegroundHex, customDarkBackgroundHex, customDarkForegroundHex,
             presetOverridesData, userThemesData)
        if followSystemDark {
            if systemPrefersDark {
                return ReaderStylePreset.resolve(ReaderStylePreset.isDarkID(darkTheme) ? darkTheme : "night")
            }
            if ReaderStylePreset.isDarkID(theme) {
                return ReaderStylePreset.resolve(ReaderStylePreset.isDarkID(previousDayTheme) ? "wechat" : previousDayTheme)
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
        if let only {
            switch only {
            case .titleStyle: titleSection
            case .headerFooter: tipSection
            case .spacing: spacingSection
            case .layout: layoutSection
            }
        } else {
            fullBody
        }
    }

    @ViewBuilder private var fullBody: some View {
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
        .onChange(of: theme) { _ in reloadBackgroundImages() }
        .sheet(item: $themeEditor) { target in
            ReaderThemeEntryEditor(target: target) { savedID in
                themeEditor = nil
                reloadBackgroundImages()
                backgroundRevision &+= 1
                if let savedID { select(savedID, dark: target.dark, haptic: false) }
            }
        }
        .sheet(isPresented: $showsThemeManager) {
            ReaderThemeManagerSheet { reloadBackgroundImages() }
        }
        Group {
            tipSection
            spacingSection
            titleSection
            layoutSection
        }
        Group {
        bubbleSection
        themeFileSection
        }
    }

    // MARK: 翻页

    private static let pageModes: [(Int, String)] = [(2, "仿真"), (1, "滑动"), (0, "平移"), (4, "无动画"), (3, "上下滚动")]

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
                swatchCard(dark: false)
            }
            AppearanceGroup("深色主题", prominent: true) {
                swatchCard(dark: true)
                ReaderSettingsFootnote(text: "轻点选用；再点一次已选中的色块可以直接改它的文字颜色、背景颜色和背景图。「新建」做一套自己的主题，长按色块可编辑、隐藏或删除。")
            }
            AppearanceGroup {
                Button { showsThemeManager = true } label: {
                    AppearanceRowLabel(title: "管理主题（显示 / 隐藏）", icon: "eye", chevron: true)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("reader.theme.manage")
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
            if dark { return darkTheme == id || (theme == id && ReaderStylePreset.isDarkID(id)) }
            return ReaderStylePreset.isDarkID(theme) ? previousDayTheme == id : theme == id
        }
        return currentStyle.id == id
    }

    private func swatchCard(dark: Bool) -> some View {
        _ = (presetOverridesData, userThemesData, hiddenThemes)
        let selectedIDs: Set<String> = [theme, dark ? darkTheme : previousDayTheme]
        let items = ReaderThemeLibrary.visibleThemes(dark: dark, selected: selectedIDs)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(items) { preset in
                    let selected = isSelected(preset, dark: dark)
                    let usesImage = ReaderThemeLibrary.usesImage(preset.id)
                    ReaderThemeSwatch(name: preset.name, background: preset.background, foreground: preset.foreground,
                                      selected: selected,
                                      image: usesImage ? swatchImages[preset.id] : nil,
                                      badge: selected ? "slider.horizontal.3" : nil) {
                        if selected {
                            // 再点已选中的色块：直接编辑它本身（预设改的就是这个预设）。
                            UISelectionFeedbackGenerator().selectionChanged()
                            themeEditor = .init(themeID: preset.id, dark: dark)
                        } else {
                            select(preset.id, dark: dark)
                        }
                    }
                    .contextMenu { swatchMenu(preset, dark: dark) }
                    .accessibilityIdentifier("reader.theme.\(preset.id)")
                }
                // 「新建」：做一套新的浅色 / 深色主题，保存后出现在这一排。
                Button {
                    UISelectionFeedbackGenerator().selectionChanged()
                    themeEditor = .init(themeID: nil, dark: dark)
                } label: {
                    VStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(palette.secondary.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            .frame(width: 50, height: 50)
                            .overlay { Image(systemName: "plus").font(.system(size: 18, weight: .medium)).foregroundStyle(palette.accent) }
                        Text("新建").font(AppFontStyle.caption.themed).foregroundStyle(palette.secondary).lineLimit(1)
                    }
                    .frame(width: 62)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(dark ? "新建深色主题" : "新建浅色主题")
                .accessibilityIdentifier(dark ? "reader.theme.customDark" : "reader.theme.customLight")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { ThemeCardSurface(radius: 14) }
    }

    @ViewBuilder private func swatchMenu(_ preset: ReaderStylePreset, dark: Bool) -> some View {
        Button { themeEditor = .init(themeID: preset.id, dark: dark) } label: {
            Label("编辑颜色和背景图", systemImage: "slider.horizontal.3")
        }
        if ReaderThemeLibrary.isModifiedPreset(preset.id) {
            Button {
                ReaderThemeLibrary.resetPreset(preset.id)
                presetOverridesData = UserDefaults.standard.data(forKey: ReaderThemeLibrary.overridesKey) ?? Data()
                reloadBackgroundImages()
                backgroundRevision &+= 1
            } label: { Label("恢复预设原色", systemImage: "arrow.uturn.backward") }
        }
        Button {
            ReaderThemeLibrary.setHidden(preset.id, true)
            hiddenThemes = UserDefaults.standard.string(forKey: ReaderThemeLibrary.hiddenKey) ?? ""
        } label: { Label("隐藏", systemImage: "eye.slash") }
        if ReaderThemeLibrary.userTheme(preset.id) != nil {
            Button(role: .destructive) {
                let wasSelected = isSelected(preset, dark: dark)
                ReaderThemeLibrary.deleteUserTheme(preset.id)
                userThemesData = UserDefaults.standard.data(forKey: ReaderThemeLibrary.userThemesKey) ?? Data()
                if wasSelected { select(dark ? "night" : "wechat", dark: dark) }
                reloadBackgroundImages()
                backgroundRevision &+= 1
            } label: { Label("删除", systemImage: "trash") }
        }
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
        var images: [String: UIImage] = [:]
        for item in ReaderThemeLibrary.allThemes(dark: false) + ReaderThemeLibrary.allThemes(dark: true)
        where ReaderThemeLibrary.usesImage(item.id) {
            images[item.id] = ReaderThemeLibrary.previewImage(item.id)
        }
        swatchImages = images
        currentThemeImage = ReaderThemeLibrary.previewImage(currentStyle.id)
    }

    private func select(_ id: String, dark: Bool, haptic: Bool = true) {
        if haptic { UISelectionFeedbackGenerator().selectionChanged() }
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

    /// 背景设置直接作用在当前主题上：预设改的就是这个预设，新建的主题改它自己，不会跳到「自定义」。
    private var editsDarkSide: Bool { currentStyle.isDark }

    private var currentID: String { currentStyle.id }

    private var sideImage: UIImage? { currentThemeImage }

    private var sideUsesImage: Bool {
        _ = (presetOverridesData, userThemesData, customUsesImage, customDarkUsesImage)
        return ReaderThemeLibrary.usesImage(currentID)
    }

    /// 阅读页现在是否铺着背景图（旧版全局开关或当前主题带图）。
    private var usesImage: Bool {
        if useBackgroundImage { return backgroundImage != nil }
        return sideUsesImage && sideImage != nil
    }

    private func syncLibraryState() {
        let defaults = UserDefaults.standard
        presetOverridesData = defaults.data(forKey: ReaderThemeLibrary.overridesKey) ?? Data()
        userThemesData = defaults.data(forKey: ReaderThemeLibrary.userThemesKey) ?? Data()
        customUsesImage = ReaderCustomThemeImage.usesImage(dark: false)
        customDarkUsesImage = ReaderCustomThemeImage.usesImage(dark: true)
        customBackgroundHex = defaults.string(forKey: ReaderStylePreset.customBackgroundKey) ?? customBackgroundHex
        customForegroundHex = defaults.string(forKey: ReaderStylePreset.customForegroundKey) ?? customForegroundHex
        customDarkBackgroundHex = defaults.string(forKey: ReaderStylePreset.customDarkBackgroundKey) ?? customDarkBackgroundHex
        customDarkForegroundHex = defaults.string(forKey: ReaderStylePreset.customDarkForegroundKey) ?? customDarkForegroundHex
    }

    private var backgroundSection: some View {
        AppearanceGroup("背景设置", prominent: true) {
            backgroundPreview
            if sideImage != nil {
                AppearanceToggleRow(title: "使用背景图", isOn: Binding(
                    get: { sideUsesImage },
                    set: { value in
                        useBackgroundImage = false
                        ReaderThemeLibrary.update(currentID, usesImage: value)
                        syncLibraryState()
                        reloadBackgroundImages()
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
                    try? FileManager.default.removeItem(at: ReaderThemeLibrary.imageURL(currentID))
                    ReaderThemeLibrary.update(currentID, usesImage: false)
                    syncLibraryState()
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
            Button { themeEditor = .init(themeID: currentID, dark: editsDarkSide) } label: {
                AppearanceRowLabel(title: "编辑「\(currentStyle.name)」", icon: "slider.horizontal.3", chevron: true)
            }
            .buttonStyle(.plain)
            if ReaderThemeLibrary.isModifiedPreset(currentID) {
                Button {
                    ReaderThemeLibrary.resetPreset(currentID)
                    syncLibraryState()
                    reloadBackgroundImages()
                    backgroundRevision &+= 1
                } label: {
                    AppearanceRowLabel(title: "恢复「\(currentStyle.name)」原来的颜色", icon: "arrow.uturn.backward")
                }
                .buttonStyle(.plain)
            }
            ReaderSettingsFootnote(text: "改文字颜色、背景颜色或背景图会直接保存到当前选中的「\(currentStyle.name)」，不会切换到别的主题。")
        }
        .readingPhotoPicker(isPresented: $showsBackgroundPicker) { data in
                do {
                    let id = currentID
                    useBackgroundImage = false
                    _ = try ReaderBackgroundStore.save(data, to: ReaderThemeLibrary.imageURL(id))
                    ReaderThemeLibrary.update(id, usesImage: true)
                    syncLibraryState()
                    reloadBackgroundImages()
                    backgroundRevision &+= 1
                    message = nil
                } catch {
                    message = error.localizedDescription
                }
            } onError: { error in
                message = error.localizedDescription
            }
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

    /// 改当前主题的文字 / 背景颜色（预设、自定义、新建主题都改它自己）。
    private func customize(foreground: String? = nil, background: String? = nil) {
        useBackgroundImage = false
        ReaderThemeLibrary.update(
            currentID,
            background: background.flatMap { $0.isEmpty ? nil : $0 },
            foreground: foreground.flatMap { $0.isEmpty ? nil : $0 }
        )
        syncLibraryState()
        backgroundRevision &+= 1
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
    @ObservedObject private var highlights = ReaderHighlightStore.shared
    @AppStorage("screenOrientation") private var screenOrientation = "0"
    @AppStorage("readerKeepScreenOn") private var keepScreenOn = false
    @AppStorage("readerHideHomeIndicator") private var hideHomeIndicator = false
    @AppStorage("readerHideStatusBar") private var hideStatusBar = false
    @AppStorage("readerBrightness") private var brightness = 0.0
    @AppStorage(ContentSanitizer.chineseConverterKey) private var chineseConverter = 0
    @AppStorage("underlineMode") private var underlineMode = 0

    /// 0 表示跟随系统亮度；拖动滑块就切到自定义亮度。
    private var followsSystemBrightness: Binding<Bool> {
        Binding(get: { brightness <= 0.05 }, set: { follows in
            brightness = follows ? 0 : max(Double(UIScreen.main.brightness), 0.06)
        })
    }

    private var brightnessBinding: Binding<Double> {
        Binding(get: { brightness > 0.05 ? brightness : Double(UIScreen.main.brightness) },
                set: { brightness = min(max($0, 0.06), 1) })
    }

    private var showsStatusBar: Binding<Bool> {
        Binding(get: { !hideStatusBar }, set: { hideStatusBar = !$0 })
    }

    var body: some View {
        AppearanceGroup("屏幕设置", prominent: true) {
            ReaderBrightnessCard(value: brightnessBinding, followsSystem: brightness <= 0.05)
            AppearanceToggleRow(title: "亮度跟随系统", isOn: followsSystemBrightness)
            AppearancePickerRow(title: "屏幕常亮", options: [(false, "跟随系统"), (true, "阅读时常亮")], selection: $keepScreenOn)
            AppearanceToggleRow(title: "显示系统状态栏", isOn: showsStatusBar)
            if #available(iOS 16.0, *) {
                AppearanceToggleRow(title: "阅读时隐藏小横条", isOn: $hideHomeIndicator)
            }
            AppearancePickerRow(title: "屏幕方向", options: UIDevice.current.userInterfaceIdiom == .phone ? [
                ("0", "跟随系统"), ("1", "竖向"), ("2", "横向"), ("3", "跟随传感器"), ("5", "反向横屏")
            ] : [
                ("0", "跟随系统"), ("1", "竖向"), ("2", "横向"), ("3", "跟随传感器"), ("4", "反向竖屏"), ("5", "反向横屏")
            ], selection: $screenOrientation)
        }
        AppearanceGroup("文字处理", prominent: true) {
            AppearancePickerRow(title: "简繁转换", options: [(0, "关闭"), (1, "繁体转简体"), (2, "简体转繁体")],
                                selection: $chineseConverter)
            ReaderSettingsFootnote(text: "正文和章节名逐字转换，朗读同样按转换后的文字读。")
            AppearanceSegmentedCard(title: "文字底线", options: [(0, "关闭"), (1, "实线"), (2, "虚线")], selection: $underlineMode)
        }
        AppearanceGroup("正则高亮", prominent: true) {
            SwiftUI.NavigationLink {
                ReaderHighlightSettingsView()
            } label: {
                AppearanceRowLabel(title: "高亮规则", icon: "highlighter",
                                   value: highlights.enabled ? "已启用 \(highlights.enabledCount) 条" : "已关闭", chevron: true)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("reader.display.highlightRules")
            ReaderSettingsFootnote(text: "按正则给对话、提示等文字上色，可用 CSS 做底色、圆角、渐变和下划线。")
        }
        if let extras { extras }
    }
}

/// 亮度卡片：小太阳 · 滑块 · 大太阳，右上角显示百分比或「跟随系统」。
private struct ReaderBrightnessCard: View {
    @Binding var value: Double
    let followsSystem: Bool
    @ThemePalette private var palette

    var body: some View {
        AppearanceCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("亮度").font(AppFontStyle.body.themed).foregroundStyle(palette.primary)
                    Spacer()
                    Text(followsSystem ? "跟随系统" : "\(Int((value * 100).rounded()))%")
                        .font(AppFontStyle.subheadline.themed.monospacedDigit())
                        .foregroundStyle(palette.secondary)
                }
                HStack(spacing: 10) {
                    Image(systemName: "sun.min").foregroundStyle(palette.secondary)
                    AppearanceSlider(value: $value, range: 0.06...1)
                        .accessibilityLabel("亮度")
                    Image(systemName: "sun.max").foregroundStyle(palette.secondary)
                }
            }
        }
    }
}

/// 「数值框 + 单位」「− 滑块 +」「范围说明」的调节行（朗读速度、音调、预加载段落）。
private struct ReaderStepperSliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    var unit: String = ""
    var digits: Int = 1
    var note: String? = nil
    var disabled = false
    @ThemePalette private var palette

    private var text: String {
        digits == 0 ? "\(Int(value.rounded()))" : String(format: "%.\(digits)f", value)
    }

    private func nudge(_ delta: Double) {
        let next = ((value + delta) / step).rounded() * step
        value = min(max(next, range.lowerBound), range.upperBound)
    }

    var body: some View {
        AppearanceCard {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(title).font(AppFontStyle.body.themed).foregroundStyle(palette.primary)
                    Spacer()
                    Text(text)
                        .font(AppFontStyle.subheadline.themed.monospacedDigit())
                        .foregroundStyle(palette.primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(palette.secondary.opacity(0.12)))
                    if !unit.isEmpty {
                        Text(unit).font(AppFontStyle.footnote.themed).foregroundStyle(palette.secondary)
                    }
                }
                HStack(spacing: 10) {
                    Button { nudge(-step) } label: {
                        Image(systemName: "minus.circle.fill").font(.system(size: 20)).foregroundStyle(palette.accent)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("减小\(title)")
                    AppearanceSlider(value: $value, range: range, step: step)
                    Button { nudge(step) } label: {
                        Image(systemName: "plus.circle.fill").font(.system(size: 20)).foregroundStyle(palette.accent)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("增大\(title)")
                }
                if let note {
                    Text(note).font(AppFontStyle.caption.themed).foregroundStyle(palette.secondary)
                }
            }
        }
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
    }
}

// MARK: - 朗读

private struct ReaderSpeechSettingsTab: View {
    let extras: AnyView?
    @ObservedObject private var status = ReaderSpeechStatus.shared
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
    @AppStorage(ReaderSpeechKeys.pitchKey) private var pitch = 1.0
    @AppStorage(ReaderSpeechKeys.preloadKey) private var preloadCount = 3
    @AppStorage(ReaderSpeechKeys.highlightEnabled) private var highlightEnabled = true
    @AppStorage(ReaderSpeechKeys.lightHighlight) private var lightHighlight = ReaderSpeechKeys.defaultLightHighlight
    @AppStorage(ReaderSpeechKeys.darkHighlight) private var darkHighlight = ReaderSpeechKeys.defaultDarkHighlight
    @State private var engines: [HttpTTS] = []
    @State private var confirmsReset = false

    private var voices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("zh") }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// 存储的语速 0～45 对应 0.5x～5.0x（与朗读控制器的 (rate + 5) / 10 一致）。
    private var rateBinding: Binding<Double> {
        Binding(get: { Double(ttsSpeechRate + 5) / 10 },
                set: { ttsSpeechRate = min(max(Int(($0 * 10).rounded()) - 5, 0), 45) })
    }

    private var preloadBinding: Binding<Double> {
        Binding(get: { Double(preloadCount) }, set: { preloadCount = min(max(Int($0.rounded()), 1), 10) })
    }

    private var timerBinding: Binding<Double> {
        Binding(get: { Double(ttsTimer) }, set: { ttsTimer = Int($0.rounded()) })
    }

    private var engineName: String {
        engines.first { String($0.id) == appTTSEngine }?.name ?? "系统 TTS"
    }

    var body: some View {
        AppearanceGroup("朗读引擎", prominent: true) {
            AppearancePickerRow(title: "引擎",
                                options: [("", "系统 TTS")] + engines.map { (String($0.id), $0.name) },
                                selection: $appTTSEngine)
            SwiftUI.NavigationLink {
                HttpTTSManagementView()
                    .onDisappear { Task { await loadEngines(force: true) } }
            } label: {
                AppearanceRowLabel(title: "朗读管理", icon: "waveform", value: "\(engines.count) 个源", chevron: true)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("reader.speech.manageEngines")
        }
        if let extras { extras }
        AppearanceGroup("朗读高亮", prominent: true) {
            AppearanceToggleRow(title: "朗读时高亮当前段落", isOn: $highlightEnabled)
            AppearanceColorRow(title: "浅色模式高亮色", hex: lightHighlight) { lightHighlight = $0 }
            AppearanceColorRow(title: "深色模式高亮色", hex: darkHighlight) { darkHighlight = $0 }
            ReaderSettingsFootnote(text: "正在朗读的段落用这个颜色显示，翻页、滚动模式都会跟读定位。")
        }
        AppearanceGroup("音频混合", prominent: true) {
            AppearanceToggleRow(title: "与其他应用同时播放", isOn: $ignoreAudioFocus)
            ReaderSettingsFootnote(text: "开启后朗读会与其他应用同时播放，关闭后朗读会独占音频输出，不再只是压低其他音频。")
            AppearanceToggleRow(title: "同时播放时来电仍暂停", isOn: $pauseReadAloudWhilePhoneCalls, disabled: !ignoreAudioFocus)
        }
        AppearanceGroup("朗读状态", prominent: true) {
            AppearanceRowLabel(title: "当前状态", value: status.label)
        }
        AppearanceGroup("语音设置", prominent: true) {
            AppearancePickerRow(title: "朗读语音",
                                options: [("", "系统默认中文声音")] + voices.map { ($0.identifier, SpeechVoiceCatalog.label($0)) },
                                selection: $systemTTSVoice)
            AppearanceToggleRow(title: "语速跟随系统", isOn: $ttsFollowSystem)
            ReaderStepperSliderRow(title: "朗读速度", value: rateBinding, range: 0.5...5.0, step: 0.1,
                                   unit: "x", note: "范围：0.5x - 5.0x", disabled: ttsFollowSystem)
            ReaderStepperSliderRow(title: "音调", value: $pitch, range: 0.5...2.0, step: 0.1,
                                   note: "范围：0.5 - 2.0（0.5=低沉，1.0=正常，2.0=高亮），作用于系统 TTS")
            ReaderStepperSliderRow(title: "预加载段落", value: preloadBinding, range: 1...10, step: 1,
                                   unit: "段", digits: 0, note: "范围：1 - 10，在线朗读预加载更多段落可减少卡顿")
        }
        AppearanceGroup("朗读方式", prominent: true) {
            AppearanceToggleRow(title: "按页朗读", isOn: $readAloudByPage)
            AppearanceToggleRow(title: "流式播放在线音频", isOn: $streamReadAloudAudio)
            AppearanceToggleRow(title: "朗读时保持亮屏", isOn: $readAloudWakeLock)
            AppearanceToggleRow(title: "媒体上一首/下一首切换章节", isOn: $mediaButtonPerNext)
            AppearanceSliderRow(title: "默认定时", value: timerBinding, range: 0...180, step: 5) {
                $0 < 1 ? "关闭" : "\(Int($0)) 分钟"
            }
        }
        Button {
            confirmsReset = true
        } label: {
            AppearanceCard {
                Text("恢复默认设置")
                    .font(AppFontStyle.body.themed)
                    .frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("reader.speech.reset")
        .confirmationDialog("把朗读设置恢复为默认值？", isPresented: $confirmsReset, titleVisibility: .visible) {
            Button("恢复默认设置", role: .destructive) { resetDefaults() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("引擎、语音、语速、音调、预加载、高亮色和朗读方式会恢复默认；朗读源本身不受影响。")
        }
        .task { await loadEngines() }
    }

    private func resetDefaults() {
        appTTSEngine = ""
        systemTTSVoice = ""
        ttsFollowSystem = true
        ttsSpeechRate = 5
        pitch = 1.0
        preloadCount = 3
        highlightEnabled = true
        lightHighlight = ReaderSpeechKeys.defaultLightHighlight
        darkHighlight = ReaderSpeechKeys.defaultDarkHighlight
        readAloudByPage = false
        streamReadAloudAudio = true
        readAloudWakeLock = false
        ignoreAudioFocus = false
        pauseReadAloudWhilePhoneCalls = false
        mediaButtonPerNext = false
        ttsTimer = 0
    }

    private func loadEngines(force: Bool = false) async {
        guard engines.isEmpty || force, let database = try? LegadoDatabase(url: LegadoDatabase.defaultURL()) else { return }
        let repository = SQLiteConfigurationRepository(database: database)
        var values = (try? await repository.loadHttpTTS()) ?? []
        let upgraded = HttpTTSLibraryModel.upgradingBundledPresets(values)
        if upgraded != values {
            values = upgraded
            try? await repository.saveHttpTTS(values)
        }
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

/// 编辑哪个主题：themeID 为 nil 表示新建。
struct ReaderThemeEditorTarget: Identifiable {
    let themeID: String?
    let dark: Bool
    var id: String { (themeID ?? "new") + (dark ? "-dark" : "-light") }
}

/// 主题编辑器：预设、旧版「自定义」、新建主题共用。改文字颜色、背景颜色、背景图，上方实时预览。
/// 预设保存后改的就是这个预设本身；新建的主题保存后出现在对应一排并立即使用。
private struct ReaderThemeEntryEditor: View {
    let target: ReaderThemeEditorTarget
    let onFinish: (String?) -> Void

    @ThemePalette private var palette
    @State private var name: String
    @State private var foregroundHex: String
    @State private var backgroundHex: String
    @State private var usesImage: Bool
    @State private var image: UIImage?
    /// 新选的图片先放在临时文件里，保存时才替换正式文件。
    @State private var pickedImageURL: URL?
    @State private var removesImage = false
    @State private var picksImage = false
    @State private var errorMessage: String?

    private var dark: Bool { target.dark }
    private var isNew: Bool { target.themeID == nil }
    private var isPreset: Bool { target.themeID.flatMap(ReaderStylePreset.original) != nil }
    private var isUserTheme: Bool { target.themeID.flatMap(ReaderThemeLibrary.userTheme) != nil }

    private static let lightSuggestions: [(String, String, String)] = [
        ("米黄", "F5EFDF", "2E2A24"), ("纸白", "FBFAF7", "1F1F1F"), ("豆沙绿", "CCE8CF", "1F3322"),
        ("浅粉", "F8E8EA", "4A2F35"), ("雾蓝", "E3EBF3", "26313D"), ("燕麦", "EDE3D1", "3B3226")
    ]
    private static let darkSuggestions: [(String, String, String)] = [
        ("暖黑", "1C1B19", "B9B2A6"), ("纯黑", "000000", "9A9A9A"), ("石墨", "2B2B2D", "C9C9CC"),
        ("夜蓝", "0E1726", "9FB0C7"), ("松绿", "10201A", "9EBFAE"), ("咖啡", "241C16", "C2B09A")
    ]

    init(target: ReaderThemeEditorTarget, onFinish: @escaping (String?) -> Void) {
        self.target = target
        self.onFinish = onFinish
        if let id = target.themeID {
            let style = ReaderStylePreset.resolve(id)
            _name = State(initialValue: style.name)
            _foregroundHex = State(initialValue: style.foreground.readerHex)
            _backgroundHex = State(initialValue: style.background.readerHex)
            _usesImage = State(initialValue: ReaderThemeLibrary.usesImage(id))
            _image = State(initialValue: ReaderThemeLibrary.previewImage(id))
        } else {
            let count = ReaderThemeLibrary.userThemes(dark: target.dark).count + 1
            let first = target.dark ? Self.darkSuggestions[0] : Self.lightSuggestions[0]
            _name = State(initialValue: (target.dark ? "我的深色" : "我的浅色") + "\(count)")
            _foregroundHex = State(initialValue: first.2)
            _backgroundHex = State(initialValue: first.1)
            _usesImage = State(initialValue: false)
            _image = State(initialValue: nil)
        }
    }

    private var foreground: Color { AppThemeColor.color(foregroundHex) }
    private var background: Color { AppThemeColor.color(backgroundHex) }
    private var showsImage: Bool { usesImage && image != nil }

    private var title: String {
        if isNew { return dark ? "新建深色主题" : "新建浅色主题" }
        return "编辑「\(name)」"
    }

    var body: some View {
        ReadingNavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    preview
                    if isNew || isUserTheme {
                        AppearanceGroup("名称", prominent: true) {
                            AppearanceCard {
                                TextField("主题名称", text: $name)
                                    .font(AppFontStyle.body.themed)
                                    .foregroundStyle(palette.primary)
                                    .accessibilityIdentifier("reader.customTheme.name")
                            }
                        }
                    }
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
                    if isPreset, let id = target.themeID, let original = ReaderStylePreset.original(id) {
                        AppearanceGroup {
                            Button {
                                ReaderThemeLibrary.resetPreset(id)
                                discardPicked()
                                onFinish(id)
                            } label: {
                                AppearanceRowLabel(title: "恢复「\(original.name)」原来的颜色", icon: "arrow.uturn.backward")
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 48)
            }
            .background { AppThemeCanvas().ignoresSafeArea() }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        discardPicked()
                        onFinish(nil)
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
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("reader-theme-\(UUID().uuidString).jpg")
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

    private func discardPicked() {
        if let pickedImageURL { try? FileManager.default.removeItem(at: pickedImageURL) }
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
        let id: String
        if let existing = target.themeID {
            id = existing
        } else {
            id = ReaderThemeLibrary.newUserThemeID()
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            ReaderThemeLibrary.saveUserTheme(.init(
                id: id,
                name: trimmed.isEmpty ? (dark ? "我的深色" : "我的浅色") : trimmed,
                dark: dark,
                backgroundHex: UIColor(readerHex: backgroundHex) != nil ? backgroundHex : (dark ? "1C1B19" : "F5EFDF"),
                foregroundHex: UIColor(readerHex: foregroundHex) != nil ? foregroundHex : (dark ? "B9B2A6" : "2E2A24")
            ))
        }
        let targetURL = ReaderThemeLibrary.imageURL(id)
        if let pickedImageURL {
            do {
                try FileManager.default.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: targetURL.path) { try FileManager.default.removeItem(at: targetURL) }
                try FileManager.default.moveItem(at: pickedImageURL, to: targetURL)
            } catch {
                errorMessage = "背景图保存失败：\(error.localizedDescription)"
                return
            }
        } else if removesImage {
            try? FileManager.default.removeItem(at: targetURL)
        }
        if var theme = ReaderThemeLibrary.userTheme(id) {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { theme.name = trimmed }
            ReaderThemeLibrary.saveUserTheme(theme)
        }
        ReaderThemeLibrary.update(id, background: backgroundHex, foreground: foregroundHex, usesImage: usesImage && image != nil)
        // 用户想看到的主题被隐藏过的话，保存后重新显示。
        ReaderThemeLibrary.setHidden(id, false)
        onFinish(id)
    }
}

/// 「管理主题」：逐个选择浅色 / 深色主题是否显示在色块里。
private struct ReaderThemeManagerSheet: View {
    let onChange: () -> Void
    @Environment(\.dismiss) private var dismiss
    @ThemePalette private var palette
    @AppStorage(ReaderThemeLibrary.hiddenKey) private var hiddenThemes = ""
    @AppStorage(ReaderThemeLibrary.userThemesKey) private var userThemesData = Data()

    var body: some View {
        ReadingNavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    group("浅色主题", dark: false)
                    group("深色主题", dark: true)
                    ReaderSettingsFootnote(text: "关掉的主题不会出现在阅读设置和「大小」面板的色块里；当前正在用的主题始终显示。新建的主题可以长按色块删除。")
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 48)
            }
            .background { AppThemeCanvas().ignoresSafeArea() }
            .navigationTitle("管理主题")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { onChange(); dismiss() }
                }
            }
        }
    }

    private func group(_ title: String, dark: Bool) -> some View {
        _ = (hiddenThemes, userThemesData)
        let hidden = ReaderThemeLibrary.hiddenIDs()
        return AppearanceGroup(title, prominent: true) {
            ForEach(ReaderThemeLibrary.allThemes(dark: dark)) { item in
                AppearanceToggleRow(title: item.name, isOn: Binding(
                    get: { !hidden.contains(item.id) },
                    set: { shown in
                        ReaderThemeLibrary.setHidden(item.id, !shown)
                        hiddenThemes = UserDefaults.standard.string(forKey: ReaderThemeLibrary.hiddenKey) ?? ""
                    }
                ))
            }
        }
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

// MARK: - 阅读页「大小」快捷面板

/// 「大小」面板底部八个入口。
enum ReaderQuickStyleAction: String, Identifiable {
    case display, spacing, speech, highlight, bubble, titleStyle, headerFooter, more
    var id: String { rawValue }
}

/// 参考应用阅读页底栏「大小」：字号 + 字体、浅色 / 深色主题色块、跟随系统深浅色、翻页方式，
/// 下面 2×4 的入口（显示、间距、朗读、高亮、气泡、标题样式、页眉页脚、更多设置）。
/// 「间距设置」在面板里原地展开，其余入口由阅读页打开对应的设置页。
struct ReaderQuickStylePanel: View {
    @Binding var pageAnimation: Int
    let tint: Color
    let onAction: (ReaderQuickStyleAction) -> Void

    @AppStorage("textSize") private var fontSize = 20.0
    @AppStorage("textFont") private var fontPath = ""
    @AppStorage("readerTheme") private var theme = "wechat"
    @AppStorage("readerPreviousDayTheme") private var previousDayTheme = "wechat"
    @AppStorage("readerDarkTheme") private var darkTheme = "night"
    @AppStorage("readerFollowSystemDark") private var followSystemDark = false
    @AppStorage("readerUseBackgroundImage") private var useBackgroundImage = false
    @AppStorage("lineSpacingExtra") private var lineSpacing = 12.0
    @AppStorage("paragraphSpacing") private var paragraphSpacing = 2.0
    @AppStorage("paddingLeft") private var paddingLeft = 16.0
    @AppStorage("paddingRight") private var paddingRight = 16.0
    @AppStorage("paddingTop") private var paddingTop = 6.0
    @AppStorage("paddingBottom") private var paddingBottom = 6.0
    @State private var showsSpacing = false

    private static let pageModes: [(Int, String)] = [(2, "仿真"), (1, "滑动"), (0, "平移"), (4, "无动画"), (3, "上下滚动")]

    private var fontTitle: String {
        fontPath.isEmpty ? "系统字体" : URL(fileURLWithPath: fontPath).deletingPathExtension().lastPathComponent
    }

    var body: some View {
        Group {
            if showsSpacing {
                spacingPage
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                mainPage
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: showsSpacing)
        .foregroundStyle(tint)
    }

    // MARK: 主页

    private var mainPage: some View {
        VStack(spacing: 12) {
            fontRow
            swatchRow(ReaderThemeLibrary.visibleThemes(dark: false, selected: [theme, previousDayTheme]), dark: false, icon: "sun.max")
            swatchRow(ReaderThemeLibrary.visibleThemes(dark: true, selected: [theme, darkTheme]), dark: true, icon: "moon")
            HStack(spacing: 8) {
                Image(systemName: "circle.lefthalf.filled").font(.system(size: 14))
                Text("跟随系统深浅色").font(.system(size: 13))
                Spacer()
                Toggle("跟随系统深浅色", isOn: $followSystemDark)
                    .labelsHidden()
                    .tint(ReadingTheme.accent)
            }
            .padding(.horizontal, 4)
            pageModeRow
            actionGrid
        }
    }

    private var fontRow: some View {
        HStack(spacing: 10) {
            Button { fontSize = max(5, fontSize - 1) } label: {
                Text("小").font(.system(size: 12, weight: .medium)).frame(width: 30, height: 30)
                    .background(Circle().fill(tint.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("字号减小")
            Slider(value: $fontSize, in: 5...50, step: 1)
                .tint(ReadingTheme.accent)
                .accessibilityLabel("字号")
                .accessibilityValue("\(Int(fontSize))")
            Button { fontSize = min(50, fontSize + 1) } label: {
                Text("大").font(.system(size: 16, weight: .semibold)).frame(width: 30, height: 30)
                    .background(Circle().fill(tint.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("字号增大")
            Menu {
                Button { fontPath = "" } label: {
                    Label("系统字体", systemImage: fontPath.isEmpty ? "checkmark" : "textformat")
                }
                ForEach(ReaderHighlighter.importedFonts(), id: \.self) { file in
                    let path = ReaderFontStore.directory.appendingPathComponent(file).path
                    Button { fontPath = path } label: {
                        Label((file as NSString).deletingPathExtension, systemImage: fontPath == path ? "checkmark" : "textformat")
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    Text(fontTitle).lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                }
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 10)
                .frame(height: 30)
                .frame(maxWidth: 96)
                .background(Capsule().fill(tint.opacity(0.08)))
            }
            .accessibilityLabel("字体")
        }
    }

    private func isSelected(_ id: String, dark: Bool) -> Bool {
        if useBackgroundImage { return false }
        if followSystemDark {
            if dark { return darkTheme == id }
            return ReaderStylePreset.isDarkID(theme) ? previousDayTheme == id : theme == id
        }
        return theme == id
    }

    private func select(_ id: String, dark: Bool) {
        UISelectionFeedbackGenerator().selectionChanged()
        useBackgroundImage = false
        if dark { darkTheme = id } else { previousDayTheme = id }
        theme = id
    }

    private func swatchRow(_ presets: [ReaderStylePreset], dark: Bool, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 14)).frame(width: 18)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(presets) { preset in
                        let selected = isSelected(preset.id, dark: dark)
                        Button { select(preset.id, dark: dark) } label: {
                            Text("文")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Color(uiColor: preset.foreground))
                                .frame(width: 32, height: 32)
                                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(uiColor: preset.background)))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .strokeBorder(selected ? ReadingTheme.accent : tint.opacity(0.15), lineWidth: selected ? 2 : 0.75)
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(preset.name)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var pageModeRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "book").font(.system(size: 14)).frame(width: 18)
            HStack(spacing: 2) {
                ForEach(Self.pageModes, id: \.0) { mode in
                    let selected = pageAnimation == mode.0
                    Button {
                        UISelectionFeedbackGenerator().selectionChanged()
                        pageAnimation = mode.0
                    } label: {
                        Text(mode.1)
                            .font(.system(size: 12, weight: selected ? .semibold : .regular))
                            .foregroundStyle(selected ? Color.white : tint)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .frame(maxWidth: .infinity, minHeight: 28)
                            .background { if selected { Capsule().fill(ReadingTheme.accent) } }
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(2)
            .background(Capsule().fill(tint.opacity(0.07)))
        }
        .accessibilityIdentifier("reader.quick.pageMode")
    }

    private var actionGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
            tile(.display, title: "显示设置") { Text("大小").font(.system(size: 14, weight: .semibold)) }
            tile(.spacing, title: "间距设置") { Image(systemName: "text.alignleft") }
            tile(.speech, title: "朗读设置") { Image(systemName: "speaker.wave.2") }
            tile(.highlight, title: "高亮设置") { Image(systemName: "highlighter") }
            tile(.bubble, title: "气泡设置") { Image(systemName: "text.bubble") }
            tile(.titleStyle, title: "标题样式") { Text("格式").font(.system(size: 14, weight: .semibold)) }
            tile(.headerFooter, title: "页眉页脚") { Image(systemName: "doc.text") }
            tile(.more, title: "更多设置") { Image(systemName: "ellipsis.circle") }
        }
    }

    private func tile<Icon: View>(_ action: ReaderQuickStyleAction, title: String, @ViewBuilder icon: () -> Icon) -> some View {
        Button {
            if action == .spacing { showsSpacing = true } else { onAction(action) }
        } label: {
            VStack(spacing: 3) {
                icon()
                    .font(.system(size: 17))
                    .frame(height: 22)
                Text(title)
                    .font(.system(size: 10))
                    .foregroundStyle(tint.opacity(0.7))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(tint.opacity(0.07)))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityIdentifier("reader.quick.\(action.rawValue)")
    }

    // MARK: 间距

    private var spacingPage: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                Text("间距设置").font(.system(size: 15, weight: .semibold))
                HStack {
                    Button { showsSpacing = false } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(tint.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("返回")
                    Spacer()
                }
            }
            spacingSlider("行间距", value: $lineSpacing, range: 0...50, step: 1)
            spacingSlider("段间距", value: $paragraphSpacing, range: 0...50, step: 0.5)
            spacingSlider("左边距", value: $paddingLeft, range: 0...100, step: 1)
            spacingSlider("右边距", value: $paddingRight, range: 0...100, step: 1)
            spacingSlider("上边距", value: $paddingTop, range: 0...100, step: 1)
            spacingSlider("下边距", value: $paddingBottom, range: 0...100, step: 1)
        }
    }

    private func spacingSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.system(size: 13))
                Spacer()
                Text(step < 1 ? String(format: "%.1f", value.wrappedValue) : "\(Int(value.wrappedValue))")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(tint.opacity(0.6))
            }
            Slider(value: value, in: range, step: step)
                .tint(ReadingTheme.accent)
                .accessibilityLabel(title)
        }
    }
}
