import SwiftUI
import ImageIO

struct ReadingUnavailableView<Label: View, Description: View, Actions: View>: View {
    private let label: Label
    private let description: Description
    private let actions: Actions

    init(
        @ViewBuilder label: () -> Label,
        @ViewBuilder description: () -> Description,
        @ViewBuilder actions: () -> Actions
    ) {
        self.label = label()
        self.description = description()
        self.actions = actions()
    }

    var body: some View {
        if #available(iOS 17.0, *), !ReadingCompatibility.usesLegacyUI {
            ContentUnavailableView {
                label
            } description: {
                description
            } actions: {
                actions
            }
        } else {
            VStack(spacing: 12) {
                label.labelStyle(ReadingUnavailableLabelStyle())
                description
                    .font(AppFontStyle.subheadline.themed)
                    .foregroundStyle(.secondary)
                actions.padding(.top, 4)
            }
            .multilineTextAlignment(.center)
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

extension ReadingUnavailableView where Label == SwiftUI.Label<Text, Image>, Description == Text?, Actions == EmptyView {
    init(_ title: String, systemImage: String, description: Text? = nil) {
        self.init {
            SwiftUI.Label(title, systemImage: systemImage)
        } description: {
            description
        } actions: {
            EmptyView()
        }
    }

    @ViewBuilder
    static func search(text: String) -> some View {
        if #available(iOS 17.0, *), !ReadingCompatibility.usesLegacyUI {
            ContentUnavailableView.search(text: text)
        } else {
            ReadingUnavailableView(
                "无搜索结果",
                systemImage: "magnifyingglass",
                description: Text("没有找到与“\(text)”相关的内容，请尝试其他关键词。")
            )
        }
    }
}

private struct ReadingUnavailableLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(spacing: 12) {
            configuration.icon
                .font(AppFontStyle.system(size: 48).themed)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            configuration.title.font(AppFontStyle.title2.bold().themed)
        }
    }
}

extension View {
    /// Keep filled controls dark in both appearances, independently of icon tint.
    func readingProminentButtonStyle() -> some View {
        buttonStyle(.borderedProminent)
            .tint(ReadingTheme.accentFill)
            .foregroundStyle(ReadingTheme.onAccent)
    }

    func readingSecondaryButtonStyle() -> some View {
        buttonStyle(.bordered)
            .tint(ReadingTheme.accentFill)
            .foregroundStyle(ReadingTheme.accent)
    }

    @ViewBuilder
    func readingChoiceButtonStyle(isSelected: Bool) -> some View {
        if isSelected {
            readingProminentButtonStyle()
                .accessibilityAddTraits(.isSelected)
        } else {
            readingSecondaryButtonStyle()
        }
    }

    func readingSearchable(text: Binding<String>, isPresented: Binding<Bool>, prompt: String, alwaysVisible: Bool = false) -> some View {
        modifier(ReadingSearchModifier(text: text, isPresented: isPresented, prompt: prompt, alwaysVisible: alwaysVisible))
    }

    @ViewBuilder
    func readingListTopMargin(_ margin: CGFloat) -> some View {
        if #available(iOS 17.0, *), !ReadingCompatibility.usesLegacyUI {
            contentMargins(.top, margin, for: .scrollContent)
        } else {
            self
        }
    }
}

private struct ReadingSearchModifier: ViewModifier {
    @Binding var text: String
    @Binding var isPresented: Bool
    let prompt: String
    var alwaysVisible: Bool = false
    @FocusState private var isFocused: Bool

