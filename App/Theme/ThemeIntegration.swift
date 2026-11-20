import SwiftUI
import UIKit
import CoreText
import UniformTypeIdentifiers

// MARK: - 与本应用对接的部分
//
// 外观主题（AppTheme / AppThemeStore / 主题编辑器）整体搬运自 joyfange/bookon。
// 下面这些类型是 bookon 里由其它界面提供、而本应用没有的依赖，
// 以及把所选主题应用到本应用原有界面（ReadingTheme 色板、底栏、书架、封面）的桥接。

/// 底栏的四个标签。rawValue 只作标识；tabIcons 用 key 保存每个标签的自定义图标。
enum LibraryTab: Int, CaseIterable {
    /// search：iOS 26 底栏右侧独立的搜索圆钮（不在 displayOrder 里，外观主题「Tab 栏」单独设置）。
    case shelf = 0, discover = 1, statistics = 2, profile = 3, search = 4

    static let displayOrder: [LibraryTab] = [.shelf, .discover, .statistics, .profile]

    var title: String {
        switch self {
        case .shelf: return "书架"
        case .discover: return "发现"
        case .statistics: return "统计"
        case .profile: return "我的"
        case .search: return "搜索"
        }
    }

    var symbol: String {
        switch self {
        case .shelf: return "book.fill"
        case .discover: return "safari"
        case .statistics: return "chart.bar"
        case .profile: return "person.crop.circle"
        case .search: return "magnifyingglass"
        }
    }

    var key: String {
        switch self {
        case .shelf: return "shelf"
        case .discover: return "discover"
        case .statistics: return "statistics"
        case .profile: return "profile"
        case .search: return "search"
        }
    }
}

/// 标签图标：按状态（未选中 / 选中 / 深色…）的自定义图片、旧版自定义图标，或默认图标。
struct ThemeTabIconImage: View {
    let tab: LibraryTab
    let theme: AppTheme
    var size: CGFloat = 22
    var state: ThemeTabIconState = .normal

    /// 当前状态应使用的图片标识或 SF Symbol 名。
    static func customValue(tab: LibraryTab, theme: AppTheme, state: ThemeTabIconState) -> String? {
        if let id = theme.customization?.tabIcon(tab.key, state: state), ThemeAssetStore.isValidID(id) { return id }
        return theme.customization?.tabIcons?[tab.key]
    }

    /// 系统底栏只认 Image / Text，这里直接给出 Image。
    static func image(tab: LibraryTab, theme: AppTheme, size: CGFloat, state: ThemeTabIconState = .normal) -> Image {
        let value = customValue(tab: tab, theme: theme, state: state)
        if let value, ThemeAssetStore.isValidID(value), let image = ThemeTabIconCache.image(for: value, size: size) {
            return Image(uiImage: image)
        }
        let symbol = value.flatMap { !ThemeAssetStore.isValidID($0) && ThemeAssetStore.shared.symbolImage(for: $0) != nil ? $0 : nil }
            ?? tab.symbol
        // 「图标大小」不是默认的 28 pt 时，按大小绘制系统图标（仍随选中颜色着色）。
        if let custom = theme.customization, abs(custom.tabIconSize - 28) > 0.5,
           let symbolImage = UIImage(systemName: symbol,
                                     withConfiguration: UIImage.SymbolConfiguration(pointSize: size * 0.68, weight: .regular)) {
            return Image(uiImage: symbolImage.withRenderingMode(.alwaysTemplate))
        }
        return Image(systemName: symbol)
    }

    var body: some View {
        let value = Self.customValue(tab: tab, theme: theme, state: state)
        if let value, ThemeAssetStore.isValidID(value), let image = ThemeTabIconCache.image(for: value, size: size) {
            Image(uiImage: image).resizable().scaledToFit().frame(width: size, height: size)
        } else if let value, !ThemeAssetStore.isValidID(value), ThemeAssetStore.shared.symbolImage(for: value) != nil {
            Image(systemName: value)
        } else {
            Image(systemName: tab.symbol)
        }
    }
}

/// 系统底栏需要固定尺寸的图片；按尺寸缓存缩放后的自定义图标。
enum ThemeTabIconCache {
    nonisolated(unsafe) private static var cache: [String: UIImage] = [:]
    private static let lock = NSLock()

    static func image(for id: String, size: CGFloat) -> UIImage? {
        let key = "\(id)@\(Int(size))"
        lock.lock()
        if let cached = cache[key] { lock.unlock(); return cached }
        lock.unlock()
        guard let source = ThemeAssetStore.shared.image(for: id) else { return nil }
        let scale = min(size / max(source.size.width, 1), size / max(source.size.height, 1))
        let target = CGSize(width: max(1, source.size.width * scale), height: max(1, source.size.height * scale))
        let renderer = UIGraphicsImageRenderer(size: target)
        let image = renderer.image { _ in source.draw(in: CGRect(origin: .zero, size: target)) }
            .withRenderingMode(.alwaysOriginal)
        lock.lock(); cache[key] = image; lock.unlock()
        return image
    }
}

