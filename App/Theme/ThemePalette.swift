import SwiftUI

struct ResolvedAppPalette {
    let accent: Color
    let background: Color
    let backgroundEnd: Color
    let surface: Color
    let primary: Color
    let secondary: Color
    let selection: Color
    let border: Color
    let placeholderTop: Color
    let placeholderBottom: Color
    let highlight: Color
    let onAccent: Color
    let gradient: Bool
    let cardRadius: CGFloat
    let cardBorder: Bool
    /// Custom text needs a known backing rather than an unpredictable material.
    let usesOpaqueSurfaces: Bool
    let interfaceEffect: ThemeInterfaceEffect?
    let cardBackground: Bool
    let pageScrimOpacity: Double
    let frostedSurfaceOpacity: Double
    /// Bounded 0...1; only meaningful for themed (non-legacy) surfaces.
    let glowIntensity: Double
    /// Bounded 0...1; drives the frosted effect's tint layer.
    let surfaceOpacity: Double
    /// 「卡片背景」自定义：开启后卡片按颜色 / 透明度 / 边框绘制。
    let customCard: Bool
    let cardOpacity: Double
    let cardBorderOpacity: Double
    let cardBorderWidth: CGFloat
    /// 弱文字（「颜色与字体」）。
    let tertiary: Color
    /// 「卡片背景」里的背景图（当前明暗）与显示方式。
    let cardImageID: String?
    let cardImageMode: ThemeCardImageMode
    private let cardRadiusOverride: CGFloat?

    /// Existing cards keep their own geometry until a radius is explicitly set.
    func cornerRadius(default legacyRadius: CGFloat) -> CGFloat {
        cardRadiusOverride ?? legacyRadius
    }

    /// - Parameter glass: 全局「玻璃模式」。传入 true 时，除主题明确选「透明」外，
    ///   卡片、列表行一律按玻璃绘制（总开关打开就是全局玻璃）；nil 保持主题原值。
    init(theme: AppTheme, scheme: ColorScheme, glass: Bool? = nil) {
        let colors = theme.swatches(for: scheme)
        let radius = colors.cardRadius.flatMap { value -> CGFloat? in
            guard value.isFinite else { return nil }
            return CGFloat(min(max(value, AppTheme.cardRadiusRange.lowerBound), AppTheme.cardRadiusRange.upperBound))
        }
        cardRadiusOverride = radius
        cardRadius = radius ?? CGFloat(AppTheme.defaultCardRadius)
        cardBorder = colors.cardBorder ?? true
        usesOpaqueSurfaces = colors.hasCustomTextOrSelection
        if glass == true {
            // 主题没指定时按玻璃；主题明确选了透明 / 不透明就照主题来（不透明＝实色卡片）。
            interfaceEffect = theme.customization?.effect ?? .frosted
        } else {
            interfaceEffect = theme.customization?.effect
        }
        cardBackground = theme.customization?.cardBackground ?? true
        let ink = colors.resolvedInk(style: theme.backgroundStyle)
        // 背景图原样显示（不再自动压一层底色），透明度由「页面背景 → 不透明度」控制。
        pageScrimOpacity = 0
        let custom = theme.customization
        // 透明模式和毛玻璃各有一份不透明度（界面效果页里两个滑块）。
        let tint = custom?.effectOpacity ?? 0.85
        let clamped = tint.isFinite ? min(max(tint, 0), 1) : 0.85
        // 界面效果里的「不透明度」直接就是卡片底色的不透明度：0% 完全透出背景，100% 实色。
        frostedSurfaceOpacity = clamped
        let glow = custom?.glowIntensity ?? 0.5
        glowIntensity = glow.isFinite ? min(max(glow, 0), 1) : 0.5
        surfaceOpacity = clamped
        customCard = custom?.customCard ?? false
        cardOpacity = min(max(custom?.cardOpacity ?? 0.6, 0), 1)
        cardBorderOpacity = min(max(custom?.cardBorderOpacity ?? 0.3, 0), 1)
        cardBorderWidth = CGFloat(min(max(custom?.cardBorderWidth ?? 0.7, 0), 4))
        cardImageID = custom?.cardImage(dark: scheme == .dark)
        cardImageMode = custom?.cardImageMode ?? .fill
        tertiary = AppThemeColor.color(colors.resolvedTertiary(style: theme.backgroundStyle))
        // Geometry-only edits must not change Classic Monochrome's native colors.
        var colorDefaults = colors
        colorDefaults.cardRadius = nil
        colorDefaults.cardBorder = nil
        if theme.customization == nil, theme.id == AppTheme.defaultID,
           theme.backgroundStyle == AppTheme.monochrome.backgroundStyle,
           colorDefaults == AppTheme.monochrome.swatches(for: scheme) {
            accent = AppPalette.accent
            background = AppPalette.background
            backgroundEnd = AppPalette.background
            surface = AppPalette.surface
            primary = .primary; secondary = .secondary
            selection = AppPalette.selection; border = AppPalette.border
            placeholderTop = AppPalette.placeholderTop; placeholderBottom = AppPalette.placeholderBottom
            highlight = AppPalette.highlight
            onAccent = scheme == .dark ? .black : .white
            gradient = false
            return
        }
        accent = AppThemeColor.color(colors.accent)
        background = AppThemeColor.color(colors.background)
        backgroundEnd = AppThemeColor.color(colors.backgroundEnd)
        surface = AppThemeColor.color(colors.surface)
        // Opaque resolved text and selection exactly match save-time validation.
        primary = AppThemeColor.color(ink.primary)
        secondary = AppThemeColor.color(ink.secondary)
        selection = AppThemeColor.color(ink.selection)
        border = AppThemeColor.color(colors.border ?? AppThemeColor.mix(colors.surface, ink.primary, fraction: 0.20))
        placeholderTop = AppThemeColor.color(AppThemeColor.mix(colors.surface, colors.accent, fraction: 0.25))
        placeholderBottom = AppThemeColor.color(AppThemeColor.mix(colors.surface, colors.accent, fraction: 0.48))
        let highlightHex = AppThemeColor.mix(colors.surface, colors.accent, fraction: 0.18)
        highlight = AppThemeColor.color(AppThemeColor.contrast(ink.primary, highlightHex) >= 4.5 ? highlightHex : colors.surface)
        let buttonInk = AppThemeColor.contrast("000000", colors.accent) >= AppThemeColor.contrast("FFFFFF", colors.accent)
            ? "000000" : "FFFFFF"
        onAccent = AppThemeColor.color(buttonInk)
        gradient = theme.backgroundStyle == .gradient
    }
}

