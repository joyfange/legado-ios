import Foundation
import SwiftSoup

public struct MetadataTextSanitizer: Sendable {
    public init() {}

    public func clean(_ value: String?) -> String? {
        guard var value else { return nil }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        do {
            value = replacingBlockTagsWithNewlines(value)
            let document = try SwiftSoup.parseBodyFragment(value)
            try document.select("script,style,noscript").remove()
            value = try document.body()?.text(trimAndNormaliseWhitespace: false) ?? document.text()
        } catch {
            value = value.replacingOccurrences(
                of: #"<[^>]+>"#,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
            value = (try? Parser.unescapeEntities(value, false)) ?? value
        }

        value = value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{200B}", with: "")
        let output = value.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let result = output.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    private func replacingBlockTagsWithNewlines(_ value: String) -> String {
        value.replacingOccurrences(
            of: #"(?i)<\s*br\s*/?\s*>|<\s*/?\s*(?:p|div|li|ul|ol|section|article|blockquote|h[1-6])\b[^>]*>"#,
            with: "\n",
            options: .regularExpression
        )
    }
}

struct ChapterHTMLFormatter {
    /// Keeps illustrations and paragraph reviews (段评) from chapter HTML.
    ///
    /// - `<comment count="N" onClick="java.startBrowser('URL')"/>` and inline
    ///   images with `{"style":"text"}` options become a review bubble marker
    ///   (`<img src="bubble://paragraph?num=N&url=…">`) at the end of the
    ///   paragraph they follow.
    /// - SVG comment cards drawn by sources (热评 / 本章说) become plain text.
    /// - Other images keep a line of their own.
    func format(_ html: String, baseURL: URL) -> String {
        guard let expression = try? NSRegularExpression(pattern: #"(?i)<(comment|img)\b[^>]*?/?>"#) else {
            return MetadataTextSanitizer().clean(html) ?? ""
        }
        var protected = html
        var replacements: [String: String] = [:]
        let token = UUID().uuidString
        let ns = html as NSString
        for (index, match) in expression.matches(in: html, range: NSRange(location: 0, length: ns.length)).enumerated().reversed() {
            guard let range = Range(match.range, in: html) else { continue }
            let tag = String(html[range])
            let name = ns.substring(with: match.range(at: 1)).lowercased()
            let marker = "LEGADOMARK\(token.replacingOccurrences(of: "-", with: ""))X\(index)X"
            let output: (text: String, inline: Bool)
            if name == "comment" {
                let count = Self.attribute("count", in: tag).flatMap { Int($0) }
                output = (Self.bubbleMarker(count: count, url: Self.clickURL(in: tag)), true)
            } else {
                output = imageOutput(tag: tag, baseURL: baseURL)
            }
            replacements[marker] = output.text
            protected.replaceSubrange(range, with: output.inline ? marker : "\n\(marker)\n")
        }
        var result = MetadataTextSanitizer().clean(protected) ?? ""
        for (marker, value) in replacements { result = result.replacingOccurrences(of: marker, with: value) }
        return result
            .replacingOccurrences(of: "\n\n+", with: "\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func imageOutput(tag: String, baseURL: URL) -> (text: String, inline: Bool) {
        let src = Self.imgSrc(in: tag)
            ?? (try? SwiftSoup.parseBodyFragment(tag).select("img").first()).flatMap { element in
                ["data-src", "data-original", "data-srcset", "src"].compactMap { try? element.attr($0) }.first { !$0.isEmpty }
            }
            ?? ""
        guard !src.isEmpty else { return ("", true) }
        let lower = src.lowercased()
        if lower.hasPrefix("dp:") || lower.hasPrefix("bubble://") {
            return ("<img src=\"\(Self.escape(src))\">", true)
        }
        let clean = Self.stripOptions(src)
        let options = Self.srcOptions(src)
        let click = Self.clickURL(in: tag) ?? Self.optionClick(in: src) ?? Self.clickFromOptions(options)
        let svg = Self.svgText(clean)
        if options["style"]?.lowercased() == "text" || Self.isParagraphReviewMarker(src) {
            let svgCount = svg.flatMap { Self.svgTexts($0).compactMap { Int($0) }.first }
            let count = Self.commentCount(svgCount: svgCount, click: click, payloadIsSVG: svg?.contains("<svg") == true)
            return (Self.bubbleMarker(count: count, url: click), true)
        }
        if let svg, let card = Self.commentCardText(fromSVG: svg, click: click) {
            return (card, false)
        }
        if clean.lowercased().hasPrefix("data:") {
            return ("<img src=\"\(Self.escape(clean))\">", false)
        }
        let url = LegadoURLBuilder.resolve(clean, against: baseURL)
        return ("<img src=\"\(Self.escape(url))\">", false)
    }

    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func bubbleMarker(count: Int?, url: String?) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var value = "bubble://paragraph?num=" + (count.map(String.init) ?? "")
        if let url, url.lowercased().hasPrefix("http"),
           let encoded = url.addingPercentEncoding(withAllowedCharacters: allowed) {
            value += "&url=" + encoded
        }
        return "<img src=\"\(escape(value))\">"
    }

    static func isParagraphReviewMarker(_ src: String) -> Bool {
        let lower = src.lowercased()
        if lower.hasPrefix("dp:") || lower.hasPrefix("bubble://") { return true }
        guard let options = src.range(of: ",{") else { return false }
        let json = src[src.index(after: options.lowerBound)...].lowercased()
        return ["\"cmt\"", "\"comment\"", "\"review\"", "\"paragraph\"", "\"qd\"", "\"fqpl\"", "\"fanqie\"",
                "'cmt'", "'qd'", "showcmt(", "showcomment(", "createsvg"]
            .contains { json.contains($0) }
    }

    // MARK: - Tag helpers (ported from BookOn's ContentBlocks)

    /// The img src. Sources often append an options object with unescaped
    /// quotes: `src="data:…,XXX,{"style":"text","click":"showCmt('1')"}"`.
    static func imgSrc(in tag: String) -> String? {
        guard let r = tag.range(of: "\\bsrc\\s*=\\s*\"", options: [.regularExpression, .caseInsensitive]) else {
            return attribute("src", in: tag)
        }
        let rest = tag[r.upperBound...]
        guard let q = rest.firstIndex(of: "\"") else { return nil }
        let first = String(rest[..<q])
        if let marker = first.range(of: ",{"), let end = rest.range(of: "}\"", range: marker.lowerBound..<rest.endIndex) {
            return String(rest[..<end.lowerBound]) + "}"
        }
        return first
    }

    static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = "\\b" + name + "\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)')"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: tag, range: NSRange(location: 0, length: (tag as NSString).length)) else { return nil }
        for i in 1...2 where m.range(at: i).location != NSNotFound {
            return (tag as NSString).substring(with: m.range(at: i))
        }
        return nil
    }

