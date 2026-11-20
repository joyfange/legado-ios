import SwiftUI
import UIKit
import ImageIO

// 段评气泡：内置「气泡 / 方泡 / 白色糖果」三种样式 + 自定义样式（模板 / SVG / 图片），
// 可调整体大小、宽高比、数字格式与颜色、数字字号比例；画在段落末尾，轻点打开段评页。

// MARK: - 样式

struct BubbleStyle: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var name = "自定义气泡"
    /// template 模板 · svg SVG · image 图片
    var mode = "template"
    /// bubble 气泡 · square 方泡 · candy 白色糖果
    var template = "bubble"
    var showNumber = true
    /// 显示格式，{n} 代表评论数；留空等同 {n}。
    var format = "{n}"
    var followText = true
    var colorHex = "#555555"
    var scale = 1.0
    var aspect = 1.0
    var svg = ""
    var imageData: Data?

    init() {}

    init(id: String, name: String, template: String) {
        self.id = id
        self.name = name
        self.template = template
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, mode, template, showNumber, format, followText, colorHex, scale, aspect, svg, imageData
    }

    /// 旧版本或导入的文件缺字段时取默认值，不让整个文件读不出来。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? UUID().uuidString
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? "自定义气泡"
        mode = (try? c.decodeIfPresent(String.self, forKey: .mode)) ?? "template"
        template = (try? c.decodeIfPresent(String.self, forKey: .template)) ?? "bubble"
        showNumber = (try? c.decodeIfPresent(Bool.self, forKey: .showNumber)) ?? true
        format = (try? c.decodeIfPresent(String.self, forKey: .format)) ?? "{n}"
        followText = (try? c.decodeIfPresent(Bool.self, forKey: .followText)) ?? true
        colorHex = (try? c.decodeIfPresent(String.self, forKey: .colorHex)) ?? "#555555"
        scale = (try? c.decodeIfPresent(Double.self, forKey: .scale)) ?? 1
        aspect = (try? c.decodeIfPresent(Double.self, forKey: .aspect)) ?? 1
        svg = (try? c.decodeIfPresent(String.self, forKey: .svg)) ?? ""
        imageData = try? c.decodeIfPresent(Data.self, forKey: .imageData)
    }

    /// 按显示格式生成气泡里的文字。
    func label(_ count: String) -> String {
        let pattern = format.trimmingCharacters(in: .whitespacesAndNewlines)
        return pattern.isEmpty ? count : pattern.replacingOccurrences(of: "{n}", with: count)
    }

    var modeTitle: String {
        switch mode {
        case "svg": "SVG"
        case "image": "图片"
        default: "模板"
        }
    }

    /// 白色糖果模板的数字颜色固定为深灰。
    var usesFixedNumberColor: Bool { mode == "template" && template == "candy" }
}

/// 模板（也是三个内置样式）：名称、说明、图标和等价的 SVG（「填入当前模板」用）。
struct BubbleTemplate: Identifiable {
    let id: String
    let name: String
    let detail: String
    let icon: String
    let svg: String

    static let bubble = BubbleTemplate(
        id: "bubble", name: "气泡", detail: "只保留一个气泡轮廓，把其他装饰全部去掉。", icon: "bubble.left",
        svg: """
        <svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 128 96'>
            <path d='M64 12C95 12 119 29 119 48C119 67 95 82 64 82C55 82 47 81 40 78L14 88L23 69C14 63 9 56 9 48C9 29 33 12 64 12Z' fill='none' stroke='__TEXT__' stroke-width='8' stroke-linecap='round' stroke-linejoin='round'/>
        </svg>
        """)
    static let square = BubbleTemplate(
        id: "square", name: "方泡", detail: "更方一些，尾巴放在左侧。", icon: "text.bubble",
        svg: """
        <svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 128 96'>
            <path d='M24 14H101C111 14 119 22 119 32V62C119 72 111 80 101 80H39L14 90L22 71C13 68 9 61 9 53V32C9 22 17 14 27 14H24Z' fill='none' stroke='__TEXT__' stroke-width='8' stroke-linecap='round' stroke-linejoin='round'/>
        </svg>
        """)
    static let candy = BubbleTemplate(
        id: "candy", name: "白色糖果", detail: "白底黑边的糖果样式，数字颜色固定为深灰。", icon: "capsule",
        svg: """
        <svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 128 96'>
            <path d='M33 40L9 25C13 39 13 57 9 71L33 56Z' fill='#FFFFFF' stroke='#1A1A1A' stroke-width='5' stroke-linejoin='round'/>
            <path d='M95 40L119 25C115 39 115 57 119 71L95 56Z' fill='#FFFFFF' stroke='#1A1A1A' stroke-width='5' stroke-linejoin='round'/>
            <rect x='31' y='20' width='66' height='56' rx='26' fill='#FFFFFF' stroke='#1A1A1A' stroke-width='6'/>
            <path d='M21 37L23 59M107 37L105 59' fill='none' stroke='#1A1A1A' stroke-width='3' stroke-linecap='round'/>
        </svg>
        """)

    static let all: [BubbleTemplate] = [bubble, square, candy]

    static func find(_ id: String) -> BubbleTemplate { all.first { $0.id == id } ?? bubble }

    /// 内置样式在「气泡样式」里的 id。
    static func builtinID(_ template: String) -> String { "builtin." + template }

    static func builtin(id: String) -> BubbleTemplate? {
        guard id.hasPrefix("builtin.") else { return nil }
        let template = String(id.dropFirst("builtin.".count))
        return all.first { $0.id == template }
    }
}

// MARK: - 存储

/// 气泡样式与气泡设置，整体存成一个文档；草稿预览不会改动正在使用的样式。
final class BubbleStyleStore: ObservableObject {
    nonisolated(unsafe) static let shared = BubbleStyleStore()

    private struct Document: Codable {
        var styles: [BubbleStyle]
        var selectedID: String?
        /// 内置样式各自的整体大小（自定义样式的大小存在样式里）。
        var builtinScales: [String: Double]?
        var numberScale: Double?
        var preferSource: Bool?
    }

