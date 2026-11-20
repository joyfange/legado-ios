import CoreText
import SwiftUI
import UIKit

// MARK: - 正则高亮：规则

/// 一条正则高亮规则。内置规则（常用引号）名称和正则固定，只能开关、改颜色和样式；
/// 自定义规则排在内置规则之后，后面的规则覆盖前面的（同一段文字同时命中时以后者为准）。
struct ReaderHighlightRule: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var pattern: String
    var builtIn: Bool = false
    var enabled: Bool = true
    /// 颜色选择器：CSS 没写 color 时用作文字颜色（RRGGBB）。
    var lightColor: String = "FF9500"
    var darkColor: String = "FFB340"
    /// nil 跟随阅读字体；"system" 系统、"serif" 宋体、"rounded" 圆体、"mono" 等宽；其它为导入字体文件名。
    var fontName: String? = nil
    var fontSize: Double? = nil
    /// 1…9 对应 100…900。
    var fontWeight: Int? = nil
    var noCrossParagraph: Bool = true
    var pageCompensation: Bool = true
    var lightCSS: String = ""
    var darkCSS: String = ""
    var lightImage: String? = nil
    var darkImage: String? = nil
    var sliceEnabled: Bool = false
    /// 9-Slice 拉伸时四边不拉伸的部分，占图片宽 / 高的比例（0…0.49）。
    var sliceTop: Double = 0.3
    var sliceLeft: Double = 0.3
    var sliceBottom: Double = 0.3
    var sliceRight: Double = 0.3
    /// 文字边距：高亮背景比文字向外多出的距离，只改变背景外观，不影响分页。
    var paddingHorizontal: Double = 0
    var paddingVertical: Double = 0

    init(id: String, name: String, pattern: String, builtIn: Bool = false, enabled: Bool = true,
         lightColor: String = "FF9500", darkColor: String = "FFB340") {
        self.id = id
        self.name = name
        self.pattern = pattern
        self.builtIn = builtIn
        self.enabled = enabled
        self.lightColor = lightColor
        self.darkColor = darkColor
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, pattern, builtIn, enabled, lightColor, darkColor, fontName, fontSize, fontWeight
        case noCrossParagraph, pageCompensation, lightCSS, darkCSS, lightImage, darkImage
        case sliceEnabled, sliceTop, sliceLeft, sliceBottom, sliceRight, paddingHorizontal, paddingVertical
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? "规则"
        pattern = (try? c.decodeIfPresent(String.self, forKey: .pattern)) ?? ""
        builtIn = (try? c.decodeIfPresent(Bool.self, forKey: .builtIn)) ?? false
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? true
        lightColor = (try? c.decodeIfPresent(String.self, forKey: .lightColor)) ?? "FF9500"
        darkColor = (try? c.decodeIfPresent(String.self, forKey: .darkColor)) ?? "FFB340"
        fontName = try? c.decodeIfPresent(String.self, forKey: .fontName)
        fontSize = try? c.decodeIfPresent(Double.self, forKey: .fontSize)
        fontWeight = try? c.decodeIfPresent(Int.self, forKey: .fontWeight)
        noCrossParagraph = (try? c.decodeIfPresent(Bool.self, forKey: .noCrossParagraph)) ?? true
        pageCompensation = (try? c.decodeIfPresent(Bool.self, forKey: .pageCompensation)) ?? true
        lightCSS = (try? c.decodeIfPresent(String.self, forKey: .lightCSS)) ?? ""
        darkCSS = (try? c.decodeIfPresent(String.self, forKey: .darkCSS)) ?? ""
        lightImage = try? c.decodeIfPresent(String.self, forKey: .lightImage)
        darkImage = try? c.decodeIfPresent(String.self, forKey: .darkImage)
        sliceEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .sliceEnabled)) ?? false
        sliceTop = (try? c.decodeIfPresent(Double.self, forKey: .sliceTop)) ?? 0.3
        sliceLeft = (try? c.decodeIfPresent(Double.self, forKey: .sliceLeft)) ?? 0.3
        sliceBottom = (try? c.decodeIfPresent(Double.self, forKey: .sliceBottom)) ?? 0.3
        sliceRight = (try? c.decodeIfPresent(Double.self, forKey: .sliceRight)) ?? 0.3
        paddingHorizontal = (try? c.decodeIfPresent(Double.self, forKey: .paddingHorizontal)) ?? 0
        paddingVertical = (try? c.decodeIfPresent(Double.self, forKey: .paddingVertical)) ?? 0
    }

    /// 内置规则的开、闭引号（用于「跨页补偿」：引号没闭合时高亮到段尾）。
    var quotePair: (open: String, close: String)? {
        if let pair = ReaderHighlightRule.builtInQuotes[id] { return pair }
        // 从内置规则复制来、正则没改过的自定义规则（形如 “[^“”\n]*”）同样适用。
        let characters = Array(pattern)
        guard characters.count == 10, characters[1] == "[", characters[2] == "^", characters[0] == characters[3],
              characters[4] == characters[9], characters[5] == "\\", characters[6] == "n", characters[7] == "]",
              characters[8] == "*", characters[0] != characters[9] else { return nil }
        return (String(characters[0]), String(characters[9]))
    }

    var regexError: String? {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "正则不能为空" }
        do { _ = try NSRegularExpression(pattern: pattern) } catch { return "正则无效" }
        return nil
    }

    static let builtInQuotes: [String: (open: String, close: String)] = [
        "builtin.double": ("“", "”"),
        "builtin.single": ("‘", "’"),
        "builtin.corner": ("「", "」"),
        "builtin.whiteCorner": ("『", "』"),
        "builtin.lenticular": ("【", "】")
    ]

    static func builtInRule(_ id: String, _ name: String, enabled: Bool = true, light: String, dark: String) -> ReaderHighlightRule {
        let pair = builtInQuotes[id] ?? ("“", "”")
        return ReaderHighlightRule(id: id, name: name, pattern: "\(pair.open)[^\(pair.open)\(pair.close)\\n]*\(pair.close)",
                                   builtIn: true, enabled: enabled, lightColor: light, darkColor: dark)
    }

    static let builtIns: [ReaderHighlightRule] = [
        builtInRule("builtin.double", "“对话”", light: "F08A00", dark: "FFB340"),
        builtInRule("builtin.single", "‘对话’", light: "1E7BEF", dark: "64A8FF"),
        builtInRule("builtin.corner", "「对话」", light: "2DAF4F", dark: "5DD47E"),
        builtInRule("builtin.whiteCorner", "『对话』", light: "A64FD6", dark: "C77DEB"),
        builtInRule("builtin.lenticular", "【提示】", enabled: false, light: "E5483D", dark: "FF6961")
    ]

    static func defaultBuiltIn(_ id: String) -> ReaderHighlightRule? { builtIns.first { $0.id == id } }
}