    static func clickURL(in tag: String) -> String? {
        guard let click = attribute("onClick", in: tag) ?? attribute("onPress", in: tag) else { return nil }
        return urlInCall(click)
    }

    static func urlInCall(_ call: String) -> String? {
        let pattern = "(?:startBrowser(?:Await)?|showBrowser|showReadingBrowser|startBrowserDp)\\(\\s*['\"]([^'\"]+)['\"]"
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: call, range: NSRange(location: 0, length: (call as NSString).length)) else { return nil }
        return (call as NSString).substring(with: m.range(at: 1))
    }

    static func stripOptions(_ src: String) -> String {
        if let r = src.range(of: ",{") { return String(src[..<r.lowerBound]) }
        return src
    }

    static func srcOptions(_ src: String) -> [String: String] {
        guard let r = src.range(of: ",{") else { return [:] }
        let json = String(src[src.index(after: r.lowerBound)...])
        if let d = json.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            return o.reduce(into: [:]) { $0[$1.key] = "\($1.value)" }
        }
        var out: [String: String] = [:]
        for key in ["style", "type", "click", "js", "onClick"] {
            for pattern in ["[\"']" + key + "[\"']\\s*:\\s*\"(.*?)\"(?:\\s*[,}])", "[\"']" + key + "[\"']\\s*:\\s*'([^']*)'"] {
                guard out[key] == nil,
                      let re = try? NSRegularExpression(pattern: pattern),
                      let m = re.firstMatch(in: json, range: NSRange(location: 0, length: (json as NSString).length)),
                      m.range(at: 1).location != NSNotFound else { continue }
                out[key] = (json as NSString).substring(with: m.range(at: 1))
            }
        }
        return out
    }

    static func clickFromOptions(_ options: [String: String]) -> String? {
        guard let c = options["click"] ?? options["js"] ?? options["onClick"], !c.isEmpty else { return nil }
        return urlInCall(c)
    }

    static func optionClick(in src: String) -> String? {
        guard src.contains(",{") else { return nil }
        return urlInCall(src)
    }

    /// Fanqie-style `createSvg('bid','cid',pid,count,…)`: the 4th argument is the count.
    static func countFromClick(_ click: String?) -> Int? {
        guard let click, !click.isEmpty else { return nil }
        let pattern = "createSvg[0-9]*\\(\\s*['\"]([^'\"]*)['\"]\\s*,\\s*['\"]([^'\"]*)['\"]\\s*,\\s*(-?\\d+)\\s*,\\s*(\\d+)"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: click, range: NSRange(location: 0, length: (click as NSString).length)),
              let r = Range(m.range(at: 4), in: click) else { return nil }
        return Int(click[r])
    }

    static func showCmtCount(_ click: String?) -> Int? {
        guard let click, !click.isEmpty else { return nil }
        let pattern = "showCmt\\(\\s*['\"]?[^,'\")]*['\"]?\\s*,\\s*['\"]?[^,'\")]*['\"]?\\s*,\\s*['\"]?[^,'\")]*['\"]?\\s*,\\s*['\"]?(\\d+)['\"]?"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: click, range: NSRange(location: 0, length: (click as NSString).length)),
              let r = Range(m.range(at: 1), in: click) else { return nil }
        return Int(click[r])
    }

    static func commentCount(svgCount: Int?, click: String?, payloadIsSVG: Bool = true) -> Int? {
        if let n = countFromClick(click) { return n }
        if let n = showCmtCount(click), n < 10000 {
            if svgCount == 99, n > 99 { return n }
            if svgCount == nil, !payloadIsSVG { return n }
        }
        return svgCount
    }

    static func svgText(_ src: String) -> String? {
        guard src.lowercased().hasPrefix("data:"), let comma = src.firstIndex(of: ",") else { return nil }
        let meta = src[..<comma].lowercased()
        guard meta.contains("svg") else { return nil }
        var payload = String(src[src.index(after: comma)...])
        if meta.contains(";base64") {
            if let cut = payload.firstIndex(of: ",") { payload = String(payload[..<cut]) }
            var p = payload.replacingOccurrences(of: "\\s", with: "", options: .regularExpression)
            while p.count % 4 != 0 { p += "=" }
            guard let d = Data(base64Encoded: p) else { return nil }
            return String(data: d, encoding: .utf8)
        }
        return payload.removingPercentEncoding
    }

    static func svgTexts(_ svg: String) -> [String] {
        let flat = svg.replacingOccurrences(of: "</?tspan\\b[^>]*>", with: "", options: [.regularExpression, .caseInsensitive])
        guard let re = try? NSRegularExpression(pattern: "<text\\b[^>]*>([^<]*)</text>", options: [.caseInsensitive]) else { return [] }
        let ns = flat as NSString
        return re.matches(in: flat, range: NSRange(location: 0, length: ns.length)).map {
            var t = ns.substring(with: $0.range(at: 1))
            for (e, d) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'"), ("&amp;", "&")] {
                t = t.replacingOccurrences(of: e, with: d)
            }
            return t.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
    }

    static let hotCommentLabels: Set<String> = ["热评", "神评论", "精选评论", "精彩评论"]
    static let discussionTitles: Set<String> = ["本章说", "本章讨论", "本书讨论", "本章评论", "本书评论"]

    /// Comment cards that sources draw as SVG, as readable text: 热评 cards
    /// become 「热评」text; 本章说 summaries become a heading plus their lines.
    static func commentCardText(fromSVG svg: String, click: String?) -> String? {
        let texts = svgTexts(svg)
        guard let first = texts.first else { return nil }
        let link = click.map { bubbleMarker(count: nil, url: $0) } ?? ""
        if hotCommentLabels.contains(first), texts.count >= 2 {
            return "【\(first)】" + texts.dropFirst().joined() + link
        }
        if let titleIndex = texts.firstIndex(where: { discussionTitles.contains($0) }) {
            var rest = Array(texts[(titleIndex + 1)...])
            var heading = "【\(texts[titleIndex])"
            if let count = rest.first, count.contains("条评论") || Int(count) != nil {
                heading += " · \(count)"
                rest.removeFirst()
            }
            heading += "】" + link
            let body = rest.prefix(12).joined(separator: " ")
            return body.isEmpty ? heading : heading + "\n" + body
        }
        return nil
    }
}