    /// 导出 / 导入的样式文件。
    struct ExportFile: Codable {
        var format = "legado.ios.bubbleStyles"
        var version = 1
        var styles: [BubbleStyle]
    }

    private static let key = "reader.bubble.styles.v1"
    static let maximumStyles = 30
    static let scaleRange: ClosedRange<Double> = 0.6...2.0
    static let aspectRange: ClosedRange<Double> = 0.5...1.5
    static let numberScaleRange: ClosedRange<Double> = 0.3...0.9
    static let defaultNumberScale = 0.4

    @Published private(set) var styles: [BubbleStyle] = []
    /// 选中的样式：自定义样式的 id，或 builtin.bubble / builtin.square / builtin.candy；nil 等同内置「气泡」。
    @Published private(set) var selectedID: String?
    @Published private(set) var builtinScales: [String: Double] = [:]
    @Published private(set) var numberScale = BubbleStyleStore.defaultNumberScale
    @Published private(set) var preferSource = false
    @Published private(set) var revision = 0
    private let defaults: UserDefaults
    private let runtime: Bool

    init(defaults: UserDefaults = .standard, runtime: Bool = true) {
        self.defaults = defaults; self.runtime = runtime
        if let data = defaults.data(forKey: Self.key), data.count <= 20_000_000,
           let doc = try? JSONDecoder().decode(Document.self, from: data) {
            styles = Array(doc.styles.prefix(Self.maximumStyles)).filter { Self.validate($0) == nil }
            if let id = doc.selectedID, styles.contains(where: { $0.id == id }) || BubbleTemplate.builtin(id: id) != nil {
                selectedID = id
            }
            builtinScales = (doc.builtinScales ?? [:]).filter { $0.value.isFinite }
                .mapValues { min(max($0, Self.scaleRange.lowerBound), Self.scaleRange.upperBound) }
            if let value = doc.numberScale, value.isFinite {
                numberScale = min(max(value, Self.numberScaleRange.lowerBound), Self.numberScaleRange.upperBound)
            }
            preferSource = doc.preferSource ?? false
        }
        publishRuntime()
    }