    func body(content: Content) -> some View {
        // 统一使用页面内常驻搜索框：系统搜索栏在 iOS 26 上会在左上角残留一个搜索图标。
        content
                .safeAreaInset(edge: .top, spacing: 0) {
                    HStack(spacing: 8) {
                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                            TextField(prompt, text: $text)
                                .focused($isFocused)
                                .textInputAutocapitalization(.never)
                                .disableAutocorrection(true)
                                .submitLabel(.search)
                            if !text.isEmpty {
                                Button {
                                    text = ""
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .accessibilityLabel("清除搜索")
                            }
                        }
                        .padding(.horizontal, 12)
                        .frame(minHeight: 40)
                        .background { ThemeSurface(shape: Capsule(), isCard: true) }
                        if isFocused {
                            Button("取消") {
                                text = ""
                                isFocused = false
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background { ReadingCanvasBackground(grouped: true).ignoresSafeArea(edges: .horizontal) }
                }
                .onAppear { isFocused = isPresented }
                .onChange(of: isPresented) { isFocused = $0 }
                .onChange(of: isFocused) { isPresented = $0 }
    }
}

/// 应用界面色板。颜色跟随「外观主题」里选用的主题（默认为经典黑白），
/// 在解析时读取当前主题，因此所有沿用这些令牌的界面都会随主题变化。
enum ReadingTheme {
    static var accent: Color { AppThemeRuntime.color { $0.accent } }
    static var accentFill: Color { AppThemeRuntime.color { $0.accent } }
    static var emphasisSurface: Color { AppThemeRuntime.color { $0.accent } }
    static var selectionBorder: Color { AppThemeRuntime.color { $0.accent } }
    static let toggleTint = Color(uiColor: .systemGreen)
    static var accentSoft: Color { AppThemeRuntime.color { $0.selection } }
    static let coral = Color(red: 0.76, green: 0.48, blue: 0.27)
    static let paper = Color(red: 0.965, green: 0.945, blue: 0.895)
    static var ink: Color { AppThemeRuntime.color { $0.primary } }
    static var canvas: Color { AppThemeRuntime.color { $0.canvas } }
    static var groupedCanvas: Color { AppThemeRuntime.color { $0.groupedCanvas } }
    static var surface: Color { AppThemeRuntime.color { $0.surface } }
    static var separator: Color { AppThemeRuntime.color { $0.separator } }
    static var onAccent: Color { AppThemeRuntime.color { $0.onAccent } }
    static var secondaryInk: Color { AppThemeRuntime.color { $0.secondary } }
    static var tertiaryInk: Color { AppThemeRuntime.color { $0.tertiary } }
}

struct ReadingPageHeader<Actions: View>: View {
    let title: String
    let subtitle: String
    /// 固定在页面顶部（不随内容滚动）时下沿留得小一些，内容从这里开始、滑上来直接被裁掉。
    var bottomPadding: CGFloat = 28
    @ViewBuilder var actions: Actions

    init(title: String, subtitle: String, bottomPadding: CGFloat = 28, @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.subtitle = subtitle
        self.bottomPadding = bottomPadding
        self.actions = actions()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 16) {
                Text(title)
                    .font(AppFontStyle.largeTitle.bold().themed)
                    .foregroundStyle(ReadingTheme.ink)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                HStack(spacing: 10) { actions }
            }
            Text(subtitle)
                .font(AppFontStyle.subheadline.themed)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, bottomPadding)
        // 把大标题行的下沿报给页面：滚上去以后由顶部悬浮栏接替标题。
        .background(alignment: .top) {
            GeometryReader { proxy in
                Color.clear.preference(key: ReadingHeaderBottomKey.self,
                                       value: proxy.frame(in: .global).minY + 20 + 44)
            }
        }
    }
}

struct ReadingHeaderBottomKey: PreferenceKey {
    static let defaultValue: CGFloat = .greatestFiniteMagnitude
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = min(value, nextValue()) }
}

/// 主页面的顶部：内容滚动时不再直接压到状态栏（时间、电量）下面。
/// 状态栏区域始终铺一层页面底色并向下渐隐；大标题滚出去以后，顶部浮出一条紧凑栏（小标题 + 原来的按钮），
/// 内容从栏下面渐隐滑过，和 Cmbok、系统「图书」的上滑效果一致。
struct ReadingPinnedTopBar<Actions: View>: ViewModifier {
    let title: String
    @ViewBuilder var actions: () -> Actions
    @State private var headerBottom: CGFloat = .greatestFiniteMagnitude

    func body(content: Content) -> some View {
        content
            .onPreferenceChange(ReadingHeaderBottomKey.self) { value in
                // 只关心「标题是否滚到顶部」，按 4pt 取整减少刷新。
                let rounded = (value / 4).rounded() * 4
                Task { @MainActor in
                    if headerBottom != rounded { headerBottom = rounded }
                }
            }
            .overlay(alignment: .top) {
                GeometryReader { proxy in
                    let top = proxy.safeAreaInsets.top
                    let barHeight: CGFloat = 50
                    let collapsed = headerBottom < top + 8
                    ZStack(alignment: .top) {
                        // 背景按整屏尺寸绘制、只露出顶部一条：颜色与下面固定不动的页面背景逐像素一致，
                        // 内容从下面滑上来时像淡出到背景里（之前按条的高度重新绘制，渐变被压扁，颜色对不上）。
                        let height = top + (collapsed ? barHeight : 0)
                        let full = proxy.size.height + top + proxy.safeAreaInsets.bottom
                        ReadingCanvasBackground()
                            .frame(width: proxy.size.width, height: full)
                            .mask(alignment: .top) {
                                LinearGradient(stops: [
                                    .init(color: .black, location: 0),
                                    .init(color: .black, location: height / (height + 4)),
                                    .init(color: .clear, location: 1)
                                ], startPoint: .top, endPoint: .bottom)
                                .frame(height: height + 4)
                            }
                            .frame(height: height + 4, alignment: .top)
                            .clipped()
                            .allowsHitTesting(false)
                        HStack(spacing: 10) {
                            Text(title)
                                .font(AppFontStyle.headline.weight(.semibold).themed)
                                .foregroundStyle(ReadingTheme.ink)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            HStack(spacing: 10) { actions() }
                                .scaleEffect(0.86, anchor: .trailing)
                        }
                        .padding(.horizontal, 24)
                        .frame(height: barHeight)
                        .padding(.top, top)
                        .opacity(collapsed ? 1 : 0)
                        .offset(y: collapsed ? 0 : -8)
                        .allowsHitTesting(collapsed)
                    }
                    .frame(maxWidth: .infinity, alignment: .top)
                    .animation(.easeOut(duration: 0.2), value: collapsed)
                    .ignoresSafeArea(edges: .top)
                }
            }
    }
}

