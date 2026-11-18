import SwiftUI
import UIKit

/// Grid-only cover width is a preference, never a minimum that can overflow.
/// Columns shrink on compact windows; accessibility uses at most two 120pt cells.
struct ThemeShelfMetrics {
    let columns: Int
    let coverWidth: CGFloat

    init(width: CGFloat, customization: ThemeCustomization, accessibility: Bool) {
        let available = max(1, (width.isFinite ? width : 320) - 48)
        let minimumCell: CGFloat = accessibility ? 120 : 60
        let fitting = max(1, Int(min(6, (available + 18) / (minimumCell + 14))))
        let requested = min(max(customization.shelfColumns, 2), 6)
        columns = min(requested, fitting, accessibility ? 2 : 6)
        let cell = max(1, (available - CGFloat(columns - 1) * 18) / CGFloat(columns))
        let desired = customization.coverWidth.isFinite ? min(max(customization.coverWidth, 60), 180) : 112
        coverWidth = min(CGFloat(desired), cell)
    }
}

/// Process-wide claim, including a launch without an image. Foregrounding and
/// changing the active theme never start another splash; additional windows do not either.
@MainActor
private final class ThemeLaunchSession {
    static let shared = ThemeLaunchSession()
    private var consumed = false
    func claim(_ id: String?) -> String? {
        guard !consumed else { return nil }
        consumed = true
        return id.flatMap { ThemeAssetStore.isValidID($0) ? $0 : nil }
    }
}

/// Reusable app overlay, deliberately unrelated to the system LaunchScreen.
struct ThemeLaunchOverlay: View {
    let image: UIImage
    let onDismiss: () -> Void
    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            GeometryReader { geometry in
                Image(uiImage: image).resizable().scaledToFit()
                    .frame(width: geometry.size.width, height: geometry.size.height)
            }
            .ignoresSafeArea().accessibilityHidden(true)

        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityAction(.escape, onDismiss)
        .accessibilityIdentifier("theme.launch.overlay")
        .task {
            do { try await Task.sleep(nanoseconds: 1_200_000_000) }
            catch { return }
            onDismiss()
        }
    }
}

struct ThemeLaunchHost: ViewModifier {
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @StateObject private var imageLoader = ThemeAssetImageLoader()
    @State private var evaluated = false
    @State private var presented = false

    func body(content: Content) -> some View {
        content
            .allowsHitTesting(!presented)
            .accessibilityHidden(presented)
            .overlay {
                if presented, let image = imageLoader.image {
                    ThemeLaunchOverlay(image: image) { presented = false }
                }
            }
            .task {
                guard !evaluated else { return }
                evaluated = true
                let id = ThemeLaunchSession.shared.claim(theme.customization?.launchImage(dark: scheme == .dark))
                await imageLoader.load(id)
                guard !Task.isCancelled, imageLoader.image != nil else { return }
                presented = true
                // Overlay owns the same automatic dismissal in production and preview.
            }
    }
}

/// App chrome only. Reader paper, pagination and ReadingFontManager stay independent.
enum ThemeTabStyle: String, Codable, CaseIterable, Identifiable {
    case iconsAndText, icons, text
    var id: String { rawValue }
    var title: String {
        switch self {
        case .iconsAndText: return "图标和文字"
        case .icons: return "仅图标"
        case .text: return "仅文字"
        }
    }
}

enum ThemeInterfaceEffect: String, Codable, CaseIterable, Identifiable {
    case transparent, frosted, opaque
    var id: String { rawValue }
    var title: String {
        switch self {
        case .transparent: return "透明"
        case .frosted: return "玻璃"
        case .opaque: return "不透明"
        }
    }
}

/// 阅读页底栏样式：经典工具栏 / 聊天输入框式。
enum ThemeReaderBarStyle: String, Codable, CaseIterable, Identifiable {
    case classic, chat
    var id: String { rawValue }
    var title: String { self == .classic ? "经典" : "聊天输入框" }
}

/// 阅读工具栏里可换图标的四个按钮。
enum ThemeReaderToolbarItem: String, CaseIterable, Identifiable {
    case toc, tts, search, style
    var id: String { rawValue }
    var title: String {
        switch self {
        case .toc: return "目录"
        case .tts: return "朗读"
        case .search: return "搜索"
        case .style: return "设置"
        }
    }
    var symbol: String {
        switch self {
        case .toc: return "list.bullet"
        case .tts: return "speaker.wave.2"
        case .search: return "magnifyingglass"
        case .style: return "textformat.size"
        }
    }
    func key(dark: Bool) -> String { rawValue + (dark ? ".dark" : ".light") }
}

