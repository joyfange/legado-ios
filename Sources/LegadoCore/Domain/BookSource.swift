import Foundation

public struct BookSource: Codable, Hashable, Identifiable, Sendable {
    public var bookSourceUrl: String
    public var bookSourceName: String
    public var bookSourceGroup: String?
    public var bookSourceType: Int
    public var bookUrlPattern: String?
    public var customOrder: Int
    public var enabled: Bool
    public var enabledExplore: Bool
    public var jsLib: String?
    public var enabledCookieJar: Bool?
    public var concurrentRate: String?
    public var header: String?
    public var loginUrl: String?
    public var loginUi: String?
    public var loginCheckJs: String?
    public var coverDecodeJs: String?
    public var bookSourceComment: String?
    public var variableComment: String?
    public var lastUpdateTime: Int64
    public var respondTime: Int64
    public var weight: Int
    public var exploreUrl: String?
    public var exploreScreen: String?
    public var ruleExplore: ExploreRule?
    public var searchUrl: String?
    public var ruleSearch: SearchRule?
    public var ruleBookInfo: BookInfoRule?
    public var ruleToc: TocRule?
    public var ruleContent: ContentRule?
    public var ruleReview: ReviewRule?
    public var eventListener: Bool
    public var customButton: Bool

    public var additionalFields: [String: JSONValue] = [:]

    public var id: String { bookSourceUrl }