// MARK: - 正则高亮：存储

@MainActor
final class ReaderHighlightStore: ObservableObject {
    static let shared = ReaderHighlightStore()
    static let storageKey = "readerRegexHighlight.v1"
    static let maximumCustom = 60

    @Published private(set) var enabled: Bool = true
    @Published private(set) var rules: [ReaderHighlightRule] = []
    /// 每次改动加一：阅读页据此重新排版。
    @Published private(set) var revision = 0

    private struct Snapshot: Codable {
        var version = 1
        var enabled: Bool
        var rules: [ReaderHighlightRule]

        init(enabled: Bool, rules: [ReaderHighlightRule]) {
            self.enabled = enabled
            self.rules = rules
        }

        /// 旧版本或部分损坏的存档：缺字段取默认值，单条坏规则跳过，不让整份规则丢失。
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? 1
            enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? true
            rules = ((try? c.decodeIfPresent([LossyRule].self, forKey: .rules)) ?? []).compactMap(\.rule)
        }

        private enum CodingKeys: String, CodingKey { case version, enabled, rules }
    }

    private struct LossyRule: Decodable {
        let rule: ReaderHighlightRule?
        init(from decoder: Decoder) throws { rule = try? ReaderHighlightRule(from: decoder) }
    }

    /// 导出 / 导入的规则文件。
    struct ExportFile: Codable {
        var format = "legado.ios.highlightRules"
        var version = 1
        var rules: [ReaderHighlightRule]
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var storedEnabled = true
        var stored: [ReaderHighlightRule] = []
        if let data = defaults.data(forKey: Self.storageKey),
           let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) {
            storedEnabled = snapshot.enabled
            stored = snapshot.rules
        }
        enabled = storedEnabled
        rules = Self.merge(stored)
    }

    var builtInRules: [ReaderHighlightRule] { rules.filter(\.builtIn) }
    var customRules: [ReaderHighlightRule] { rules.filter { !$0.builtIn } }
    var enabledCount: Int { rules.filter(\.enabled).count }

    /// 内置规则名称、正则固定：存档里的旧值一律用当前定义覆盖；未知的内置规则丢弃。
    private static func merge(_ stored: [ReaderHighlightRule]) -> [ReaderHighlightRule] {
        var result: [ReaderHighlightRule] = []
        for definition in ReaderHighlightRule.builtIns {
            if var saved = stored.first(where: { $0.id == definition.id }) {
                saved.name = definition.name
                saved.pattern = definition.pattern
                saved.builtIn = true
                result.append(saved)
            } else {
                result.append(definition)
            }
        }
        var seen = Set(result.map(\.id))
        for rule in stored where !rule.builtIn && seen.insert(rule.id).inserted {
            result.append(rule)
        }
        return result
    }

    func rule(id: String) -> ReaderHighlightRule? { rules.first { $0.id == id } }

    /// 整体替换开关和规则（测试用；内置规则的名称、正则仍以当前定义为准）。
    func restoreForTesting(enabled: Bool, rules: [ReaderHighlightRule]) {
        self.enabled = enabled
        self.rules = Self.merge(rules)
        persist()
    }

    func setEnabled(_ value: Bool) {
        guard enabled != value else { return }
        enabled = value
        persist()
    }

    func setRuleEnabled(_ id: String, _ value: Bool) {
        guard let index = rules.firstIndex(where: { $0.id == id }), rules[index].enabled != value else { return }
        rules[index].enabled = value
        persist()
    }

    /// 保存（新建或替换）一条规则。内置规则的名称和正则不会被改。
    func save(_ rule: ReaderHighlightRule) {
        var value = rule
        if let index = rules.firstIndex(where: { $0.id == value.id }) {
            if rules[index].builtIn, let definition = ReaderHighlightRule.defaultBuiltIn(value.id) {
                value.name = definition.name
                value.pattern = definition.pattern
                value.builtIn = true
            }
            rules[index] = value
        } else {
            guard customRules.count < Self.maximumCustom else { return }
            value.builtIn = false
            rules.append(value)
        }
        persist()
    }

    /// 新建的自定义规则先带上一个能用的正则（中文双引号对话），保存、预览、CSS 预设立刻有效果；用户再按需要改。
    static let defaultCustomPattern = "“[^“”\\n]*”"

    func newCustomRule() -> ReaderHighlightRule {
        ReaderHighlightRule(id: "custom." + UUID().uuidString.lowercased(),
                            name: "自定义规则\(customRules.count + 1)", pattern: Self.defaultCustomPattern, builtIn: false,
                            lightColor: "E5483D", darkColor: "FF6961")
    }

    /// 复制一份为自定义规则（内置规则要改匹配方式时用）。
    @discardableResult
    func duplicate(_ rule: ReaderHighlightRule) -> ReaderHighlightRule? {
        guard customRules.count < Self.maximumCustom else { return nil }
        var copy = rule
        copy.id = "custom." + UUID().uuidString.lowercased()
        copy.builtIn = false
        copy.name = String((rule.name + " 副本").prefix(30))
        copy.lightImage = ReaderHighlightImageStore.copy(rule.lightImage)
        copy.darkImage = ReaderHighlightImageStore.copy(rule.darkImage)
        rules.append(copy)
        persist()
        return copy
    }

    func delete(_ id: String) {
        guard let index = rules.firstIndex(where: { $0.id == id }), !rules[index].builtIn else { return }
        let removed = rules.remove(at: index)
        ReaderHighlightImageStore.remove(removed.lightImage)
        ReaderHighlightImageStore.remove(removed.darkImage)
        persist()
    }

    func moveCustom(from source: IndexSet, to destination: Int) {
        var custom = customRules
        custom.move(fromOffsets: source, toOffset: destination)
        rules = builtInRules + custom
        persist()
    }

    func resetBuiltIn(_ id: String) {
        guard let index = rules.firstIndex(where: { $0.id == id }),
              let definition = ReaderHighlightRule.defaultBuiltIn(id) else { return }
        ReaderHighlightImageStore.remove(rules[index].lightImage)
        ReaderHighlightImageStore.remove(rules[index].darkImage)
        rules[index] = definition
        persist()
    }

    func resetAllBuiltIns() {
        for definition in ReaderHighlightRule.builtIns { resetBuiltIn(definition.id) }
        if !enabled { enabled = true; persist() }
    }

    func exportData() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(ExportFile(rules: customRules.map { rule in
            var value = rule
            value.lightImage = nil
            value.darkImage = nil
            return value
        }))
    }

    /// 导入规则文件：接受本应用导出的文件，或直接是规则数组；返回导入条数。
    func importRules(_ data: Data) throws -> Int {
        let decoder = JSONDecoder()
        let incoming: [ReaderHighlightRule]
        if let file = try? decoder.decode(ExportFile.self, from: data) {
            incoming = file.rules
        } else {
            incoming = try decoder.decode([ReaderHighlightRule].self, from: data)
        }
        var count = 0
        for var rule in incoming where rule.regexError == nil {
            guard customRules.count < Self.maximumCustom else { break }
            rule.id = "custom." + UUID().uuidString.lowercased()
            rule.builtIn = false
            rule.lightImage = nil
            rule.darkImage = nil
            if rule.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { rule.name = "导入的规则" }
            rules.append(rule)
            count += 1
        }
        if count > 0 { persist() }
        return count
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(Snapshot(enabled: enabled, rules: rules)) {
            defaults.set(data, forKey: Self.storageKey)
        }
        revision &+= 1
    }
}

