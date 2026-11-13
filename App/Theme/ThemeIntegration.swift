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

/// 标签图标：自定义图片（资产 ID）、旧版保存的 SF Symbol，或默认图标。
struct ThemeTabIconImage: View {
    let tab: LibraryTab
    let theme: AppTheme
    var size: CGFloat = 22

    /// 系统底栏只认 Image / Text，这里直接给出 Image。
    static func image(tab: LibraryTab, theme: AppTheme, size: CGFloat) -> Image {
        let value = theme.customization?.tabIcons?[tab.key]
        if let value, ThemeAssetStore.isValidID(value), let image = ThemeTabIconCache.image(for: value, size: size) {
            return Image(uiImage: image)
        }
        if let value, !ThemeAssetStore.isValidID(value), ThemeAssetStore.shared.symbolImage(for: value) != nil {
            return Image(systemName: value)
        }
        return Image(systemName: tab.symbol)
    }

    var body: some View {
        let value = theme.customization?.tabIcons?[tab.key]
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
    }

    nonisolated(unsafe) private static var theme: AppTheme = .monochrome
    nonisolated(unsafe) private static var cached: [Bool: Tokens] = [:]
    private static let lock = NSLock()

    static func update(_ value: AppTheme) {
        lock.lock(); defer { lock.unlock() }
        theme = value
        cached = [:]
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
            selection: ink.selection
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

    /// 是否需要在页面底层绘制主题画布（渐变或背景图片）。
    static var drawsCanvas: Bool {
        let value = current
        return value.backgroundStyle == .gradient || value.customization?.pageBackgroundImage != nil
    }
}

/// 页面底色：纯色主题直接用底色；渐变或背景图片的主题画出完整画布。
struct ReadingCanvasBackground: View {
    @Environment(\.appTheme) private var theme
    var body: some View {
        if theme.backgroundStyle == .gradient || theme.customization?.pageBackgroundImage != nil {
            AppThemeCanvas()
        } else {
            ReadingTheme.canvas
        }
    }
}

extension View {
    /// 页面级背景，跟随主题的纯色 / 渐变 / 背景图片。
    func readingCanvas() -> some View {
        background { ReadingCanvasBackground().ignoresSafeArea() }
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
        .sheet(isPresented: $presenter.isPresented) {
            if #available(iOS 17.0, *) {
                NavigationStack {
                    AppAppearanceSettingsView(store: store)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("完成") { presenter.isPresented = false }
                            }
                        }
                }
                .modifier(AppThemeRoot(store: store))
            }
        }
    }
}