/// bookon 的书架玻璃：内容卡片走主题「界面效果 / 卡片背景」设置。
struct ShelfGlass<S: InsettableShape>: ViewModifier {
    let shape: S
    var isCard: Bool = false
    func body(content: Content) -> some View {
        content.background { ThemeSurface(shape: shape, isCard: isCard) }
    }
}

// MARK: - 界面字体

struct ReadingFontChoice: Identifiable, Hashable {
    let id: String
    let name: String
}

struct ReadingImportedFontFamily: Identifiable, Hashable {
    let id: String
    let faces: [ReadingFontChoice]
}

/// 主题「颜色与字体」里可选的界面字体：系统内置中文字体 + 阅读设置里导入的字体文件。
/// 只给应用界面使用，不改阅读器字体与分页。
/// 在主线程构造与修改；不做类型隔离，供主题编辑器的静态辅助函数同步读取（与 bookon 一致）。
final class ReadingFontManager: ObservableObject {
    nonisolated(unsafe) static let shared = ReadingFontManager()

    @Published private(set) var builtInFonts: [ReadingFontChoice] = []
    @Published private(set) var importedFonts: [ReadingImportedFontFamily] = []
    /// 应用界面的全局字体：本应用没有单独的界面字体设置，跟随系统。
    let selectedPostScriptName = ""
    var selectedDisplayName: String { "系统默认" }

    /// 字体管理里删除过的预设字体（系统字体删不掉，只是不再出现在列表里）。
    @Published private(set) var hasHiddenBuiltIns = false
    private static let hiddenKey = "fonts.hiddenBuiltIn"
    private static var hiddenBuiltInIDs: [String] {
        UserDefaults.standard.stringArray(forKey: hiddenKey) ?? []
    }

    private init() { reload() }

    /// 从列表里删除一个预设字体。
    func hideBuiltIn(_ id: String) {
        var ids = Self.hiddenBuiltInIDs
        guard !ids.contains(id) else { return }
        ids.append(id)
        UserDefaults.standard.set(ids, forKey: Self.hiddenKey)
        reload()
    }

    /// 恢复所有删除过的预设字体。
    func restoreBuiltIns() {
        UserDefaults.standard.removeObject(forKey: Self.hiddenKey)
        reload()
    }

    func reload() {
        let candidates: [(String, String)] = [
            ("PingFangSC-Regular", "苹方"),
            ("PingFangSC-Light", "苹方 细体"),
            ("STSongti-SC-Regular", "宋体"),
            ("STHeitiSC-Light", "黑体"),
            ("Georgia", "Georgia"),
            ("Avenir-Book", "Avenir")
        ]
        let available = candidates.filter { UIFont(name: $0.0, size: 17) != nil }
        let hidden = Set(Self.hiddenBuiltInIDs)
        hasHiddenBuiltIns = available.contains { hidden.contains($0.0) }
        builtInFonts = available.filter { !hidden.contains($0.0) }
            .map { ReadingFontChoice(id: $0.0, name: $0.1) }
        var families: [ReadingImportedFontFamily] = []
        let directory = ReaderFontStore.directory
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where ["ttf", "otf", "ttc"].contains(file.pathExtension.lowercased()) {
            guard let provider = CGDataProvider(url: file as CFURL), let font = CGFont(provider),
                  let name = font.postScriptName as String? else { continue }
            CTFontManagerRegisterGraphicsFont(font, nil)
            guard UIFont(name: name, size: 17) != nil else { continue }
            let display = (font.fullName as String?) ?? file.deletingPathExtension().lastPathComponent
            families.append(.init(id: file.lastPathComponent, faces: [.init(id: name, name: display)]))
        }
        importedFonts = families
    }
}

// MARK: - 把所选主题应用到原有界面

/// 当前主题的运行时快照。ReadingTheme 的动态颜色在解析时读取这里，
/// 所以原有界面不需要逐个改写就能跟随主题；切换主题后根视图整体刷新一次。
enum AppThemeRuntime {
    struct Tokens {
        var background: String
        var canvas: String
        var surface: String
        var groupedCanvas: String
        var accent: String
        var onAccent: String
        var primary: String
        var secondary: String
        var separator: String
        var selection: String
        var tertiary: String
    }

    nonisolated(unsafe) private static var theme: AppTheme = .monochrome
    nonisolated(unsafe) private static var cached: [Bool: Tokens] = [:]
    private static let lock = NSLock()

    nonisolated(unsafe) private static var resolvedFontName: String?

    static func update(_ value: AppTheme) {
        lock.lock(); defer { lock.unlock() }
        theme = value
        cached = [:]
        resolvedFontName = nil
    }