// MARK: - 正则高亮：图片

/// 规则的背景图存在 Application Support/Legado/highlight 下，按文件名引用。
enum ReaderHighlightImageStore {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Legado/highlight", isDirectory: true)
    }

    nonisolated(unsafe) private static let cache = NSCache<NSString, UIImage>()

    static func save(_ data: Data) throws -> String {
        guard let image = UIImage(data: data) else { throw CocoaError(.fileReadCorruptFile) }
        let maxSide: CGFloat = 600
        let scale = min(1, maxSide / max(image.size.width, image.size.height, 1))
        let size = CGSize(width: max(1, image.size.width * scale), height: max(1, image.size.height * scale))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = false
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let png = resized.pngData() else { throw CocoaError(.fileWriteUnknown) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = UUID().uuidString.lowercased() + ".png"
        try png.write(to: directory.appendingPathComponent(name), options: .atomic)
        return name
    }

    static func image(_ name: String?) -> UIImage? {
        guard let name, !name.isEmpty, !name.contains("/") else { return nil }
        if let cached = cache.object(forKey: name as NSString) { return cached }
        guard let image = UIImage(contentsOfFile: directory.appendingPathComponent(name).path) else { return nil }
        cache.setObject(image, forKey: name as NSString)
        return image
    }

    static func copy(_ name: String?) -> String? {
        guard let name, let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else { return nil }
        return try? save(data)
    }

    static func remove(_ name: String?) {
        guard let name, !name.isEmpty, !name.contains("/") else { return }
        cache.removeObject(forKey: name as NSString)
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
    }
}

// MARK: - 正则高亮：CSS

/// 高级 CSS 支持的子集：color、background、background-color、border-radius、text-decoration 及其分项。
struct ReaderHighlightCSS: Equatable {
    enum Paint: Equatable {
        case color(UIColor)
        case gradient(angle: CGFloat, colors: [UIColor])
        case current
    }

    enum DecorationStyle: String { case solid, double, dotted, dashed, wavy }

    var color: Paint?
    var background: Paint?
    var radius: CGFloat?
    var underline = false
    var lineThrough = false
    var decorationNone = false
    var decorationStyle: DecorationStyle = .solid
    var decorationColor: Paint?
    var warnings: [String] = []

    var isEmpty: Bool {
        color == nil && background == nil && radius == nil && !underline && !lineThrough
    }