    static func validate(_ s: BubbleStyle) -> String? {
        if s.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || s.name.count > 40 { return "样式名称须为 1–40 个字符" }
        if !s.scale.isFinite || !(0.5...2.0).contains(s.scale) || !s.aspect.isFinite || !(0.5...2.0).contains(s.aspect) { return "尺寸超出允许范围" }
        if s.format.count > 16 || s.format.contains("\n") { return "显示格式最多 16 字符且不能换行" }
        if s.colorHex.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) == nil { return "颜色格式无效" }
        switch s.mode {
        case "template": if !["bubble", "candy", "square"].contains(s.template) { return "模板无效" }
        case "svg": return BubbleSVG.validate(s.svg)
        case "image":
            guard let data = s.imageData else { return "请先选择一张 PNG 或透明背景图片。" }
            guard data.count <= 2_000_000, let image = UIImage(data: data),
                  image.size.width > 0, image.size.height > 0,
                  image.size.width * image.scale <= 1024, image.size.height * image.scale <= 1024 else { return "请选择有效的 PNG 图片（不超过 1024 像素/2 MB）" }
        default: return "创建方式无效"
        }
        return nil
    }

    // MARK: 选中样式

    var selectedStyle: BubbleStyle? { styles.first { $0.id == selectedID } }

    /// 选中项的 id（未选时是内置「气泡」）。
    var effectiveSelectedID: String {
        if let selectedID, selectedStyle != nil || BubbleTemplate.builtin(id: selectedID) != nil { return selectedID }
        return BubbleTemplate.builtinID("bubble")
    }

    var selectedName: String {
        if let style = selectedStyle { return style.name }
        return BubbleTemplate.builtin(id: effectiveSelectedID)?.name ?? "气泡"
    }

    /// 正在使用的样式（内置样式换算成一个模板样式）。
    var resolvedStyle: BubbleStyle {
        if let style = selectedStyle { return style }
        let template = BubbleTemplate.builtin(id: effectiveSelectedID) ?? .bubble
        return Self.builtinStyle(template, scale: builtinScales[template.id] ?? 1)
    }

    static func builtinStyle(_ template: BubbleTemplate, scale: Double = 1) -> BubbleStyle {
        var style = BubbleStyle(id: BubbleTemplate.builtinID(template.id), name: template.name, template: template.id)
        style.scale = scale
        return style
    }

    /// 「当前样式大小」：内置样式单独记，自定义样式就是样式自己的整体大小。
    var currentScale: Double {
        if let style = selectedStyle { return style.scale }
        let template = BubbleTemplate.builtin(id: effectiveSelectedID) ?? .bubble
        return builtinScales[template.id] ?? 1
    }

    func setCurrentScale(_ value: Double) throws {
        let clamped = min(max(value, Self.scaleRange.lowerBound), Self.scaleRange.upperBound)
        if var style = selectedStyle {
            style.scale = clamped
            var next = styles
            if let index = next.firstIndex(where: { $0.id == style.id }) { next[index] = style }
            try persist(next, selected: selectedID)
        } else {
            let template = BubbleTemplate.builtin(id: effectiveSelectedID) ?? .bubble
            builtinScales[template.id] = clamped
            try persist(styles, selected: selectedID)
        }
    }

    func setNumberScale(_ value: Double) throws {
        numberScale = min(max(value, Self.numberScaleRange.lowerBound), Self.numberScaleRange.upperBound)
        try persist(styles, selected: selectedID)
    }

    func setPreferSource(_ value: Bool) throws {
        preferSource = value
        try persist(styles, selected: selectedID)
    }

    // MARK: 增删改

    func save(_ style: BubbleStyle) throws {
        if let error = Self.validate(style) { throw failure(error) }
        var next = styles
        if let i = next.firstIndex(where: { $0.id == style.id }) { next[i] = style }
        else { guard next.count < Self.maximumStyles else { throw failure("最多保存 \(Self.maximumStyles) 个样式") }; next.append(style) }
        try persist(next, selected: selectedID)
    }

    func select(_ id: String?) throws {
        guard id == nil || styles.contains(where: { $0.id == id }) || BubbleTemplate.builtin(id: id ?? "") != nil else {
            throw failure("样式不存在")
        }
        try persist(styles, selected: id)
    }

    func delete(_ id: String) throws {
        try persist(styles.filter { $0.id != id }, selected: selectedID == id ? nil : selectedID)
    }

    /// 段评图片下载完成等：只让阅读页重新排版。
    func bumpRevision() {
        revision += 1
    }

    // MARK: 导入导出

    /// 导出当前样式（内置样式导出成等价的模板样式）。
    func exportCurrentData() -> Data? {
        var style = resolvedStyle
        if selectedStyle == nil { style.id = UUID().uuidString }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(ExportFile(styles: [style]))
    }

    /// 导入样式文件：本应用导出的文件、样式数组或单个样式；导入后选中最后一个。返回导入个数。
    @discardableResult
    func importStyles(_ data: Data) throws -> Int {
        let decoder = JSONDecoder()
        var incoming: [BubbleStyle]
        // 样式字段都可缺省，先确认文件确实是气泡样式（对象里有 mode），别把其它 JSON 当成样式导入。
        let json = try? JSONSerialization.jsonObject(with: data)
        func isStyle(_ value: Any) -> Bool { (value as? [String: Any])?["mode"] is String }
        if let file = try? decoder.decode(ExportFile.self, from: data), file.format == "legado.ios.bubbleStyles", !file.styles.isEmpty {
            incoming = file.styles
        } else if let list = json as? [Any], !list.isEmpty, list.allSatisfy(isStyle),
                  let styles = try? decoder.decode([BubbleStyle].self, from: data) {
            incoming = styles
        } else if let object = json, isStyle(object) {
            incoming = [try decoder.decode(BubbleStyle.self, from: data)]
        } else {
            throw failure("这不是气泡样式文件")
        }
        var next = styles
        var lastID: String?
        for var style in incoming {
            guard next.count < Self.maximumStyles else { break }
            style.id = UUID().uuidString
            style.scale = min(max(style.scale, Self.scaleRange.lowerBound), Self.scaleRange.upperBound)
            style.aspect = min(max(style.aspect, Self.aspectRange.lowerBound), Self.aspectRange.upperBound)
            guard Self.validate(style) == nil else { continue }
            next.append(style)
            lastID = style.id
        }
        guard let lastID else { throw failure("文件里没有可用的气泡样式") }
        let added = next.count - styles.count
        try persist(next, selected: lastID)
        return added
    }

    private func persist(_ next: [BubbleStyle], selected: String?) throws {
        let document = Document(styles: next, selectedID: selected, builtinScales: builtinScales,
                                numberScale: numberScale, preferSource: preferSource)
        let data = try JSONEncoder().encode(document)
        guard data.count <= 20_000_000 else { throw failure("气泡样式总容量不能超过 20 MB") }
        defaults.set(data, forKey: Self.key)
        styles = next; selectedID = selected
        publishRuntime()
        revision += 1
    }

    private func publishRuntime() {
        guard runtime else { return }
        BubbleStyleRuntime.set(BubbleRenderConfig(style: resolvedStyle, numberScale: numberScale, preferSource: preferSource))
    }

    private func failure(_ text: String) -> NSError { NSError(domain: "BubbleStyle", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
}

/// 阅读页排版用的气泡设置快照。
struct BubbleRenderConfig: Equatable {
    var style: BubbleStyle
    var numberScale: Double
    var preferSource: Bool

    static let standard = BubbleRenderConfig(style: BubbleStyleStore.builtinStyle(.bubble), numberScale: BubbleStyleStore.defaultNumberScale,
                                             preferSource: false)
}

/// Layout and prepagination may run off-main; runtime snapshots are lock protected.
enum BubbleStyleRuntime {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var current = BubbleRenderConfig.standard
    private nonisolated(unsafe) static var version = 0
    static var revision: Int { lock.lock(); defer { lock.unlock() }; return version }
    static func set(_ config: BubbleRenderConfig) { lock.lock(); current = config; version += 1; lock.unlock() }
    static func snapshot() -> BubbleRenderConfig { lock.lock(); defer { lock.unlock() }; return current }
}

// MARK: - 绘制

enum BubbleStyleRenderer {
    /// 参考 23pt 正文 @3x，109×85px 画布。
    static func bounds(style: BubbleStyle, fontSize: CGFloat) -> CGRect {
        let s = max(fontSize, 1) / 23 * CGFloat(style.scale)
        return CGRect(x: 0, y: -4 * s, width: 109 / 3 * s * CGFloat(style.aspect), height: 85 / 3 * s)
    }

    static func image(style: BubbleStyle, count: Int, fontSize: CGFloat, color: UIColor,
                      numberScale: Double = BubbleStyleStore.defaultNumberScale) -> UIImage {
        image(style: style, label: String(max(0, count)), fontSize: fontSize, color: color, numberScale: numberScale)
    }

    static func image(style: BubbleStyle, label count: String, fontSize: CGFloat, color: UIColor,
                      numberScale: Double = BubbleStyleStore.defaultNumberScale, sourceImage: UIImage? = nil) -> UIImage {
        let size = bounds(style: style, fontSize: fontSize).size
        let s = max(fontSize, 1) / 23 * CGFloat(style.scale)
        let aspect = CGFloat(style.aspect)
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            let context = renderer.cgContext
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)
            let ink = style.followText ? color : hex(style.colorHex)
            var center = CGPoint(x: size.width / 2, y: size.height * 0.49)
            if let sourceImage {
                // 书源自带的气泡图：按比例放进气泡框。
                let fit = min(rect.width / max(sourceImage.size.width, 1), rect.height / max(sourceImage.size.height, 1))
                let drawn = CGSize(width: sourceImage.size.width * fit, height: sourceImage.size.height * fit)
                sourceImage.draw(in: CGRect(x: rect.midX - drawn.width / 2, y: rect.midY - drawn.height / 2,
                                            width: drawn.width, height: drawn.height))
                center = CGPoint(x: size.width / 2, y: size.height / 2)
            } else if style.mode == "image" {
                if let data = style.imageData, let image = UIImage(data: data) { image.draw(in: rect) }
                center = CGPoint(x: size.width / 2, y: size.height / 2)
            } else if style.mode == "svg" {
                BubbleSVG.draw(style.svg, in: rect, color: ink)
            } else {
                switch style.template {
                case "square":
                    BubbleSVG.draw(BubbleTemplate.square.svg, in: rect, color: ink)
                    center = CGPoint(x: rect.minX + rect.width * 64 / 128, y: rect.minY + rect.height * 47 / 96)
                case "candy":
                    BubbleSVG.draw(BubbleTemplate.candy.svg, in: rect, color: ink)
                    center = CGPoint(x: rect.minX + rect.width * 64 / 128, y: rect.minY + rect.height * 48 / 96)
                default:
                    drawOutline(in: context, canvas: size, scale: s, aspect: aspect, color: ink)
                    center = CGPoint(x: 54.5 / 3 * s * aspect, y: 42 / 3 * s)
                }
            }
            if style.showNumber {
                let textColor = style.usesFixedNumberColor && sourceImage == nil ? UIColor(red: 0.29, green: 0.29, blue: 0.29, alpha: 1) : ink
                let fontSize = 10.8 * s * CGFloat(numberScale / BubbleStyleStore.defaultNumberScale)
                drawNumber(style.label(count), center: center, fontSize: fontSize, maxWidth: size.width * 0.74,
                           color: textColor, canvasHeight: size.height, context: context)
            }
        }.withRenderingMode(.alwaysOriginal)
    }

    /// 内置「气泡」的轮廓（参考图描出的空心气泡，奇偶填充）。
    static func drawOutline(in context: CGContext, canvas: CGSize, scale s: CGFloat, aspect: CGFloat, color: UIColor) {
        context.saveGState()
        context.translateBy(x: 0, y: canvas.height)
        context.scaleBy(x: s * aspect / 30, y: -s / 30)
        context.addPath(CommentBubble.outline)
        context.setFillColor(color.cgColor)
        context.drawPath(using: .eoFill)
        context.restoreGState()
    }

    static func drawNumber(_ label: String, center: CGPoint, fontSize: CGFloat, maxWidth: CGFloat, color: UIColor,
                           canvasHeight: CGFloat, context: CGContext) {
        guard !label.isEmpty, fontSize > 0.5 else { return }
        var font = UIFont.systemFont(ofSize: fontSize, weight: .semibold)
        var text = NSAttributedString(string: label, attributes: [.font: font, .foregroundColor: color])
        if text.size().width > maxWidth, text.size().width > 0 {
            font = font.withSize(font.pointSize * maxWidth / text.size().width)
            text = NSAttributedString(string: label, attributes: [.font: font, .foregroundColor: color])
        }
        let line = CTLineCreateWithAttributedString(text)
        let ink = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
        context.saveGState()
        context.translateBy(x: 0, y: canvasHeight)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: center.x - ink.midX, y: canvasHeight - center.y - ink.midY)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    static func hex(_ value: String) -> UIColor {
        let n = UInt32(value.dropFirst(), radix: 16) ?? 0x555555
        return UIColor(red: CGFloat((n >> 16) & 255) / 255, green: CGFloat((n >> 8) & 255) / 255, blue: CGFloat(n & 255) / 255, alpha: 1)
    }
}