extension View {
    func readingPinnedTopBar<Actions: View>(title: String, @ViewBuilder actions: @escaping () -> Actions) -> some View {
        modifier(ReadingPinnedTopBar(title: title, actions: actions))
    }
}

// MARK: - 主页面大标题（仿系统大标题导航栏的上滑效果）

enum ReadingLargeTitleMetrics {
    /// 顶部栏高度（右上角按钮、收起后的小标题都在这一条里）。
    static let barHeight: CGFloat = 48
    /// 内容滚进顶部栏的这段距离里，顶部栏底色逐渐出现。
    static let fadeDistance: CGFloat = 20
}

struct ReadingLargeTitleBottomKey: PreferenceKey {
    static let defaultValue: CGFloat = .greatestFiniteMagnitude
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = min(value, nextValue()) }
}

/// 放在主页面滚动内容最上面的占位：只留出顶部栏的高度，不再单独占一行大标题。
/// 页面名称改为顶部栏左侧的紧凑标题，与右上角按钮同一行，下面的内容整体上移；配合 `readingLargeTitleBar` 使用。
struct ReadingLargeTitle: View {
    let title: String

    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: ReadingLargeTitleMetrics.barHeight)
            .accessibilityHidden(true)
            .background(alignment: .bottom) {
                GeometryReader { proxy in
                    Color.clear.preference(key: ReadingLargeTitleBottomKey.self,
                                           value: proxy.frame(in: .global).maxY)
                }
            }
    }
}

/// 主页面顶部栏：左侧紧凑标题与右上角按钮同一行、始终固定；内容向上滚进顶部栏时，顶部栏铺出与页面背景
/// 逐像素一致的底色（下沿柔和渐隐），内容像淡出到背景里。下拉时内容跟手，背景不动。
struct ReadingLargeTitleBar<Actions: View>: ViewModifier {
    let title: String
    @ViewBuilder var actions: () -> Actions
    @State private var titleBottom: CGFloat = .greatestFiniteMagnitude

    func body(content: Content) -> some View {
        content
            .onPreferenceChange(ReadingLargeTitleBottomKey.self) { value in
                let rounded = (value / 2).rounded() * 2
                Task { @MainActor in
                    if titleBottom != rounded { titleBottom = rounded }
                }
            }
            .overlay(alignment: .top) {
                GeometryReader { proxy in
                    let top = proxy.safeAreaInsets.top
                    let barHeight = ReadingLargeTitleMetrics.barHeight
                    let fade = ReadingLargeTitleMetrics.fadeDistance
                    let barBottom = top + barHeight
                    // 0：内容还没滚到顶部栏下面；1：内容已经滚进顶部栏。
                    let raw = (barBottom - titleBottom) / fade
                    let progress = raw.isFinite ? min(max(raw, 0), 1) : 0
                    let height = barBottom
                    let edge: CGFloat = 18
                    let full = proxy.size.height + top + proxy.safeAreaInsets.bottom
                    ZStack(alignment: .top) {
                        // 背景按整屏尺寸绘制、只露出顶部一条：颜色与下面固定不动的页面背景完全一致。
                        ReadingCanvasBackground()
                            .frame(width: proxy.size.width, height: full)
                            .mask(alignment: .top) {
                                LinearGradient(stops: [
                                    .init(color: .black, location: 0),
                                    .init(color: .black, location: height / (height + edge)),
                                    .init(color: .clear, location: 1)
                                ], startPoint: .top, endPoint: .bottom)
                                .frame(height: height + edge)
                            }
                            .frame(height: height + edge, alignment: .top)
                            .clipped()
                            .opacity(progress)
                            .allowsHitTesting(false)
                        HStack(spacing: 10) {
                            Text(title)
                                .font(AppFontStyle.title2.bold().themed)
                                .foregroundStyle(ReadingTheme.ink)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                                .accessibilityAddTraits(.isHeader)
                            Spacer(minLength: 0)
                            actions()
                        }
                        .padding(.leading, 24)
                        .padding(.trailing, 20)
                        .frame(height: barHeight)
                        .padding(.top, top)
                    }
                    .frame(maxWidth: .infinity, alignment: .top)
                    .ignoresSafeArea(edges: .top)
                }
            }
    }
}