    static func parse(_ source: String) -> ReaderHighlightCSS {
        var css = ReaderHighlightCSS()
        var text = source
        while let start = text.range(of: "/*") {
            if let end = text.range(of: "*/", range: start.upperBound..<text.endIndex) {
                text.removeSubrange(start.lowerBound..<end.upperBound)
            } else {
                text.removeSubrange(start.lowerBound..<text.endIndex)
            }
        }
        if let open = text.firstIndex(of: "{") {
            let afterOpen = text.index(after: open)
            let close = text[afterOpen...].lastIndex(of: "}") ?? text.endIndex
            text = String(text[afterOpen..<close])
        }
        for declaration in split(text, by: ";") {
            let trimmed = declaration.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard let colon = trimmed.firstIndex(of: ":") else {
                css.warnings.append("无法识别：\(trimmed)")
                continue
            }
            let property = trimmed[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            var value = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if value.lowercased().hasSuffix("!important") {
                value = String(value.dropLast(10)).trimmingCharacters(in: .whitespaces)
            }
            switch property {
            case "color":
                if let parsed = paint(value) { css.color = parsed } else { css.warnings.append("color 的值无效：\(value)") }
            case "background", "background-color":
                if value.lowercased() == "none" {
                    css.background = .color(.clear)
                } else if let parsed = paint(value) {
                    css.background = parsed
                } else {
                    css.warnings.append("\(property) 的值无效：\(value)")
                }
            case "border-radius":
                if let number = Self.length(value) { css.radius = number } else { css.warnings.append("border-radius 只支持 px：\(value)") }
            case "text-decoration":
                css.applyDecoration(value)
            case "text-decoration-line":
                css.applyDecoration(value, onlyLines: true)
            case "text-decoration-style":
                if let style = DecorationStyle(rawValue: value.lowercased()) { css.decorationStyle = style }
                else { css.warnings.append("text-decoration-style 不支持：\(value)") }
            case "text-decoration-color":
                if let parsed = paint(value), isGradient(parsed) {
                    css.warnings.append("text-decoration-color 不支持渐变")
                } else if let parsed = paint(value) {
                    css.decorationColor = parsed
                } else {
                    css.warnings.append("text-decoration-color 的值无效：\(value)")
                }
            default:
                css.warnings.append("不支持的属性：\(property)")
            }
        }
        return css
    }

    private mutating func applyDecoration(_ value: String, onlyLines: Bool = false) {
        for token in Self.split(value, by: " ") {
            let word = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty else { continue }
            switch word.lowercased() {
            case "underline": underline = true; decorationNone = false
            case "line-through": lineThrough = true; decorationNone = false
            case "none": underline = false; lineThrough = false; decorationNone = true
            case "overline": warnings.append("不支持 overline")
            case "solid", "double", "dotted", "dashed", "wavy":
                if onlyLines { warnings.append("text-decoration-line 不能写样式：\(word)") }
                else { decorationStyle = DecorationStyle(rawValue: word.lowercased()) ?? .solid }
            default:
                if !onlyLines, let parsed = Self.paint(word), !Self.isGradient(parsed) {
                    decorationColor = parsed
                } else {
                    warnings.append("text-decoration 无法识别：\(word)")
                }
            }
        }
    }

    private static func isGradient(_ paint: Paint) -> Bool {
        if case .gradient = paint { return true }
        return false
    }

    /// 按分隔符切开，括号里的不切。
    static func split(_ text: String, by separator: Character) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        for character in text {
            if character == "(" { depth += 1 }
            if character == ")" { depth = max(0, depth - 1) }
            if depth == 0 && (character == separator || (separator == " " && (character == "\n" || character == "\t"))) {
                if !current.isEmpty { parts.append(current) }
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    static func length(_ value: String) -> CGFloat? {
        var text = value.lowercased().trimmingCharacters(in: .whitespaces)
        if let first = split(text, by: " ").first { text = first }
        for suffix in ["px", "pt"] where text.hasSuffix(suffix) { text.removeLast(2) }
        guard let number = Double(text), number >= 0 else { return nil }
        return CGFloat(number)
    }

    static func paint(_ raw: String) -> Paint? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = value.lowercased()
        if lower == "currentcolor" { return .current }
        if lower.hasPrefix("linear-gradient(") && lower.hasSuffix(")") {
            let inner = String(value.dropFirst("linear-gradient(".count).dropLast())
            var arguments = split(inner, by: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            var angle: CGFloat = 180
            if let first = arguments.first?.lowercased() {
                if first.hasSuffix("deg"), let degrees = Double(first.dropLast(3).trimmingCharacters(in: .whitespaces)) {
                    angle = CGFloat(degrees)
                    arguments.removeFirst()
                } else if first.hasPrefix("to ") {
                    switch first {
                    case "to right": angle = 90
                    case "to left": angle = 270
                    case "to top": angle = 0
                    default: angle = 180
                    }
                    arguments.removeFirst()
                }
            }
            let colors = arguments.compactMap { argument -> UIColor? in
                // 颜色后面可以跟位置（如 rgba(…) 30%），只取颜色。
                guard let token = split(argument, by: " ").first else { return nil }
                return color(token)
            }
            guard colors.count >= 2 else { return colors.first.map { .color($0) } }
            return .gradient(angle: angle, colors: colors)
        }
        return color(value).map { .color($0) }
    }

    static func color(_ raw: String) -> UIColor? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value == "transparent" { return .clear }
        if value.hasPrefix("#") {
            let hex = String(value.dropFirst())
            guard hex.allSatisfy(\.isHexDigit) else { return nil }
            func component(_ text: Substring) -> CGFloat { CGFloat(Int(text, radix: 16) ?? 0) / 255 }
            var digits = hex
            if digits.count == 3 || digits.count == 4 { digits = digits.map { "\($0)\($0)" }.joined() }
            guard digits.count == 6 || digits.count == 8 else { return nil }
            let chars = Array(digits)
            let r = component(Substring(String(chars[0...1])))
            let g = component(Substring(String(chars[2...3])))
            let b = component(Substring(String(chars[4...5])))
            let a = digits.count == 8 ? component(Substring(String(chars[6...7]))) : 1
            return UIColor(red: r, green: g, blue: b, alpha: a)
        }
        if value.hasPrefix("rgb"), let open = value.firstIndex(of: "("), value.hasSuffix(")") {
            let inner = value[value.index(after: open)..<value.index(before: value.endIndex)]
            let parts = inner.replacingOccurrences(of: "/", with: ",")
                .split(whereSeparator: { $0 == "," || $0 == " " })
                .map { String($0) }
            guard parts.count == 3 || parts.count == 4 else { return nil }
            func channel(_ text: String) -> CGFloat? {
                if text.hasSuffix("%"), let number = Double(text.dropLast()) { return CGFloat(number / 100) }
                guard let number = Double(text) else { return nil }
                return CGFloat(number / 255)
            }
            guard let r = channel(parts[0]), let g = channel(parts[1]), let b = channel(parts[2]) else { return nil }
            var alpha: CGFloat = 1
            if parts.count == 4 {
                if parts[3].hasSuffix("%"), let number = Double(parts[3].dropLast()) { alpha = CGFloat(number / 100) }
                else if let number = Double(parts[3]) { alpha = CGFloat(number) }
                else { return nil }
            }
            return UIColor(red: min(max(r, 0), 1), green: min(max(g, 0), 1), blue: min(max(b, 0), 1), alpha: min(max(alpha, 0), 1))
        }
        let named: [String: UInt32] = [
            "white": 0xFFFFFF, "black": 0x000000, "red": 0xFF0000, "orange": 0xFFA500, "yellow": 0xFFFF00,
            "green": 0x008000, "blue": 0x0000FF, "purple": 0x800080, "gray": 0x808080, "grey": 0x808080,
            "pink": 0xFFC0CB, "gold": 0xFFD700, "brown": 0xA52A2A
        ]
        if let hex = named[value] {
            return UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        return nil
    }
}

/// 「CSS 预设」：点选后覆盖浅色 CSS 和深色 CSS。
struct ReaderHighlightCSSPreset: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let icon: String
    let light: String
    let dark: String

    static let all: [ReaderHighlightCSSPreset] = [
        .init(id: "soft", title: "柔和标记", subtitle: "保留颜色选择器文字色，只加柔和渐变底色", icon: "highlighter",
              light: "background: linear-gradient(90deg, rgba(255, 217, 61, .58), rgba(0, 194, 255, .30));\nborder-radius: 999px;",
              dark: "background: linear-gradient(90deg, rgba(255, 200, 61, .40), rgba(0, 170, 255, .30));\nborder-radius: 999px;"),
        .init(id: "notice", title: "提示底色", subtitle: "渐变文字、暖红渐变背景、点状下划线", icon: "exclamationmark.bubble",
              light: "color: linear-gradient(90deg, #ffffff, #fff176);\nbackground: linear-gradient(90deg, rgba(255, 48, 86, .46), rgba(126, 87, 194, .30));\nborder-radius: 999px;\ntext-decoration: underline dotted;",
              dark: "color: linear-gradient(90deg, #ffffff, #ffeb3b);\nbackground: linear-gradient(90deg, rgba(255, 80, 120, .42), rgba(126, 87, 194, .32));\nborder-radius: 999px;\ntext-decoration: underline dotted;"),
        .init(id: "underline", title: "蓝色下划线", subtitle: "适合只强调命中片段，不加底色", icon: "underline",
              light: "color: #1f6feb;\ntext-decoration: underline solid currentColor;",
              dark: "color: #79c0ff;\ntext-decoration: underline solid currentColor;"),
        .init(id: "strike", title: "删除线批注", subtitle: "用虚线删除线标出需要略读的内容", icon: "strikethrough",
              light: "color: #8a5a00;\ntext-decoration: line-through dashed currentColor;",
              dark: "color: #d29922;\ntext-decoration: line-through dashed currentColor;"),
        .init(id: "plain", title: "只用颜色选择器", subtitle: "清空 CSS，恢复旧版单色高亮行为", icon: "eyedropper",
              light: "", dark: "")
    ]
}

// MARK: - 正则高亮：绘制

extension NSAttributedString.Key {
    /// 需要自绘的高亮：圆角 / 渐变背景、背景图、渐变文字、波浪线。
    static let readerHighlight = NSAttributedString.Key("legado.readerHighlight")
}

/// 一处命中需要自绘的内容。每处命中一个实例，相邻两处命中不会被合并成一段。
/// 支持安全归档：正文被选中复制时系统会归档富文本属性，不可归档的自定义属性会让复制失败。
/// 归档时不带任何内容（只是绘制用的临时信息）。
final class ReaderHighlightDrawing: NSObject, NSSecureCoding, @unchecked Sendable {
    static var supportsSecureCoding: Bool { true }

    override init() { super.init() }

    init?(coder: NSCoder) { super.init() }

    func encode(with coder: NSCoder) {}

    enum Fill {
        case solid(UIColor)
        case gradient(angle: CGFloat, colors: [UIColor])
    }

    var background: Fill?
    var radius: CGFloat = 0
    var paddingX: CGFloat = 0
    var paddingY: CGFloat = 0
    var image: UIImage?
    var sliceInsets: UIEdgeInsets?
    var textGradient: (angle: CGFloat, colors: [UIColor])?
    var wavyUnderline: UIColor?
    var wavyStrike: UIColor?

    var drawsBackground: Bool { background != nil || image != nil }
    var drawsForeground: Bool { textGradient != nil || wavyUnderline != nil || wavyStrike != nil }

    func drawBackground(in rect: CGRect, context: CGContext) {
        let box = rect.insetBy(dx: -paddingX, dy: -paddingY)
        guard box.width > 0, box.height > 0 else { return }
        let corner = min(radius, box.height / 2, box.width / 2)
        let path = UIBezierPath(roundedRect: box, cornerRadius: max(corner, 0)).cgPath
        context.saveGState()
        context.addPath(path)
        context.clip()
        switch background {
        case .solid(let color):
            context.setFillColor(color.cgColor)
            context.fill(box)
        case .gradient(let angle, let colors):
            ReaderHighlightDrawing.drawGradient(colors: colors, angle: angle, in: box, context: context)
        case nil:
            break
        }
        if let image {
            if let insets = sliceInsets {
                image.resizableImage(withCapInsets: insets, resizingMode: .stretch).draw(in: box)
            } else {
                image.draw(in: box)
            }
        }
        context.restoreGState()
    }

    static func drawGradient(colors: [UIColor], angle: CGFloat, in rect: CGRect, context: CGContext) {
        guard let first = colors.first else { return }
        guard colors.count > 1,
              let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                        colors: colors.map(\.cgColor) as CFArray, locations: nil) else {
            context.setFillColor(first.cgColor)
            context.fill(rect)
            return
        }
        // CSS：0deg 向上、90deg 向右、180deg 向下。
        let radians = angle * .pi / 180
        let dx = sin(radians)
        let dy = -cos(radians)
        let half = abs(rect.width * dx) / 2 + abs(rect.height * dy) / 2
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let start = CGPoint(x: center.x - dx * half, y: center.y - dy * half)
        let end = CGPoint(x: center.x + dx * half, y: center.y + dy * half)
        context.drawLinearGradient(gradient, start: start, end: end,
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    static func wave(from start: CGFloat, to end: CGFloat, y: CGFloat, amplitude: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let period = max(amplitude * 4, 4)
        var x = start
        path.move(to: CGPoint(x: x, y: y))
        var up = true
        while x < end {
            let next = min(x + period / 2, end)
            path.addQuadCurve(to: CGPoint(x: next, y: y),
                              control: CGPoint(x: (x + next) / 2, y: y + (up ? -amplitude : amplitude) * 2))
            up.toggle()
            x = next
        }
        return path
    }
}

/// 正文用的 TextKit 1 排版器：先按系统方式画背景 / 文字，再补画高亮的圆角背景、渐变、背景图、渐变文字和波浪线。
/// 没有高亮属性时和 NSLayoutManager 完全一样。
final class ReaderHighlightLayoutManager: NSLayoutManager {
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        drawHighlights(glyphsToShow, at: origin, foreground: false)
    }

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        drawHighlights(glyphsToShow, at: origin, foreground: true)
    }

    private func drawHighlights(_ glyphsToShow: NSRange, at origin: CGPoint, foreground: Bool) {
        guard glyphsToShow.length > 0, let storage = textStorage, storage.length > 0,
              let context = UIGraphicsGetCurrentContext() else { return }
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        guard characters.length > 0, NSMaxRange(characters) <= storage.length else { return }
        var items: [(ReaderHighlightDrawing, NSRange)] = []
        storage.enumerateAttribute(.readerHighlight, in: characters, options: []) { value, range, _ in
            guard let drawing = value as? ReaderHighlightDrawing else { return }
            if (foreground ? drawing.drawsForeground : drawing.drawsBackground) { items.append((drawing, range)) }
        }
        guard !items.isEmpty else { return }
        for (drawing, range) in items {
            let glyphs = NSIntersectionRange(glyphRange(forCharacterRange: range, actualCharacterRange: nil), glyphsToShow)
            guard glyphs.length > 0 else { continue }
            var lines: [(lineRect: CGRect, part: NSRange, container: NSTextContainer)] = []
            enumerateLineFragments(forGlyphRange: glyphs) { lineRect, _, container, lineGlyphs, _ in
                let part = NSIntersectionRange(lineGlyphs, glyphs)
                if part.length > 0 { lines.append((lineRect, part, container)) }
            }
            for line in lines {
                let part = trimmedLineBreaks(line.part, in: storage)
                guard part.length > 0 else { continue }
                let box = boundingRect(forGlyphRange: part, in: line.container)
                let characterIndex = characterIndexForGlyph(at: part.location)
                let font = (characterIndex < storage.length ? storage.attribute(.font, at: characterIndex, effectiveRange: nil) as? UIFont : nil)
                    ?? UIFont.systemFont(ofSize: 17)
                let baseline = line.lineRect.minY + location(forGlyphAt: part.location).y
                let rect = CGRect(x: box.minX + origin.x, y: baseline - font.ascender + origin.y,
                                  width: box.width, height: font.ascender - font.descender)
                if foreground {
                    drawForeground(drawing, part: part, lineRect: line.lineRect, rect: rect, baseline: baseline + origin.y,
                                   font: font, origin: origin, storage: storage, context: context)
                } else {
                    drawing.drawBackground(in: rect, context: context)
                }
            }
        }
    }

    /// 段末换行不参与背景宽度。
    private func trimmedLineBreaks(_ part: NSRange, in storage: NSTextStorage) -> NSRange {
        var result = part
        let text = storage.string as NSString
        while result.length > 0 {
            let character = characterIndexForGlyph(at: NSMaxRange(result) - 1)
            guard character < text.length else { break }
            let unit = text.character(at: character)
            if unit == 10 || unit == 13 || unit == 0x2028 || unit == 0x2029 { result.length -= 1 } else { break }
        }
        return result
    }

    private func drawForeground(_ drawing: ReaderHighlightDrawing, part: NSRange, lineRect: CGRect, rect: CGRect,
                                baseline: CGFloat, font: UIFont, origin: CGPoint, storage: NSTextStorage, context: CGContext) {
        if let gradient = drawing.textGradient {
            let path = CGMutablePath()
            for glyphIndex in part.location..<NSMaxRange(part) {
                let property = propertyForGlyph(at: glyphIndex)
                if property.contains(.null) || property.contains(.controlCharacter) { continue }
                let character = characterIndexForGlyph(at: glyphIndex)
                guard character < storage.length else { continue }
                if storage.attribute(.attachment, at: character, effectiveRange: nil) != nil { continue }
                let glyphFont = storage.attribute(.font, at: character, effectiveRange: nil) as? UIFont ?? font
                let point = location(forGlyphAt: glyphIndex)
                var transform = CGAffineTransform(a: 1, b: 0, c: 0, d: -1,
                                                  tx: origin.x + lineRect.minX + point.x,
                                                  ty: origin.y + lineRect.minY + point.y)
                if let outline = CTFontCreatePathForGlyph(glyphFont as CTFont, cgGlyph(at: glyphIndex), &transform) {
                    path.addPath(outline)
                }
            }
            if !path.isEmpty {
                context.saveGState()
                context.addPath(path)
                context.clip()
                ReaderHighlightDrawing.drawGradient(colors: gradient.colors, angle: gradient.angle,
                                                    in: path.boundingBoxOfPath.union(rect), context: context)
                context.restoreGState()
            }
        }
        let lineWidth = max(1, font.pointSize / 18)
        if let color = drawing.wavyUnderline {
            let y = baseline - CTFontGetUnderlinePosition(font as CTFont) + lineWidth
            stroke(ReaderHighlightDrawing.wave(from: rect.minX, to: rect.maxX, y: y, amplitude: lineWidth * 1.1),
                   color: color, width: lineWidth, context: context)
        }
        if let color = drawing.wavyStrike {
            let y = baseline - font.xHeight / 2
            stroke(ReaderHighlightDrawing.wave(from: rect.minX, to: rect.maxX, y: y, amplitude: lineWidth * 1.1),
                   color: color, width: lineWidth, context: context)
        }
    }

    private func stroke(_ path: CGPath, color: UIColor, width: CGFloat, context: CGContext) {
        context.saveGState()
        context.addPath(path)
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(width)
        context.setLineCap(.round)
        context.strokePath()
        context.restoreGState()
    }
}

// MARK: - 正则高亮：应用到正文

@MainActor
enum ReaderHighlighter {
    private static var regexCache: [String: NSRegularExpression] = [:]
    private static var cssCache: [String: ReaderHighlightCSS] = [:]