public struct ContentProcessingReport: Sendable {
    public var title: String
    public var content: String
    public var effectiveRuleIDs: [Int64]
    public var removedDuplicateTitle: Bool
    public var diagnostics: [RuleDiagnostic]

    public init(
        title: String,
        content: String,
        effectiveRuleIDs: [Int64] = [],
        removedDuplicateTitle: Bool = false,
        diagnostics: [RuleDiagnostic] = []
    ) {
        self.title = title
        self.content = content
        self.effectiveRuleIDs = effectiveRuleIDs
        self.removedDuplicateTitle = removedDuplicateTitle
        self.diagnostics = diagnostics
    }
}

public struct ContentSanitizer: Sendable {
    private let regex: RegexEvaluator

    public init(regex: RegexEvaluator = .init()) {
        self.regex = regex
    }

    public func process(
        book: Book,
        chapter: BookChapter,
        content: String,
        rules: [ReplaceRule],
        removeDuplicateTitle: Bool = true,
        resegment: Bool = true
    ) -> ContentProcessingReport {
        let ordered = rules.filter(\.isEnabled).sorted { $0.sortOrder == $1.sortOrder ? $0.id < $1.id : $0.sortOrder < $1.sortOrder }
        var title = chapter.title
        var body = content
        var effective: [Int64] = []
        var diagnostics: [RuleDiagnostic] = []

        for rule in ordered where rule.scopeTitle && applies(rule, to: book) {
            let result = apply(rule, to: title, book: book, chapter: chapter)
            diagnostics += result.diagnostics
            if result.value != title, !result.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                title = result.value
                effective.append(rule.id)
            }
        }

