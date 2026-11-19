import SwiftUI
import UIKit
import CoreText

// MARK: - 与本应用对接的部分
//
// 外观主题（AppTheme / AppThemeStore / 主题编辑器）整体搬运自 joyfange/bookon。
// 下面这些类型是 bookon 里由其它界面提供、而本应用没有的依赖，
// 以及把所选主题应用到本应用原有界面（ReadingTheme 色板、底栏、书架、封面）的桥接。

/// 底栏的四个标签。rawValue 只作标识；tabIcons 用 key 保存每个标签的自定义图标。
enum LibraryTab: Int, CaseIterable {
    case shelf = 0, discover = 1, statistics = 2, profile = 3

    static let displayOrder: [LibraryTab] = [.shelf, .discover, .statistics, .profile]

    var title: String {
        switch self {
        case .shelf: return "书架"
        case .discover: return "发现"
        case .statistics: return "统计"
        case .profile: return "我的"
        }
    }

    var symbol: String {
        switch self {
        case .shelf: return "book.fill"
        case .discover: return "safari"
        case .statistics: return "chart.bar"
        case .profile: return "person.crop.circle"
        }
    }

    var key: String {
        switch self {
        case .shelf: return "shelf"
        case .discover: return "discover"
        case .statistics: return "statistics"
        case .profile: return "profile"
        }
    }
}

/// 主题编辑器里的底栏示意（主界面使用系统底栏，这里只用于预览显示方式与自定义图标）。
struct LibraryDock: View {
    @ThemePalette private var palette
    @Environment(\.appTheme) private var theme
    @Binding var selection: LibraryTab
    private var style: ThemeTabStyle { theme.customization?.tabStyle ?? .iconsAndText }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(LibraryTab.displayOrder, id: \.rawValue) { tab in
                Button { selection = tab } label: {
                    VStack(spacing: 3) {
                        if style != .text {
                            ThemeTabIconImage(tab: tab, theme: theme, size: 20)
                                .frame(width: 24, height: 22)
                        }
                        if style != .icons {
                            Text(tab.title).appFont(.system(size: style == .text ? 14 : 10, weight: .medium))
                        }
                    }
                    .foregroundStyle(selection == tab ? palette.accent : palette.secondary)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(selection == tab ? palette.selection : Color.clear, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(5)
        .background { ThemeSurface(shape: Capsule()) }
        .padding(.horizontal, 16)
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

    private init() { reload() }

    func reload() {
        let candidates: [(String, String)] = [
            ("PingFangSC-Regular", "苹方"),
            ("PingFangSC-Light", "苹方 细体"),
            ("STSongti-SC-Regular", "宋体"),
            ("STHeitiSC-Light", "黑体"),
            ("Georgia", "Georgia"),
            ("Avenir-Book", "Avenir")
        ]
        builtInFonts = candidates.filter { UIFont(name: $0.0, size: 17) != nil }
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
                    // 「系统」（透明模式、毛玻璃都没开）：恢复第二轮之前的默认玻璃行底；玻璃总开关关闭时仍是实色。
                    if glassEnabled {
                        ThemeSystemGlassRowFill(palette: palette)
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
    func readingRowBackground() -> some View {
        listRowBackground(ThemeListRowBackground())
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
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ZStack {
            content
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
