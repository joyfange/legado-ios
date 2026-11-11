import CoreText
import ImageIO
import SwiftUI
import UIKit
import WebKit
#if SWIFT_PACKAGE
import LegadoCore
#endif

private struct ReaderPositionPreferenceKey: PreferenceKey {
    static let defaultValue: [Int: CGFloat] = [:]
    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

struct ReaderStylePreset: Identifiable {
    let id: String
    let name: String
    let background: UIColor
    let foreground: UIColor

    static let legadoDefaults: [ReaderStylePreset] = [
        .init(id: "wechat", name: "微信读书", background: UIColor(hex: 0xC0EDC6), foreground: UIColor(hex: 0x0B0B0B)),
        .init(id: "preset1", name: "预设1", background: UIColor(hex: 0xFFFFFF), foreground: UIColor(hex: 0x000000)),
        .init(id: "preset2", name: "预设2", background: UIColor(hex: 0xDDC090), foreground: UIColor(hex: 0x3E3422)),
        .init(id: "preset3", name: "预设3", background: UIColor(hex: 0xC2D8AA), foreground: UIColor(hex: 0x596C44)),
        .init(id: "preset4", name: "预设4", background: UIColor(hex: 0xDBB8E2), foreground: UIColor(hex: 0x68516C)),
        .init(id: "preset5", name: "预设5", background: UIColor(hex: 0xABCEE0), foreground: UIColor(hex: 0x3D4C54)),
        .init(id: "night", name: "夜间", background: UIColor(hex: 0x000000), foreground: UIColor(hex: 0xADADAD))
    ]
    static let eInk = ReaderStylePreset(
        id: "eink",
        name: "E-Ink",
        background: UIColor(hex: 0xFFFFFF),
        foreground: UIColor(hex: 0x000000)
    )

    static func resolve(_ id: String) -> ReaderStylePreset {
        let migratedID = switch id {
        case "dark": "night"
        case "light": "preset1"
        case "paper": "preset2"
        default: id
        }
        if migratedID == customID { return custom() }
        return legadoDefaults.first(where: { $0.id == migratedID }) ?? legadoDefaults[0]
    }

    static let customID = "custom"
    static let customBackgroundKey = "readerCustomBackgroundHex"
    static let customForegroundKey = "readerCustomForegroundHex"
    static let defaultCustomBackground = "F5EFDF"
    static let defaultCustomForeground = "2E2A24"

    /// User-defined background and text colours ("自定义").
    static func custom(defaults: UserDefaults = .standard) -> ReaderStylePreset {
        let background = UIColor(readerHex: defaults.string(forKey: customBackgroundKey) ?? "")
            ?? UIColor(readerHex: defaultCustomBackground)!
        let foreground = UIColor(readerHex: defaults.string(forKey: customForegroundKey) ?? "")
            ?? UIColor(readerHex: defaultCustomForeground)!
        return ReaderStylePreset(id: customID, name: "自定义", background: background, foreground: foreground)
    }
}

extension UIColor {
    /// Parses "RRGGBB" or "#RRGGBB"; returns nil for anything else.
    convenience init?(readerHex: String) {
        var text = readerHex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(hex: value)
    }

    /// "RRGGBB" in sRGB, alpha ignored.
    var readerHex: String {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        let resolved = resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        guard resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return "" }
        func channel(_ value: CGFloat) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "%02X%02X%02X", channel(red), channel(green), channel(blue))
    }
}

private extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255,
            alpha: 1
        )
    }
}

enum ReaderBackgroundStore {
    static let maximumPixelSize = 2560

    static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Legado/reader-background.jpg")
    }

    static func load(from source: URL = url) -> UIImage? {
        guard let data = try? Data(contentsOf: source, options: .mappedIfSafe) else { return nil }
        return try? downsample(data)
    }

    static func save(_ data: Data, to target: URL = url) throws -> UIImage {
        let image = try downsample(data)
        guard let encoded = image.jpegData(compressionQuality: 0.9) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoded.write(to: target, options: .atomic)
        return image
    }

    private static func downsample(_ data: Data) throws -> UIImage {
        // Decode only the size used by the reader, including backgrounds saved
        // by older versions. Full-resolution camera photos can exhaust memory.
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize
              ] as CFDictionary) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return UIImage(cgImage: image)
    }

    static func remove() { try? FileManager.default.removeItem(at: url) }
}