        var removed = false
        if removeDuplicateTitle {
            let lines = body.components(separatedBy: .newlines)
            if let firstIndex = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                let normalizedLine = normalize(lines[firstIndex])
                let normalizedTitles = [chapter.title, title, book.name + chapter.title].map(normalize)
                if normalizedTitles.contains(normalizedLine) {
                    var updated = lines
                    updated.remove(at: firstIndex)
                    body = updated.joined(separator: "\n")
                    removed = true
                }
            }
        }

        if resegment {
            body = body.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "　"))) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        }

        for rule in ordered where rule.scopeContent && applies(rule, to: book) {
            let result = apply(rule, to: body, book: book, chapter: chapter)
            diagnostics += result.diagnostics
            if result.value != body {
                body = result.value
                effective.append(rule.id)
            }
        }

        var seen = Set<Int64>()
        effective = effective.filter { seen.insert($0).inserted }
        return .init(
            title: title,
            content: body,
            effectiveRuleIDs: effective,
            removedDuplicateTitle: removed,
            diagnostics: diagnostics
        )
    }

    private func applies(_ rule: ReplaceRule, to book: Book) -> Bool {
        if let excluded = rule.excludeScope, !excluded.isEmpty,
           (!book.name.isEmpty && excluded.contains(book.name)) || (!book.origin.isEmpty && excluded.contains(book.origin)) { return false }
        guard let scope = rule.scope, !scope.isEmpty else { return true }
        return (!book.name.isEmpty && scope.contains(book.name)) || (!book.origin.isEmpty && scope.contains(book.origin))
    }

    private func apply(_ rule: ReplaceRule, to input: String, book: Book, chapter: BookChapter) -> (value: String, diagnostics: [RuleDiagnostic]) {
        guard !rule.pattern.isEmpty else { return (input, []) }
        do {
            if rule.isRegex {
                if rule.replacement.hasPrefix("@js:") {
                    let evaluate = JavaScriptRuleEvaluator().replacementEvaluator(
                        script: String(rule.replacement.dropFirst(4)), book: book, chapter: chapter)
                    return (try regex.replacingStrict(pattern: rule.pattern, in: input,
                        timeoutMilliseconds: rule.timeoutMillisecond, replacement: evaluate), [])
                }
                return (try regex.replacingStrict(pattern: rule.pattern, in: input, with: rule.replacement, timeoutMilliseconds: rule.timeoutMillisecond), [])
            }
            return (input.replacingOccurrences(of: rule.pattern, with: rule.replacement), [])
        } catch let error as RuleEngineError {
            return (input, [error.diagnostic])
        } catch {
            return (input, [.init(
                severity: .error,
                code: "replace.failed",
                message: "净化规则“\(rule.name)”执行失败：\(error.localizedDescription)",
                rule: rule.pattern
            )])
        }
    }

    private func normalize(_ value: String) -> String {
        value.unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.punctuationCharacters.contains($0)
        }.map(String.init).joined().lowercased()
    }
}