extension View {
    /// 配合滚动内容最上面的 `ReadingLargeTitle` 使用。
    func readingLargeTitleBar<Actions: View>(title: String, @ViewBuilder actions: @escaping () -> Actions) -> some View {
        modifier(ReadingLargeTitleBar(title: title, actions: actions))
    }

    func readingLargeTitleBar(title: String) -> some View {
        modifier(ReadingLargeTitleBar(title: title) { EmptyView() })
    }
}

struct ReadingToolbarIcon: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(AppFontStyle.system(size: 19, weight: .regular).themed)
            .foregroundStyle(ReadingTheme.accent)
            .frame(width: 44, height: 44)
            // 玻璃圆钮（跟随外观主题的玻璃/实色/透明设置），和 bookon 右上角按钮一致。
            .background { ThemeSurface(shape: Circle()) }
            .shadow(color: .black.opacity(0.06), radius: 4, y: 2)
            .contentShape(Circle())
            .accessibilityHidden(true)
    }
}

enum BookReadingPresentation {
    static func hasStarted(_ book: Book) -> Bool {
        book.durChapterIndex > 0 || book.durChapterPos > 0 || book.durChapterTime > 0
    }

    static func progress(_ book: Book) -> Double {
        guard hasStarted(book), book.totalChapterNum > 0 else { return 0 }
        return min(1, max(0, Double(book.durChapterIndex + 1) / Double(book.totalChapterNum)))
    }

    static func position(_ book: Book) -> String {
        if let title = book.durChapterTitle, !title.isEmpty { return title }
        guard hasStarted(book) else { return "尚未阅读" }
        return book.totalChapterNum > 0
            ? "第\(book.durChapterIndex + 1)章 · 共\(book.totalChapterNum)章"
            : "已读至第\(book.durChapterIndex + 1)章"
    }

    static func progressLabel(_ book: Book) -> String {
        guard hasStarted(book) else { return "尚未阅读" }
        guard book.totalChapterNum > 0 else { return position(book) }
        return "已读\(Int((progress(book) * 100).rounded()))%"
    }
}

struct ReadingProgressLine: View {
    let value: Double

    var body: some View {
        GeometryReader { geometry in
            Capsule().fill(ReadingTheme.separator)
                .overlay(alignment: .leading) {
                    Capsule().fill(ReadingTheme.accent)
                        .frame(width: geometry.size.width * min(1, max(0, value)))
                }
        }
        .frame(height: 3)
        .accessibilityHidden(true)
    }
}