enum ReaderFontStore {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Legado/fonts", isDirectory: true)
    }

    static func install(from source: URL) throws -> String {
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: source)
        guard let provider = CGDataProvider(data: data as CFData),
              font(provider: provider, size: 20, weight: 0) != nil else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent(source.lastPathComponent)
        if target != source {
            try data.write(to: target, options: .atomic)
        }
        return target.path
    }

    static func font(at path: String, size: CGFloat, weight: Int) -> UIFont? {
        guard !path.isEmpty,
              let provider = CGDataProvider(url: URL(fileURLWithPath: path) as CFURL) else { return nil }
        return font(provider: provider, size: size, weight: weight)
    }

    private static func font(provider: CGDataProvider, size: CGFloat, weight: Int) -> UIFont? {
        guard let graphicsFont = CGFont(provider) else { return nil }
        CTFontManagerRegisterGraphicsFont(graphicsFont, nil)
        guard let postScriptName = graphicsFont.postScriptName else { return nil }
        let name = postScriptName as String
        guard let base = UIFont(name: name, size: size) else { return nil }
        if weight == 1,
           let descriptor = base.fontDescriptor.withSymbolicTraits(.traitBold) {
            return UIFont(descriptor: descriptor, size: size)
        }
        if weight == 2 {
            let descriptor = base.fontDescriptor.addingAttributes([
                .traits: [UIFontDescriptor.TraitKey.weight: UIFont.Weight.light.rawValue]
            ])
            return UIFont(descriptor: descriptor, size: size)
        }
        return base
    }
}

/// A small live sample of the reading page, shown at the top of the style
/// sheet so every change is visible while adjusting it. It renders sample
/// text only and never touches reading progress.
struct ReaderStylePreviewCard: View {
    let background: UIColor
    let foreground: UIColor
    let backgroundImage: UIImage?
    let fontSize: Double
    let fontPath: String
    let fontWeight: Int
    let letterSpacing: Double
    let lineSpacing: Double
    let paragraphSpacing: Double
    let paragraphIndent: String
    let paddingLeft: Double
    let paddingRight: Double
    let titleMode: Int
    let titleSize: Double
    let titleColor: UIColor?
    let titleBold: Bool
    let footerLeft: String
    let footerRight: String
    let footerPaddingLeft: Double
    let footerPaddingRight: Double
    let showsFooter: Bool