private struct AppThemeEnvironmentKey: EnvironmentKey {
    static let defaultValue = AppTheme.monochrome
}
extension EnvironmentValues {
    var appTheme: AppTheme {
        get { self[AppThemeEnvironmentKey.self] }
        set { self[AppThemeEnvironmentKey.self] = newValue }
    }
}

/// Every consumer observes both values; editing an active theme or changing the
/// system appearance invalidates the view without resetting navigation identity.
@propertyWrapper
struct ThemePalette: DynamicProperty {
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @AppStorage(AppGlassMode.storageKey) private var glassEnabled = true
    var wrappedValue: ResolvedAppPalette { ResolvedPaletteCache.shared.palette(theme: theme, scheme: scheme, glass: glassEnabled) }
}

/// 色板解析含对比度计算（背景图片时还要逐级试算遮罩），每张玻璃卡片、每个按钮都会读一次。
/// 同一主题 / 明暗 / 玻璃开关只算一次，滚动和打开「外观主题」时不再反复计算。
final class ResolvedPaletteCache: @unchecked Sendable {
    static let shared = ResolvedPaletteCache()
    private struct Entry {
        let theme: AppTheme
        let dark: Bool
        let glass: Bool
        let palette: ResolvedAppPalette
    }
    private let lock = NSLock()
    private var entries: [Entry] = []

    func palette(theme: AppTheme, scheme: ColorScheme, glass: Bool) -> ResolvedAppPalette {
        let dark = scheme == .dark
        lock.lock()
        if let hit = entries.first(where: { $0.dark == dark && $0.glass == glass && $0.theme == theme }) {
            lock.unlock()
            return hit.palette
        }
        lock.unlock()
        let value = ResolvedAppPalette(theme: theme, scheme: scheme, glass: glass)
        lock.lock()
        entries.insert(Entry(theme: theme, dark: dark, glass: glass, palette: value), at: 0)
        if entries.count > 24 { entries.removeLast(entries.count - 24) }
        lock.unlock()
        return value
    }
}

