import Foundation

public struct RSSSourceImportPayload: Sendable {
    public var sources: [RssSource]
    public var subscriptionURLs: [String]
    public init(sources: [RssSource] = [], subscriptionURLs: [String] = []) {
        self.sources = sources
        self.subscriptionURLs = subscriptionURLs
    }
}

public enum RSSSourceImportError: Error, LocalizedError, Sendable {
    case emptyDocument
    case wrongFormat
    case invalidSource
    case duplicate(String)
    public var errorDescription: String? {
        switch self {
        case .emptyDocument: "导入内容为空"
        case .wrongFormat: "RSS源格式错误"
        case .invalidSource: "不是订阅源"
        case .duplicate(let url): "RSS源已存在：\(url)"
        }
    }
}

public struct RSSSourceImporter: Sendable {
    public init() {}

    public func decode(_ data: Data) throws -> RSSSourceImportPayload {
        var data = data
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { data = Data(data.dropFirst(3)) }
        guard !data.isEmpty else { throw RSSSourceImportError.emptyDocument }
        let decoder = JSONDecoder()
        if let manifest = try? decoder.decode(SubscriptionManifest.self, from: data), !manifest.sourceUrls.isEmpty {
            return .init(subscriptionURLs: manifest.sourceUrls)
        }
        let sources: [RssSource]
        if let values = try? decoder.decode([RssSource].self, from: data) { sources = values }
        else if let value = try? decoder.decode(RssSource.self, from: data) { sources = [value] }
        else { throw RSSSourceImportError.wrongFormat }
        guard sources.isEmpty || sources.first?.sourceUrl.isEmpty == false else { throw RSSSourceImportError.invalidSource }
        return .init(sources: sources)
    }

    public func merge(
        _ incoming: [RssSource],
        into existing: [RssSource],
        duplicatePolicy: DuplicatePolicy = .replace,
        addGroup: String? = nil
    ) throws -> [RssSource] {
        var result = existing
        var indexes = Dictionary(result.enumerated().map { ($0.element.sourceUrl, $0.offset) }, uniquingKeysWith: { first, _ in first })
        for original in incoming where !original.sourceUrl.isEmpty {
            var source = original
            if let addGroup, !addGroup.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { source.addGroups(addGroup) }
            if let index = indexes[source.sourceUrl] {
                switch duplicatePolicy {
                case .replace: result[index] = source
                case .skip: continue
                case .fail: throw RSSSourceImportError.duplicate(source.sourceUrl)
                }
            } else {
                indexes[source.sourceUrl] = result.count
                result.append(source)
            }
        }
        return result
    }

    public func defaultSelection(incoming: [RssSource], existing: [RssSource]) -> [Bool] {
        let current = Dictionary(existing.map { ($0.sourceUrl, $0.lastUpdateTime) }, uniquingKeysWith: { first, _ in first })
        return incoming.map { source in
            guard let oldTime = current[source.sourceUrl] else { return true }
            return oldTime < source.lastUpdateTime
        }
    }

    public func encode(_ sources: [RssSource], prettyPrinted: Bool = true) throws -> Data {
        let encoder = JSONEncoder()
        if prettyPrinted { encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] }
        return try encoder.encode(sources)
    }

    private struct SubscriptionManifest: Decodable {
        var sourceUrls: [String]
    }
}