    static func regex(_ pattern: String, options: NSRegularExpression.Options = []) -> NSRegularExpression? {
        let key = "\(options.rawValue)|\(pattern)"
        if let cached = regexCache[key] { return cached }
        guard let expression = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        if regexCache.count > 200 { regexCache.removeAll() }
        regexCache[key] = expression
        return expression
    }

    static func css(_ text: String) -> ReaderHighlightCSS {
        if let cached = cssCache[text] { return cached }
        let parsed = ReaderHighlightCSS.parse(text)
        if cssCache.count > 200 { cssCache.removeAll() }
        cssCache[text] = parsed
        return parsed
    }

    /// 阅读页：按已保存的规则给正文上色（全局开关关闭时不做任何改动）。
    static func apply(to text: NSMutableAttributedString, in range: NSRange, foreground: UIColor) {
        let store = ReaderHighlightStore.shared
        guard store.enabled else { return }
        let active = store.rules.filter { $0.enabled }
        guard !active.isEmpty else { return }
        apply(rules: active, to: text, in: range, foreground: foreground)
    }

    /// 文字颜色偏亮就是深色阅读主题：用规则的深色颜色和深色 CSS。
    static func isDark(foreground: UIColor) -> Bool {
        let resolved = foreground.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        if resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
            return 0.299 * red + 0.587 * green + 0.114 * blue > 0.5
        }
        var white: CGFloat = 0
        if resolved.getWhite(&white, alpha: &alpha) { return white > 0.5 }
        return false
    }