/// 书源自带的气泡图片（「优先使用自带气泡」）：后台下载一次后缓存，下载完成让阅读页重新排版。
enum BubbleSourceImageCache {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var images: [String: UIImage] = [:]
    private nonisolated(unsafe) static var loading: Set<String> = []
    private nonisolated(unsafe) static var failed: Set<String> = []

    static func image(for url: URL) -> UIImage? {
        let key = url.absoluteString
        lock.lock()
        if let image = images[key] { lock.unlock(); return image }
        let shouldLoad = !loading.contains(key) && !failed.contains(key) && loading.count < 8
        if shouldLoad { loading.insert(key) }
        lock.unlock()
        if shouldLoad { load(url) }
        return nil
    }

    private static func load(_ url: URL) {
        let key = url.absoluteString
        let request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 15)
        URLSession.shared.dataTask(with: request) { data, _, _ in
            let image = data.flatMap(decode)
            lock.lock()
            loading.remove(key)
            if let image {
                if images.count > 64 { images.removeAll() }
                images[key] = image
            } else {
                failed.insert(key)
            }
            lock.unlock()
            guard image != nil else { return }
            DispatchQueue.main.async { BubbleStyleStore.shared.bumpRevision() }
        }.resume()
    }

    private static func decode(_ data: Data) -> UIImage? {
        guard data.count <= 4_000_000,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 256,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}

// MARK: - SVG

/// 不依赖 WebKit 的极简 SVG 渲染：svg / g / path（M L H V C S Q T A Z）/ rect / circle / ellipse / line /
/// polygon / polyline，fill、stroke、stroke-width、stroke-linecap、stroke-linejoin、opacity、fill-opacity、
/// stroke-opacity，viewBox。颜色写 __TEXT__ / TEXT / currentColor 时跟随「文字颜色」。
/// 不支持脚本、外链、实体、文字和嵌入图片。
enum BubbleSVG {
    static func validate(_ svg: String) -> String? { parse(svg).error }

    private nonisolated(unsafe) static var cache: [String: Parser] = [:]
    private static let lock = NSLock()

    private static func parse(_ svg: String) -> Parser {
        lock.lock()
        if let hit = cache[svg] { lock.unlock(); return hit }
        lock.unlock()
        let delegate = Parser()
        if svg.utf8.count > 32_768 || svg.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || svg.contains("<!") || svg.contains("<?xml-stylesheet") {
            delegate.error = svg.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "请填写 SVG 代码" : "SVG 须小于 32 KB，且不能包含声明、实体或脚本"
        } else {
            let parser = XMLParser(data: Data(svg.utf8))
            parser.delegate = delegate
            parser.shouldResolveExternalEntities = false
            if !parser.parse(), delegate.error == nil { delegate.error = "SVG XML 格式无效" }
            if delegate.error == nil, delegate.viewBox == nil { delegate.error = "请提供有效的 SVG viewBox" }
            if delegate.error == nil, delegate.shapes.isEmpty { delegate.error = "SVG 里没有可画的图形" }
        }
        lock.lock()
        if cache.count > 32 { cache.removeAll() }
        cache[svg] = delegate
        lock.unlock()
        return delegate
    }

