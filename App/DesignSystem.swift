import SwiftUI

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
                    .font(.subheadline)
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
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            configuration.title.font(.title2.bold())
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

    func readingSearchable(text: Binding<String>, isPresented: Binding<Bool>, prompt: String) -> some View {
        modifier(ReadingSearchModifier(text: text, isPresented: isPresented, prompt: prompt))
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
    @FocusState private var isFocused: Bool

    func body(content: Content) -> some View {
        if #available(iOS 17.0, *), !ReadingCompatibility.usesLegacyUI {
            content.searchable(text: $text, isPresented: $isPresented, prompt: prompt)
        } else {
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
                        .padding(10)
                        .background(ReadingTheme.groupedCanvas, in: RoundedRectangle(cornerRadius: 10))
                        if isFocused {
                            Button("取消") {
                                text = ""
                                isFocused = false
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(ReadingTheme.canvas)
                }
                .onAppear { isFocused = isPresented }
                .onChange(of: isPresented) { isFocused = $0 }
                .onChange(of: isFocused) { isPresented = $0 }
        }
    }
}

enum ReadingTheme {
    static let accent = adaptive(0x171717, dark: 0xDADAE0)
    static let accentFill = adaptive(0x171717, dark: 0x414148)
    static let emphasisSurface = adaptive(0x171717, dark: 0x29292E)
    static let selectionBorder = adaptive(0x171717, dark: 0x777780)
    static let toggleTint = Color(uiColor: .systemGreen)
    static let accentSoft = adaptive(0xEEEEEF, dark: 0x29292C)
    static let coral = Color(red: 0.76, green: 0.48, blue: 0.27)
    static let paper = Color(red: 0.965, green: 0.945, blue: 0.895)
    static let ink = Color.primary
    static let canvas = adaptive(0xFCFCFC, dark: 0x111113)
    static let groupedCanvas = adaptive(0xF3F3F4, dark: 0x1C1C1F)
    static let surface = adaptive(0xFFFFFF, dark: 0x232326)
    static let separator = adaptive(0xE6E6E8, dark: 0x363639)
    static let onAccent = Color.white

    private static func adaptive(_ light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(
                red: CGFloat((hex >> 16) & 0xff) / 255,
                green: CGFloat((hex >> 8) & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255,
                alpha: 1
            )
        })
    }
}

struct ReadingPageHeader<Actions: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 16) {
                Text(title)
                    .font(.largeTitle.bold())
                    .foregroundStyle(ReadingTheme.ink)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                HStack(spacing: 10) { actions }
            }
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 28)
    }
}

struct ReadingToolbarIcon: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 19, weight: .regular))
            .foregroundStyle(ReadingTheme.accent)
            .frame(width: 44, height: 44)
            .background(ReadingTheme.groupedCanvas, in: Circle())
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
            if let remoteURL, remoteURL.hasPrefix("data:image/"),
               let comma = remoteURL.firstIndex(of: ","),
               let data = Data(base64Encoded: String(remoteURL[remoteURL.index(after: comma)...])),
               let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                CachedCoverImage(url: remoteURL.flatMap(URL.init(string:))) {
                    placeholder
                }
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay(alignment: .leading) {
            Rectangle().fill(.black.opacity(0.15)).frame(width: max(2, width * 0.035))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(.black.opacity(0.08), lineWidth: 0.5)
        }
        .accessibilityHidden(true)
    }

    private var placeholder: some View {
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
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(20)
            .background(ReadingTheme.groupedCanvas, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
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
        .font(.caption.weight(.medium))
        .foregroundStyle(color)
    }
}


/// 封面图缓存：内存 + 磁盘。视图重建（启动、从阅读页返回）时同步取到图片，不再先闪一下占位封面。
@MainActor
final class CoverImageCache {
    static let shared = CoverImageCache()
    private let memory = NSCache<NSString, UIImage>()
    private let directory: URL

    private init() {
        memory.countLimit = 300
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
    func cachedImage(for url: URL) -> UIImage? {
        let key = url.absoluteString as NSString
        if let image = memory.object(forKey: key) { return image }
        guard let data = try? Data(contentsOf: fileURL(for: url)), let image = UIImage(data: data) else { return nil }
        memory.setObject(image, forKey: key)
        return image
    }

    func image(for url: URL) async -> UIImage? {
        if let image = cachedImage(for: url) { return image }
        guard let (data, response) = try? await URLSession.shared.data(from: url) else { return nil }
        if let image = memory.object(forKey: url.absoluteString as NSString) { return image }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return nil }
        guard let image = UIImage(data: data) else { return nil }
        memory.setObject(image, forKey: url.absoluteString as NSString)
        try? data.write(to: fileURL(for: url), options: .atomic)
        return image
    }
}

/// 带缓存的远程封面。已缓存的图片在第一帧就显示。
struct CachedCoverImage<Placeholder: View>: View {
    let url: URL?
    let placeholder: () -> Placeholder
    @State private var image: UIImage?

    init(url: URL?, @ViewBuilder placeholder: @escaping () -> Placeholder) {
        self.url = url
        self.placeholder = placeholder
        _image = State(initialValue: url.flatMap { CoverImageCache.shared.cachedImage(for: $0) })
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
            let loaded = await CoverImageCache.shared.image(for: url)
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
            .font(.system(size: 13, weight: .semibold))
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
                        .font(.subheadline.weight(count == value ? .semibold : .regular))
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
                .font(.caption)
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