    /// 返回命中处数（预览用）。
    @discardableResult
    static func apply(rules: [ReaderHighlightRule], to text: NSMutableAttributedString, in range: NSRange,
                      foreground: UIColor, dark: Bool? = nil) -> Int {
        guard range.length > 0, NSMaxRange(range) <= text.length else { return 0 }
        let dark = dark ?? isDark(foreground: foreground)
        let string = text.string as NSString
        var total = 0
        for rule in rules {
            guard let expression = regex(rule.pattern) else { continue }
            var ranges: [NSRange] = []
            for match in expression.matches(in: text.string, range: range) where match.range.length > 0 {
                ranges.append(match.range)
                if ranges.count >= 20_000 { break }
            }
            if rule.pageCompensation, let pair = rule.quotePair {
                let pattern = NSRegularExpression.escapedPattern(for: pair.open)
                    + "[^" + NSRegularExpression.escapedPattern(for: pair.open)
                    + NSRegularExpression.escapedPattern(for: pair.close) + "\\n]*$"
                if let open = regex(pattern, options: [.anchorsMatchLines]) {
                    for match in open.matches(in: text.string, range: range) where match.range.length > 1 {
                        ranges.append(match.range)
                    }
                }
            }
            guard !ranges.isEmpty else { continue }
            let style = ResolvedStyle(rule: rule, dark: dark, foreground: foreground)
            for var target in ranges {
                if rule.noCrossParagraph {
                    let lineBreak = string.rangeOfCharacter(from: .newlines, options: [], range: target)
                    if lineBreak.location != NSNotFound { target.length = lineBreak.location - target.location }
                }
                guard target.length > 0 else { continue }
                total += 1
                style.apply(to: text, range: target)
            }
        }
        return total
    }