    static func draw(_ svg: String, in rect: CGRect, color: UIColor) {
        let parsed = parse(svg)
        guard parsed.error == nil, let box = parsed.viewBox, let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.saveGState(); defer { ctx.restoreGState() }
        ctx.clip(to: rect)
        ctx.translateBy(x: rect.minX, y: rect.minY)
        ctx.scaleBy(x: rect.width / box.width, y: rect.height / box.height)
        ctx.translateBy(x: -box.minX, y: -box.minY)
        for shape in parsed.shapes {
            ctx.saveGState()
            ctx.setAlpha(shape.style.opacity)
            if let fill = paint(shape.style.fill, current: color) {
                ctx.addPath(shape.path)
                ctx.setFillColor(fill.withAlphaComponent(fill.cgColor.alpha * shape.style.fillOpacity).cgColor)
                ctx.drawPath(using: shape.style.evenOdd ? .eoFill : .fill)
            }
            if let stroke = paint(shape.style.stroke, current: color), shape.style.width > 0 {
                ctx.addPath(shape.path)
                ctx.setStrokeColor(stroke.withAlphaComponent(stroke.cgColor.alpha * shape.style.strokeOpacity).cgColor)
                ctx.setLineWidth(shape.style.width)
                ctx.setLineCap(shape.style.cap)
                ctx.setLineJoin(shape.style.join)
                ctx.strokePath()
            }
            ctx.restoreGState()
        }
    }

    static func isTextColor(_ value: String) -> Bool {
        ["__text__", "text", "currentcolor"].contains(value.lowercased())
    }

    private static func paint(_ value: String, current: UIColor) -> UIColor? {
        let lower = value.trimmingCharacters(in: .whitespaces).lowercased()
        if lower == "none" || lower == "transparent" { return nil }
        if isTextColor(lower) { return current }
        return color(lower)
    }

    static func color(_ raw: String) -> UIColor? {
        let value = raw.trimmingCharacters(in: .whitespaces).lowercased()
        let named: [String: UInt32] = [
            "black": 0x000000, "white": 0xFFFFFF, "red": 0xFF0000, "gray": 0x808080, "grey": 0x808080,
            "orange": 0xFFA500, "yellow": 0xFFFF00, "green": 0x008000, "blue": 0x0000FF, "purple": 0x800080,
            "pink": 0xFFC0CB, "brown": 0xA52A2A, "darkgray": 0xA9A9A9, "lightgray": 0xD3D3D3
        ]
        if let hex = named[value] { return BubbleStyleRenderer.hex(String(format: "#%06X", hex)) }
        if value.hasPrefix("#") {
            var digits = String(value.dropFirst())
            guard digits.allSatisfy(\.isHexDigit) else { return nil }
            if digits.count == 3 { digits = digits.map { "\($0)\($0)" }.joined() }
            guard digits.count == 6 else { return nil }
            return BubbleStyleRenderer.hex("#" + digits)
        }
        if value.hasPrefix("rgb"), let open = value.firstIndex(of: "("), value.hasSuffix(")") {
            let parts = value[value.index(after: open)..<value.index(before: value.endIndex)]
                .split(whereSeparator: { $0 == "," || $0 == " " }).compactMap { Double($0) }
            guard parts.count == 3 || parts.count == 4 else { return nil }
            return UIColor(red: CGFloat(min(max(parts[0], 0), 255) / 255), green: CGFloat(min(max(parts[1], 0), 255) / 255),
                           blue: CGFloat(min(max(parts[2], 0), 255) / 255), alpha: CGFloat(parts.count == 4 ? min(max(parts[3], 0), 1) : 1))
        }
        return nil
    }

    fileprivate struct Style {
        var fill = "black"
        var stroke = "none"
        var width: CGFloat = 1
        var cap: CGLineCap = .butt
        var join: CGLineJoin = .miter
        var opacity: CGFloat = 1
        var fillOpacity: CGFloat = 1
        var strokeOpacity: CGFloat = 1
        var evenOdd = false
    }

    fileprivate struct Shape {
        var path: CGPath
        var style: Style
    }

    private final class Parser: NSObject, XMLParserDelegate, @unchecked Sendable {
        var error: String?
        var viewBox: CGRect?
        var shapes: [Shape] = []
        private var stack: [Style] = []
        private var depth = 0