    static let sampleTitle = "第一章 示例标题"
    static let sampleText = "清晨的阳光透过窗棂洒在书页上，他翻开那本泛黄的旧书，指尖轻轻拂过一行行文字。\n这是一段示例正文，用来实时预览字号、行距、段距、缩进与配色的效果，不会写入阅读记录。"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if titleMode != 2 {
                Text(Self.sampleTitle)
                    .font(Font(font(size: fontSize + titleSize, bold: titleBold) as CTFont))
                    .foregroundStyle(Color(uiColor: titleColor ?? foreground))
                    .frame(maxWidth: .infinity, alignment: titleMode == 1 ? .center : .leading)
                    .padding(.bottom, max(lineSpacing, 4))
            }
            VStack(alignment: .leading, spacing: CGFloat(lineSpacing + paragraphSpacing)) {
                ForEach(Array(Self.sampleText.split(separator: "\n").enumerated()), id: \.offset) { _, line in
                    Text(paragraphIndent + String(line))
                        .font(Font(font(size: fontSize, bold: false) as CTFont))
                        .kerning(CGFloat(letterSpacing * fontSize))
                        .lineSpacing(CGFloat(lineSpacing))
                        .foregroundStyle(Color(uiColor: foreground))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            Spacer(minLength: 0)
            if showsFooter {
                HStack {
                    Text(footerLeft).lineLimit(1).minimumScaleFactor(0.75)
                    Spacer(minLength: 8)
                    Text(footerRight).lineLimit(1).fixedSize()
                }
                .font(.system(size: 10))
                .foregroundStyle(Color(uiColor: foreground))
                .padding(.leading, max(0, footerPaddingLeft - paddingLeft))
                .padding(.trailing, max(0, footerPaddingRight - paddingRight))
                .padding(.top, 6)
            }
        }
        .padding(.leading, min(paddingLeft, 40))
        .padding(.trailing, min(paddingRight, 40))
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .frame(height: 150, alignment: .top)
        .background {
            ZStack {
                Color(uiColor: background)
                if let backgroundImage {
                    Image(uiImage: backgroundImage).resizable().scaledToFill()
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 0.5)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("排版预览")
        .accessibilityIdentifier("reader.stylePreview")
    }

    private func font(size: Double, bold: Bool) -> UIFont {
        let size = CGFloat(max(5, size))
        if let custom = ReaderFontStore.font(at: fontPath, size: size, weight: bold ? 1 : fontWeight) {
            return custom
        }
        if bold { return UIFont.systemFont(ofSize: size, weight: .bold) }
        switch fontWeight {
        case 1: return UIFont.systemFont(ofSize: size, weight: .bold)
        case 2: return UIFont.systemFont(ofSize: size, weight: .light)
        default: return UIFont(name: "STSongti-SC-Regular", size: size) ?? UIFont.systemFont(ofSize: size)
        }
    }
}

/// Header/footer row. Short items (time, page, progress) keep their natural
/// width so a long chapter title can use the rest of the row instead of
/// being squeezed into a third of it and cut off with "…".
struct ReaderTipRowLayout: View {
    let left: String
    let middle: String
    let right: String

    var body: some View {
        if middle.isEmpty {
            HStack(spacing: 8) {
                if left.count >= right.count {
                    flexible(left, alignment: .leading)
                    if !right.isEmpty { Text(right).lineLimit(1).fixedSize() }
                } else {
                    if !left.isEmpty { Text(left).lineLimit(1).fixedSize() }
                    flexible(right, alignment: .trailing)
                }
            }
        } else {
            HStack(spacing: 8) {
                flexible(left, alignment: .leading)
                Text(middle).lineLimit(1).minimumScaleFactor(0.7)
                    .layoutPriority(1)
                flexible(right, alignment: .trailing)
            }
        }
    }

    private func flexible(_ text: String, alignment: Alignment) -> some View {
        Text(text)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: alignment)
    }
}

extension NSAttributedString.Key {
    /// A tappable link inside chapter text (段评气泡 or an illustration).
    static let readerLink = NSAttributedString.Key("legado.readerLink")
}

/// Renders the `<img src="…">` markers chapter text can carry. Paragraph
/// review counts (段评, `dp:12`, `bubble://paragraph?num=12`, or a review
/// image with `{"type":"cmt"…}` options) become a small count bubble at the
/// end of the paragraph; other images become an "插图" chip instead of raw
/// HTML. The marker keeps its length (its other characters are drawn at
/// near-zero size) so saved reading positions stay valid.
enum ReaderInlineMarkup {
    struct Bubble: Equatable {
        var text: String
        var color: UIColor?
        var emphasis: Bool
        var url: URL?
    }

    enum Item: Equatable {
        case bubble(Bubble)
        case image(URL?)
    }

    private static let reviewTypes: Set<String> = [
        "qd", "fqpl", "fanqie", "cmt", "comment", "comments", "review", "reviews", "paragraph", "duanping", "dp"
    ]

