import SwiftUI
import UIKit
import ImageIO

// 段评气泡样式：移植自 joyfange/bookon（BubbleStyle / BubbleSVG / CommentBubble）。
// 默认气泡为参考图描出的轮廓；自定义样式支持模板、SVG、图片三种方式，
// 可调数字格式、颜色、整体大小与宽高比，应用到所有书源的段评气泡。


struct BubbleStyle: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var name = "自定义气泡"
    var mode = "template"
    var template = "bubble"
    var showNumber = true
    var format = "{n}"
    var followText = true
    var colorHex = "#555555"
    var scale = 1.0
    var aspect = 1.0
    var svg = ""
    var imageData: Data?
}

/// One atomic document; draft previews never change the selected runtime style.
final class BubbleStyleStore: ObservableObject {
    nonisolated(unsafe) static let shared = BubbleStyleStore()
    private struct Document: Codable { var styles: [BubbleStyle]; var selectedID: String? }
    private static let key = "reader.bubble.styles.v1"
    @Published private(set) var styles: [BubbleStyle] = []
    @Published private(set) var selectedID: String?
    @Published private(set) var revision = 0
    private let defaults: UserDefaults
    private let runtime: Bool
    init(defaults: UserDefaults = .standard, runtime: Bool = true) {
        self.defaults = defaults; self.runtime = runtime
        if let data = defaults.data(forKey: Self.key), data.count <= 20_000_000,
           let doc = try? JSONDecoder().decode(Document.self, from: data) {
            styles = Array(doc.styles.prefix(30)).filter { Self.validate($0) == nil }
            selectedID = styles.contains { $0.id == doc.selectedID } ? doc.selectedID : nil
        }
        if runtime { BubbleStyleRuntime.set(styles.first { $0.id == selectedID }) }
    }
    static func validate(_ s: BubbleStyle) -> String? {
        if s.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || s.name.count > 40 { return "样式名称须为 1–40 个字符" }
        if !s.scale.isFinite || !(0.6...1.8).contains(s.scale) || !s.aspect.isFinite || !(0.6...2).contains(s.aspect) { return "尺寸超出允许范围" }
        if s.format.count > 16 || s.format.contains("\n") { return "显示格式最多 16 字符且不能换行" }
        if s.colorHex.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) == nil { return "颜色格式无效" }
        switch s.mode {
        case "template": if !["bubble", "candy", "square"].contains(s.template) { return "模板无效" }
        case "svg": return BubbleSVG.validate(s.svg)
        case "image":
            guard let data = s.imageData, data.count <= 2_000_000, let image = UIImage(data: data),
                  image.size.width > 0, image.size.height > 0,
                  image.size.width * image.scale <= 1024, image.size.height * image.scale <= 1024 else { return "请选择有效的 PNG 图片（不超过 1024 像素/2 MB）" }
        default: return "创建方式无效"
        }
        return nil
    }
    func save(_ style: BubbleStyle) throws {
        if let error = Self.validate(style) { throw failure(error) }
        var next = styles
        if let i = next.firstIndex(where: { $0.id == style.id }) { next[i] = style }
        else { guard next.count < 30 else { throw failure("最多保存 30 个样式") }; next.append(style) }
        try persist(next, selected: selectedID)
    }
    func select(_ id: String?) throws {
        guard id == nil || styles.contains(where: { $0.id == id }) else { throw failure("样式不存在") }
        try persist(styles, selected: id)
    }
    func delete(_ id: String) throws {
        try persist(styles.filter { $0.id != id }, selected: selectedID == id ? nil : selectedID)
    }
    private func persist(_ next: [BubbleStyle], selected: String?) throws {
        let data = try JSONEncoder().encode(Document(styles: next, selectedID: selected))
        guard data.count <= 20_000_000 else { throw failure("气泡样式总容量不能超过 20 MB") }
        defaults.set(data, forKey: Self.key)
        styles = next; selectedID = selected
        if runtime { BubbleStyleRuntime.set(next.first { $0.id == selected }) }
        revision += 1
    }
    private func failure(_ text: String) -> NSError { NSError(domain: "BubbleStyle", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
}

/// Layout and prepagination may run off-main; runtime snapshots are lock protected.
enum BubbleStyleRuntime {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var selected: BubbleStyle?
    private nonisolated(unsafe) static var version = 0
    static var revision: Int { lock.lock(); defer { lock.unlock() }; return version }
    static func set(_ style: BubbleStyle?) { lock.lock(); selected = style; version += 1; lock.unlock() }
    static func snapshot() -> BubbleStyle? { lock.lock(); defer { lock.unlock() }; return selected }
}

enum BubbleStyleRenderer {
    static func bounds(style: BubbleStyle, fontSize: CGFloat) -> CGRect {
        let s = max(fontSize, 1) / 23 * CGFloat(style.scale)
        return CGRect(x: 0, y: -4 * s, width: 109 / 3 * s * CGFloat(style.aspect), height: 85 / 3 * s)
    }
    static func image(style: BubbleStyle, count: Int, fontSize: CGFloat, color: UIColor) -> UIImage {
        image(style: style, label: String(max(0, count)), fontSize: fontSize, color: color)
    }
    static func image(style: BubbleStyle, label count: String, fontSize: CGFloat, color: UIColor) -> UIImage {
        let size = bounds(style: style, fontSize: fontSize).size
        let format = UIGraphicsImageRendererFormat(); format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)
            let ink = style.followText ? color : hex(style.colorHex)
            if style.mode == "image", let data = style.imageData, let image = UIImage(data: data) {
                image.draw(in: rect)
            } else if style.mode == "svg" {
                BubbleSVG.draw(style.svg, in: rect, color: ink)
            } else {
                let body = rect.insetBy(dx: rect.width * 0.08, dy: rect.height * 0.09)
                let path = UIBezierPath(roundedRect: body, cornerRadius: style.template == "square" ? 3 : body.height * 0.42)
                if style.template == "candy" {
                    UIColor.white.setFill(); path.fill(); UIColor.black.setStroke()
                    for x in [rect.minX, body.maxX] {
                        let wing = UIBezierPath(); wing.move(to: CGPoint(x: x, y: body.midY - 4))
                        wing.addLine(to: CGPoint(x: x + rect.width * 0.08, y: body.midY))
                        wing.addLine(to: CGPoint(x: x, y: body.midY + 4)); wing.close()
                        UIColor.white.setFill(); wing.fill(); wing.lineWidth = 0.8; wing.stroke()
                    }
                } else { ink.setStroke() }
                path.lineWidth = max(0.8, size.height / 28); path.stroke()
                if style.template != "candy" {
                    let tail = UIBezierPath(); tail.move(to: CGPoint(x: body.minX + 5, y: body.maxY - 2))
                    tail.addLine(to: CGPoint(x: body.minX + 1, y: rect.maxY))
                    tail.addLine(to: CGPoint(x: body.minX + 12, y: body.maxY)); tail.lineWidth = path.lineWidth; tail.stroke()
                }
            }
            if style.showNumber {
                let label = style.format.replacingOccurrences(of: "{n}", with: count)
                let textColor = style.mode == "template" && style.template == "candy" ? UIColor.darkGray : ink
                var fontSize = size.height * 0.38
                let maxWidth = size.width * 0.74
                var attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: fontSize, weight: .semibold), .foregroundColor: textColor]
                let width = (label as NSString).size(withAttributes: attrs).width
                if width > maxWidth { fontSize *= maxWidth / max(width, 1); attrs[.font] = UIFont.systemFont(ofSize: fontSize, weight: .semibold) }
                let measured = (label as NSString).size(withAttributes: attrs)
                (label as NSString).draw(at: CGPoint(x: (size.width - measured.width) / 2, y: (size.height - measured.height) / 2 - 1), withAttributes: attrs)
            }
        }.withRenderingMode(.alwaysOriginal)
    }
    static func hex(_ value: String) -> UIColor {
        let n = UInt32(value.dropFirst(), radix: 16) ?? 0x555555
        return UIColor(red: CGFloat((n >> 16) & 255) / 255, green: CGFloat((n >> 8) & 255) / 255, blue: CGFloat(n & 255) / 255, alpha: 1)
    }
}