        private static let styleKeys: Set<String> = [
            "fill", "stroke", "stroke-width", "stroke-linecap", "stroke-linejoin", "stroke-miterlimit",
            "opacity", "fill-opacity", "stroke-opacity", "fill-rule", "id", "class"
        ]
        private static let allowed: [String: Set<String>] = [
            "svg": ["xmlns", "xmlns:xlink", "viewbox", "width", "height", "version", "fill", "stroke", "stroke-width",
                    "stroke-linecap", "stroke-linejoin", "preserveaspectratio"],
            "g": [], "rect": ["x", "y", "width", "height", "rx", "ry"], "circle": ["cx", "cy", "r"],
            "ellipse": ["cx", "cy", "rx", "ry"], "line": ["x1", "y1", "x2", "y2"],
            "polygon": ["points"], "polyline": ["points"], "path": ["d"]
        ]

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes raw: [String: String]) {
            guard error == nil else { parser.abortParsing(); return }
            depth += 1
            let element = name.lowercased()
            let attributes = Dictionary(raw.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
            guard depth <= 6, shapes.count < 128 else { fail(parser, "SVG 最多 128 个图形、6 层嵌套"); return }
            guard let allowed = Self.allowed[element], (depth == 1) == (element == "svg") else {
                fail(parser, "不支持 SVG 元素：\(name)"); return
            }
            guard Set(attributes.keys).isSubset(of: allowed.union(Self.styleKeys)) else {
                let unknown = Set(attributes.keys).subtracting(allowed.union(Self.styleKeys)).sorted().joined(separator: "、")
                fail(parser, "SVG 含未支持属性：\(unknown)（不支持样式表、变换或外链）"); return
            }
            var style = stack.last ?? Style()
            if let fill = attributes["fill"] { style.fill = fill }
            if let stroke = attributes["stroke"] { style.stroke = stroke }
            for value in [attributes["fill"], attributes["stroke"]].compactMap({ $0 }) {
                let lower = value.trimmingCharacters(in: .whitespaces).lowercased()
                guard lower == "none" || lower == "transparent" || BubbleSVG.isTextColor(lower) || BubbleSVG.color(lower) != nil else {
                    fail(parser, "SVG 颜色请用 #RGB、#RRGGBB、rgb()、基本颜色名或 __TEXT__"); return
                }
            }
            if let width = attributes["stroke-width"] { style.width = number(width) ?? style.width }
            switch attributes["stroke-linecap"]?.lowercased() {
            case "round"?: style.cap = .round
            case "square"?: style.cap = .square
            case "butt"?: style.cap = .butt
            default: break
            }
            switch attributes["stroke-linejoin"]?.lowercased() {
            case "round"?: style.join = .round
            case "bevel"?: style.join = .bevel
            case "miter"?: style.join = .miter
            default: break
            }
            if let value = attributes["opacity"], let n = number(value) { style.opacity = min(max(n, 0), 1) * (stack.last?.opacity ?? 1) }
            if let value = attributes["fill-opacity"], let n = number(value) { style.fillOpacity = min(max(n, 0), 1) }
            if let value = attributes["stroke-opacity"], let n = number(value) { style.strokeOpacity = min(max(n, 0), 1) }
            if let rule = attributes["fill-rule"] { style.evenOdd = rule.lowercased() == "evenodd" }
            stack.append(style)

            func value(_ key: String, _ fallback: CGFloat = 0) -> CGFloat {
                guard let text = attributes[key] else { return fallback }
                guard let n = number(text) else { self.error = "SVG 数值无效：\(key)"; return 0 }
                return n
            }
            let path = CGMutablePath()
            switch element {
            case "svg":
                if let box = attributes["viewbox"].flatMap(Self.numbers), box.count == 4, box[2] > 0, box[3] > 0 {
                    viewBox = CGRect(x: box[0], y: box[1], width: box[2], height: box[3])
                } else if let w = attributes["width"].flatMap({ self.number($0) }), let h = attributes["height"].flatMap({ self.number($0) }), w > 0, h > 0 {
                    viewBox = CGRect(x: 0, y: 0, width: w, height: h)
                } else {
                    fail(parser, "SVG 需要有效 viewBox 或宽高")
                }
                return
            case "g":
                return
            case "rect":
                let w = value("width"), h = value("height")
                guard w > 0, h > 0 else { fail(parser, "矩形宽高须大于零"); return }
                var rx = attributes["rx"] != nil ? value("rx") : -1
                var ry = attributes["ry"] != nil ? value("ry") : -1
                if rx < 0 { rx = max(ry, 0) }
                if ry < 0 { ry = rx }
                rx = min(rx, w / 2); ry = min(ry, h / 2)
                let r = CGRect(x: value("x"), y: value("y"), width: w, height: h)
                if rx > 0, ry > 0 { path.addRoundedRect(in: r, cornerWidth: rx, cornerHeight: ry) } else { path.addRect(r) }
            case "circle", "ellipse":
                let rx = value(element == "circle" ? "r" : "rx"), ry = value(element == "circle" ? "r" : "ry")
                guard rx > 0, ry > 0 else { fail(parser, "圆半径须大于零"); return }
                path.addEllipse(in: CGRect(x: value("cx") - rx, y: value("cy") - ry, width: 2 * rx, height: 2 * ry))
            case "line":
                path.move(to: CGPoint(x: value("x1"), y: value("y1")))
                path.addLine(to: CGPoint(x: value("x2"), y: value("y2")))
            case "polygon", "polyline":
                guard let n = Self.numbers(attributes["points"] ?? ""), n.count >= 4, n.count % 2 == 0 else { fail(parser, "SVG points 无效"); return }
                path.move(to: CGPoint(x: n[0], y: n[1]))
                for i in stride(from: 2, to: n.count, by: 2) { path.addLine(to: CGPoint(x: n[i], y: n[i + 1])) }
                if element == "polygon" { path.closeSubpath() }
            case "path":
                guard let result = BubbleSVG.path(attributes["d"] ?? "") else { fail(parser, "路径 d 无效（支持 M L H V C S Q T A Z）"); return }
                path.addPath(result)
            default:
                return
            }
            guard error == nil else { parser.abortParsing(); return }
            shapes.append(Shape(path: path, style: style))
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
            depth -= 1
            if !stack.isEmpty { stack.removeLast() }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { fail(parser, "SVG 背景不支持文字，数字请使用下方显示格式") }
        }

        private func fail(_ parser: XMLParser, _ text: String) {
            if error == nil { error = text }
            parser.abortParsing()
        }

        private func number(_ text: String) -> CGFloat? {
            var value = text.trimmingCharacters(in: .whitespaces).lowercased()
            if value.hasSuffix("px") { value.removeLast(2) }
            guard let n = Double(value), n.isFinite, abs(n) <= 10000 else { return nil }
            return CGFloat(n)
        }

        static func numbers(_ text: String) -> [CGFloat]? {
            let parts = text.split { $0.isWhitespace || $0 == "," }
            guard parts.count <= 2048 else { return nil }
            var values: [CGFloat] = []
            for p in parts { guard let n = Double(p), n.isFinite, abs(n) <= 10000 else { return nil }; values.append(CGFloat(n)) }
            return values
        }
    }