    static let tagExpression = try? NSRegularExpression(pattern: #"<img\s+src\s*=\s*"([^"]*)"\s*/?>"#, options: [.caseInsensitive])

    static func containsMarkup(_ text: String) -> Bool {
        text.range(of: "<img", options: .caseInsensitive) != nil
    }

    static func unescape(_ value: String) -> String {
        value.replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#34;", with: "\"")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    static func parse(src rawSource: String) -> Item {
        let source = unescape(rawSource).trimmingCharacters(in: .whitespacesAndNewlines)
        // dp:12  or  dp:12,{"status":"emphasis","displayColor":"#FF0000"}
        if source.lowercased().hasPrefix("dp:") {
            let body = String(source.dropFirst(3))
            let (head, options) = splitOptions(body)
            return .bubble(.init(
                text: displayCount(options["displayText"] as? String ?? head),
                color: (options["displayColor"] as? String).flatMap { UIColor(readerHex: $0) },
                emphasis: (options["status"] as? String) == "emphasis",
                url: nil
            ))
        }
        // bubble://paragraph?num=12&status=emphasis&displayColor=%23FF0000
        if source.lowercased().hasPrefix("bubble://"), let components = URLComponents(string: source) {
            let query = Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
            return .bubble(.init(
                text: displayCount(query["displayText"] ?? query["num"] ?? ""),
                color: query["displayColor"].flatMap { UIColor(readerHex: $0) },
                emphasis: query["status"] == "emphasis",
                url: query["url"].flatMap { URL(string: $0) } ?? query["js"].flatMap(scriptURL)
            ))
        }
        let (head, options) = splitOptions(source)
        let url = URL(string: head)
        if !options.isEmpty {
            let type = (options["type"] as? String ?? "").lowercased()
            let style = (options["style"] as? String ?? "").uppercased()
            let click = (options["click"] as? String ?? "") + (options["pclick"] as? String ?? "")
            let isReview = reviewTypes.contains(type)
                || click.contains("showCmt(") || click.contains("showComment(") || click.contains("paragraph")
                || (style == "TEXT" && !type.isEmpty)
            if isReview {
                let count = (options["num"] as? String) ?? (options["num"] as? Int).map(String.init)
                    ?? (options["text"] as? String) ?? ""
                let link = (options["url"] as? String).flatMap { URL(string: $0) }
                    ?? (click.contains("showBrowser") ? url : nil)
                return .bubble(.init(
                    text: displayCount(count),
                    color: (options["displayColor"] as? String).flatMap { UIColor(readerHex: $0) },
                    emphasis: (options["status"] as? String) == "emphasis",
                    url: link.flatMap { ["http", "https"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil }
                ))
            }
        }
        return .image(url.flatMap { ["http", "https"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil })
    }

    static let scriptScheme = "legado-review-js"

    /// A source click callback (`showCmt(...)`) carried as a tappable link;
    /// the reader runs it with the book source to find the review page.
    static func scriptURL(_ script: String) -> URL? {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard !script.isEmpty, let encoded = script.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "\(scriptScheme)://run?code=\(encoded)")
    }

    static func script(from url: URL) -> String? {
        guard url.scheme == scriptScheme else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "code" }?.value
    }

    private static func splitOptions(_ value: String) -> (String, [String: Any]) {
        guard let comma = value.range(of: ",{") else { return (value, [:]) }
        let head = String(value[..<comma.lowerBound])
        let json = String(value[value.index(after: comma.lowerBound)...])
        let options = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
        return (head, options)
    }

    private static func displayCount(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "段评" }
        if let number = Int(trimmed), number >= 1000 {
            return number >= 10000 ? String(format: "%.1fw", Double(number) / 10000) : "\(number / 1000)k+"
        }
        return trimmed
    }