struct AppThemeCanvas: View {
    @ThemePalette private var palette
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @Environment(\.themePageScope) private var scope
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @StateObject private var imageLoader = ThemeAssetImageLoader()

    private var page: ThemePageBackground? { theme.customization?.pageBackground(scope) }
    private var imageID: String? { theme.customization?.pageBackgroundImage(dark: scheme == .dark, scope: scope) }

    var body: some View {
        base
            .overlay {
                if let image = currentImage, !reduceTransparency {
                    GeometryReader { geometry in
                        Image(uiImage: image).resizable().scaledToFill()
                            .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                            // 照片原样显示，只按「页面背景 → 不透明度」透出主题底色。
                            .opacity(min(max(theme.customization?.backgroundImageOpacity ?? 1, 0), 1))
                            .overlay {
                                if theme.customization?.effect == .transparent, palette.glowIntensity > 0 {
                                    RadialGradient(
                                        colors: [palette.accent.opacity(0.18 * palette.glowIntensity),
                                                 palette.accent.opacity(0)],
                                        center: .center,
                                        startRadius: 0,
                                        endRadius: max(geometry.size.width, geometry.size.height) * 0.6
                                    )
                                }
                            }
                    }
                }
            }
            .task(id: imageID) {
                await imageLoader.load(imageID)
            }
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }

    /// 先用解码缓存里的图：新开的页面（每个 Tab、每次 push）第一帧就有照片，不再先闪一下主题底色。
    private var currentImage: UIImage? {
        guard let id = imageID else { return nil }
        if let image = imageLoader.image, imageLoader.assetID == id { return image }
        return ThemeAssetStore.shared.cachedImage(for: id)
    }

    @ViewBuilder private var base: some View {
        if let page, page.hasColors {
            // 这个页面单独设置了颜色：没设的一项沿用全局。
            let dark = scheme == .dark
            let swatch = theme.swatches(for: scheme)
            let start = (dark ? page.darkBackground : page.lightBackground) ?? swatch.background
            let end = (dark ? page.darkBackgroundEnd : page.lightBackgroundEnd) ?? swatch.backgroundEnd
            if start != end {
                LinearGradient(colors: [AppThemeColor.color(start), AppThemeColor.color(end)], startPoint: .top, endPoint: .bottom)
            } else {
                AppThemeColor.color(start)
            }
        } else if palette.gradient {
            LinearGradient(colors: [palette.background, palette.backgroundEnd], startPoint: .top, endPoint: .bottom)
        } else { palette.background }
    }
}

/// Native glass shared by app-owned controls; content and hit regions stay untouched.
/// Older iOS uses real backdrop material, not a translucent solid imitation.
struct AppGlassSurface<S: InsettableShape>: View {
    let shape: S
    var tint: Color
    var tintOpacity: Double
    var reduceTransparency: Bool
    @AppStorage(AppGlassMode.storageKey) private var glassEnabled = true
    @Environment(\.scenePhase) private var scenePhase

    init(shape: S, tint: Color = Color(uiColor: .secondarySystemBackground),
         tintOpacity: Double = 0.10, reduceTransparency: Bool = false) {
        self.shape = shape
        self.tint = tint
        self.tintOpacity = tintOpacity
        self.reduceTransparency = reduceTransparency
    }

    var body: some View {
        Group {
            if reduceTransparency || !glassEnabled {
                shape.fill(tint)
            } else if scenePhase == .background {
                // 系统在 App 进后台时截图做多任务卡片，截图拍不到实时模糊，玻璃会变成一块偏暗的灰，
                // 回到 App 时就看到「由暗转亮」。后台时改画接近玻璃观感的半透明底，截图和实际一致。
                shape.fill(tint.opacity(min(0.92, tintOpacity + 0.5)))
                    .overlay { shape.fill(Color.white.opacity(0.18)) }
            } else {
                // 毛玻璃（磨砂模糊 + 淡淡底色），不用 iOS 26 的 Liquid Glass，没有高光和亮边。
                shape.fill(.ultraThinMaterial)
                    .overlay { shape.fill(tint.opacity(tintOpacity)) }
            }
        }
        // 作为按钮背景时整块都能点（之前不参与点击，卡片空白处点了没反应，比如「管理书源」）。
        .contentShape(shape)
        .accessibilityHidden(true)
    }
}