    /// path 的 d：M L H V C S Q T A Z（大小写），数字可紧挨、可省略重复命令。
    static func path(_ text: String) -> CGPath? {
        var tokens: [Character] = Array(text)
        var index = 0
        func skipSeparators() {
            while index < tokens.count, tokens[index].isWhitespace || tokens[index] == "," { index += 1 }
        }
        func readNumber() -> CGFloat? {
            skipSeparators()
            var end = index
            if end < tokens.count, tokens[end] == "+" || tokens[end] == "-" { end += 1 }
            var digits = false, dot = false
            while end < tokens.count {
                let c = tokens[end]
                if c.isNumber { digits = true; end += 1 }
                else if c == ".", !dot { dot = true; end += 1 }
                else { break }
            }
            if digits, end < tokens.count, tokens[end] == "e" || tokens[end] == "E" {
                var exponent = end + 1
                if exponent < tokens.count, tokens[exponent] == "+" || tokens[exponent] == "-" { exponent += 1 }
                var hasExponentDigits = false
                while exponent < tokens.count, tokens[exponent].isNumber { exponent += 1; hasExponentDigits = true }
                if hasExponentDigits { end = exponent }
            }
            guard digits, let value = Double(String(tokens[index..<end])), value.isFinite, abs(value) <= 10000 else { return nil }
            index = end
            return CGFloat(value)
        }
        func readFlag() -> Bool? {
            skipSeparators()
            guard index < tokens.count, tokens[index] == "0" || tokens[index] == "1" else { return nil }
            defer { index += 1 }
            return tokens[index] == "1"
        }
        tokens = tokens.count <= 20_000 ? tokens : []
        guard !tokens.isEmpty else { return nil }
        let path = CGMutablePath()
        var command: Character = " "
        var current = CGPoint.zero, start = CGPoint.zero
        var lastControl: CGPoint?
        var lastCommand: Character = " "
        var segments = 0
        while true {
            skipSeparators()
            if index >= tokens.count { break }
            let c = tokens[index]
            if c.isLetter {
                guard "MmLlHhVvCcSsQqTtAaZz".contains(c) else { return nil }
                command = c
                index += 1
            } else if command == " " || command == "Z" || command == "z" {
                // 没有命令字母、或 Z 后面直接跟数字：无效路径（也避免原地死循环）。
                return nil
            }
            segments += 1
            guard segments <= 4096 else { return nil }
            let relative = command.isLowercase
            let upper: Character = command.isLowercase ? Character(String(command).uppercased()) : command
            if path.isEmpty && upper != "M" { return nil }
            func point() -> CGPoint? {
                guard let x = readNumber(), let y = readNumber() else { return nil }
                return relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
            }
            switch upper {
            case "M":
                guard let p = point() else { return nil }
                path.move(to: p); current = p; start = p
                command = relative ? "l" : "L"
                lastControl = nil
            case "L":
                guard let p = point() else { return nil }
                if path.isEmpty { path.move(to: current) }
                path.addLine(to: p); current = p; lastControl = nil
            case "H":
                guard let x = readNumber() else { return nil }
                current.x = relative ? current.x + x : x
                path.addLine(to: current); lastControl = nil
            case "V":
                guard let y = readNumber() else { return nil }
                current.y = relative ? current.y + y : y
                path.addLine(to: current); lastControl = nil
            case "C":
                guard let c1 = point(), let c2 = point(), let p = point() else { return nil }
                path.addCurve(to: p, control1: c1, control2: c2); lastControl = c2; current = p
            case "S":
                guard let c2 = point(), let p = point() else { return nil }
                let c1 = "CcSs".contains(lastCommand) && lastControl != nil
                    ? CGPoint(x: 2 * current.x - lastControl!.x, y: 2 * current.y - lastControl!.y) : current
                path.addCurve(to: p, control1: c1, control2: c2); lastControl = c2; current = p
            case "Q":
                guard let c1 = point(), let p = point() else { return nil }
                path.addQuadCurve(to: p, control: c1); lastControl = c1; current = p
            case "T":
                guard let p = point() else { return nil }
                let c1 = "QqTt".contains(lastCommand) && lastControl != nil
                    ? CGPoint(x: 2 * current.x - lastControl!.x, y: 2 * current.y - lastControl!.y) : current
                path.addQuadCurve(to: p, control: c1); lastControl = c1; current = p
            case "A":
                guard let rx = readNumber(), let ry = readNumber(), let rotation = readNumber(),
                      let large = readFlag(), let sweep = readFlag(), let p = point() else { return nil }
                addArc(to: path, from: current, to: p, rx: abs(rx), ry: abs(ry), rotation: rotation, large: large, sweep: sweep)
                current = p; lastControl = nil
            case "Z":
                path.closeSubpath(); current = start; lastControl = nil
            default:
                return nil
            }
            lastCommand = command
        }
        return path.isEmpty ? nil : path
    }

    /// SVG 椭圆弧（端点参数）转成中心参数后加到路径上。
    static func addArc(to path: CGMutablePath, from p0: CGPoint, to p1: CGPoint, rx inRx: CGFloat, ry inRy: CGFloat,
                       rotation: CGFloat, large: Bool, sweep: Bool) {
        if p0 == p1 { return }
        var rx = inRx, ry = inRy
        if rx == 0 || ry == 0 { path.addLine(to: p1); return }
        let phi = rotation * .pi / 180
        let cosPhi = cos(phi), sinPhi = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1p = cosPhi * dx + sinPhi * dy
        let y1p = -sinPhi * dx + cosPhi * dy
        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 { rx *= sqrt(lambda); ry *= sqrt(lambda) }
        let numerator = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
        let denominator = rx * rx * y1p * y1p + ry * ry * x1p * x1p
        var factor = denominator == 0 ? 0 : sqrt(max(0, numerator / denominator))
        if large == sweep { factor = -factor }
        let cxp = factor * rx * y1p / ry
        let cyp = -factor * ry * x1p / rx
        let cx = cosPhi * cxp - sinPhi * cyp + (p0.x + p1.x) / 2
        let cy = sinPhi * cxp + cosPhi * cyp + (p0.y + p1.y) / 2
        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let dot = ux * vx + uy * vy
            let length = sqrt(ux * ux + uy * uy) * sqrt(vx * vx + vy * vy)
            var value = acos(min(max(dot / max(length, 1e-9), -1), 1))
            if ux * vy - uy * vx < 0 { value = -value }
            return value
        }
        let theta1 = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
        var delta = angle((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
        if !sweep && delta > 0 { delta -= 2 * .pi }
        if sweep && delta < 0 { delta += 2 * .pi }
        let transform = CGAffineTransform(translationX: cx, y: cy).rotated(by: phi).scaledBy(x: rx, y: ry)
        path.addRelativeArc(center: .zero, radius: 1, startAngle: theta1, delta: delta, transform: transform)
    }
}

// MARK: - 阅读页用的气泡

/// 段落末尾的段评气泡：按选中的样式和设置绘制，并按样式版本缓存。
enum CommentBubble {
    private nonisolated(unsafe) static var cache: [String: UIImage] = [:]
    private static let lock = NSLock()