    /// Replaces each marker inside `range` without changing the text length.
    static func decorate(_ text: NSMutableAttributedString, in range: NSRange, font: UIFont, foreground: UIColor, accent: UIColor, showsBubbles: Bool = true, bubbleStyle: Int = 0, bubbleAccent: Bool = false, customBubbleRevision: Int = 0) {
        guard range.length > 0 else { return }
        styleCommentCards(text, in: range, font: font, foreground: foreground, accent: accent)
        guard let expression = tagExpression,
              containsMarkup((text.string as NSString).substring(with: range)) else { return }
        let matches = expression.matches(in: text.string, range: range)
        for match in matches where match.range.length > 1 && match.numberOfRanges > 1 {
            let source = (text.string as NSString).substring(with: match.range(at: 1))
            let item = parse(src: source)
            let image: UIImage
            var link: URL?
            switch item {
            case .bubble where !showsBubbles:
                text.addAttributes([.font: UIFont.systemFont(ofSize: 0.01), .foregroundColor: UIColor.clear, .kern: 0], range: match.range)
                text.removeAttribute(.underlineStyle, range: match.range)
                continue
            case .bubble(let bubble):
                // 气泡形状与数字格式跟随「段评气泡」样式；颜色优先用书源给的 displayColor，
                // 其次强调状态用强调色，否则跟随正文（自定义样式可改为固定颜色）。
                image = CommentBubble.image(label: bubble.text, fontSize: font.pointSize, color: bubble.color ?? (bubble.emphasis ? accent : foreground))
                link = bubble.url
            case .image(let url):
                image = bubbleImage(text: "插图", font: font, color: foreground, style: 0)
                link = url
            }
            let attachment = NSTextAttachment()
            attachment.image = image
            let capHeight = font.capHeight
            if case .bubble = item {
                let bounds = CommentBubble.attachmentBounds(fontSize: font.pointSize)
                attachment.bounds = CGRect(x: 0, y: bounds.minY, width: image.size.width, height: image.size.height)
            } else {
                attachment.bounds = CGRect(x: 0, y: (capHeight - image.size.height) / 2, width: image.size.width, height: image.size.height)
            }
            let existing = text.attributes(at: match.range.location, effectiveRange: nil)
            let replacement = NSMutableAttributedString(attachment: attachment)
            var attributes = existing
            attributes[.attachment] = attachment
            attributes.removeValue(forKey: .underlineStyle)
            replacement.setAttributes(attributes, range: NSRange(location: 0, length: replacement.length))
            text.replaceCharacters(in: NSRange(location: match.range.location, length: 1), with: replacement)
            let hidden = NSRange(location: match.range.location + 1, length: match.range.length - 1)
            text.addAttributes([
                .font: UIFont.systemFont(ofSize: 0.01),
                .foregroundColor: UIColor.clear,
                .kern: 0
            ], range: hidden)
            text.removeAttribute(.underlineStyle, range: hidden)
            if let link { text.addAttribute(.readerLink, value: link, range: match.range) }
        }
    }

    /// 0 描边胶囊（默认）· 1 实心糖果 · 2 方角标签 · 3 对话气泡 · 4 自定义图片
    static let bubbleStyleNames = ["描边胶囊", "实心糖果", "方角标签", "对话气泡", "自定义图片"]

    private static let cardExpression = try? NSRegularExpression(
        pattern: "(?m)^【(?:热评|神评论|精选评论|精彩评论|本章说|本章讨论|本书讨论|本章评论|本书评论)[^】\\n]*】[^\\n]*"
    )

    /// 热评 / 本章说 卡片：标签用强调色加粗，正文缩小、浅色衬底，与正文区分开。
    static func styleCommentCards(_ text: NSMutableAttributedString, in range: NSRange, font: UIFont, foreground: UIColor, accent: UIColor) {
        let substring = (text.string as NSString).substring(with: range)
        guard substring.contains("【"), let expression = cardExpression else { return }
        let small = font.withSize(max(11, font.pointSize * 0.86))
        for match in expression.matches(in: text.string, range: range) {
            text.addAttributes([
                .font: small,
                .foregroundColor: foreground.withAlphaComponent(0.75),
                .backgroundColor: foreground.withAlphaComponent(0.06)
            ], range: match.range)
            let line = (text.string as NSString).substring(with: match.range)
            if let close = line.firstIndex(of: "】") {
                let labelLength = (String(line[...close]) as NSString).length
                text.addAttributes([
                    .font: UIFont.systemFont(ofSize: small.pointSize, weight: .bold),
                    .foregroundColor: accent
                ], range: NSRange(location: match.range.location, length: labelLength))
            }
        }
    }

    /// 用户导入的自定义气泡底图（PNG / JPEG），保存在 UserDefaults。
    static let customBubbleImageKey = "reviewBubbleCustomImage"
    nonisolated(unsafe) private static var customImageRevision = -1
    nonisolated(unsafe) private static var customImage: UIImage?

    static func customBubbleImage(revision: Int) -> UIImage? {
        if revision != customImageRevision {
            customImageRevision = revision
            customImage = UserDefaults.standard.data(forKey: customBubbleImageKey).flatMap { UIImage(data: $0) }
            imageCache.removeAllObjects()
        }
        return customImage
    }