struct BookCoverArtwork: View {
    let title: String
    var author: String = ""
    var remoteURL: String?
    var width: CGFloat = 68
    var height: CGFloat = 96
    var cornerRadius: CGFloat = 4
    /// 左侧那道深色书脊阴影；书架「平面」封面关掉它，才是真正的平面。
    var spineShade = true
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.themePageScope) private var pageScope

    /// 外观主题的默认封面（当前明暗）；「标签页启用默认封面」关闭时只在书架页使用。
    private var themeDefaultCover: String? {
        guard let custom = AppThemeRuntime.current.customization else { return nil }
        guard custom.defaultCoverInTabs || pageScope == .shelf || pageScope == .global else { return nil }
        return custom.defaultCover(dark: colorScheme == .dark)
    }

    /// 「封面圆角」：0 圆角的调用方（实体书封面自己画形状）保持不变。
    private var effectiveRadius: CGFloat {
        cornerRadius <= 0 ? 0 : AppThemeRuntime.coverCornerRadius(width: width, legacy: cornerRadius)
    }

    private var coverStyle: Int {
        switch title {
        case "长夜里的灯": 0
        case "群星沉默时": 1
        case "山海入梦来": 2
        default: title.unicodeScalars.reduce(0) { ($0 + Int($1.value)) % 3 }
        }
    }

    private var coverColor: Color {
        switch coverStyle {
        case 1: Color(red: 0.22, green: 0.35, blue: 0.44)
        case 2: Color(red: 0.71, green: 0.44, blue: 0.34)
        default: Color(red: 0.14, green: 0.15, blue: 0.16)
        }
    }

    var body: some View {
        Group {
            if AppThemeRuntime.current.customization?.forceDefaultCover == true, themeDefaultCover != nil {
                // 外观主题「强制使用默认封面」：所有书都用主题的默认封面。
                placeholder
            } else if let remoteURL, remoteURL.hasPrefix("data:image/"),
               let image = CoverImageCache.shared.inlineImage(for: remoteURL) {
                // 内嵌封面（本地书等）解码一次后缓存，之前每次刷新都在主线程重新 base64 解码 + 解图。
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                CachedCoverImage(address: remoteURL) {
                    placeholder
                }
            }
        }
        .frame(width: width, height: height)
        .overlay(alignment: .leading) {
            if spineShade {
                Rectangle().fill(.black.opacity(0.15)).frame(width: max(2, width * 0.035))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: effectiveRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: effectiveRadius, style: .continuous)
                .strokeBorder(.black.opacity(0.08), lineWidth: 0.5)
        }
        .accessibilityHidden(true)
    }

    private var placeholder: some View {
        CoverLibraryFallback(title: title, author: author, width: width, height: height) {
            themePlaceholder
        }
    }

    @ViewBuilder
    private var themePlaceholder: some View {
        if let custom = themeDefaultCover,
           let image = ThemeAssetStore.shared.image(for: custom) {
            // 主题「默认封面」：只在书籍没有可用封面时显示。
            ZStack(alignment: .bottomLeading) {
                Image(uiImage: image).resizable().scaledToFill()
                    .frame(width: width, height: height).clipped()
                if width >= 50 {
                    Text(title)
                        .font(.system(size: max(8, width * 0.12), weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .shadow(color: .black.opacity(0.6), radius: 2)
                        .padding(width * 0.08)
                }
            }
        } else {
            generatedPlaceholder
        }
    }

    private var generatedPlaceholder: some View {
        ZStack(alignment: .topLeading) {
            coverColor
            Canvas { context, size in
                drawArtwork(context: context, size: size)
            }
            VStack(alignment: .leading, spacing: width * 0.10) {
                Text(coverStyle == 0 ? title.map(String.init).joined(separator: "\n") : title)
                    .font(.system(size: max(9, width * (coverStyle == 0 ? 0.16 : 0.18)), weight: .medium, design: .serif))
                    .lineLimit(coverStyle == 0 ? 7 : 4)
                    .minimumScaleFactor(0.65)
                    .frame(maxWidth: coverStyle == 0 ? width * 0.32 : .infinity, alignment: .leading)
                if !author.isEmpty, width >= 50 {
                    Text(author)
                        .font(.system(size: max(7, width * 0.09)))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(.white.opacity(0.94))
            .padding(width * 0.15)
            .padding(.top, coverStyle == 1 ? height * 0.33 : 0)
        }
    }

    private func drawArtwork(context: GraphicsContext, size: CGSize) {
        if coverStyle == 0 {
            let moon = CGRect(x: size.width * 0.68, y: size.height * 0.18, width: size.width * 0.17, height: size.width * 0.17)
            context.fill(Path(ellipseIn: moon), with: .color(Color(red: 0.89, green: 0.87, blue: 0.81)))
        } else if coverStyle == 1 {
            let normalizedPoints: [CGPoint] = [
                .init(x: 0.12, y: 0.19), .init(x: 0.39, y: 0.11), .init(x: 0.62, y: 0.22),
                .init(x: 0.88, y: 0.13), .init(x: 0.76, y: 0.42), .init(x: 0.33, y: 0.48)
            ]
            let points = normalizedPoints.map { point in
                CGPoint(x: point.x * size.width, y: point.y * size.height)
            }
            var constellation = Path()
            constellation.addLines(points)
            context.stroke(constellation, with: .color(.white.opacity(0.22)), lineWidth: 0.6)
            for point in points {
                context.fill(Path(ellipseIn: CGRect(x: point.x, y: point.y, width: 1.5, height: 1.5)), with: .color(.white.opacity(0.7)))
            }
        } else {
            let arch = CGRect(x: size.width * 0.28, y: size.height * 0.40, width: size.width * 0.58, height: size.height * 0.48)
            context.fill(Path(roundedRect: arch, cornerRadius: size.width * 0.29), with: .color(.white.opacity(0.25)))
        }
        for index in 0..<3 {
            var horizon = Path()
            let baseline = size.height * (0.78 + CGFloat(index) * 0.065)
            horizon.move(to: CGPoint(x: 0, y: baseline))
            horizon.addCurve(
                to: CGPoint(x: size.width, y: baseline + 8),
                control1: CGPoint(x: size.width * 0.3, y: baseline + 18),
                control2: CGPoint(x: size.width * 0.6, y: baseline - 20)
            )
            context.stroke(horizon, with: .color(.white.opacity(0.17)), lineWidth: 0.7)
        }

    }
}

struct ReadingCard<Content: View>: View {
    @ThemePalette private var palette
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: palette.cornerRadius(default: 20), style: .continuous)
        content
            .padding(20)
            .background { ThemeSurface(shape: shape, isCard: true) }
    }
}

struct StatusPill: View {
    let text: String
    var color: Color = ReadingTheme.accent
    var systemImage: String?

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text)
        }
        .font(AppFontStyle.caption.weight(.medium).themed)
        .foregroundStyle(color)
    }
}