    /// 一条规则在当前明暗下解析好的样式。
    @MainActor
    private struct ResolvedStyle {
        let rule: ReaderHighlightRule
        let css: ReaderHighlightCSS
        let textColor: UIColor
        let textGradient: (angle: CGFloat, colors: [UIColor])?
        let image: UIImage?

        init(rule: ReaderHighlightRule, dark: Bool, foreground: UIColor) {
            self.rule = rule
            let source = dark ? (rule.darkCSS.isEmpty ? rule.lightCSS : rule.darkCSS) : rule.lightCSS
            css = ReaderHighlighter.css(source)
            let picker = UIColor(readerHex: dark ? rule.darkColor : rule.lightColor) ?? foreground
            switch css.color {
            case .color(let color)?:
                textColor = color
                textGradient = nil
            case .current?:
                textColor = foreground
                textGradient = nil
            case .gradient(let angle, let colors)?:
                textColor = colors.first ?? picker
                textGradient = (angle, colors)
            case nil:
                textColor = picker
                textGradient = nil
            }
            image = ReaderHighlightImageStore.image(dark ? (rule.darkImage ?? rule.lightImage) : rule.lightImage)
        }

        private var decorationColor: UIColor {
            switch css.decorationColor {
            case .color(let color)?: return color
            default: return textColor
            }
        }