    static func attachmentBounds(fontSize: CGFloat) -> CGRect {
        BubbleStyleRenderer.bounds(style: BubbleStyleRuntime.snapshot().style, fontSize: fontSize)
    }

    static func image(label: String, fontSize: CGFloat, color: UIColor, sourceImageURL: URL? = nil) -> UIImage {
        let config = BubbleStyleRuntime.snapshot()
        let source = config.preferSource ? sourceImageURL.flatMap(BubbleSourceImageCache.image(for:)) : nil
        let format = UIGraphicsImageRendererFormat.default()
        let key = "v6|\(BubbleStyleRuntime.revision)|\(config.style.id)|\(label)|\(fontSize)|\(color.readerHex)|\(format.scale)|\(source == nil ? "" : sourceImageURL?.absoluteString ?? "")"
        lock.lock()
        if let hit = cache[key] { lock.unlock(); return hit }
        lock.unlock()
        let image = BubbleStyleRenderer.image(style: config.style, label: label, fontSize: fontSize, color: color,
                                              numberScale: config.numberScale, sourceImage: source)
        lock.lock()
        if cache.count >= 256 { cache.removeAll(keepingCapacity: true) }
        cache[key] = image
        lock.unlock()
        return image
    }

    /// 内置「气泡」轮廓：参考图 @3x 描出的路径（坐标 ×10，原点在左下）。
    nonisolated(unsafe) static let outline: CGPath = {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 340, y: 802))
        p.addCurve(to: CGPoint(x: 149, y: 689), control1: CGPoint(x: 253, y: 773), control2: CGPoint(x: 200, y: 742))
        p.addCurve(to: CGPoint(x: 40, y: 350), control1: CGPoint(x: 62, y: 600), control2: CGPoint(x: 19, y: 466))
        p.addCurve(to: CGPoint(x: 115, y: 176), control1: CGPoint(x: 54, y: 273), control2: CGPoint(x: 71, y: 233))
        p.addCurve(to: CGPoint(x: 144, y: 78), control1: CGPoint(x: 148, y: 132), control2: CGPoint(x: 150, y: 126))
        p.addLine(to: CGPoint(x: 137, y: 27))
        p.addLine(to: CGPoint(x: 196, y: 32))
        p.addCurve(to: CGPoint(x: 327, y: 70), control1: CGPoint(x: 231, y: 36), control2: CGPoint(x: 285, y: 51))
        p.addCurve(to: CGPoint(x: 447, y: 90), control1: CGPoint(x: 396, y: 101), control2: CGPoint(x: 402, y: 102))
        p.addCurve(to: CGPoint(x: 765, y: 79), control1: CGPoint(x: 517, y: 72), control2: CGPoint(x: 695, y: 66))
        p.addCurve(to: CGPoint(x: 1043, y: 291), control1: CGPoint(x: 901, y: 104), control2: CGPoint(x: 1010, y: 187))
        p.addCurve(to: CGPoint(x: 1039, y: 555), control1: CGPoint(x: 1067, y: 362), control2: CGPoint(x: 1065, y: 472))
        p.addCurve(to: CGPoint(x: 967, y: 675), control1: CGPoint(x: 1022, y: 610), control2: CGPoint(x: 1008, y: 633))
        p.addCurve(to: CGPoint(x: 540, y: 816), control1: CGPoint(x: 870, y: 772), control2: CGPoint(x: 753, y: 810))
        p.addCurve(to: CGPoint(x: 340, y: 802), control1: CGPoint(x: 419, y: 820), control2: CGPoint(x: 386, y: 817))
        p.closeSubpath()
        p.move(to: CGPoint(x: 702, y: 735))
        p.addCurve(to: CGPoint(x: 923, y: 621), control1: CGPoint(x: 795, y: 716), control2: CGPoint(x: 870, y: 678))
        p.addCurve(to: CGPoint(x: 1000, y: 406), control1: CGPoint(x: 976, y: 564), control2: CGPoint(x: 1000, y: 497))
        p.addCurve(to: CGPoint(x: 840, y: 171), control1: CGPoint(x: 999, y: 299), control2: CGPoint(x: 946, y: 220))
        p.addCurve(to: CGPoint(x: 667, y: 142), control1: CGPoint(x: 793, y: 149), control2: CGPoint(x: 768, y: 145))
        p.addCurve(to: CGPoint(x: 473, y: 156), control1: CGPoint(x: 578, y: 139), control2: CGPoint(x: 531, y: 142))
        p.addCurve(to: CGPoint(x: 371, y: 163), control1: CGPoint(x: 415, y: 169), control2: CGPoint(x: 392, y: 171))
        p.addCurve(to: CGPoint(x: 285, y: 126), control1: CGPoint(x: 357, y: 157), control2: CGPoint(x: 318, y: 140))
        p.addLine(to: CGPoint(x: 225, y: 101))
        p.addLine(to: CGPoint(x: 219, y: 131))
        p.addCurve(to: CGPoint(x: 182, y: 198), control1: CGPoint(x: 215, y: 148), control2: CGPoint(x: 199, y: 178))
        p.addCurve(to: CGPoint(x: 106, y: 400), control1: CGPoint(x: 124, y: 271), control2: CGPoint(x: 106, y: 319))
        p.addCurve(to: CGPoint(x: 186, y: 629), control1: CGPoint(x: 105, y: 498), control2: CGPoint(x: 129, y: 565))
        p.addCurve(to: CGPoint(x: 702, y: 735), control1: CGPoint(x: 291, y: 745), control2: CGPoint(x: 467, y: 781))
        p.closeSubpath()
        return p
    }()
}