/// Tab 栏图标的四种状态。
enum ThemeTabIconState: String, CaseIterable, Identifiable {
    case normal, selected, darkNormal, darkSelected
    var id: String { rawValue }
    var title: String {
        switch self {
        case .normal: return "未选中"
        case .selected: return "选中"
        case .darkNormal: return "深色未选中"
        case .darkSelected: return "深色选中"
        }
    }
    var isSelected: Bool { self == .selected || self == .darkSelected }
    var isDark: Bool { self == .darkNormal || self == .darkSelected }
    static func state(selected: Bool, dark: Bool) -> ThemeTabIconState {
        dark ? (selected ? .darkSelected : .darkNormal) : (selected ? .selected : .normal)
    }
    /// 没设置这个状态的图片时依次退回的状态。
    var fallbacks: [ThemeTabIconState] {
        switch self {
        case .normal: return [.normal]
        case .selected: return [.selected, .normal]
        case .darkNormal: return [.darkNormal, .normal]
        case .darkSelected: return [.darkSelected, .selected, .darkNormal, .normal]
        }
    }
}

/// 书架顶部样式。
enum ThemeShelfTopStyle: String, Codable, CaseIterable, Identifiable {
    case groupsAndSearch, groups, search, plain
    var id: String { rawValue }
    var title: String {
        switch self {
        case .groupsAndSearch: return "分组与搜索"
        case .groups: return "仅分组"
        case .search: return "仅搜索"
        case .plain: return "仅标题"
        }
    }
    var showsGroups: Bool { self == .groupsAndSearch || self == .groups }
    var showsSearch: Bool { self == .groupsAndSearch || self == .search }
}

/// 书架标签的文字颜色。
enum ThemeTagColorStyle: String, Codable, CaseIterable, Identifiable {
    case colorful, text, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .colorful: return "彩色"
        case .text: return "文字色"
        case .custom: return "自定义"
        }
    }
}

/// 卡片背景图的显示方式。
enum ThemeCardImageMode: String, Codable, CaseIterable, Identifiable {
    case fill, fit, stretch, tile
    var id: String { rawValue }
    var title: String {
        switch self {
        case .fill: return "填充"
        case .fit: return "适应"
        case .stretch: return "拉伸"
        case .tile: return "平铺"
        }
    }
}

/// 「页面背景」的编辑范围：全局默认或单独某个页面。
enum ThemePageScope: String, Codable, CaseIterable, Identifiable, Sendable {
    case global, shelf, discover, search, statistics, files, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .global: return "全局默认"
        case .shelf: return "书架"
        case .discover: return "发现"
        case .search: return "搜索"
        case .statistics: return "统计"
        case .files: return "文件管理"
        case .settings: return "设置"
        }
    }
}

/// 单个页面的背景覆盖；为空的项沿用全局默认。
struct ThemePageBackground: Codable, Equatable {
    var lightBackground: String? = nil
    var lightBackgroundEnd: String? = nil
    var darkBackground: String? = nil
    var darkBackgroundEnd: String? = nil
    var lightImage: String? = nil
    var darkImage: String? = nil

    var isEmpty: Bool { self == ThemePageBackground() }
    var colors: [String] { [lightBackground, lightBackgroundEnd, darkBackground, darkBackgroundEnd].compactMap { $0 } }
    var images: [String] { [lightImage, darkImage].compactMap { $0 } }
    var hasColors: Bool { !colors.isEmpty }
    func image(dark: Bool) -> String? { dark ? (darkImage ?? lightImage) : lightImage }
}

private struct ThemePageScopeKey: EnvironmentKey {
    static let defaultValue: ThemePageScope = .global
}

extension EnvironmentValues {
    /// 当前页面属于哪个「页面背景」范围（各标签页、搜索、文件管理分别设置）。
    var themePageScope: ThemePageScope {
        get { self[ThemePageScopeKey.self] }
        set { self[ThemePageScopeKey.self] = newValue }
    }
}