    /// 缩到 96 像素高再存，避免大图拖慢排版。
    static func normalizedBubbleImageData(_ data: Data) -> Data? {
        guard data.count <= 10_000_000, let image = UIImage(data: data), image.size.height > 0 else { return nil }
        let height: CGFloat = 96
        let width = min(max(image.size.width * height / image.size.height, 24), 384)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { _ in
            image.draw(in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return resized.pngData()
    }

    nonisolated(unsafe) private static let imageCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 300
        return cache
    }()

    static func bubbleImage(text: String, font: UIFont, color: UIColor, style: Int = 0) -> UIImage {
        let key = "\(text)|\(font.pointSize)|\(color.readerHex)|\(style)" as NSString
        if let cached = imageCache.object(forKey: key) { return cached }
        let image = renderBubble(text: text, font: font, color: color, style: style)
        imageCache.setObject(image, forKey: key)
        return image
    }

    private static func renderCustomBubble(text: String, font: UIFont, color: UIColor, image: UIImage) -> UIImage {
        let labelFont = UIFont.systemFont(ofSize: max(9, font.pointSize * 0.55), weight: .bold)
        let attributes: [NSAttributedString.Key: Any] = [.font: labelFont, .foregroundColor: color]
        let textSize = (text as NSString).size(withAttributes: attributes)
        let height = ceil(labelFont.lineHeight + 6)
        let imageWidth = image.size.width * height / max(image.size.height, 1)
        let width = ceil(max(imageWidth, textSize.width + 10)) + 4
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height)).image { _ in
            let box = CGRect(x: 4, y: 0, width: width - 4, height: height)
            image.draw(in: box)
            (text as NSString).draw(
                at: CGPoint(x: box.midX - textSize.width / 2, y: (height - textSize.height) / 2),
                withAttributes: attributes
            )
        }
    }

    private static func renderBubble(text: String, font: UIFont, color: UIColor, style: Int) -> UIImage {
        let labelFont = UIFont.systemFont(ofSize: max(9, font.pointSize * 0.58), weight: .semibold)
        if style == 4, let custom = customImage {
            return renderCustomBubble(text: text, font: font, color: color, image: custom)
        }
        let textColor = style == 1 ? UIColor.white : color
        let attributes: [NSAttributedString.Key: Any] = [.font: labelFont, .foregroundColor: textColor]
        let textSize = (text as NSString).size(withAttributes: attributes)
        let height = ceil(labelFont.lineHeight + 4)
        let tail: CGFloat = style == 3 ? 4 : 0
        let size = CGSize(width: ceil(max(textSize.width + 12, height + 4)) + 4, height: height + tail)
        return UIGraphicsImageRenderer(size: size).image { _ in
            let bubble = CGRect(x: 4, y: 0, width: size.width - 4, height: height)
            let path: UIBezierPath
            switch style {
            case 2: path = UIBezierPath(roundedRect: bubble, cornerRadius: 3)
            case 3:
                path = UIBezierPath(roundedRect: bubble, cornerRadius: height / 2)
                let tip = UIBezierPath()
                tip.move(to: CGPoint(x: bubble.minX + 5, y: bubble.maxY - 2))
                tip.addLine(to: CGPoint(x: bubble.minX + 3, y: size.height))
                tip.addLine(to: CGPoint(x: bubble.minX + 11, y: bubble.maxY - 1))
                tip.close()
                path.append(tip)
            default: path = UIBezierPath(roundedRect: bubble, cornerRadius: height / 2)
            }
            if style == 1 {
                color.withAlphaComponent(0.85).setFill()
                path.fill()
            } else {
                color.withAlphaComponent(0.12).setFill()
                path.fill()
                color.withAlphaComponent(0.55).setStroke()
                path.lineWidth = 0.8
                path.stroke()
            }
            (text as NSString).draw(
                at: CGPoint(x: bubble.midX - textSize.width / 2, y: (height - textSize.height) / 2),
                withAttributes: attributes
            )
        }
    }
}

struct ReaderReviewPage: Identifiable {
    var url: URL?
    var html: String?
    var bridge: (@MainActor (String) async -> String)?
    /// 书源回调：先弹出半屏显示“正在加载”，在后台执行脚本拿到页面。
    var loader: (@MainActor () async -> JavaScriptRuleEvaluator.ClickResolution)?
    let id = UUID()

    init(url: URL?, html: String? = nil, bridge: (@MainActor (String) async -> String)? = nil,
         loader: (@MainActor () async -> JavaScriptRuleEvaluator.ClickResolution)? = nil) {
        self.url = url
        self.html = html
        self.bridge = bridge
        self.loader = loader
    }
}