/// 封面图缓存：内存 + 磁盘。视图重建（启动、从阅读页返回）时同步取到图片，不再先闪一下占位封面。
@MainActor
final class CoverImageCache {
    static let shared = CoverImageCache()
    private let memory = NSCache<NSString, UIImage>()
    private let inline = NSCache<NSString, UIImage>()
    private let directory: URL

    private init() {
        memory.countLimit = 300
        inline.countLimit = 64
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        directory = base.appendingPathComponent("BookCovers", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func fileURL(for url: URL) -> URL {
        let key = url.absoluteString.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
        return directory.appendingPathComponent(String(key, radix: 16))
    }

    /// 只查内存和本地磁盘，不发网络请求。
    /// 磁盘上的原图按显示需要缩到最长边 720 像素并立即解码：之前 UIImage(data:) 只是懒解码，
    /// 第一次绘制时在主线程按原尺寸解码（几十张封面的页面推入时明显卡顿），内存里也一直留着原尺寸位图。
    func cachedImage(for url: URL) -> UIImage? {
        let key = url.absoluteString as NSString
        if let image = memory.object(forKey: key) { return image }
        guard let data = try? Data(contentsOf: fileURL(for: url)),
              let image = Self.displayImage(from: data) ?? UIImage(data: data) else { return nil }
        memory.setObject(image, forKey: key)
        return image
    }

    /// `data:image/…;base64,` 内嵌封面：解码结果按地址缓存。
    func inlineImage(for address: String) -> UIImage? {
        let key = address as NSString
        if let image = inline.object(forKey: key) { return image }
        guard let comma = address.firstIndex(of: ","),
              let data = Data(base64Encoded: String(address[address.index(after: comma)...])),
              let image = Self.displayImage(from: data) ?? UIImage(data: data) else { return nil }
        inline.setObject(image, forKey: key)
        return image
    }

    /// 封面显示用位图：ImageIO 直接按目标尺寸解码（JPEG 可按比例缩放解码，比先解原图再缩快得多），
    /// 结果已解码，绘制时不再在主线程解码。动图等只取第一帧，与 UIImage(data:) 显示一致。
    nonisolated static func displayImage(from data: Data, maxPixelSize: Int = 720) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
              CGImageSourceGetCount(source) > 0 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }

    func image(for url: URL) async -> UIImage? {
        if let image = cachedImage(for: url) { return image }
        guard let cover = CoverRequest(address: url.absoluteString) else { return nil }
        return await image(for: cover)
    }

    /// 按书源写法的封面地址取图：支持 `地址,{"headers":{…}}`、中文或空格未编码、`//` 开头的地址，
    /// 自动带上书源的请求头和 Referer；失败时再用图片所在站点做 Referer 重试一次（防盗链图床）。
    func image(for cover: CoverRequest) async -> UIImage? {
        if let image = cachedImage(for: cover.url) { return image }
        if let running = inFlight[cover.url] { return await running.value }
        let attempts = cover.attempts
        let decodeScript = cover.decodeScript
        let target = fileURL(for: cover.url)
        let key = cover.url.absoluteString
        let task = Task<UIImage?, Never> {
            for request in attempts {
                guard let (data, response) = try? await URLSession.shared.data(for: request) else { continue }
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { continue }
                // 加密封面（书源的 coverDecodeJs）：先解密再解码；没加密的图直接解码。
                var payload = data
                var image = UIImage(data: data) ?? CoverImageCache.decodeDataImage(data)
                if image == nil, let decodeScript,
                   let decoded = await Task.detached(priority: .utility, operation: {
                       CoverDecodeScript.decode(data, script: decodeScript)
                   }).value {
                    image = UIImage(data: decoded)
                    payload = decoded
                }
                if let image {
                    let data = payload
                    // 缩放解码放到后台线程，主线程拿到的是已解码的小图。
                    let display = await Task.detached(priority: .utility) {
                        CoverImageCache.displayImage(from: data)
                    }.value ?? image
                    CoverImageCache.shared.memory.setObject(display, forKey: key as NSString)
                    try? data.write(to: target, options: .atomic)
                    return display
                }
            }
            return nil
        }
        inFlight[cover.url] = task
        let image = await task.value
        inFlight[cover.url] = nil
        return image
    }

    private var inFlight: [URL: Task<UIImage?, Never>] = [:]

    /// 有的接口把图片包成 `data:image/...;base64,` 文本返回。
    nonisolated static func decodeDataImage(_ data: Data) -> UIImage? {
        guard data.count < 4_000_000, let text = String(data: data, encoding: .utf8),
              text.hasPrefix("data:image"), let comma = text.firstIndex(of: ","),
              let decoded = Data(base64Encoded: String(text[text.index(after: comma)...]).trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        return UIImage(data: decoded)
    }
}

/// 把书源给出的封面地址整理成可以请求的 URLRequest。
struct CoverRequest {
    let url: URL
    let headers: [String: String]
    let decodeScript: String?

    init?(address raw: String) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.hasPrefix("data:") else { return nil }
        let registered = CoverRequestRegistry.shared.entry(forCover: text)
        var headers: [String: String] = registered?.headers ?? [:]
        decodeScript = registered?.decodeScript
        if let range = text.range(of: #",\s*\{"#, options: .regularExpression) {
            let options = String(text[text.index(before: range.upperBound)...])
            text = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            if let value = try? LegadoURLBuilder.decodeLenientJSON(options), case .object(let object) = value,
               let header = object["headers"] ?? object["header"] {
                switch header {
                case .object(let fields):
                    for (key, item) in fields { headers[key] = item.stringValue }
                case .string(let json):
                    if let parsed = try? LegadoURLBuilder.decodeLenientJSON(json), case .object(let fields) = parsed {
                        for (key, item) in fields { headers[key] = item.stringValue }
                    }
                default: break
                }
            }
        }
        if text.hasPrefix("//") { text = "https:" + text }
        guard let url = URL(string: text) ?? Self.encoded(text),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        self.url = url
        self.headers = headers
    }

    private static func encoded(_ text: String) -> URL? {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.insert(charactersIn: "#%")
        return text.addingPercentEncoding(withAllowedCharacters: allowed).flatMap(URL.init(string:))
    }

    private static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    /// 先用书源的请求头；不行再用图片站点自己做 Referer；最后不带 Referer。
    var attempts: [URLRequest] {
        func request(_ fields: [String: String]) -> URLRequest {
            var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 20)
            request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("image/avif,image/webp,image/apng,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
            for (key, value) in fields { request.setValue(value, forHTTPHeaderField: key) }
            return request
        }
        var result = [request(headers)]
        let hasReferer = headers.keys.contains { $0.caseInsensitiveCompare("Referer") == .orderedSame }
        if let scheme = url.scheme, let host = url.host {
            var withOrigin = headers.filter { $0.key.caseInsensitiveCompare("Referer") != .orderedSame }
            withOrigin["Referer"] = "\(scheme)://\(host)/"
            if withOrigin != headers { result.append(request(withOrigin)) }
        }
        if hasReferer {
            result.append(request(headers.filter { $0.key.caseInsensitiveCompare("Referer") != .orderedSame }))
        }
        return result
    }
}

/// 带缓存的远程封面。已缓存的图片在第一帧就显示。
struct CachedCoverImage<Placeholder: View>: View {
    let url: URL?
    private let cover: CoverRequest?
    let placeholder: () -> Placeholder
    @State private var image: UIImage?