struct ThemeCustomization: Codable, Equatable {
    var tabStyle: ThemeTabStyle = .iconsAndText
    var shelfColumns: Int = 3
    var coverWidth: Double = 112
    var defaultCoverImage: String? = nil
    var launchImage: String? = nil
    var pageBackgroundImage: String? = nil
    /// nil follows the existing font manager; an empty string explicitly means system.
    var fontPostScriptName: String? = nil
    var effect: ThemeInterfaceEffect = .frosted
    var cardBackground: Bool = true
    /// Optional per-tab icon override. Keys are LibraryTab raw names
    /// ("shelf"/"statistics"/"profile"); values are either an SF Symbol name
    /// or a ThemeAssetStore identifier (UUID.jpg) for an imported image.
    var tabIcons: [String: String]? = nil
    /// Strength of the subtle glow behind transparent surfaces, 0 disables it.
    var glowIntensity: Double = 0.6
    /// Opacity of the frosted effect's surface tint layer.
    var surfaceOpacity: Double = 0.85
    /// 深色模式背景图；为空时深色也用亮色背景图。
    var darkPageBackgroundImage: String? = nil
    /// 背景图本身的不透明度（越低越透出主题底色）。
    var backgroundImageOpacity: Double = 1
    /// 「卡片背景」：开启后卡片用下面的颜色 / 透明度 / 边框，替代界面效果。
    var customCard: Bool = false
    var cardOpacity: Double = 0.15
    var cardBorderOpacity: Double = 0
    var cardBorderWidth: Double = 0.7
    var darkLaunchImage: String? = nil
    var forceDefaultCover: Bool = false
    // 阅读界面
    var readerBarStyle: ThemeReaderBarStyle = .classic
    var readerToolbarIconSize: Double = 17
    /// 键为「toc.light」「tts.dark」等，值为主题图片标识。
    var readerToolbarIcons: [String: String]? = nil
    // Tab 栏
    var tabIconSize: Double = 28
    var classicTabBar: Bool = false
    /// 键为「shelf.selected」「discover.darkNormal」等，值为主题图片标识。
    var tabStateIcons: [String: String]? = nil
    // 书架
    var shelfTopStyle: ThemeShelfTopStyle = .groupsAndSearch
    var shelfShowTags: Bool = true
    var shelfTagColor: ThemeTagColorStyle = .colorful
    var shelfTagCustomColor: String = "007AFF"
    // 默认封面
    var coverCornerRadius: Double = 8
    var defaultCoverInTabs: Bool = false
    var darkDefaultCoverImage: String? = nil
    // 启动图
    var launchEnabled: Bool = true
    // 页面背景：按页面单独设置
    var pageBackgrounds: [String: ThemePageBackground]? = nil
    // 界面效果
    var transparentOpacity: Double = 0
    var frostedOpacity: Double = 0.1
    var readerPanelFollowsTheme: Bool = false
    var progressBarFollowsTheme: Bool = false
    // 卡片背景图
    var cardImage: String? = nil
    var darkCardImage: String? = nil
    var cardImageMode: ThemeCardImageMode = .fill

    static let shelfColumnsRange = 2...6
    static let coverWidthRange: ClosedRange<Double> = 60...180
    static let glowIntensityRange: ClosedRange<Double> = 0...1
    static let surfaceOpacityRange: ClosedRange<Double> = 0...1
    static let tabIconKeys: Set<String> = ["shelf", "discover", "statistics", "profile"]

    init(tabStyle: ThemeTabStyle = .iconsAndText, shelfColumns: Int = 3,
         coverWidth: Double = 112, defaultCoverImage: String? = nil,
         launchImage: String? = nil, pageBackgroundImage: String? = nil,
         fontPostScriptName: String? = nil, effect: ThemeInterfaceEffect = .opaque,
         cardBackground: Bool = true, tabIcons: [String: String]? = nil,
         glowIntensity: Double = 0.6, surfaceOpacity: Double = 0.85) {
        self.tabStyle = tabStyle
        self.shelfColumns = shelfColumns
        self.coverWidth = coverWidth
        self.defaultCoverImage = defaultCoverImage
        self.launchImage = launchImage
        self.pageBackgroundImage = pageBackgroundImage
        self.fontPostScriptName = fontPostScriptName
        self.effect = effect
        self.cardBackground = cardBackground
        self.tabIcons = tabIcons
        self.glowIntensity = glowIntensity
        self.surfaceOpacity = surfaceOpacity
    }