/// Static vector backgrounds only: no WebKit, scripts, network, entities or embedded images.
enum BubbleSVG {
    static func validate(_ svg: String) -> String? { parse(svg).error }
    private static func parse(_ svg: String) -> Parser {
        let delegate = Parser()
        guard svg.utf8.count <= 32_768, !svg.isEmpty,
              !svg.contains("<!"), !svg.contains("<?") else {
            delegate.error = "SVG 须小于 32 KB，且不能包含声明、实体或脚本"; return delegate
        }
        let parser = XMLParser(data: Data(svg.utf8)); parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        if !parser.parse(), delegate.error == nil { delegate.error = "SVG XML 格式无效" }
        if delegate.viewBox == nil { delegate.error = "请提供有效的 SVG viewBox" }
        return delegate
    }
    static func draw(_ svg: String, in rect: CGRect, color: UIColor) {
        let parsed = parse(svg)
        guard parsed.error == nil, let box = parsed.viewBox, let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.saveGState(); defer { ctx.restoreGState() }
        ctx.clip(to: rect); ctx.translateBy(x: rect.minX, y: rect.minY)
        ctx.scaleBy(x: rect.width / box.width, y: rect.height / box.height)
        ctx.translateBy(x: -box.minX, y: -box.minY)
        for shape in parsed.shapes {
            ctx.saveGState(); ctx.setAlpha(shape.opacity)
            if let fill = paint(shape.fill, current: color) {
                ctx.addPath(shape.path.cgPath); ctx.setFillColor(fill.cgColor); ctx.drawPath(using: .fill)
            }
            if let stroke = paint(shape.stroke, current: color) {
                ctx.addPath(shape.path.cgPath); ctx.setStrokeColor(stroke.cgColor); ctx.setLineWidth(shape.width); ctx.strokePath()
            }
            ctx.restoreGState()
        }
    }
    private static func paint(_ value: String, current: UIColor) -> UIColor? {
        switch value { case "none": return nil; case "currentColor": return current
        case "black": return .black; case "white": return .white; case "red": return .red
        case "gray": return .gray; default: return BubbleStyleRenderer.hex(value) }
    }
    private struct Shape { var path: UIBezierPath; var fill: String; var stroke: String; var width: CGFloat; var opacity: CGFloat }
    private final class Parser: NSObject, XMLParserDelegate {
        var error: String?
        var viewBox: CGRect?
        var shapes: [Shape] = []
        var depth = 0
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String]) {
            guard error == nil else { parser.abortParsing(); return }
            depth += 1
            guard depth <= 2, shapes.count < 128 else { fail(parser, "SVG 最多 128 个图形，仅支持根节点下的静态图形"); return }
            let allowed: [String: Set<String>] = [
                "svg": ["xmlns", "viewBox", "width", "height"],
                "rect": ["x", "y", "width", "height", "rx"], "circle": ["cx", "cy", "r"],
                "ellipse": ["cx", "cy", "rx", "ry"], "line": ["x1", "y1", "x2", "y2"],
                "polygon": ["points"], "polyline": ["points"], "path": ["d"]]
            guard let attrs = allowed[name], (depth == 1) == (name == "svg") else { fail(parser, "不支持 SVG 元素：\(name)"); return }
            let style: Set<String> = name == "svg" ? [] : ["fill", "stroke", "stroke-width", "opacity"]
            guard Set(a.keys).isSubset(of: attrs.union(style)) else { fail(parser, "SVG 含未支持属性（不支持样式表、变换或外链）"); return }
            func number(_ key: String, _ fallback: CGFloat = 0) -> CGFloat {
                guard let raw = a[key] else { return fallback }
                guard let n = Double(raw), n.isFinite, abs(n) <= 10000 else { self.error = "SVG 数值无效"; return 0 }
                return CGFloat(n)
            }
            if name == "svg" {
                let nums = Self.numbers(a["viewBox"] ?? "0 0 \(a["width"] ?? "") \(a["height"] ?? "")")
                guard let n = nums, n.count == 4, n[2] > 0, n[3] > 0 else { fail(parser, "SVG 需要有效 viewBox 或宽高"); return }
                viewBox = CGRect(x: n[0], y: n[1], width: n[2], height: n[3]); return
            }
            let fill = a["fill"] ?? "black", stroke = a["stroke"] ?? "none"
            for value in [fill, stroke] {
                if !["none", "currentColor", "black", "white", "red", "gray"].contains(value), value.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) == nil { fail(parser, "SVG 颜色请用 #RRGGBB、currentColor 或基本颜色名"); return }
            }
            var path = UIBezierPath()
            switch name {
            case "rect":
                let w = number("width"), h = number("height")
                guard w > 0, h > 0 else { fail(parser, "矩形宽高须大于零"); return }
                path = UIBezierPath(roundedRect: CGRect(x: number("x"), y: number("y"), width: w, height: h), cornerRadius: max(0, number("rx")))
            case "circle", "ellipse":
                let rx = number(name == "circle" ? "r" : "rx"), ry = number(name == "circle" ? "r" : "ry")
                guard rx > 0, ry > 0 else { fail(parser, "圆半径须大于零"); return }
                path = UIBezierPath(ovalIn: CGRect(x: number("cx") - rx, y: number("cy") - ry, width: 2 * rx, height: 2 * ry))
            case "line": path.move(to: CGPoint(x: number("x1"), y: number("y1"))); path.addLine(to: CGPoint(x: number("x2"), y: number("y2")))
            case "polygon", "polyline":
                guard let n = Self.numbers(a["points"] ?? ""), n.count >= 4, n.count % 2 == 0 else { fail(parser, "SVG points 无效"); return }
                path.move(to: CGPoint(x: n[0], y: n[1]))
                for i in stride(from: 2, to: n.count, by: 2) { path.addLine(to: CGPoint(x: n[i], y: n[i + 1])) }
                if name == "polygon" { path.close() }
            case "path":
                guard let result = BubbleSVG.path(a["d"] ?? "") else { fail(parser, "路径仅支持 M/L/H/V/C/Q/Z 命令，请展开其他命令后导入"); return }; path = result
            default: break
            }
            let width = number("stroke-width", 1), opacity = number("opacity", 1)
            guard error == nil, width >= 0, (0...1).contains(opacity) else { fail(parser, "SVG 线宽或透明度无效"); return }
            shapes.append(Shape(path: path, fill: fill, stroke: stroke, width: width, opacity: opacity))
        }
        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) { depth -= 1 }
        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { fail(parser, "SVG 背景不支持文字，数字请使用下方显示格式") }
        }
        private func fail(_ parser: XMLParser, _ text: String) { error = text; parser.abortParsing() }
        static func numbers(_ text: String) -> [CGFloat]? {
            let parts = text.split { $0.isWhitespace || $0 == "," }
            guard parts.count <= 2048 else { return nil }
            var values: [CGFloat] = []
            for p in parts { guard let n = Double(p), n.isFinite, abs(n) <= 10000 else { return nil }; values.append(CGFloat(n)) }
            return values
        }
    }
    private static func path(_ text: String) -> UIBezierPath? {
        guard let re = try? NSRegularExpression(pattern: "[MmLlHhVvCcQqZz]|[-+]?(?:[0-9]*\\.[0-9]+|[0-9]+\\.?[0-9]*)(?:[eE][-+]?[0-9]+)?") else { return nil }
        let ns = text as NSString
        let matches = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard matches.count <= 2048 else { return nil }
        var end = 0, tokens: [String] = []
        for m in matches {
            let gap = ns.substring(with: NSRange(location: end, length: m.range.location - end))
            guard gap.allSatisfy({ $0.isWhitespace || $0 == "," }) else { return nil }
            tokens.append(ns.substring(with: m.range)); end = m.range.location + m.range.length
        }
        guard ns.substring(from: end).allSatisfy({ $0.isWhitespace || $0 == "," }), tokens.first?.uppercased() == "M" else { return nil }
        let p = UIBezierPath(); var i = 0, command = "", point = CGPoint.zero, start = CGPoint.zero
        while i < tokens.count {
            if tokens[i].first?.isLetter == true { command = tokens[i]; i += 1 }
            let upper = command.uppercased(), relative = command != upper
            if upper == "Z" { p.close(); point = start; command = ""; continue }
            let sizes = ["M": 2, "L": 2, "H": 1, "V": 1, "C": 6, "Q": 4]
            guard let count = sizes[upper], i + count <= tokens.count else { return nil }
            var n: [CGFloat] = []
            for k in 0..<count { guard let v = Double(tokens[i + k]), v.isFinite, abs(v) <= 10000 else { return nil }; n.append(CGFloat(v)) }
            i += count
            func xy(_ k: Int) -> CGPoint { CGPoint(x: n[k] + (relative ? point.x : 0), y: n[k + 1] + (relative ? point.y : 0)) }
            switch upper {
            case "M": point = xy(0); start = point; p.move(to: point); command = relative ? "l" : "L"
            case "L": point = xy(0); p.addLine(to: point)
            case "H": point.x = n[0] + (relative ? point.x : 0); p.addLine(to: point)
            case "V": point.y = n[0] + (relative ? point.y : 0); p.addLine(to: point)
            case "C": let a = xy(0), b = xy(2), c = xy(4); p.addCurve(to: c, controlPoint1: a, controlPoint2: b); point = c
            case "Q": let a = xy(0), b = xy(2); p.addQuadCurve(to: b, controlPoint: a); point = b
            default: return nil
            }
            guard abs(point.x) <= 10000, abs(point.y) <= 10000 else { return nil }
        }
        return p
    }
}