    init(url: URL?, @ViewBuilder placeholder: @escaping () -> Placeholder) {
        self.url = url
        cover = url.flatMap { CoverRequest(address: $0.absoluteString) }
        self.placeholder = placeholder
        _image = State(initialValue: url.flatMap { CoverImageCache.shared.cachedImage(for: $0) })
    }

    /// 直接用书源给的封面字符串（可能带请求头参数、未编码的中文）。
    init(address: String?, @ViewBuilder placeholder: @escaping () -> Placeholder) {
        let cover = address.flatMap { CoverRequest(address: $0) }
        self.cover = cover
        url = cover?.url
        self.placeholder = placeholder
        _image = State(initialValue: cover.flatMap { CoverImageCache.shared.cachedImage(for: $0.url) })
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            guard let url else { image = nil; return }
            if let cached = CoverImageCache.shared.cachedImage(for: url) {
                if image !== cached { image = cached }
                return
            }
            var loaded: UIImage?
            if let cover {
                loaded = await CoverImageCache.shared.image(for: cover)
            } else {
                loaded = await CoverImageCache.shared.image(for: url)
            }
            if !Task.isCancelled, let loaded { image = loaded }
        }
    }
}

// MARK: - 可精确调整的滑杆

/// 滑杆两边带「−」「＋」按钮，每点一下按步长调整一次，长按连续调整。
struct AdjustableSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    var format: (Double) -> String

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text(format(value)).monospacedDigit().foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                AdjustableStepButton(systemName: "minus", label: "\(title)减少",
                                     enabled: value > range.lowerBound + step / 2) { adjust(by: -1) }
                Slider(value: $value, in: range, step: step)
                    .accessibilityLabel(title)
                AdjustableStepButton(systemName: "plus", label: "\(title)增加",
                                     enabled: value < range.upperBound - step / 2) { adjust(by: 1) }
            }
        }
    }

    private func adjust(by steps: Double) {
        let current = ((value - range.lowerBound) / step).rounded()
        var next = range.lowerBound + (current + steps) * step
        next = min(max(next, range.lowerBound), range.upperBound)
        // 去掉浮点误差，例如 0.1 + 0.2。
        value = (next * 1_000_000).rounded() / 1_000_000
    }
}