    public init(bookSourceUrl: String, bookSourceName: String) {
        self.bookSourceUrl = bookSourceUrl
        self.bookSourceName = bookSourceName
        bookSourceGroup = nil
        bookSourceType = 0
        bookUrlPattern = nil
        customOrder = 0
        enabled = true
        enabledExplore = true
        jsLib = nil
        enabledCookieJar = true
        concurrentRate = nil
        header = nil
        loginUrl = nil
        loginUi = nil
        loginCheckJs = nil
        coverDecodeJs = nil
        bookSourceComment = nil
        variableComment = nil
        lastUpdateTime = 0
        respondTime = 180_000
        weight = 0
        exploreUrl = nil
        exploreScreen = nil
        ruleExplore = nil
        searchUrl = nil
        ruleSearch = nil
        ruleBookInfo = nil
        ruleToc = nil
        ruleContent = nil
        ruleReview = nil
        eventListener = false
        customButton = false
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case bookSourceUrl, bookSourceName, bookSourceGroup, bookSourceType, bookUrlPattern, customOrder, enabled, enabledExplore, jsLib, enabledCookieJar, concurrentRate, header, loginUrl, loginUi, loginCheckJs, coverDecodeJs, bookSourceComment, variableComment, lastUpdateTime, respondTime, weight, exploreUrl, exploreScreen, ruleExplore, searchUrl, ruleSearch, ruleBookInfo, ruleToc, ruleContent, ruleReview, eventListener, customButton
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        bookSourceUrl = values.decodeLossyString(forKey: .bookSourceUrl) ?? ""
        bookSourceName = values.decodeLossyString(forKey: .bookSourceName) ?? ""
        bookSourceGroup = values.decodeLossyString(forKey: .bookSourceGroup)
        bookSourceType = try values.decodeLossyInt(forKey: .bookSourceType) ?? 0
        bookUrlPattern = values.decodeLossyString(forKey: .bookUrlPattern)
        customOrder = try values.decodeLossyInt(forKey: .customOrder) ?? 0
        enabled = try values.decodeLossyBool(forKey: .enabled) ?? true
        enabledExplore = try values.decodeLossyBool(forKey: .enabledExplore) ?? true
        jsLib = values.decodeLossyString(forKey: .jsLib)
        enabledCookieJar = values.contains(.enabledCookieJar)
            ? try values.decodeLossyBool(forKey: .enabledCookieJar)
            : true
        concurrentRate = values.decodeLossyString(forKey: .concurrentRate)
        header = values.decodeLossyString(forKey: .header)
        loginUrl = values.decodeLossyString(forKey: .loginUrl)
        loginUi = values.decodeLossyString(forKey: .loginUi)
        loginCheckJs = values.decodeLossyString(forKey: .loginCheckJs)
        coverDecodeJs = values.decodeLossyString(forKey: .coverDecodeJs)
        bookSourceComment = values.decodeLossyString(forKey: .bookSourceComment)
        variableComment = values.decodeLossyString(forKey: .variableComment)
        lastUpdateTime = try values.decodeLossyInt64(forKey: .lastUpdateTime) ?? 0
        respondTime = try values.decodeLossyInt64(forKey: .respondTime) ?? 180_000
        weight = try values.decodeLossyInt(forKey: .weight) ?? 0
        exploreUrl = values.decodeLossyString(forKey: .exploreUrl)
        exploreScreen = values.decodeLossyString(forKey: .exploreScreen)
        ruleExplore = try values.decodeFlexible(ExploreRule.self, forKey: .ruleExplore)
        searchUrl = values.decodeLossyString(forKey: .searchUrl)
        ruleSearch = try values.decodeFlexible(SearchRule.self, forKey: .ruleSearch)
        ruleBookInfo = try values.decodeFlexible(BookInfoRule.self, forKey: .ruleBookInfo)
        ruleToc = try values.decodeFlexible(TocRule.self, forKey: .ruleToc)
        ruleContent = try values.decodeFlexible(ContentRule.self, forKey: .ruleContent)
        ruleReview = try values.decodeFlexible(ReviewRule.self, forKey: .ruleReview)
        eventListener = try values.decodeLossyBool(forKey: .eventListener) ?? false
        customButton = try values.decodeLossyBool(forKey: .customButton) ?? false
        if case .object(var raw) = try JSONValue(from: decoder) {
            for key in CodingKeys.allCases {
                if BookSourceEditorDocument.ruleKeys.contains(key.rawValue) {
                    var nested: [String: JSONValue] = [:]
                    var value = raw[key.rawValue]
                    if case .string(let text) = value { value = try? JSONValue.decode(data: Data(text.utf8)) }
                    if case .object(let object) = value { nested = object }
                    for field in BookSourceEditorSchema.sections.flatMap(\.fields) where field.path.hasPrefix(key.rawValue + ".") {
                        nested.removeValue(forKey: String(field.path.split(separator: ".")[1]))
                    }
                    raw[key.rawValue] = nested.isEmpty ? nil : .object(nested)
                } else { raw.removeValue(forKey: key.rawValue) }
            }
            additionalFields = raw
        }
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: SourceCodingKey.self)
        for (key, value) in additionalFields { try values.encode(value, forKey: SourceCodingKey(key)) }
        try values.encode(bookSourceUrl, forKey: SourceCodingKey("bookSourceUrl"))
        try values.encode(bookSourceName, forKey: SourceCodingKey("bookSourceName"))
        try values.encodeIfPresent(bookSourceGroup, forKey: SourceCodingKey("bookSourceGroup"))
        try values.encode(bookSourceType, forKey: SourceCodingKey("bookSourceType"))
        try values.encodeIfPresent(bookUrlPattern, forKey: SourceCodingKey("bookUrlPattern"))
        try values.encode(customOrder, forKey: SourceCodingKey("customOrder"))
        try values.encode(enabled, forKey: SourceCodingKey("enabled"))
        try values.encode(enabledExplore, forKey: SourceCodingKey("enabledExplore"))
        try values.encodeIfPresent(jsLib, forKey: SourceCodingKey("jsLib"))
        try values.encode(enabledCookieJar, forKey: SourceCodingKey("enabledCookieJar"))
        try values.encodeIfPresent(concurrentRate, forKey: SourceCodingKey("concurrentRate"))
        try values.encodeIfPresent(header, forKey: SourceCodingKey("header"))
        try values.encodeIfPresent(loginUrl, forKey: SourceCodingKey("loginUrl"))
        try values.encodeIfPresent(loginUi, forKey: SourceCodingKey("loginUi"))
        try values.encodeIfPresent(loginCheckJs, forKey: SourceCodingKey("loginCheckJs"))
        try values.encodeIfPresent(coverDecodeJs, forKey: SourceCodingKey("coverDecodeJs"))
        try values.encodeIfPresent(bookSourceComment, forKey: SourceCodingKey("bookSourceComment"))
        try values.encodeIfPresent(variableComment, forKey: SourceCodingKey("variableComment"))
        try values.encode(lastUpdateTime, forKey: SourceCodingKey("lastUpdateTime"))
        try values.encode(respondTime, forKey: SourceCodingKey("respondTime"))
        try values.encode(weight, forKey: SourceCodingKey("weight"))
        try values.encodeIfPresent(exploreUrl, forKey: SourceCodingKey("exploreUrl"))
        try values.encodeIfPresent(exploreScreen, forKey: SourceCodingKey("exploreScreen"))
        try encodeRule(ruleExplore, key: "ruleExplore", into: &values)
        try values.encodeIfPresent(searchUrl, forKey: SourceCodingKey("searchUrl"))
        try encodeRule(ruleSearch, key: "ruleSearch", into: &values)
        try encodeRule(ruleBookInfo, key: "ruleBookInfo", into: &values)
        try encodeRule(ruleToc, key: "ruleToc", into: &values)
        try encodeRule(ruleContent, key: "ruleContent", into: &values)
        try encodeRule(ruleReview, key: "ruleReview", into: &values)
        try values.encode(eventListener, forKey: SourceCodingKey("eventListener"))
        try values.encode(customButton, forKey: SourceCodingKey("customButton"))
    }

    private func encodeRule<T: Encodable>(_ rule: T?, key: String, into values: inout KeyedEncodingContainer<SourceCodingKey>) throws {
        var object: [String: JSONValue] = [:]
        if case .object(let extra) = additionalFields[key] { object = extra }
        if let rule, case .object(let known) = try JSONValue.decode(data: JSONEncoder().encode(rule)) {
            object.merge(known) { _, new in new }
        }
        if rule != nil || !object.isEmpty { try values.encode(object, forKey: SourceCodingKey(key)) }
    }

}