    /// 导入新字体后让界面字体重新解析。
    static func invalidateFont() {
        lock.lock(); resolvedFontName = nil; lock.unlock()
    }

    /// 主题选择的界面字体 PostScript 名；空字符串表示系统字体。
    static var fontName: String {
        lock.lock()
        if let value = resolvedFontName { lock.unlock(); return value }
        let requested = theme.customization?.fontPostScriptName ?? ""
        lock.unlock()
        // 先让字体管理器注册导入的字体文件，再判断字体是否可用。
        _ = ReadingFontManager.shared
        let value = !requested.isEmpty && UIFont(name: requested, size: 17) != nil ? requested : ""
        lock.lock(); resolvedFontName = value; lock.unlock()
        return value
    }

    static var current: AppTheme {
        lock.lock(); defer { lock.unlock() }
        return theme
    }

    static func tokens(dark: Bool) -> Tokens {
        lock.lock(); defer { lock.unlock() }
        if let value = cached[dark] { return value }
        let colors = theme.swatches(for: dark ? .dark : .light)
        let ink = colors.resolvedInk(style: theme.backgroundStyle)
        let canvas = theme.backgroundStyle == .gradient
            ? AppThemeColor.mix(colors.background, colors.backgroundEnd, fraction: 0.5)
            : colors.background
        let onAccent = AppThemeColor.contrast("000000", colors.accent) >= AppThemeColor.contrast("FFFFFF", colors.accent)
            ? "000000" : "FFFFFF"
        let value = Tokens(
            background: colors.background,
            canvas: canvas,
            surface: colors.surface,
            groupedCanvas: AppThemeColor.mix(canvas, ink.primary, fraction: dark ? 0.07 : 0.045),
            accent: colors.accent,
            onAccent: onAccent,
            primary: ink.primary,
            secondary: ink.secondary,
            separator: colors.border ?? AppThemeColor.mix(colors.surface, ink.primary, fraction: 0.12),
            selection: ink.selection,
            tertiary: colors.resolvedTertiary(style: theme.backgroundStyle)
        )
        cached[dark] = value
        return value
    }

    static func color(_ pick: @escaping @Sendable (Tokens) -> String) -> Color {
        Color(uiColor: uiColor(pick))
    }

    static func uiColor(_ pick: @escaping @Sendable (Tokens) -> String) -> UIColor {
        UIColor { traits in
            let (r, g, b) = AppThemeColor.components(pick(tokens(dark: traits.userInterfaceStyle == .dark)))
            return UIColor(red: r, green: g, blue: b, alpha: 1)
        }
    }

    /// 「默认封面 → 封面圆角」：主题自定义过时按设置，按封面宽度等比（以 60pt 宽为基准）；否则沿用原圆角。
    static func coverCornerRadius(width: CGFloat, legacy: CGFloat) -> CGFloat {
        guard let custom = current.customization else { return legacy }
        let value = CGFloat(min(max(custom.coverCornerRadius, 0), 30))
        return min(value * min(max(width / 60, 0.5), 1.6), width / 2)
    }

    /// 是否需要在页面底层绘制主题画布（渐变或背景图片）。
    static var drawsCanvas: Bool {
        let value = current
        return value.backgroundStyle == .gradient || value.customization?.hasPageBackground == true
    }
}

/// 页面底色：纯色主题直接用底色；渐变或背景图片的主题画出完整画布。
struct ReadingCanvasBackground: View {
    @Environment(\.appTheme) private var theme
    @Environment(\.themePageScope) private var scope
    var grouped = false
    var body: some View {
        ZStack {
            if theme.backgroundStyle == .gradient || theme.customization?.hasPageBackground(scope: scope) == true
                || theme.customization?.pageBackground(scope) != nil {
                AppThemeCanvas()
            } else if grouped {
                ReadingTheme.groupedCanvas
            } else {
                ReadingTheme.canvas
            }
            ThemeAmbientGlow()
        }
    }
}

/// 玻璃效果的「背后有东西」：自定义主题选了玻璃时，在页面底层铺两团很淡的主题色光斑，
/// 毛玻璃卡片滑过时才看得出模糊和通透感（纯色底上的毛玻璃只是一块灰）。
/// 只用径向渐变，不用 blur，滚动时没有额外开销。
struct ThemeAmbientGlow: View {
    @ThemePalette private var palette
    @Environment(\.appTheme) private var theme
    @Environment(\.themePageScope) private var scope
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage(AppGlassMode.storageKey) private var glassEnabled = true

