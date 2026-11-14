import Foundation

public enum ReplaceRuleImportError: Error, LocalizedError, Equatable {
    case emptyDocument
    case documentTooLarge(Int)
    case invalidDocument(String)
    case emptyPattern(String)

    public var errorDescription: String? {
        switch self {
        case .emptyDocument: "净化规则内容为空"
        case .documentTooLarge(let maximum): "净化规则文件超过 \(maximum / 1_024 / 1_024) MB 上限"
        case .invalidDocument(let detail): "无法解析净化规则 JSON：\(detail)"
        case .emptyPattern(let name): "净化规则“\(name)”没有匹配内容"
        }
    }
}

public struct ReplaceRuleImporter: Sendable {
    public static let maximumDocumentBytes = 10 * 1_024 * 1_024

    public init() {}

    public func decode(_ data: Data) throws -> [ReplaceRule] {
        guard data.count <= Self.maximumDocumentBytes else {
            throw ReplaceRuleImportError.documentTooLarge(Self.maximumDocumentBytes)
        }
        let bom = Data([0xEF, 0xBB, 0xBF])
        let cleaned = data.starts(with: bom) ? Data(data.dropFirst(3)) : data
        guard !cleaned.isEmpty else { throw ReplaceRuleImportError.emptyDocument }
        do {
            let decoder = JSONDecoder()
            let rules = if let array = try? decoder.decode([ReplaceRule].self, from: cleaned) {
                array
            } else {
                [try decoder.decode(ReplaceRule.self, from: cleaned)]
            }
            for rule in rules { try ReplaceRuleValidator.validate(rule) }
            return rules
        } catch let error as ReplaceRuleImportError {
            throw error
        } catch {
            throw ReplaceRuleImportError.invalidDocument(error.localizedDescription)
        }
    }

    public func merge(_ incoming: [ReplaceRule], into existing: [ReplaceRule]) -> [ReplaceRule] {
        var result = existing
        var indexes = Dictionary(result.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        for rule in incoming {
            if let index = indexes[rule.id] {
                result[index] = rule
            } else {
                indexes[rule.id] = result.count
                result.append(rule)
            }
        }
        return result.sorted { $0.sortOrder < $1.sortOrder }
    }
}

public protocol ReplaceRuleRepository: Sendable {
    func load() async throws -> [ReplaceRule]
    func save(_ rules: [ReplaceRule]) async throws
}

public actor FileReplaceRuleRepository: ReplaceRuleRepository {
    private let fileURL: URL

    public init(fileURL: URL) { self.fileURL = fileURL }

    public func load() throws -> [ReplaceRule] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        return try JSONDecoder().decode([ReplaceRule].self, from: Data(contentsOf: fileURL))
    }

    public func save(_ rules: [ReplaceRule]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(rules).write(to: fileURL, options: .atomic)
    }
}

public actor InMemoryReplaceRuleRepository: ReplaceRuleRepository {
    private var rules: [ReplaceRule]
    public init(rules: [ReplaceRule] = []) { self.rules = rules }
    public func load() -> [ReplaceRule] { rules }
    public func save(_ rules: [ReplaceRule]) { self.rules = rules }
}