public extension BookSource {
    var groups: [String] {
        Self.parseGroups(bookSourceGroup)
    }

    func hasGroup(_ group: String) -> Bool {
        groups.contains(group.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    mutating func addGroups(_ value: String) {
        bookSourceGroup = Self.joinGroups(groups + Self.parseGroups(value))
    }

    mutating func removeGroups(_ value: String) {
        let removed = Set(Self.parseGroups(value))
        bookSourceGroup = Self.joinGroups(groups.filter { !removed.contains($0) })
    }

    mutating func replaceGroup(_ oldValue: String, with newValue: String?) {
        let oldValue = oldValue.trimmingCharacters(in: .whitespacesAndNewlines)
        var values = groups.filter { $0 != oldValue }
        if let newValue { values += Self.parseGroups(newValue) }
        bookSourceGroup = Self.joinGroups(values)
    }

    static func parseGroups(_ value: String?) -> [String] {
        guard let value else { return [] }
        var seen = Set<String>()
        return value
            .components(separatedBy: CharacterSet(charactersIn: ",;，；"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    static func joinGroups(_ values: [String]) -> String? {
        var seen = Set<String>()
        let normalized = values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        return normalized.isEmpty ? nil : normalized.joined(separator: ",")
    }
}

private extension KeyedDecodingContainer {
    func decodeFlexible<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T? {
        // Android Legado tolerates `[]`, `""` or malformed rule blocks and
        // treats them as empty; never reject a whole source over one block.
        guard contains(key), (try? decodeNil(forKey: key)) != true else { return nil }
        if let value = try? decode(T.self, forKey: key) {
            return value
        }
        guard let json = try? decode(String.self, forKey: key),
              !json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let data = json.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// Strings in hand-edited sources are sometimes numbers, booleans, or
    /// inline JSON (e.g. `exploreUrl` as an array). Keep them as text.
    func decodeLossyString(forKey key: Key) -> String? {
        guard contains(key), (try? decodeNil(forKey: key)) != true else { return nil }
        if let value = try? decode(String.self, forKey: key) { return value }
        if let value = try? decode(JSONValue.self, forKey: key) {
            switch value {
            case .string(let text): return text
            case .null: return nil
            default:
                if let data = try? JSONEncoder().encode(value) { return String(decoding: data, as: UTF8.self) }
            }
        }
        return nil
    }

    func decodeLossyBool(forKey key: Key) throws -> Bool? {
        guard contains(key), try !decodeNil(forKey: key) else { return nil }
        if let value = try? decode(Bool.self, forKey: key) { return value }
        if let value = try? decode(Int.self, forKey: key) { return value != 0 }
        let value = try decode(String.self, forKey: key).lowercased()
        if ["true", "1", "yes"].contains(value) { return true }
        if ["false", "0", "no"].contains(value) { return false }
        return nil
    }

    func decodeLossyInt(forKey key: Key) throws -> Int? {
        guard contains(key), try !decodeNil(forKey: key) else { return nil }
        if let value = try? decode(Int.self, forKey: key) { return value }
        return Int(try decode(String.self, forKey: key))
    }

    func decodeLossyInt64(forKey key: Key) throws -> Int64? {
        guard contains(key), try !decodeNil(forKey: key) else { return nil }
        if let value = try? decode(Int64.self, forKey: key) { return value }
        return Int64(try decode(String.self, forKey: key))
    }
}