    var body: some View {
        if palette.interfaceEffect == .frosted, glassEnabled, !reduceTransparency,
           theme.customization?.hasPageBackground(scope: scope) != true, palette.glowIntensity > 0 {
            GeometryReader { geometry in
                let size = max(geometry.size.width, geometry.size.height)
                let strength = (scheme == .dark ? 0.30 : 0.22) * palette.glowIntensity
                ZStack {
                    RadialGradient(colors: [palette.accent.opacity(strength), palette.accent.opacity(0)],
                                   center: UnitPoint(x: 0.05, y: 0.08), startRadius: 0, endRadius: size * 0.55)
                    RadialGradient(colors: [palette.highlight.opacity(strength * 1.6), palette.highlight.opacity(0)],
                                   center: UnitPoint(x: 0.95, y: 0.62), startRadius: 0, endRadius: size * 0.5)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

enum ReadingGlassRowMetrics {
    /// 「系统」玻璃下相邻两张行卡片之间的间距。
    static let gap: CGFloat = 8
    /// 行卡片圆角（与「我的」入口卡片相近）。
    static let radius: CGFloat = 16
    /// 玻璃卡片与单元格左右边界之间的余量：玻璃的亮边和柔光不会被单元格裁掉。
    static let edgeInset: CGFloat = 6
}

/// 列表行底 + 分隔线：「系统」玻璃时行是独立卡片，不画分隔线；其它效果保持系统分隔线。
struct ReadingRowBackgroundModifier: ViewModifier {
    @ThemePalette private var palette
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage(AppGlassMode.storageKey) private var glassEnabled = true

    private var separatedCards: Bool {
        glassEnabled && !reduceTransparency && !palette.customCard && palette.cardBackground
            && (palette.interfaceEffect ?? .opaque) == .opaque
    }

    func body(content: Content) -> some View {
        content
            .listRowBackground(ThemeListRowBackground())
            .listRowSeparator(separatedCards ? .hidden : .automatic)
    }
}

/// 列表（List / Form）每一行的底：跟随主题的「界面效果」「卡片背景」和全局「玻璃模式」。
/// 透明：直接透出页面背景；玻璃：毛玻璃 + 主题卡片色；不透明或关闭玻璃模式：主题卡片实色。
struct ThemeListRowBackground: View {
    @ThemePalette private var palette
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage(AppGlassMode.storageKey) private var glassEnabled = true

    var body: some View {
        Group {
            if palette.customCard {
                palette.surface.opacity(reduceTransparency ? 1 : palette.cardOpacity)
            } else if !palette.cardBackground {
                Color.clear
            } else if reduceTransparency {
                palette.surface
            } else {
                // 未自定义的主题（系统原样）列表保持实色，和 iOS 原生设置页一致。
                switch palette.interfaceEffect ?? .opaque {
                case .transparent:
                    // 透明模式：纯白（深色为深灰）按不透明度铺底，没有模糊。
                    ThemeEffectFill.transparentColor(dark: scheme == .dark).opacity(palette.surfaceOpacity)
                case .frosted:
                    if glassEnabled {
                        // 毛玻璃：背后内容的磨砂模糊，整体按不透明度淡入；无高光、无亮边。
                        ThemeFrostedFill(shape: Rectangle(), opacity: palette.frostedSurfaceOpacity)
                    } else {
                        palette.surface
                    }
                case .opaque:
                    // 「系统」（透明模式、毛玻璃都没开）：每一行是一张独立的圆角玻璃卡片（与「我的」入口卡片同款），
                    // 行与行之间留出间距、不再连成一整块；分隔线由 `readingRowBackground` 一并隐藏。
                    // 玻璃总开关关闭时仍是实色。
                    if glassEnabled {
                        // 与外观主题里的玻璃卡片同一种系统玻璃（iOS 26 Liquid Glass，更早系统为磨砂材质）。
                        // 之前两侧出现马赛克：卡片左右边缘正好贴着单元格边界，玻璃的亮边与外圈柔光画到单元格外面，
                        // 被单元格矩形裁成硬边。现在四周都留出余量（左右 edgeInset、上下各半个行间距），
                        // 玻璃完整画在单元格以内，边缘干净。
                        ThemeSurface(shape: RoundedRectangle(cornerRadius: palette.cornerRadius(default: ReadingGlassRowMetrics.radius),
                                                             style: .continuous), isCard: true)
                            .padding(.horizontal, ReadingGlassRowMetrics.edgeInset)
                            .padding(.vertical, ReadingGlassRowMetrics.gap / 2)
                    } else {
                        palette.surface
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension View {
    /// 页面级背景，跟随主题的纯色 / 渐变 / 背景图片。
    func readingCanvas() -> some View {
        background { ReadingCanvasBackground().ignoresSafeArea() }
    }

    /// 列表页背景：隐藏系统底色，画出主题页面背景（纯色 / 渐变 / 图片）。
    func readingThemedListBackground() -> some View {
        readingScrollContentBackgroundHidden()
            .background { ReadingCanvasBackground(grouped: true).ignoresSafeArea() }
    }

    /// 自绘的底部弹窗（没有导航栏、标题行在列表外面）整体铺主题底色：
    /// 否则标题区是系统白/黑，列表区是主题色，上下两截颜色对不上。
    func readingSheetCanvas() -> some View {
        background { ReadingCanvasBackground(grouped: true).ignoresSafeArea() }
    }

    /// 让这一组列表行使用主题卡片底（界面效果、卡片背景、玻璃模式都会生效）。
    /// 「系统」玻璃下每行是独立的圆角玻璃卡片，行间分隔线随之隐藏。
    func readingRowBackground() -> some View {
        modifier(ReadingRowBackgroundModifier())
    }

    /// 页面顶部常驻的搜索框，代替系统搜索栏（系统搜索栏在部分系统上会在左上角留下一个搜索图标）。
    func readingInlineSearch(text: Binding<String>, prompt: String, onSubmit: (() -> Void)? = nil) -> some View {
        modifier(ReadingInlineSearchModifier(text: text, prompt: prompt, submit: onSubmit))
    }
}

private struct ReadingInlineSearchModifier: ViewModifier {
    @Binding var text: String
    let prompt: String
    let submit: (() -> Void)?
    @FocusState private var focused: Bool
    /// 页面背景（整屏，含导航栏和底部）在全局坐标里的位置：搜索区按它绘制同一张背景再裁出来。
    @State private var canvasFrame: CGRect = .zero

    func body(content: Content) -> some View {
        content
            // 整页只有一张页面背景：和列表自己的背景位置、尺寸完全相同（都铺满整屏），
            // 列表为空 / 页面没有自带背景时（如阅读记录为空）也保证搜索区上下是同一张背景。
            .background {
                ReadingCanvasBackground(grouped: true)
                    .overlay {
                        GeometryReader { proxy in
                            Color.clear.preference(key: ReadingInlineSearchCanvasFrameKey.self,
                                                   value: proxy.frame(in: .named(ReadingInlineSearchCanvasFrameKey.space)))
                        }
                    }
                    .ignoresSafeArea()
            }
            .onPreferenceChange(ReadingInlineSearchCanvasFrameKey.self) { value in
                Task { @MainActor in
                    if canvasFrame != value { canvasFrame = value }
                }
            }
            // iOS 26 不在列表上沿叠系统的滚动边缘模糊（否则搜索区下面多出一条朦胧色带）。
            .readingTopScrollEdgeHidden()
            .safeAreaInset(edge: .top, spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(ReadingTheme.secondaryInk)
                        .accessibilityHidden(true)
                    TextField(prompt, text: $text)
                        .focused($focused)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .submitLabel(.search)
                        .onSubmit {
                            focused = false
                            submit?()
                        }
                        .accessibilityIdentifier("inlineSearch.field")
                    if !text.isEmpty {
                        Button { text = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(ReadingTheme.secondaryInk)
                                .frame(width: 28, height: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("清除搜索")
                    }
                }
                .padding(.leading, 12)
                .padding(.trailing, text.isEmpty ? 12 : 4)
                .frame(minHeight: 40)
                .background { ThemeSurface(shape: Capsule(), isCard: true) }
                if focused {
                    Button("取消") {
                        text = ""
                        focused = false
                    }
                    .transition(.opacity)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 8)
            // 搜索区不再单独画一块背景（单独按这一条的尺寸绘制时，渐变被压扁、背景图裁到别的位置，
            // 看起来像另一块屏幕）：按整屏尺寸画同一张页面背景，只露出导航栏到搜索框下沿这一段，
            // 和下面列表的背景逐像素对齐；列表内容滑上来在搜索区下沿直接裁掉（与书架 / 发现 / 统计 / 我的一致）。
            .background {
                GeometryReader { proxy in
                    let band = proxy.frame(in: .named(ReadingInlineSearchCanvasFrameKey.space))
                    if canvasFrame.width > 0, canvasFrame.height > 0 {
                        ReadingCanvasBackground(grouped: true)
                            .frame(width: canvasFrame.width, height: canvasFrame.height)
                            .offset(x: canvasFrame.minX - band.minX, y: canvasFrame.minY - band.minY)
                    } else {
                        ReadingCanvasBackground(grouped: true)
                    }
                }
                .clipped()
                .ignoresSafeArea(edges: [.horizontal, .top])
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .animation(.easeOut(duration: 0.15), value: focused)
        }
        // 两块背景都在同一个坐标系里量位置：推入 / 返回动画时两者一起移动，不会错位。
        .coordinateSpace(name: ReadingInlineSearchCanvasFrameKey.space)
    }
}

private struct ReadingInlineSearchCanvasFrameKey: PreferenceKey {
    static let space = "reading.inlineSearch.page"
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

/// 打开外观主题页。外观主题页由根视图之上的容器弹出，主题切换后根视图刷新时不会被关掉。
@MainActor
final class AppearanceHubPresenter: ObservableObject {
    static let shared = AppearanceHubPresenter()
    @Published var isPresented = false
}

/// 应用外壳：注入主题环境、启动图，并在主题变化后刷新原有界面。
struct AppThemeShell<Content: View>: View {
    @ObservedObject private var store = AppThemeStore.shared
    @ObservedObject private var presenter = AppearanceHubPresenter.shared
    @AppStorage("themeMode") private var themeMode = "0"
    /// 每次主题刷新都重新构造根视图：根视图的初始值（如当前所在的标签）在构造时读取，
    /// 只构造一次的话，刷新后会回到最初的标签（例如在「我的」里换界面字体后跳回书架）。
    let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        ZStack {
            content()
                .id(store.revision)
        }
        // 启动图要读到所选主题，放在 AppThemeRoot 之内。
        .modifier(ThemeLaunchHost())
        .modifier(AppTypographyRoot())
        .modifier(AppThemeRoot(store: store))
        .preferredColorScheme(themeMode == "2" ? .dark : (themeMode == "1" || themeMode == "3" ? .light : nil))
        // 外观主题整页覆盖（参考应用是一个完整页面），页面本身显示主题背景与玻璃效果，改动即时可见。
        .fullScreenCover(isPresented: $presenter.isPresented) {
            AppearanceSettingsRoot { presenter.isPresented = false }
                .modifier(AppTypographyRoot())
                .modifier(AppThemeRoot(store: store))
        }
    }
}

// MARK: - 字体管理（「我的」→ 字体管理）

/// 换界面字体会整体刷新应用：刷新后回到「我的」并重新打开字体管理（停在原来的分段）。
@MainActor
enum FontManagementRestore {
    static var pendingPart: FontManagementView.Part?
}

/// 字体管理：导入的字体文件（.ttf / .otf / .ttc）放在同一个字体库里，分两部分使用——
/// 「书籍字体」决定阅读正文的字体（与阅读设置里的字体是同一个设置），
/// 「界面字体」决定应用界面的字体（与外观主题「颜色与字体」里的字体是同一个设置）。
/// 顶部一个分段切换，下面是当前字体预览和可选字体列表；右上角「+」导入，长按导入的字体可删除。
struct FontManagementView: View {
    enum Part: String, CaseIterable, Identifiable {
        case book, interface
        var id: String { rawValue }
        var title: String { self == .book ? "书籍字体" : "界面字体" }
        var icon: String { self == .book ? "book" : "rectangle.3.group" }
    }

    private struct Option: Identifiable {
        /// 书籍字体：字体文件名（系统默认为空）；界面字体：PostScript 名（系统默认为空）。
        let id: String
        let name: String
        /// 预览用的 PostScript 名，空为系统字体。
        let postScriptName: String
        let fileName: String?
    }

    @ObservedObject private var fonts = ReadingFontManager.shared
    @Environment(\.appTheme) private var theme
    @ThemePalette private var palette
    @AppStorage("textFont") private var readerFontPath = ""
    @State private var part: Part = .book
    @State private var importing = false
    @State private var message: String?
    @State private var pendingDelete: String?
    @State private var pendingPreset: Option?
    @Namespace private var segmentAnimation

    private static let sample = "永和九年，岁在癸丑 Aa 123"

    init(initialPart: Part = .book) {
        _part = State(initialValue: initialPart)
    }

    private var importedOptions: [Option] {
        fonts.importedFonts.compactMap { family in
            guard let face = family.faces.first else { return nil }
            return Option(id: family.id, name: face.name, postScriptName: face.id, fileName: family.id)
        }
    }

    private var options: [Option] {
        let system = Option(id: "", name: "系统默认", postScriptName: "", fileName: nil)
        switch part {
        case .book:
            return [system] + importedOptions
        case .interface:
            let builtIn = fonts.builtInFonts.map { Option(id: $0.id, name: $0.name, postScriptName: $0.id, fileName: nil) }
            let imported = importedOptions.map { Option(id: $0.postScriptName, name: $0.name, postScriptName: $0.postScriptName, fileName: $0.fileName) }
            return [system] + builtIn + imported
        }
    }

    private var readerFileName: String {
        readerFontPath.isEmpty ? "" : URL(fileURLWithPath: readerFontPath).lastPathComponent
    }

    private var interfaceFontName: String {
        let name = theme.customization?.fontPostScriptName ?? ""
        guard !name.isEmpty else { return "" }
        let known = fonts.builtInFonts.contains { $0.id == name }
            || importedOptions.contains { $0.postScriptName == name }
        return known ? name : ""
    }

    private var selectedID: String {
        switch part {
        case .book:
            let file = readerFileName
            return importedOptions.contains(where: { $0.id == file }) ? file : ""
        case .interface:
            return interfaceFontName
        }
    }

    private var selectedOption: Option? { options.first { $0.id == selectedID } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                segmentedControl
                previewCard
                if let message {
                    Text(message)
                        .font(AppFontStyle.footnote.themed)
                        .foregroundStyle(palette.secondary)
                        .padding(.horizontal, 4)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(part == .book ? "阅读正文使用的字体" : "应用界面使用的字体")
                        .font(AppFontStyle.footnote.themed)
                        .foregroundStyle(palette.secondary)
                        .padding(.leading, 4)
                    ForEach(options) { option in
                        row(option)
                    }
                    deleteHint
                }
                if importedOptions.isEmpty {
                    emptyCard
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 40)
        }
        .readingCanvas()
        .navigationTitle("字体管理")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { importing = true } label: {
                    Image(systemName: "plus").font(.system(size: 17, weight: .semibold))
                }
                .accessibilityLabel("导入字体")
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: Self.fontTypes, allowsMultipleSelection: true) { result in
            importFonts(result)
        }
        .confirmationDialog("删除这个字体？", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        ), titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                if let file = pendingDelete { delete(file) }
                pendingDelete = nil
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("书籍和界面里正在使用这个字体时会恢复为系统默认。")
        }
        .confirmationDialog("删除这个预设字体？", isPresented: Binding(
            get: { pendingPreset != nil },
            set: { if !$0 { pendingPreset = nil } }
        ), titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                if let option = pendingPreset { deletePreset(option) }
                pendingPreset = nil
            }
            Button("取消", role: .cancel) { pendingPreset = nil }
        } message: {
            Text("预设字体是系统自带的，删除后只是不再出现在列表里，可随时在这里恢复。正在使用时会恢复为系统默认。")
        }
        .onAppear { fonts.reload() }
        .readingTabBarHidden()
    }

    // MARK: 组件

    /// 玻璃分段切换：选中项是一块跟随「界面效果」的玻璃胶囊。
    private var segmentedControl: some View {
        HStack(spacing: 4) {
            ForEach(Part.allCases) { item in
                Button {
                    withAnimation(.easeOut(duration: 0.22)) { part = item }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: item.icon).font(.system(size: 13, weight: .medium))
                        Text(item.title)
                            .font(AppFontStyle.system(size: 15, weight: part == item ? .semibold : .regular).themed)
                    }
                    .foregroundStyle(part == item ? palette.primary : palette.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 36)
                    .background {
                        if part == item {
                            ThemeSurface(shape: Capsule())
                                .matchedGeometryEffect(id: "font.part", in: segmentAnimation)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(part == item ? .isSelected : [])
            }
        }
        .padding(4)
        .background { ThemeSurface(shape: Capsule()) }
    }

    /// 当前字体预览：大字号示例 + 字体名。
    private var previewCard: some View {
        let option = selectedOption
        let name = option?.postScriptName ?? ""
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(part == .book ? "当前书籍字体" : "当前界面字体")
                    .font(AppFontStyle.caption.themed)
                    .foregroundStyle(palette.secondary)
                Spacer(minLength: 0)
                Text(option?.name ?? "系统默认")
                    .font(AppFontStyle.caption.weight(.medium).themed)
                    .foregroundStyle(palette.accent)
                    .lineLimit(1)
            }
            Text(Self.sample)
                .font(Self.previewFont(name, size: 24))
                .foregroundStyle(palette.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(part == .book ? "天朗气清，惠风和畅。仰观宇宙之大，俯察品类之盛。" : "书架 · 发现 · 统计 · 我的")
                .font(Self.previewFont(name, size: 15))
                .foregroundStyle(palette.secondary)
                .lineLimit(2)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { ThemeCardSurface(radius: 18) }
    }

    private func row(_ option: Option) -> some View {
        let selected = option.id == selectedID
        return Button { select(option) } label: {
            AppearanceCard {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(option.name)
                            .font(Self.previewFont(option.postScriptName, size: 17))
                            .foregroundStyle(palette.primary)
                            .lineLimit(1)
                        Text(subtitle(option))
                            .font(AppFontStyle.caption.themed)
                            .foregroundStyle(palette.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 20))
                        .foregroundStyle(selected ? palette.accent : palette.secondary.opacity(0.4))
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let file = option.fileName {
                Button(role: .destructive) { pendingDelete = file } label: {
                    Label("删除字体", systemImage: "trash")
                }
            } else if part == .interface, !option.id.isEmpty {
                Button(role: .destructive) { pendingPreset = option } label: {
                    Label("删除预设字体", systemImage: "trash")
                }
            }
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// 只含西文字形的系统字体：中文仍显示为系统字体，只有英文和数字会变。
    private static let latinOnlyFonts: Set<String> = ["Georgia", "Avenir-Book"]

    private func subtitle(_ option: Option) -> String {
        if let file = option.fileName { return "已导入 · \(file)" }
        if option.id.isEmpty { return "跟随系统" }
        return Self.latinOnlyFonts.contains(option.id) ? "系统内置 · 仅英文和数字生效" : "系统内置"
    }

    /// 列表下方：怎么删除字体，以及恢复删除过的预设字体。
    @ViewBuilder
    private var deleteHint: some View {
        let canDelete = part == .interface || !importedOptions.isEmpty
        if canDelete || (part == .interface && fonts.hasHiddenBuiltIns) {
            HStack(spacing: 8) {
                if canDelete {
                    Text(part == .interface ? "长按预设或导入的字体可删除" : "长按导入的字体可删除")
                        .font(AppFontStyle.caption.themed)
                        .foregroundStyle(palette.secondary)
                }
                Spacer(minLength: 0)
                if part == .interface, fonts.hasHiddenBuiltIns {
                    Button("恢复预设字体") { fonts.restoreBuiltIns() }
                        .font(AppFontStyle.caption.weight(.medium).themed)
                        .foregroundStyle(palette.accent)
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 4)
            .padding(.top, 2)
        }
    }

    private var emptyCard: some View {
        VStack(spacing: 8) {
            Image(systemName: "textformat")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(palette.accent)
            Text("暂无自定义字体")
                .font(AppFontStyle.subheadline.weight(.semibold).themed)
                .foregroundStyle(palette.primary)
            Text("点击右上角导入 .ttf、.otf、.ttc 格式的字体文件")
                .font(AppFontStyle.caption.themed)
                .foregroundStyle(palette.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .padding(.horizontal, 16)
        .background { ThemeCardSurface(radius: 18) }
        .contentShape(Rectangle())
        .onTapGesture { importing = true }
    }

    // MARK: 操作

    private static var fontTypes: [UTType] {
        var types: [UTType] = [.font]
        for ext in ["ttf", "otf", "ttc"] {
            if let type = UTType(filenameExtension: ext), !types.contains(type) { types.append(type) }
        }
        return types
    }

    private static func previewFont(_ postScriptName: String, size: CGFloat) -> Font {
        guard !postScriptName.isEmpty, UIFont(name: postScriptName, size: size) != nil else {
            return AppFontStyle.system(size: size).themed
        }
        return .custom(postScriptName, size: size)
    }

    private func select(_ option: Option) {
        UISelectionFeedbackGenerator().selectionChanged()
        switch part {
        case .book:
            readerFontPath = option.fileName.map { ReaderFontStore.directory.appendingPathComponent($0).path } ?? ""
        case .interface:
            setInterfaceFont(option.id)
        }
    }

    /// 界面字体写进当前外观主题（与外观主题「颜色与字体」同一个设置），保存后整个应用立即生效。
    private func setInterfaceFont(_ name: String) {
        let current = theme.customization?.fontPostScriptName ?? ""
        guard current != name else { return }
        let model = AppearanceLiveModel.shared
        model.resync()
        model.custom { $0.fontPostScriptName = name }
        let revision = AppThemeStore.shared.revision
        model.commit()
        // 保存后整个应用会刷新一次（界面字体要全局生效），导航会回到根页面：
        // 记下当前所在的部分，「我的」重新出现时直接回到字体管理，看起来一直停在这个页面。
        if AppThemeStore.shared.revision != revision { FontManagementRestore.pendingPart = part }
        AppThemeRuntime.invalidateFont()
        if let error = model.message { message = error }
    }

    private func importFonts(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, !urls.isEmpty else {
            if case .failure(let error) = result { message = error.localizedDescription }
            return
        }
        var installed = 0
        var failed = 0
        for url in urls {
            do {
                _ = try ReaderFontStore.install(from: url)
                installed += 1
            } catch {
                failed += 1
            }
        }
        fonts.reload()
        AppThemeRuntime.invalidateFont()
        if failed == 0 {
            message = "已导入 \(installed) 个字体"
        } else {
            message = installed > 0 ? "已导入 \(installed) 个字体，\(failed) 个文件无法识别" : "无法识别这个字体文件"
        }
    }

    private func deletePreset(_ option: Option) {
        let inUse = (theme.customization?.fontPostScriptName ?? "") == option.id
        fonts.hideBuiltIn(option.id)
        if inUse { setInterfaceFont("") }
        message = "已删除「\(option.name)」"
    }

    private func delete(_ file: String) {
        let faces = fonts.importedFonts.first { $0.id == file }?.faces.map(\.id) ?? []
        if readerFileName == file { readerFontPath = "" }
        if let name = theme.customization?.fontPostScriptName, faces.contains(name) {
            setInterfaceFont("")
        }
        try? FileManager.default.removeItem(at: ReaderFontStore.directory.appendingPathComponent(file))
        fonts.reload()
        AppThemeRuntime.invalidateFont()
        message = "已删除字体"
    }
}
