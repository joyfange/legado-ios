import CoreText
import ImageIO
import SwiftUI
import UIKit

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