/// 未选自定义样式时的默认气泡（参考 23pt 正文 @3x，109x85px 画布）。
enum CommentBubble {
    private nonisolated(unsafe) static var cache: [String: UIImage] = [:]
    private static let lock = NSLock()

    static func attachmentBounds(fontSize: CGFloat) -> CGRect {
        if let style = BubbleStyleRuntime.snapshot() { return BubbleStyleRenderer.bounds(style: style, fontSize: fontSize) }
        let scale = max(fontSize, 1) / 23
        return CGRect(x: 0, y: -4 * scale, width: 109 / 3 * scale, height: 85 / 3 * scale)
    }

    static func image(label: String, fontSize: CGFloat, color: UIColor) -> UIImage {
        if let style = BubbleStyleRuntime.snapshot() { return BubbleStyleRenderer.image(style: style, label: label, fontSize: fontSize, color: color) }
        let scale = max(fontSize, 1) / 23
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = false
        let key = "ref590-v1|\(label)|\(fontSize)|\(color.readerHex)|\(format.scale)"
        lock.lock()
        if let hit = cache[key] { lock.unlock(); return hit }
        lock.unlock()
        let canvas = CGSize(width: 109 / 3 * scale, height: 85 / 3 * scale)
        let img = UIGraphicsImageRenderer(size: canvas, format: format).image { renderer in
            let context = renderer.cgContext
            context.saveGState()
            context.translateBy(x: 0, y: canvas.height)
            context.scaleBy(x: scale / 30, y: -scale / 30)
            context.addPath(outline)
            context.setFillColor(color.cgColor)
            context.drawPath(using: .eoFill)
            context.restoreGState()
            var font = UIFont.systemFont(ofSize: 10.8 * scale, weight: .semibold)
            var text = NSAttributedString(string: label, attributes: [.font: font, .foregroundColor: color])
            let maxWidth = 80 / 3 * scale
            if text.size().width > maxWidth {
                font = font.withSize(font.pointSize * maxWidth / text.size().width)
                text = NSAttributedString(string: label, attributes: [.font: font, .foregroundColor: color])
            }
            let line = CTLineCreateWithAttributedString(text)
            let ink = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
            context.saveGState()
            context.translateBy(x: 0, y: canvas.height)
            context.scaleBy(x: 1, y: -1)
            context.textMatrix = .identity
            let center = CGPoint(x: 54.5 / 3 * scale, y: canvas.height - 42 / 3 * scale)
            context.textPosition = CGPoint(x: center.x - ink.midX, y: center.y - ink.midY)
            CTLineDraw(line, context)
            context.restoreGState()
        }.withRenderingMode(.alwaysOriginal)
        lock.lock()
        if cache.count >= 128 { cache.removeAll(keepingCapacity: true) }
        cache[key] = img
        lock.unlock()
        return img
    }

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