/// 段评 / 插图页：点一下立即半屏弹出，可上划展开到全屏；书源回调在里面加载，
/// 失败时就地显示原因和重试。
struct ReaderReviewSheet: View {
    let page: ReaderReviewPage
    @State private var resolved: (url: URL, html: String?)?
    @State private var error: String?
    @State private var attempt = 0

    var body: some View {
        Group {
            if let resolved {
                ReaderReviewWebView(url: resolved.url, html: resolved.html, bridge: page.bridge)
                    .ignoresSafeArea(edges: .bottom)
            } else if let error {
                VStack(spacing: 14) {
                    Image(systemName: "text.bubble").font(.largeTitle).foregroundStyle(.secondary)
                    Text("段评加载失败").font(.headline)
                    Text(error).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("重试") { self.error = nil; attempt += 1 }.buttonStyle(.borderedProminent)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView("正在加载段评…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .readingPresentationDetents([.medium, .large])
        .task(id: attempt) { await load() }
    }

    private func load() async {
        guard resolved == nil else { return }
        if let loader = page.loader {
            let result = await loader()
            if let html = result.html {
                resolved = (result.url.flatMap(URL.init(string:)) ?? URL(string: "about:blank")!, html)
            } else if let target = result.url.flatMap(URL.init(string:)) {
                resolved = (target, nil)
            } else {
                error = result.error ?? "书源没有给出段评内容"
            }
        } else if let url = page.url {
            resolved = (url, page.html)
        } else {
            error = "没有段评地址"
        }
    }
}

private struct ReaderReviewWebView: UIViewRepresentable {
    let url: URL
    var html: String?
    var bridge: (@MainActor (String) async -> String)?

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        if bridge != nil {
            // 安卓 showBrowser 页面用 window.run / qmRun 回调书源 JS，返回 Promise。
            let controller = configuration.userContentController
            controller.addScriptMessageHandler(context.coordinator, contentWorld: .page, name: "legadoRun")
            controller.addUserScript(WKUserScript(source: """
                (function(){
                  function run(code){ return window.webkit.messageHandlers.legadoRun.postMessage(String(code)); }
                  window.run = run; window.qmRun = run; window.qmLocalCommentPage = true;
                })();
                """, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
        }
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.customUserAgent = ApplicationSettingsStore.shared.settings.effectiveUserAgent
        web.allowsBackForwardNavigationGestures = true
        web.navigationDelegate = context.coordinator
        if let html {
            web.loadHTMLString(html, baseURL: url)
        } else {
            web.load(URLRequest(url: url))
        }
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.configuration.userContentController.removeAllScriptMessageHandlers()
    }

    func makeCoordinator() -> Coordinator { Coordinator(host: url.host, bridge: bridge) }

    /// 不少段评接口的证书已过期，书源阅读里会直接空白。只对段评页自己的域名、
    /// 且仅在“证书过期”这一个错误时放行；其他证书问题照常拦下。
    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandlerWithReply {
        let host: String?
        let bridge: (@MainActor (String) async -> String)?
        init(host: String?, bridge: (@MainActor (String) async -> String)? = nil) {
            self.host = host
            self.bridge = bridge
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage,
            replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
        ) {
            guard let bridge, let code = message.body as? String else {
                replyHandler(nil, "阅读端没有注入 run 桥接")
                return
            }
            Task { @MainActor in
                replyHandler(await bridge(code), nil)
            }
        }

        func webView(
            _ webView: WKWebView,
            didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping @MainActor @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            let space = challenge.protectionSpace
            guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                  let trust = space.serverTrust, let host, Self.sameSite(space.host, host) else {
                completionHandler(.performDefaultHandling, nil)
                return
            }
            var error: CFError?
            if SecTrustEvaluateWithError(trust, &error) {
                completionHandler(.performDefaultHandling, nil)
            } else if let error, CFErrorGetCode(error) == Int(errSecCertificateExpired) {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
        }

        nonisolated static func sameSite(_ a: String, _ b: String) -> Bool {
            func root(_ h: String) -> String { h.lowercased().split(separator: ".").suffix(2).joined(separator: ".") }
            return root(a) == root(b)
        }
    }
}