struct AppGlassModifier<S: InsettableShape>: ViewModifier {
    let shape: S
    var tint: Color = Color(uiColor: .secondarySystemBackground)
    var tintOpacity: Double = 0.10
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        content.background {
            AppGlassSurface(shape: shape, tint: tint, tintOpacity: tintOpacity,
                            reduceTransparency: reduceTransparency)
        }
    }
}

struct IndependentGlassListRow: ViewModifier {
    @ThemePalette private var palette
    func body(content: Content) -> some View {
        content
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 14, leading: 18, bottom: 14, trailing: 18))
            .listRowBackground(
                ThemeSurface(shape: RoundedRectangle(cornerRadius: palette.cornerRadius(default: AppLayout.radiusCard)))
                    .padding(.vertical, 4)
            )
    }
}

extension View {
    func independentGlassRow() -> some View { modifier(IndependentGlassListRow()) }
    func appGlass<S: InsettableShape>(in shape: S, tint: Color = Color(uiColor: .secondarySystemBackground),
                                      tintOpacity: Double = 0.10) -> some View {
        modifier(AppGlassModifier(shape: shape, tint: tint, tintOpacity: tintOpacity))
    }
}

/// Shared custom-theme surface for shelf glass, detail cards and library cards.
/// Card backgrounds never control buttons/dock; Reduce Transparency keeps those opaque.
struct ThemeSurface<S: InsettableShape>: View {
    @ThemePalette private var palette
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let shape: S
    var isCard: Bool = false

    var body: some View {
        ThemeSurfaceRendering(shape: shape, isCard: isCard, palette: palette,
                              reduceTransparency: reduceTransparency)
    }
}

/// Explicit inputs let the native renderer be checked without attempting to
/// write SwiftUI's read-only accessibility environment. Production passes the
/// real system value through ThemeSurface above.
struct ThemeSurfaceRendering<S: InsettableShape>: View {
    let shape: S
    let isCard: Bool
    let palette: ResolvedAppPalette
    let reduceTransparency: Bool
    @AppStorage(AppGlassMode.storageKey) private var glassEnabled = true
    @Environment(\.colorScheme) private var scheme

    init(shape: S, isCard: Bool, palette: ResolvedAppPalette, reduceTransparency: Bool) {
        self.shape = shape
        self.isCard = isCard
        self.palette = palette
        self.reduceTransparency = reduceTransparency
    }

    private var effect: ThemeInterfaceEffect { palette.interfaceEffect ?? .frosted }

    var body: some View {
        ZStack {
            Color.clear
            if isCard, palette.customCard {
                // 「卡片背景」：自定义背景图 + 颜色 + 透明度 + 边框，完全按设置绘制。
                if let id = palette.cardImageID, !reduceTransparency, let image = ThemeAssetStore.shared.image(for: id) {
                    ThemeCardImageFill(image: image, mode: palette.cardImageMode)
                        .clipShape(shape)
                }
                if reduceTransparency {
                    shape.fill(palette.surface)
                } else {
                    shape.fill(palette.surface.opacity(palette.cardOpacity))
                }
                if palette.cardBorderOpacity > 0, palette.cardBorderWidth > 0 {
                    shape.strokeBorder(palette.border.opacity(palette.cardBorderOpacity), lineWidth: palette.cardBorderWidth)
                }
            } else if !isCard || palette.cardBackground {
                if reduceTransparency {
                    shape.fill(palette.surface)
                } else {
                    switch effect {
                    case .transparent:
                        // 透明模式：纯白（深色模式为深灰）按「不透明度」铺底，没有模糊；0% 完全没有卡片。
                        shape.fill(ThemeEffectFill.transparentColor(dark: scheme == .dark)
                            .opacity(palette.surfaceOpacity))
                    case .frosted:
                        if glassEnabled {
                            ThemeFrostedFill(shape: shape, opacity: palette.frostedSurfaceOpacity)
                        } else {
                            shape.fill(palette.surface)
                        }
                    case .opaque:
                        shape.fill(palette.surface)
                    }
                }
                if !isCard || palette.cardBorder {
                    // 毛玻璃、透明模式都不画亮边（参考应用卡片没有描边）；只有实色卡片保留细分隔线。
                    if reduceTransparency || effect == .opaque || (effect == .frosted && !glassEnabled) {
                        shape.strokeBorder(palette.border.opacity(0.6), lineWidth: 0.5)
                    }
                }
            }
        }
        // 整块参与点击：放在按钮 / 链接背后时，卡片空白处也能点中。
        .contentShape(shape)
        .accessibilityHidden(true)
    }
}