/// 「−」「＋」小圆按钮：轻点调整一次，按住不放每 0.1 秒连续调整。
struct AdjustableStepButton: View {
    let systemName: String
    let label: String
    var enabled: Bool = true
    let action: () -> Void

    @State private var repeatTask: Task<Void, Never>?

    var body: some View {
        Image(systemName: systemName)
            .font(AppFontStyle.system(size: 13, weight: .semibold).themed)
            .foregroundStyle(enabled ? Color.primary : Color.secondary.opacity(0.5))
            .frame(width: 30, height: 30)
            .background(Color.secondary.opacity(0.14), in: Circle())
            .frame(width: 36, height: 36)
            .contentShape(Rectangle())
            .onTapGesture { if enabled { action() } }
            .onLongPressGesture(minimumDuration: 0.4, pressing: { pressing in
                if !pressing { stopRepeating() }
            }, perform: {
                guard enabled else { return }
                startRepeating()
            })
            .onDisappear { stopRepeating() }
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { if enabled { action() } }
    }

    private func startRepeating() {
        stopRepeating()
        let action = self.action
        repeatTask = Task { @MainActor in
            action()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                if Task.isCancelled { break }
                action()
            }
        }
    }

    private func stopRepeating() {
        repeatTask?.cancel()
        repeatTask = nil
    }
}

// MARK: - 段落缩进

/// 段落缩进按「几个字符」设置：可点 0～4 快速选择，也可以用「−」「＋」或直接输入 0～10。
/// 存储仍是缩进字符串（每个字符为一个全角空格），与旧设置兼容。
struct ParagraphIndentControl: View {
    @Binding var indent: String
    static let maxCharacters = 10

    /// 旧设置可能是半角空格或其它字符：全角空格算 1 个，半角空格两个算 1 个，其它字符各算 1 个。
    static func characterCount(of indent: String) -> Int {
        var full = 0
        var half = 0
        for character in indent {
            if character == " " { half += 1 } else { full += 1 }
        }
        return full + (half + 1) / 2
    }

    static func indentString(characters: Int) -> String {
        String(repeating: "　", count: min(max(characters, 0), maxCharacters))
    }

    private var count: Int { Self.characterCount(of: indent) }

    private var countBinding: Binding<Int> {
        Binding(get: { count }, set: { indent = Self.indentString(characters: $0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("段落缩进")
                Spacer()
                AdjustableStepButton(systemName: "minus", label: "段落缩进减少", enabled: count > 0) {
                    countBinding.wrappedValue = count - 1
                }
                TextField("0", text: textBinding)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.center)
                    .font(.body.monospacedDigit())
                    .frame(width: 44, height: 32)
                    .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityLabel("段落缩进字符数")
                Text("字符").foregroundStyle(.secondary)
                AdjustableStepButton(systemName: "plus", label: "段落缩进增加", enabled: count < Self.maxCharacters) {
                    countBinding.wrappedValue = count + 1
                }
            }
            HStack(spacing: 8) {
                ForEach(0...4, id: \.self) { value in
                    Text(value == 0 ? "不缩进" : "\(value) 字")
                        .font(AppFontStyle.subheadline.weight(count == value ? .semibold : .regular).themed)
                        .foregroundStyle(count == value ? Color.white : Color.primary)
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .background(count == value ? ReadingTheme.accent : Color.secondary.opacity(0.12), in: Capsule())
                        .contentShape(Capsule())
                        .onTapGesture { countBinding.wrappedValue = value }
                        .accessibilityAddTraits(count == value ? [.isButton, .isSelected] : .isButton)
                }
            }
            Text("每段开头空出几个汉字的宽度，默认 2 个字符，可输入 0～\(Self.maxCharacters)。")
                .font(AppFontStyle.caption.themed)
                .foregroundStyle(.secondary)
        }
    }

    /// 手动输入：只取数字，超过上限按上限。
    private var textBinding: Binding<String> {
        Binding(
            get: { String(count) },
            set: { text in
                let digits = text.filter(\.isNumber)
                let number = Int(digits.suffix(2)) ?? 0
                indent = Self.indentString(characters: number)
            }
        )
    }
}