    private enum CodingKeys: String, CodingKey {
        case tabStyle, shelfColumns, coverWidth, defaultCoverImage, launchImage
        case pageBackgroundImage, fontPostScriptName, effect, cardBackground
        case tabIcons, glowIntensity, surfaceOpacity
        case darkPageBackgroundImage, backgroundImageOpacity, customCard, cardOpacity
        case cardBorderOpacity, cardBorderWidth, darkLaunchImage, forceDefaultCover
        case readerBarStyle, readerToolbarIconSize, readerToolbarIcons
        case tabIconSize, classicTabBar, tabStateIcons
        case shelfTopStyle, shelfShowTags, shelfTagColor, shelfTagCustomColor
        case coverCornerRadius, defaultCoverInTabs, darkDefaultCoverImage, launchEnabled
        case pageBackgrounds, transparentOpacity, frostedOpacity
        case readerPanelFollowsTheme, progressBarFollowsTheme
        case cardImage, darkCardImage, cardImageMode
    }

    /// Newly added fields get their defaults; malformed present values still fail.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        tabStyle = try values.decodeIfPresent(ThemeTabStyle.self, forKey: .tabStyle) ?? .iconsAndText
        shelfColumns = try values.decodeIfPresent(Int.self, forKey: .shelfColumns) ?? 3
        coverWidth = try values.decodeIfPresent(Double.self, forKey: .coverWidth) ?? 112
        defaultCoverImage = try values.decodeIfPresent(String.self, forKey: .defaultCoverImage)
        launchImage = try values.decodeIfPresent(String.self, forKey: .launchImage)
        pageBackgroundImage = try values.decodeIfPresent(String.self, forKey: .pageBackgroundImage)
        fontPostScriptName = try values.decodeIfPresent(String.self, forKey: .fontPostScriptName)
        effect = try values.decodeIfPresent(ThemeInterfaceEffect.self, forKey: .effect) ?? .transparent
        cardBackground = try values.decodeIfPresent(Bool.self, forKey: .cardBackground) ?? true
        tabIcons = try values.decodeIfPresent([String: String].self, forKey: .tabIcons)
        glowIntensity = try values.decodeIfPresent(Double.self, forKey: .glowIntensity) ?? 0.5
        surfaceOpacity = try values.decodeIfPresent(Double.self, forKey: .surfaceOpacity) ?? 0.85
        darkPageBackgroundImage = try values.decodeIfPresent(String.self, forKey: .darkPageBackgroundImage)
        backgroundImageOpacity = try values.decodeIfPresent(Double.self, forKey: .backgroundImageOpacity) ?? 1
        customCard = try values.decodeIfPresent(Bool.self, forKey: .customCard) ?? false
        cardOpacity = try values.decodeIfPresent(Double.self, forKey: .cardOpacity) ?? 0.6
        cardBorderOpacity = try values.decodeIfPresent(Double.self, forKey: .cardBorderOpacity) ?? 0.3
        cardBorderWidth = try values.decodeIfPresent(Double.self, forKey: .cardBorderWidth) ?? 0.7
        darkLaunchImage = try values.decodeIfPresent(String.self, forKey: .darkLaunchImage)
        forceDefaultCover = try values.decodeIfPresent(Bool.self, forKey: .forceDefaultCover) ?? false
        readerBarStyle = (try? values.decodeIfPresent(ThemeReaderBarStyle.self, forKey: .readerBarStyle)) ?? .classic
        readerToolbarIconSize = try values.decodeIfPresent(Double.self, forKey: .readerToolbarIconSize) ?? 17
        readerToolbarIcons = try values.decodeIfPresent([String: String].self, forKey: .readerToolbarIcons)
        tabIconSize = try values.decodeIfPresent(Double.self, forKey: .tabIconSize) ?? 28
        classicTabBar = try values.decodeIfPresent(Bool.self, forKey: .classicTabBar) ?? false
        tabStateIcons = try values.decodeIfPresent([String: String].self, forKey: .tabStateIcons)
        shelfTopStyle = (try? values.decodeIfPresent(ThemeShelfTopStyle.self, forKey: .shelfTopStyle)) ?? .groupsAndSearch
        shelfShowTags = try values.decodeIfPresent(Bool.self, forKey: .shelfShowTags) ?? true
        shelfTagColor = (try? values.decodeIfPresent(ThemeTagColorStyle.self, forKey: .shelfTagColor)) ?? .colorful
        shelfTagCustomColor = try values.decodeIfPresent(String.self, forKey: .shelfTagCustomColor) ?? "007AFF"
        coverCornerRadius = try values.decodeIfPresent(Double.self, forKey: .coverCornerRadius) ?? 8
        defaultCoverInTabs = try values.decodeIfPresent(Bool.self, forKey: .defaultCoverInTabs) ?? false
        darkDefaultCoverImage = try values.decodeIfPresent(String.self, forKey: .darkDefaultCoverImage)
        launchEnabled = try values.decodeIfPresent(Bool.self, forKey: .launchEnabled) ?? true
        pageBackgrounds = try values.decodeIfPresent([String: ThemePageBackground].self, forKey: .pageBackgrounds)
        // 旧版只有一个 surfaceOpacity，两种效果共用。
        let legacyOpacity: Double? = values.contains(.surfaceOpacity) ? surfaceOpacity : nil
        transparentOpacity = try values.decodeIfPresent(Double.self, forKey: .transparentOpacity) ?? legacyOpacity ?? 0
        frostedOpacity = try values.decodeIfPresent(Double.self, forKey: .frostedOpacity) ?? legacyOpacity ?? 0.1
        readerPanelFollowsTheme = try values.decodeIfPresent(Bool.self, forKey: .readerPanelFollowsTheme) ?? false
        progressBarFollowsTheme = try values.decodeIfPresent(Bool.self, forKey: .progressBarFollowsTheme) ?? false
        cardImage = try values.decodeIfPresent(String.self, forKey: .cardImage)
        darkCardImage = try values.decodeIfPresent(String.self, forKey: .darkCardImage)
        cardImageMode = (try? values.decodeIfPresent(ThemeCardImageMode.self, forKey: .cardImageMode)) ?? .fill
    }

    /// 当前明暗下实际使用的背景图。
    func pageBackgroundImage(dark: Bool) -> String? {
        dark ? (darkPageBackgroundImage ?? pageBackgroundImage) : pageBackgroundImage
    }

    var hasPageBackground: Bool { pageBackgroundImage != nil || darkPageBackgroundImage != nil }

    func launchImage(dark: Bool) -> String? {
        guard launchEnabled else { return nil }
        return dark ? (darkLaunchImage ?? launchImage) : launchImage
    }

    func defaultCover(dark: Bool) -> String? {
        dark ? (darkDefaultCoverImage ?? defaultCoverImage) : defaultCoverImage
    }

    var hasDefaultCover: Bool { defaultCoverImage != nil || darkDefaultCoverImage != nil }

    func cardImage(dark: Bool) -> String? {
        dark ? (darkCardImage ?? cardImage) : cardImage
    }

    /// 当前界面效果对应的卡片不透明度（透明模式与毛玻璃各自一份）。
    var effectOpacity: Double {
        switch effect {
        case .transparent: return transparentOpacity
        case .frosted: return frostedOpacity
        case .opaque: return 1
        }
    }

    func pageBackground(_ scope: ThemePageScope) -> ThemePageBackground? {
        guard scope != .global, let value = pageBackgrounds?[scope.rawValue], !value.isEmpty else { return nil }
        return value
    }

    /// 某个页面实际使用的背景图（页面自己的优先，否则全局）。
    func pageBackgroundImage(dark: Bool, scope: ThemePageScope) -> String? {
        pageBackground(scope)?.image(dark: dark) ?? pageBackgroundImage(dark: dark)
    }

    func hasPageBackground(scope: ThemePageScope) -> Bool {
        hasPageBackground || pageBackground(scope)?.images.isEmpty == false
    }

    func readerToolbarIcon(_ item: ThemeReaderToolbarItem, dark: Bool) -> String? {
        let icons = readerToolbarIcons ?? [:]
        return dark ? (icons[item.key(dark: true)] ?? icons[item.key(dark: false)]) : icons[item.key(dark: false)]
    }

    func tabIcon(_ tabKey: String, state: ThemeTabIconState) -> String? {
        let icons = tabStateIcons ?? [:]
        for candidate in state.fallbacks {
            if let id = icons[tabKey + "." + candidate.rawValue] { return id }
        }
        return nil
    }

    var assetIDs: Set<String> {
        var ids = Set([defaultCoverImage, launchImage, pageBackgroundImage, darkPageBackgroundImage, darkLaunchImage,
                       darkDefaultCoverImage, cardImage, darkCardImage].compactMap { $0 })
        ids.formUnion((tabIcons ?? [:]).values.filter(ThemeAssetStore.isValidID))
        ids.formUnion((readerToolbarIcons ?? [:]).values)
        ids.formUnion((tabStateIcons ?? [:]).values)
        for value in (pageBackgrounds ?? [:]).values { ids.formUnion(value.images) }
        return ids
    }

    /// 把所有图片标识换成新的（导入主题时图片会重新保存，标识改变）。
    mutating func remapAssets(_ map: @escaping (String) -> String?) {
        func remap(_ id: String?) -> String? { id.flatMap(map) }
        defaultCoverImage = remap(defaultCoverImage)
        darkDefaultCoverImage = remap(darkDefaultCoverImage)
        launchImage = remap(launchImage)
        darkLaunchImage = remap(darkLaunchImage)
        pageBackgroundImage = remap(pageBackgroundImage)
        darkPageBackgroundImage = remap(darkPageBackgroundImage)
        cardImage = remap(cardImage)
        darkCardImage = remap(darkCardImage)
        func remapDictionary(_ value: [String: String]?, keepSymbols: Bool) -> [String: String]? {
            var result: [String: String] = [:]
            for (key, id) in value ?? [:] {
                if keepSymbols, !ThemeAssetStore.isValidID(id) { result[key] = id; continue }
                if let mapped = map(id) { result[key] = mapped }
            }
            return result.isEmpty ? nil : result
        }
        tabIcons = remapDictionary(tabIcons, keepSymbols: true)
        tabStateIcons = remapDictionary(tabStateIcons, keepSymbols: false)
        readerToolbarIcons = remapDictionary(readerToolbarIcons, keepSymbols: false)
        if let pages = pageBackgrounds {
            var result: [String: ThemePageBackground] = [:]
            for (key, var value) in pages {
                value.lightImage = remap(value.lightImage)
                value.darkImage = remap(value.darkImage)
                if !value.isEmpty { result[key] = value }
            }
            pageBackgrounds = result.isEmpty ? nil : result
        }
    }

    var validationMessage: String? {
        guard Self.shelfColumnsRange.contains(shelfColumns) else { return "书架列数须在 2–6 列之间。" }
        guard coverWidth.isFinite, Self.coverWidthRange.contains(coverWidth) else { return "封面宽度须在 60–180 点之间。" }
        if let font = fontPostScriptName,
           font.count > 128 || font.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            return "字体标识无效，最多允许 128 个字符。"
        }
        guard glowIntensity.isFinite, Self.glowIntensityRange.contains(glowIntensity) else {
            return "光晕强度须在 0–1 之间。"
        }
        guard surfaceOpacity.isFinite, Self.surfaceOpacityRange.contains(surfaceOpacity) else {
            return "透明度须在 0–1 之间。"
        }
        for value in [backgroundImageOpacity, cardOpacity, cardBorderOpacity] {
            guard value.isFinite, (0...1).contains(value) else { return "透明度须在 0–1 之间。" }
        }
        guard cardBorderWidth.isFinite, (0...4).contains(cardBorderWidth) else { return "边框大小须在 0–4 之间。" }
        for value in [transparentOpacity, frostedOpacity] {
            guard value.isFinite, (0...1).contains(value) else { return "不透明度须在 0–1 之间。" }
        }
        guard readerToolbarIconSize.isFinite, (10...40).contains(readerToolbarIconSize) else { return "工具栏图标大小无效。" }
        guard tabIconSize.isFinite, (16...44).contains(tabIconSize) else { return "Tab 栏图标大小无效。" }
        guard coverCornerRadius.isFinite, (0...30).contains(coverCornerRadius) else { return "封面圆角须在 0–30 之间。" }
        guard AppThemeColor.isValid(shelfTagCustomColor) else { return "标签颜色无效。" }
        for value in (pageBackgrounds ?? [:]).values where !value.colors.allSatisfy(AppThemeColor.isValid) {
            return "页面背景包含无效颜色。"
        }
        if let tabIcons {
            guard !tabIcons.isEmpty, tabIcons.count <= Self.tabIconKeys.count,
                  tabIcons.keys.allSatisfy(Self.tabIconKeys.contains) else {
                return "标签页图标设置无效，请重新配置。"
            }
            guard tabIcons.values.allSatisfy({
                ThemeAssetStore.isValidID($0) || ThemeAssetStore.isValidSymbolName($0)
            }) else { return "标签页图标无效，请重新选择图标或图片。" }
        }
        guard assetIDs.allSatisfy(ThemeAssetStore.isValidID) else { return "主题图片标识无效，请重新导入图片。" }
        return nil
    }
}