        private func underlineStyle() -> NSUnderlineStyle {
            switch css.decorationStyle {
            case .solid, .wavy: return .single
            case .double: return .double
            case .dotted: return [.single, .patternDot]
            case .dashed: return [.single, .patternDash]
            }
        }

        private func makeDrawing() -> ReaderHighlightDrawing? {
            let drawing = ReaderHighlightDrawing()
            switch css.background {
            case .color(let color)?:
                if color != .clear { drawing.background = .solid(color) }
            case .gradient(let angle, let colors)?:
                drawing.background = .gradient(angle: angle, colors: colors)
            case .current?:
                drawing.background = .solid(textColor.withAlphaComponent(0.2))
            case nil:
                break
            }
            drawing.radius = css.radius ?? 0
            drawing.paddingX = CGFloat(rule.paddingHorizontal)
            drawing.paddingY = CGFloat(rule.paddingVertical)
            if let image {
                drawing.image = image
                if rule.sliceEnabled {
                    let size = image.size
                    drawing.sliceInsets = UIEdgeInsets(
                        top: size.height * CGFloat(min(max(rule.sliceTop, 0), 0.49)),
                        left: size.width * CGFloat(min(max(rule.sliceLeft, 0), 0.49)),
                        bottom: size.height * CGFloat(min(max(rule.sliceBottom, 0), 0.49)),
                        right: size.width * CGFloat(min(max(rule.sliceRight, 0), 0.49)))
                }
            }
            drawing.textGradient = textGradient
            if css.decorationStyle == .wavy {
                if css.underline { drawing.wavyUnderline = decorationColor }
                if css.lineThrough { drawing.wavyStrike = decorationColor }
            }
            return drawing.drawsBackground || drawing.drawsForeground ? drawing : nil
        }

        func apply(to text: NSMutableAttributedString, range: NSRange) {
            var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: textColor]
            if css.decorationStyle != .wavy {
                if css.underline {
                    attributes[.underlineStyle] = underlineStyle().rawValue
                    attributes[.underlineColor] = decorationColor
                }
                if css.lineThrough {
                    attributes[.strikethroughStyle] = underlineStyle().rawValue
                    attributes[.strikethroughColor] = decorationColor
                }
            }
            let drawing = makeDrawing()
            let changesFont = rule.fontName != nil || rule.fontSize != nil || rule.fontWeight != nil
            // 段评气泡、插图等隐藏标记（极小字号或附件）保持原样。
            text.enumerateAttributes(in: range, options: []) { existing, part, _ in
                if existing[.attachment] != nil { return }
                if let font = existing[.font] as? UIFont, font.pointSize < 1 { return }
                text.addAttributes(attributes, range: part)
                if css.decorationNone {
                    text.removeAttribute(.underlineStyle, range: part)
                    text.removeAttribute(.strikethroughStyle, range: part)
                }
                if let drawing { text.addAttribute(.readerHighlight, value: drawing, range: part) }
                if changesFont, let font = existing[.font] as? UIFont {
                    text.addAttribute(.font, value: ReaderHighlighter.font(for: rule, base: font), range: part)
                }
            }
        }
    }

    static let fontChoices: [(id: String, title: String)] = [
        ("system", "系统字体"), ("serif", "宋体"), ("rounded", "圆体"), ("mono", "等宽")
    ]

    static func importedFonts() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: ReaderFontStore.directory.path)) ?? []
        return files.filter { ["ttf", "otf", "ttc"].contains(($0 as NSString).pathExtension.lowercased()) }.sorted()
    }

    static func fontTitle(_ name: String?) -> String {
        guard let name else { return "跟随阅读字体" }
        if let choice = fontChoices.first(where: { $0.id == name }) { return choice.title }
        return (name as NSString).deletingPathExtension
    }

    static func font(for rule: ReaderHighlightRule, base: UIFont) -> UIFont {
        let size = CGFloat(rule.fontSize ?? Double(base.pointSize))
        let weights: [UIFont.Weight] = [.ultraLight, .thin, .light, .regular, .medium, .semibold, .bold, .heavy, .black]
        let weight = rule.fontWeight.map { weights[min(max($0, 1), 9) - 1] }
        var font: UIFont
        switch rule.fontName {
        case nil:
            font = base.withSize(size)
        case "system"?:
            font = UIFont.systemFont(ofSize: size, weight: weight ?? .regular)
        case "rounded"?:
            let system = UIFont.systemFont(ofSize: size, weight: weight ?? .regular)
            font = system.fontDescriptor.withDesign(.rounded).map { UIFont(descriptor: $0, size: size) } ?? system
        case "mono"?:
            font = UIFont.monospacedSystemFont(ofSize: size, weight: weight ?? .regular)
        case "serif"?:
            font = UIFont(name: "STSongti-SC-Regular", size: size)
                ?? UIFont.systemFont(ofSize: size, weight: weight ?? .regular).fontDescriptor.withDesign(.serif)
                    .map { UIFont(descriptor: $0, size: size) }
                ?? UIFont.systemFont(ofSize: size)
        case let file?:
            let path = ReaderFontStore.directory.appendingPathComponent(file).path
            font = ReaderFontStore.font(at: path, size: size, weight: 0) ?? base.withSize(size)
        }
        if let weight, rule.fontName != "system", rule.fontName != "rounded", rule.fontName != "mono" {
            let descriptor = font.fontDescriptor.addingAttributes([
                .traits: [UIFontDescriptor.TraitKey.weight: weight.rawValue]
            ])
            var weighted = UIFont(descriptor: descriptor, size: size)
            if weight.rawValue >= UIFont.Weight.semibold.rawValue,
               let bold = weighted.fontDescriptor.withSymbolicTraits(.traitBold) {
                weighted = UIFont(descriptor: bold, size: size)
            }
            font = weighted
        }
        return font
    }
}