/// 界面效果的两种卡片底。
enum ThemeEffectFill {
    /// 透明模式的卡片色：亮色纯白，深色接近黑的深灰。
    static func transparentColor(dark: Bool) -> Color {
        dark ? Color(white: 0.11) : Color.white
    }
}

/// 毛玻璃：对卡片背后的内容做强高斯模糊（系统磨砂材质，柔和、偏奶白），整体按「不透明度」淡入：
/// 100% 时是完整的磨砂卡片，10% 时几乎直接透出背景、只带一点朦胧。没有 Liquid Glass 高光、亮边。
struct ThemeFrostedFill<S: Shape>: View {
    let shape: S
    let opacity: Double
    @Environment(\.colorScheme) private var scheme
    @Environment(\.scenePhase) private var scenePhase

    init(shape: S, opacity: Double) {
        self.shape = shape
        self.opacity = opacity
    }

    var body: some View {
        let amount = min(max(opacity.isFinite ? opacity : 0, 0), 1)
        Group {
            if scenePhase == .background {
                // 多任务截图拍不到实时模糊：后台时画接近磨砂观感的半透明底，回到 App 时不会由暗转亮。
                shape.fill(scheme == .dark ? Color(white: 0.16).opacity(0.8) : Color(white: 0.97).opacity(0.78))
            } else {
                shape.fill(.ultraThinMaterial)
                    .overlay { shape.fill(Color.white.opacity(scheme == .dark ? 0.02 : 0.12)) }
            }
        }
        .opacity(amount)
    }
}

/// 卡片背景图：填充 / 适应 / 拉伸 / 平铺。
struct ThemeCardImageFill: View {
    let image: UIImage
    let mode: ThemeCardImageMode

    var body: some View {
        GeometryReader { geometry in
            switch mode {
            case .fill:
                Image(uiImage: image).resizable().scaledToFill()
                    .frame(width: geometry.size.width, height: geometry.size.height).clipped()
            case .fit:
                Image(uiImage: image).resizable().scaledToFit()
                    .frame(width: geometry.size.width, height: geometry.size.height)
            case .stretch:
                Image(uiImage: image).resizable()
                    .frame(width: geometry.size.width, height: geometry.size.height)
            case .tile:
                Image(uiImage: image).resizable(resizingMode: .tile)
                    .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
        .allowsHitTesting(false)
    }
}

/// Cover the photograph enough that every allowed pixel keeps 4.5:1 label contrast.
/// The black/white extremes bound the luminance of all composited image pixels.
private enum ThemeReadability {
    static func scrimOpacity(backgrounds: [String], labels: [String]) -> Double {
        for step in 36...50 {
            let opacity = Double(step) / 50
            let readable = backgrounds.allSatisfy { base in
                let low = AppThemeColor.luminance(AppThemeColor.mix("000000", base, fraction: opacity))
                let high = AppThemeColor.luminance(AppThemeColor.mix("FFFFFF", base, fraction: opacity))
                return labels.allSatisfy { label in
                    let value = AppThemeColor.luminance(label)
                    if value <= low { return (low + 0.05) / (value + 0.05) >= 4.5 }
                    if value >= high { return (value + 0.05) / (high + 0.05) >= 4.5 }
                    return false
                }
            }
            if readable { return opacity }
        }
        return 1
    }
}

struct AppThemeRoot: ViewModifier {
    @ObservedObject var store: AppThemeStore
    init(store: AppThemeStore = .shared) { self.store = store }
    func body(content: Content) -> some View {
        content.modifier(MonochromeAppStyle()).environment(\.appTheme, store.selectedTheme)
    }
}

/// 主题卡片底：圆角跟随「编辑主题」里的卡片圆角（未设置时用各处原来的圆角），
/// 材质跟随卡片效果（玻璃 / 透明 / 不透明）、「显示卡片背景」与卡片边框开关。
struct ThemeCardSurface: View {
    @ThemePalette private var palette
    var radius: CGFloat

    var body: some View {
        ThemeSurface(shape: RoundedRectangle(cornerRadius: palette.cornerRadius(default: radius), style: .continuous),
                     isCard: true)
    }
}
