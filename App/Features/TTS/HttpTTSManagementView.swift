import AVFoundation
import Security
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 朗读源库

@MainActor
final class HttpTTSLibraryModel: ObservableObject {
    @Published private(set) var engines: [HttpTTS] = []
    @Published var errorMessage: String?
    @Published var notice: String?

    private func repository() throws -> SQLiteConfigurationRepository {
        SQLiteConfigurationRepository(database: try LegadoDatabase(url: LegadoDatabase.defaultURL()))
    }

    func load() async {
        do {
            var values = try await repository().loadHttpTTS()
            if values.isEmpty { values = try bundledDefaults() }
            values = Self.upgradingBundledPresets(values)
            engines = sorted(values)
            if !values.isEmpty { try await repository().saveHttpTTS(engines) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func save(_ value: HttpTTS) async {
        var value = value
        value.lastUpdateTime = Int64(Date().timeIntervalSince1970 * 1_000)
        var values = engines.filter { $0.id != value.id }
        values.append(value)
        await persist(values)
    }

    func delete(ids: Set<Int64>) async {
        await persist(engines.filter { !ids.contains($0.id) })
    }

    func importData(_ data: Data) async {
        do {
            let decoder = JSONDecoder()
            let imported: [HttpTTS]
            if let array = try? decoder.decode([HttpTTS].self, from: data) {
                imported = array
            } else {
                imported = [try decoder.decode(HttpTTS.self, from: data)]
            }
            let valid = imported.filter {
                !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && !$0.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            guard !valid.isEmpty else {
                errorMessage = "没有找到可用的朗读源：JSON 里需要有 name 和 url。"
                return
            }
            var byID = Dictionary(engines.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for value in valid { byID[value.id] = value }
            await persist(Array(byID.values))
            if errorMessage == nil { notice = "已导入 \(valid.count) 个朗读源" }
        } catch {
            errorMessage = "无法识别的朗读源 JSON：\(error.localizedDescription)"
        }
    }

    func importText(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "剪贴板里没有内容。"
            return
        }
        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) {
            await importURL(trimmed)
            return
        }
        await importData(Data(trimmed.utf8))
    }

    func importURL(_ value: String) async {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            errorMessage = "请输入以 http:// 或 https:// 开头的网址。"
            return
        }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            if let status = (response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(status) {
                errorMessage = "下载失败（HTTP \(status)）"
                return
            }
            await importData(data)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func restoreDefaults() async {
        do {
            let defaults = try bundledDefaults()
            var byID = Dictionary(engines.filter { $0.id >= 0 }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for value in defaults { byID[value.id] = value }
            await persist(Array(byID.values))
            if errorMessage == nil { notice = "已恢复内置朗读源" }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func exportData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(engines)
    }

    static func json(_ engine: HttpTTS) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(engine) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// 旧版内置朗读源里有试听必失败的写法（百度 pdt=160 已被接口拒绝；Next 引擎未配置接口时拼出 undefined 网址）。
    /// 用户没改过的旧预设，换成当前内置版本；用户自己改过的保持不动。
    static func upgradingBundledPresets(_ values: [HttpTTS]) -> [HttpTTS] {
        guard let url = Bundle.main.url(forResource: "httpTTS", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let defaults = try? JSONDecoder().decode([HttpTTS].self, from: data) else { return values }
        let bundled = Dictionary(defaults.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return values.map { stored in
            guard let fresh = bundled[stored.id] else { return stored }
            // 百度：旧参数（pdt=160 等）已被接口拒绝，没换成 pdt=301 的都换掉。
            let staleBaidu = stored.url.contains("tts.baidu.com/text2audio") && !stored.url.contains("pdt=301")
            // Next 引擎：第三方转发服务器已全部失效，换成内置 Edge 朗读版本（保留用户登录配置里选的发言人）。
            let staleNext = (stored.jsLib ?? "").contains("function apiurl(")
                && !(stored.jsLib ?? "").contains("iOS 内置Edge")
                && stored.lastUpdateTime <= 1_770_778_835_144
            guard staleBaidu || staleNext else { return stored }
            return fresh
        }
    }

    private func bundledDefaults() throws -> [HttpTTS] {
        guard let url = Bundle.main.url(forResource: "httpTTS", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try JSONDecoder().decode([HttpTTS].self, from: Data(contentsOf: url))
    }

    private func persist(_ values: [HttpTTS]) async {
        do {
            let values = sorted(values)
            try await repository().saveHttpTTS(values)
            engines = values
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func sorted(_ values: [HttpTTS]) -> [HttpTTS] {
        values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

// MARK: - 系统语音

enum SpeechVoiceCatalog {
    /// 已安装的中文系统语音（普通话 / 粤语 / 台湾），增强版排前。
    static var chineseVoices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("zh") }
            .sorted {
                if $0.quality != $1.quality { return $0.quality.rawValue > $1.quality.rawValue }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }

    static func label(_ voice: AVSpeechSynthesisVoice) -> String {
        let region: String
        switch voice.language {
        case "zh-CN": region = "普通话"
        case "zh-HK": region = "粤语"
        case "zh-TW": region = "台湾"
        default: region = voice.language
        }
        let gender: String
        switch voice.gender {
        case .male: gender = " · 男"
        case .female: gender = " · 女"
        default: gender = ""
        }
        return "\(voice.name)（\(region)\(gender)）" + (voice.quality == .enhanced ? " · 增强" : "")
    }

    /// AI 多角色朗读没有指定声音时，自动挑一个同性别的中文声音（优先普通话、避开旁白正在用的声音）。
    static func automaticVoice(gender: AVSpeechSynthesisVoiceGender, avoiding identifier: String?) -> AVSpeechSynthesisVoice? {
        let candidates = chineseVoices.filter { $0.gender == gender }
        let mandarin = candidates.filter { $0.language == "zh-CN" }
        let pool = mandarin.isEmpty ? candidates : mandarin
        return pool.first { $0.identifier != identifier } ?? pool.first
    }
}

// MARK: - AI 多角色朗读：设置

enum AIRoleKind: String, Codable, Sendable {
    case narrator, male, female, unknown
}

struct AIRoleAssignment: Codable, Equatable, Sendable {
    var name: String
    var kind: AIRoleKind
}

/// 一个 OpenAI 兼容的角色识别接口（API Key 单独存在 Keychain）。
struct AIRoleEndpoint: Codable, Hashable, Identifiable, Sendable {
    var id: String = UUID().uuidString.lowercased()
    var name: String = ""
    var baseURL: String = ""
    var model: String = ""
    var concurrency: Int = 2
    var batchCharacters: Int = 8_000
    var contextCharacters: Int = 160

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? values.decodeIfPresent(String.self, forKey: .id)) ?? UUID().uuidString.lowercased()
        name = (try? values.decodeIfPresent(String.self, forKey: .name)) ?? ""
        baseURL = (try? values.decodeIfPresent(String.self, forKey: .baseURL)) ?? ""
        model = (try? values.decodeIfPresent(String.self, forKey: .model)) ?? ""
        concurrency = min(max((try? values.decodeIfPresent(Int.self, forKey: .concurrency)) ?? 2, 1), 8)
        batchCharacters = min(max((try? values.decodeIfPresent(Int.self, forKey: .batchCharacters)) ?? 8_000, 1_000), 32_000)
        contextCharacters = min(max((try? values.decodeIfPresent(Int.self, forKey: .contextCharacters)) ?? 160, 0), 2_000)
    }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? model : trimmed
    }

    var isUsable: Bool {
        !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct AIRoleSpeechSettings: Codable, Equatable, Sendable {
    static let storageKey = "speech.aiRole.v1"

    var enabled = false
    var endpoints: [AIRoleEndpoint] = []
    var activeEndpointID: String?
    var maleVoiceID = ""
    var femaleVoiceID = ""
    var maleEngineID = ""
    var femaleEngineID = ""
    var variesCharacterPitch = true

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? values.decodeIfPresent(Bool.self, forKey: .enabled)) ?? false
        endpoints = (try? values.decodeIfPresent([AIRoleEndpoint].self, forKey: .endpoints)) ?? []
        activeEndpointID = try? values.decodeIfPresent(String.self, forKey: .activeEndpointID)
        maleVoiceID = (try? values.decodeIfPresent(String.self, forKey: .maleVoiceID)) ?? ""
        femaleVoiceID = (try? values.decodeIfPresent(String.self, forKey: .femaleVoiceID)) ?? ""
        maleEngineID = (try? values.decodeIfPresent(String.self, forKey: .maleEngineID)) ?? ""
        femaleEngineID = (try? values.decodeIfPresent(String.self, forKey: .femaleEngineID)) ?? ""
        variesCharacterPitch = (try? values.decodeIfPresent(Bool.self, forKey: .variesCharacterPitch)) ?? true
    }

    var activeEndpoint: AIRoleEndpoint? {
        endpoints.first { $0.id == activeEndpointID && $0.isUsable } ?? endpoints.first(where: \.isUsable)
    }

    var isActive: Bool { enabled && activeEndpoint != nil }

    static func load() -> AIRoleSpeechSettings {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let value = try? JSONDecoder().decode(AIRoleSpeechSettings.self, from: data) else { return AIRoleSpeechSettings() }
        return value
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}

/// API Key 只存在本机 Keychain（不进备份、不进 UserDefaults）。
enum AIRoleKeychain {
    private static let service = "legado.ai-role-speech"

    private static func baseQuery(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func key(for account: String) -> String {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    static func setKey(_ value: String, for account: String) {
        SecItemDelete(baseQuery(account) as CFDictionary)
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var query = baseQuery(account)
        query[kSecValueData as String] = Data(trimmed.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(query as CFDictionary, nil)
    }
}

@MainActor
final class AIRoleSpeechStore: ObservableObject {
    static let shared = AIRoleSpeechStore()

    @Published var settings: AIRoleSpeechSettings {
        didSet { settings.save() }
    }
    /// 识别结果缓存（片段原文 → 角色）：暂停后继续、重听同一章时不再重复请求。
    private var cache: [String: AIRoleAssignment] = [:]

    private init() {
        settings = AIRoleSpeechSettings.load()
    }

    func cached(_ text: String) -> AIRoleAssignment? { cache[text] }

    func remember(_ values: [String: AIRoleAssignment]) {
        guard !values.isEmpty else { return }
        if cache.count > 6_000 { cache.removeAll(keepingCapacity: true) }
        cache.merge(values) { _, new in new }
    }

    func clearCache() { cache.removeAll() }

    func upsert(_ endpoint: AIRoleEndpoint, apiKey: String) {
        var value = settings
        if let index = value.endpoints.firstIndex(where: { $0.id == endpoint.id }) {
            value.endpoints[index] = endpoint
        } else {
            value.endpoints.append(endpoint)
        }
        if value.activeEndpointID == nil || !value.endpoints.contains(where: { $0.id == value.activeEndpointID }) {
            value.activeEndpointID = endpoint.id
        }
        AIRoleKeychain.setKey(apiKey, for: endpoint.id)
        settings = value
        cache.removeAll()
    }

    func delete(_ ids: Set<String>) {
        var value = settings
        value.endpoints.removeAll { ids.contains($0.id) }
        for id in ids { AIRoleKeychain.setKey("", for: id) }
        if let active = value.activeEndpointID, ids.contains(active) { value.activeEndpointID = value.endpoints.first?.id }
        if value.endpoints.isEmpty { value.enabled = false }
        settings = value
        cache.removeAll()
    }

    func activate(_ id: String) {
        guard settings.activeEndpointID != id else { return }
        settings.activeEndpointID = id
        cache.removeAll()
    }
}

// MARK: - AI 多角色朗读：文本拆分

enum AIRoleText {
    private static let openQuotes: Set<Character> = ["\u{201C}", "「", "『", "﹁", "﹃"]
    private static let closeQuotes: Set<Character> = ["\u{201D}", "」", "』", "﹂", "﹄"]

    static func isDialogue(_ text: String) -> Bool {
        text.contains { openQuotes.contains($0) || $0 == "\"" }
    }

    /// 把一段拆成旁白 / 对白片段：引号内（含引号）是一片，引号外是一片；只有标点的碎片并到前一片。
    static func split(_ line: String) -> [String] {
        guard isDialogue(line) else { return [line] }
        var pieces: [String] = []
        var current = ""
        var inQuote = false
        for character in line {
            if !inQuote, openQuotes.contains(character) || character == "\"" {
                flush(&current, into: &pieces)
                inQuote = true
                current.append(character)
            } else if inQuote, closeQuotes.contains(character) || character == "\"" {
                current.append(character)
                inQuote = false
                flush(&current, into: &pieces)
            } else {
                current.append(character)
            }
        }
        flush(&current, into: &pieces)
        return pieces.isEmpty ? [line] : pieces
    }

    private static func flush(_ current: inout String, into pieces: inout [String]) {
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        current = ""
        guard !trimmed.isEmpty else { return }
        let hasWords = trimmed.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
        if !hasWords, !pieces.isEmpty {
            pieces[pieces.count - 1] += trimmed
        } else {
            pieces.append(trimmed)
        }
    }

    /// 同性别的不同角色按名字给一个稳定的音调微调（0.92～1.08），听得出是不同的人。
    static func pitchVariation(for name: String) -> Float {
        let hash = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return 0.92 + Float(hash % 5) * 0.04
    }
}

// MARK: - AI 多角色朗读：接口

enum AIRoleError: LocalizedError {
    case invalidURL
    case http(Int, String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .invalidURL: "Base URL 无效"
        case .http(let status, let body): "接口返回 HTTP \(status)\(body.isEmpty ? "" : "：\(body)")"
        case .badResponse: "接口返回的内容不是 OpenAI 兼容格式"
        }
    }
}

struct AIRoleAnalyzer: Sendable {
    let endpoint: AIRoleEndpoint
    let apiKey: String

    private static let systemPrompt = """
    你是中文小说有声书的角色标注助手。用户给出带编号的段落，标记了 [对白] 的段落需要判断说话人。
    只输出一个 JSON 对象，不要任何解释或 Markdown：
    {"roles":[{"id":编号,"name":"说话人","gender":"male|female|unknown"}]}
    规则：
    1. 只为标记了 [对白] 的段落输出；结合前后文（如“他说”“她笑道”）判断是谁在说话。
    2. 同一个人始终用同一个名字（优先用全名）；无法确定姓名时用称谓（如“老者”“少女”）。
    3. 引号内其实是心理活动、引用、书名或无法判断说话人时，name 写“旁白”。
    4. gender 依据角色性别：男性 male，女性 female，不确定 unknown。
    """

    var completionsURL: URL? {
        var base = endpoint.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard !base.isEmpty else { return nil }
        if !base.hasSuffix("/chat/completions") { base += "/chat/completions" }
        return URL(string: base)
    }

    func testConnection() async throws -> String {
        let reply = try await chat(system: "你是接口连通性测试助手。", user: "请只回复两个字母：OK", maxTokens: 16)
        return reply.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func chat(system: String, user: String, maxTokens: Int? = nil) async throws -> String {
        guard let url = completionsURL else { throw AIRoleError.invalidURL }
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        var body: [String: Any] = [
            "model": endpoint.model.trimmingCharacters(in: .whitespacesAndNewlines),
            "temperature": 0,
            "stream": false,
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]]
        ]
        if let maxTokens { body["max_tokens"] = maxTokens }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw AIRoleError.http(status, String(String(decoding: data, as: UTF8.self).prefix(200)))
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else { throw AIRoleError.badResponse }
        return content
    }

    /// 把片段切成连续的批次（每批字数不超过上限，第一批更小以便尽快开口），只保留含有未识别对白的批次。
    static func batches(for segments: [String], limit: Int, firstLimit: Int, known: Set<Int>) -> [ClosedRange<Int>] {
        var output: [ClosedRange<Int>] = []
        var start = 0
        var count = 0
        for index in segments.indices {
            let length = segments[index].count
            let budget = output.isEmpty ? firstLimit : limit
            if index > start, count + length > budget {
                output.append(start...(index - 1))
                start = index
                count = 0
            }
            count += length
        }
        if !segments.isEmpty { output.append(start...(segments.count - 1)) }
        return output.filter { range in
            range.contains { !known.contains($0) && AIRoleText.isDialogue(segments[$0]) }
        }
    }

    func analyze(_ range: ClosedRange<Int>, in segments: [String]) async throws -> [Int: AIRoleAssignment] {
        let dialogue = range.filter { segments.indices.contains($0) && AIRoleText.isDialogue(segments[$0]) }
        guard !dialogue.isEmpty else { return [:] }
        var user = ""
        if endpoint.contextCharacters > 0, range.lowerBound > 0 {
            var pieces: [String] = []
            var count = 0
            for index in stride(from: range.lowerBound - 1, through: 0, by: -1) {
                pieces.insert(segments[index], at: 0)
                count += segments[index].count
                if count >= endpoint.contextCharacters { break }
            }
            let context = String(pieces.joined(separator: "\n").suffix(endpoint.contextCharacters))
            user += "【前文，仅供参考】\n\(context)\n\n"
        }
        user += "【待标注段落】\n"
        for index in range where segments.indices.contains(index) {
            user += AIRoleText.isDialogue(segments[index]) ? "[\(index)][对白] " : "[\(index)] "
            user += segments[index] + "\n"
        }
        let reply = try await chat(system: Self.systemPrompt, user: user)
        return Self.parse(reply, allowed: Set(dialogue))
    }

    static func parse(_ reply: String, allowed: Set<Int>) -> [Int: AIRoleAssignment] {
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start < end,
              let data = String(reply[start...end]).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let roles = object["roles"] as? [[String: Any]] else { return [:] }
        var output: [Int: AIRoleAssignment] = [:]
        for role in roles {
            let index: Int?
            if let value = role["id"] as? Int {
                index = value
            } else if let value = role["id"] as? String {
                index = Int(value.trimmingCharacters(in: CharacterSet(charactersIn: "[] ")))
            } else {
                index = nil
            }
            guard let index, allowed.contains(index) else { continue }
            let name = ((role["name"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let gender = ((role["gender"] as? String) ?? "").lowercased()
            let kind: AIRoleKind
            if name.isEmpty || name == "旁白" || gender == "narrator" {
                kind = .narrator
            } else if gender.hasPrefix("f") || gender.contains("女") {
                kind = .female
            } else if gender.hasPrefix("m") || gender.contains("男") {
                kind = .male
            } else {
                kind = .unknown
            }
            output[index] = AIRoleAssignment(name: name.isEmpty ? "旁白" : name, kind: kind)
        }
        return output
    }
}

// MARK: - 朗读管理

struct HttpTTSManagementView: View {
    @StateObject private var model = HttpTTSLibraryModel()
    @ObservedObject private var roles = AIRoleSpeechStore.shared
    @StateObject private var speech = ReaderSpeechController()
    @AppStorage("appTtsEngine") private var defaultEngine = ""
    @AppStorage("systemTtsVoice") private var systemVoice = ""
    @State private var query = ""
    @State private var editing: HttpTTS?
    @State private var importsFile = false
    @State private var exportsFile = false
    @State private var exportDocument = HttpTTSJSONDocument(data: Data("[]".utf8))
    @State private var importsFromNetwork = false
    @State private var cacheBytes: Int64 = 0
    @State private var confirmsClearCache = false
    @State private var previewingID: Int64?

    private static let previewText = "这是朗读试听：雨落在旧城的瓦檐上，故事从一束灯光开始。"

    private var filtered: [HttpTTS] {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return model.engines }
        return model.engines.filter {
            $0.name.localizedCaseInsensitiveContains(keyword) || $0.url.localizedCaseInsensitiveContains(keyword)
        }
    }

    private var cacheText: String {
        cacheBytes == 0 ? "无缓存" : ByteCountFormatter.string(fromByteCount: cacheBytes, countStyle: .file)
    }

    var body: some View {
        List {
            Section {
                Picker("默认朗读", selection: $defaultEngine) {
                    Text("系统语音").tag("")
                    ForEach(model.engines) { engine in
                        Text(engine.name).tag(String(engine.id))
                    }
                }
                Picker("系统声音", selection: $systemVoice) {
                    Text("系统默认中文声音").tag("")
                    ForEach(SpeechVoiceCatalog.chineseVoices, id: \.identifier) { voice in
                        Text(SpeechVoiceCatalog.label(voice)).tag(voice.identifier)
                    }
                }
                Button {
                    previewSystemVoice()
                } label: {
                    Label(previewingID == -1 && speech.isSpeaking ? "停止试听" : "试听系统声音",
                          systemImage: previewingID == -1 && speech.isSpeaking ? "stop.circle" : "play.circle")
                }
            } header: {
                Text("默认朗读")
            } footer: {
                Text("阅读页的朗读按钮默认使用这里的设置；单本书可以在阅读页的阅读设置里单独指定朗读源。")
            }
            .readingRowBackground()

            Section("AI 多角色朗读") {
                NavigationLink {
                    AIRoleSpeechView()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "person.2.wave.2")
                            .foregroundStyle(ReadingTheme.accent)
                            .frame(width: 26)
                        Text("角色识别接口")
                        Spacer(minLength: 8)
                        Text(roles.settings.isActive ? "已开启" : "已关闭")
                            .font(AppFontStyle.footnote.themed)
                            .foregroundStyle(ReadingTheme.secondaryInk)
                    }
                }
            }
            .readingRowBackground()

            Section {
                if filtered.isEmpty {
                    emptyState
                } else {
                    ForEach(filtered) { engine in
                        engineRow(engine)
                    }
                    .onDelete { offsets in
                        let ids = Set(offsets.map { filtered[$0].id })
                        if ids.contains(where: { String($0) == defaultEngine }) { defaultEngine = "" }
                        Task { await model.delete(ids: ids) }
                    }
                }
            } header: {
                Text(model.engines.isEmpty ? "朗读源" : "朗读源 · \(model.engines.count)")
            }
            .readingRowBackground()

            Section {
                HStack {
                    Text("TTS 缓存")
                    Spacer()
                    Text(cacheText).foregroundStyle(ReadingTheme.secondaryInk)
                }
                Button(role: .destructive) {
                    confirmsClearCache = true
                } label: {
                    Label("清除 TTS 缓存", systemImage: "trash")
                }
                .disabled(cacheBytes == 0)
            } header: {
                Text("缓存")
            } footer: {
                Text("在线 TTS 通过网络合成语音，需要网络连接。朗读源为 JSON 格式，支持从剪贴板、网址或文件导入。选择朗读源后，在阅读页点击朗读即使用在线 TTS；合成过的音频会缓存，重听不再消耗流量。")
            }
            .readingRowBackground()
        }
        .readingThemedListBackground()
        .navigationTitle("朗读管理")
        .readingInlineSearch(text: $query, prompt: "搜索朗读源")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("新建朗读源", systemImage: "square.and.pencil") { editing = HttpTTS() }
                    Divider()
                    Button("从剪贴板导入", systemImage: "doc.on.clipboard") {
                        let text = UIPasteboard.general.string ?? ""
                        Task { await model.importText(text) }
                    }
                    Button("从网络导入", systemImage: "globe") { importsFromNetwork = true }
                    Button("从文件导入", systemImage: "folder") { importsFile = true }
                    Divider()
                    Button("导出全部", systemImage: "square.and.arrow.up") {
                        do {
                            exportDocument = .init(data: try model.exportData())
                            exportsFile = true
                        } catch { model.errorMessage = error.localizedDescription }
                    }
                    .disabled(model.engines.isEmpty)
                    Button("恢复内置朗读源", systemImage: "arrow.counterclockwise") {
                        Task { await model.restoreDefaults() }
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("添加朗读源")
            }
        }
        .task {
            await model.load()
            await refreshCacheSize()
        }
        .onDisappear { speech.stop() }
        .sheet(item: $editing) { engine in
            ReadingNavigationStack {
                HttpTTSEditorView(engine: engine, isNew: !model.engines.contains { $0.id == engine.id }) { value in
                    Task { await model.save(value) }
                }
            }
        }
        .sheet(isPresented: $importsFromNetwork) {
            ReadingNavigationStack {
                HttpTTSNetworkImportView { url in
                    Task { await model.importURL(url) }
                }
            }
        }
        .fileImporter(isPresented: $importsFile, allowedContentTypes: [.json, .plainText, .data]) { result in
            do {
                let url = try result.get()
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url)
                Task { await model.importData(data) }
            } catch { model.errorMessage = error.localizedDescription }
        }
        .fileExporter(
            isPresented: $exportsFile,
            document: exportDocument,
            contentType: .json,
            defaultFilename: "httpTTS"
        ) { result in
            if case .failure(let error) = result { model.errorMessage = error.localizedDescription }
        }
        .confirmationDialog("清除全部 TTS 缓存？", isPresented: $confirmsClearCache, titleVisibility: .visible) {
            Button("清除", role: .destructive) {
                Task {
                    await HttpTTSAudioCache.shared.clear()
                    roles.clearCache()
                    await refreshCacheSize()
                }
            }
        }
        .alert("朗读管理", isPresented: Binding(
            get: { model.errorMessage != nil || model.notice != nil },
            set: { if !$0 { model.errorMessage = nil; model.notice = nil } }
        )) {
            Button("确定", role: .cancel) { model.errorMessage = nil; model.notice = nil }
        } message: {
            Text(model.errorMessage ?? model.notice ?? "")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform.circle")
                .font(AppFontStyle.system(size: 40, weight: .light).themed)
                .foregroundStyle(ReadingTheme.accent)
            Text(query.isEmpty ? "暂无朗读源" : "没有匹配的朗读源")
                .font(AppFontStyle.headline.themed)
            Text(query.isEmpty ? "点击右上角 + 从剪贴板、网络或文件导入 TTS 源 JSON，或新建一个朗读源。" : "换个关键词试试。")
                .font(AppFontStyle.footnote.themed)
                .foregroundStyle(ReadingTheme.secondaryInk)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    private func engineRow(_ engine: HttpTTS) -> some View {
        let isDefault = defaultEngine == String(engine.id)
        let isPreviewing = previewingID == engine.id && speech.isSpeaking
        return Button {
            editing = engine
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(engine.name)
                            .foregroundStyle(ReadingTheme.ink)
                            .lineLimit(1)
                        if isDefault {
                            Text("默认")
                                .font(AppFontStyle.caption.themed)
                                .foregroundStyle(ReadingTheme.accent)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .overlay(Capsule().strokeBorder(ReadingTheme.accent.opacity(0.6), lineWidth: 0.6))
                        }
                    }
                    Text(engine.url)
                        .font(AppFontStyle.caption.themed)
                        .foregroundStyle(ReadingTheme.secondaryInk)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                Button {
                    preview(engine)
                } label: {
                    Image(systemName: isPreviewing ? "stop.circle.fill" : "play.circle")
                        .font(AppFontStyle.system(size: 22, weight: .regular).themed)
                        .foregroundStyle(ReadingTheme.accent)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(isPreviewing ? "停止试听" : "试听")
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(isDefault ? "已是默认朗读" : "设为默认朗读", systemImage: "checkmark.circle") {
                defaultEngine = String(engine.id)
            }
            .disabled(isDefault)
            Button("试听", systemImage: "play.circle") { preview(engine) }
            Button("编辑", systemImage: "square.and.pencil") { editing = engine }
            Button("复制源 JSON", systemImage: "doc.on.doc") {
                UIPasteboard.general.string = HttpTTSLibraryModel.json(engine)
            }
            Button("删除", systemImage: "trash", role: .destructive) {
                if isDefault { defaultEngine = "" }
                Task { await model.delete(ids: [engine.id]) }
            }
        }
    }

    private func preview(_ engine: HttpTTS) {
        if speech.isSpeaking, previewingID == engine.id {
            speech.stop()
            previewingID = nil
            return
        }
        speech.stop()
        previewingID = engine.id
        speech.allowsRoleAnalysis = false
        speech.configure(followsSystemRate: false, speechRate: 5, readByPage: true, streamsHTTPAudio: true)
        speech.speakHTTP(engine: engine, text: Self.previewText)
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await refreshCacheSize()
        }
    }

    private func previewSystemVoice() {
        if speech.isSpeaking, previewingID == -1 {
            speech.stop()
            previewingID = nil
            return
        }
        speech.stop()
        previewingID = -1
        speech.allowsRoleAnalysis = false
        speech.configure(followsSystemRate: true, speechRate: 5, readByPage: true, voiceIdentifier: systemVoice)
        speech.speak(Self.previewText)
    }

    private func refreshCacheSize() async {
        cacheBytes = await HttpTTSAudioCache.shared.totalBytes()
    }
}

private struct HttpTTSNetworkImportView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    let onImport: (String) -> Void

    var body: some View {
        Form {
            Section {
                TextField("https://…", text: $url)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
            } header: {
                Text("网址")
            } footer: {
                Text("输入朗读源 JSON 的网址（单个源或数组都可以），同 id 的朗读源会被覆盖。")
            }
            .readingRowBackground()
        }
        .readingThemedListBackground()
        .navigationTitle("从网络导入")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("导入") {
                    onImport(url)
                    dismiss()
                }
                .disabled(url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .onAppear {
            if let text = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
               text.lowercased().hasPrefix("http") {
                url = text
            }
        }
    }
}

// MARK: - 朗读源编辑

private enum HttpTTSField: String, Identifiable {
    case name, url, contentType, concurrentRate, header, jsLib, loginCheckJs, loginUrl, loginUi, loginInfo

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: "名称"
        case .url: "URL"
        case .contentType: "Content-Type"
        case .concurrentRate: "并发率"
        case .header: "请求头"
        case .jsLib: "JS 库"
        case .loginCheckJs: "登录检查 JS"
        case .loginUrl: "登录 URL"
        case .loginUi: "登录界面"
        case .loginInfo: "登录信息"
        }
    }

    var placeholder: String {
        switch self {
        case .name: "朗读源名称"
        case .url: "URL，支持 {{speakText}}、{{speakSpeed}} 与 JS"
        case .contentType: "响应类型校验正则，如 audio/mpeg"
        case .concurrentRate: "如 1/1000（每秒最多 1 次）"
        case .header: "请求头 JSON"
        case .jsLib: "JS 库"
        case .loginCheckJs: "登录检查 JS"
        case .loginUrl: "登录 URL 或登录脚本"
        case .loginUi: "登录界面 JSON"
        case .loginInfo: "登录信息 JSON"
        }
    }

    var monospaced: Bool { self != .name }
}

private struct HttpTTSEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var engine: HttpTTS
    let isNew: Bool
    let onSave: (HttpTTS) -> Void
    @StateObject private var speech = ReaderSpeechController()
    @State private var testText = "这是一段朗读源试听文本。"
    @State private var loginInfo: String
    @State private var showsLoginForm = false
    @State private var expanded: Set<String> = ["basic", "request"]
    @State private var expandedField: HttpTTSField?
    @State private var showsHelp = false
    @State private var message: String?
    @State private var confirmsDiscard = false
    private let original: HttpTTS

    init(engine: HttpTTS, isNew: Bool = false, onSave: @escaping (HttpTTS) -> Void) {
        _engine = State(initialValue: engine)
        original = engine
        self.isNew = isNew
        self.onSave = onSave
        _loginInfo = State(initialValue: BookSourceRuntimeStore.shared.get(sourceID: engine.sourceKey, key: "loginInfo"))
    }

    private var canSave: Bool {
        !engine.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !engine.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Form {
            Section {
                if expanded.contains("basic") {
                    field(.name)
                    field(.url)
                    field(.contentType)
                    field(.concurrentRate)
                }
            } header: {
                sectionHeader("基本信息", key: "basic")
            }
            .readingRowBackground()

            Section {
                if expanded.contains("request") {
                    field(.header)
                    Toggle("启用 Cookie", isOn: optionalBool(\.enabledCookieJar))
                }
            } header: {
                sectionHeader("请求配置", key: "request")
            }
            .readingRowBackground()

            Section {
                if expanded.contains("script") {
                    field(.jsLib)
                    field(.loginCheckJs)
                }
            } header: {
                sectionHeader("脚本", key: "script")
            }
            .readingRowBackground()

            Section {
                if expanded.contains("login") {
                    field(.loginUrl)
                    field(.loginUi)
                    field(.loginInfo)
                    if engine.loginUi?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                        Button("打开登录表单", systemImage: "person.badge.key") { showsLoginForm = true }
                    }
                }
            } header: {
                sectionHeader("登录 / 配置 UI", key: "login")
            }
            .readingRowBackground()

            Section {
                TextField("试听文本", text: $testText)
                Button {
                    preview()
                } label: {
                    Label(speech.isSpeaking ? "停止试听" : "试听", systemImage: speech.isSpeaking ? "stop.circle" : "play.circle")
                }
                .disabled(engine.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if let error = speech.errorMessage {
                    Text(error).foregroundStyle(.red).font(AppFontStyle.footnote.themed)
                }
            } header: {
                Text("试听")
            }
            .readingRowBackground()
        }
        .readingThemedListBackground()
        .navigationTitle(isNew ? "新建朗读源" : (engine.name.isEmpty ? "编辑朗读源" : engine.name))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") {
                    if engine != original { confirmsDiscard = true } else { dismiss() }
                }
            }
            ToolbarItemGroup(placement: .confirmationAction) {
                Menu {
                    Button("帮助", systemImage: "questionmark.circle") { showsHelp = true }
                    Button("试听", systemImage: "play.circle") { preview() }
                    Divider()
                    Button("查看登录头", systemImage: "eye") {
                        let header = BookSourceRuntimeStore.shared.get(sourceID: engine.sourceKey, key: "loginHeader")
                        message = header.isEmpty ? "当前没有登录头。" : header
                    }
                    Button("清除登录头", systemImage: "trash", role: .destructive) {
                        BookSourceRuntimeStore.shared.put(sourceID: engine.sourceKey, key: "loginHeader", value: "")
                        message = "已清除登录头。"
                    }
                    Divider()
                    Button("复制源 JSON", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = HttpTTSLibraryModel.json(engine)
                        message = "已复制朗读源 JSON。"
                    }
                    Button("粘贴源", systemImage: "doc.on.clipboard") { pasteSource() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                Button("保存") {
                    BookSourceRuntimeStore.shared.put(sourceID: engine.sourceKey, key: "loginInfo", value: loginInfo)
                    onSave(engine)
                    dismiss()
                }
                .disabled(!canSave)
            }
        }
        .sheet(isPresented: $showsLoginForm) {
            ReadingNavigationStack {
                HttpTTSLoginView(engine: engine) { value in loginInfo = value }
            }
        }
        .sheet(item: $expandedField) { field in
            HttpTTSFieldEditor(title: field.title, text: binding(for: field))
        }
        .alert("朗读源", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("确定", role: .cancel) { message = nil }
        } message: {
            Text(message ?? "")
        }
        .alert("朗读源帮助", isPresented: $showsHelp) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text("URL 与阅读 App（Legado）的朗读源格式一致：{{speakText}} 是朗读文本、{{speakSpeed}} 是语速，可用 @js: 或 <js></js> 写脚本，也可以用「url,{\"method\":\"POST\",\"body\":...}」发 POST。Content-Type 用来校验返回的是音频；并发率如 1/1000 表示每 1000 毫秒最多请求 1 次。需要登录的源填写登录 URL / 登录界面，保存后在「打开登录表单」里登录。")
        }
        .confirmationDialog("放弃未保存的修改？", isPresented: $confirmsDiscard, titleVisibility: .visible) {
            Button("放弃修改", role: .destructive) { dismiss() }
        }
        .onDisappear { speech.stop() }
    }

    private func sectionHeader(_ title: String, key: String) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                if expanded.contains(key) { expanded.remove(key) } else { expanded.insert(key) }
            }
        } label: {
            HStack {
                Text(title)
                    .font(AppFontStyle.subheadline.weight(.semibold).themed)
                    .foregroundStyle(ReadingTheme.ink)
                Spacer()
                Image(systemName: expanded.contains(key) ? "chevron.up" : "chevron.down")
                    .font(AppFontStyle.caption.weight(.semibold).themed)
                    .foregroundStyle(ReadingTheme.secondaryInk)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .textCase(nil)
        .accessibilityLabel("\(title)，\(expanded.contains(key) ? "已展开" : "已收起")")
    }

    private func field(_ field: HttpTTSField) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(field.title)
                    .font(AppFontStyle.caption.weight(.medium).themed)
                    .foregroundStyle(ReadingTheme.ink)
                Text(field.rawValue)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(ReadingTheme.secondaryInk.opacity(0.7))
                Spacer()
                Button {
                    expandedField = field
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(AppFontStyle.caption.themed)
                        .foregroundStyle(ReadingTheme.accent)
                        .frame(width: 28, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("全屏编辑\(field.title)")
            }
            TextField(field.placeholder, text: binding(for: field))
                .font(field.monospaced ? .system(.callout, design: .monospaced) : AppFontStyle.body.themed)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
        }
        .padding(.vertical, 2)
    }

    private func binding(for field: HttpTTSField) -> Binding<String> {
        switch field {
        case .name: $engine.name
        case .url: $engine.url
        case .contentType: optional(\.contentType)
        case .concurrentRate: optional(\.concurrentRate)
        case .header: optional(\.header)
        case .jsLib: optional(\.jsLib)
        case .loginCheckJs: optional(\.loginCheckJs)
        case .loginUrl: optional(\.loginUrl)
        case .loginUi: optional(\.loginUi)
        case .loginInfo: $loginInfo
        }
    }

    private func preview() {
        if speech.isSpeaking {
            speech.stop()
            return
        }
        speech.allowsRoleAnalysis = false
        speech.configure(followsSystemRate: false, speechRate: 5, readByPage: true, streamsHTTPAudio: true)
        speech.speakHTTP(engine: engine, text: testText.isEmpty ? "朗读源试听" : testText)
    }

    private func pasteSource() {
        guard let text = UIPasteboard.general.string, let data = text.data(using: .utf8) else {
            message = "剪贴板里没有朗读源 JSON。"
            return
        }
        let decoder = JSONDecoder()
        let pasted = (try? decoder.decode(HttpTTS.self, from: data)) ?? (try? decoder.decode([HttpTTS].self, from: data))?.first
        guard var value = pasted, !value.url.isEmpty else {
            message = "剪贴板里不是有效的朗读源 JSON。"
            return
        }
        value.id = engine.id
        engine = value
        message = "已粘贴朗读源，保存后生效。"
    }

    private func optional(_ keyPath: WritableKeyPath<HttpTTS, String?>) -> Binding<String> {
        Binding(get: { engine[keyPath: keyPath] ?? "" }, set: { engine[keyPath: keyPath] = $0.isEmpty ? nil : $0 })
    }

    private func optionalBool(_ keyPath: WritableKeyPath<HttpTTS, Bool?>) -> Binding<Bool> {
        Binding(get: { engine[keyPath: keyPath] == true }, set: { engine[keyPath: keyPath] = $0 })
    }
}

private struct HttpTTSFieldEditor: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    @Binding var text: String

    var body: some View {
        ReadingNavigationStack {
            TextEditor(text: $text)
                .font(.system(.callout, design: .monospaced))
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .padding(.horizontal, 12)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("清空") { text = "" }.disabled(text.isEmpty)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { dismiss() }
                    }
                }
        }
    }
}

// MARK: - AI 多角色朗读页面

struct AIRoleSpeechView: View {
    @ObservedObject private var store = AIRoleSpeechStore.shared
    @StateObject private var library = HttpTTSLibraryModel()
    @State private var editing: AIRoleEndpoint?
    @State private var showsNoEndpoint = false

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { store.settings.enabled },
            set: { value in
                if value, store.settings.activeEndpoint == nil {
                    showsNoEndpoint = true
                    return
                }
                store.settings.enabled = value
            }
        )
    }

    var body: some View {
        List {
            Section {
                Toggle(isOn: enabledBinding) {
                    Label("AI 多角色朗读", systemImage: "person.2.wave.2")
                }
            } footer: {
                Text("开启后，朗读时先由 AI 判断每句对白是哪个角色说的：旁白用默认声音，男 / 女角色换成下面设置的声音，同性别的不同角色还会自动微调音调。AI 只负责判断角色，语音仍由 App 的系统语音或在线朗读源生成。")
            }
            .readingRowBackground()

            Section {
                if store.settings.endpoints.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "server.rack")
                            .font(AppFontStyle.system(size: 34, weight: .light).themed)
                            .foregroundStyle(ReadingTheme.accent)
                        Text("暂无接口配置")
                            .font(AppFontStyle.headline.themed)
                        Text("点击右上角 + 添加 OpenAI 兼容接口")
                            .font(AppFontStyle.footnote.themed)
                            .foregroundStyle(ReadingTheme.secondaryInk)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                } else {
                    ForEach(store.settings.endpoints) { endpoint in
                        endpointRow(endpoint)
                    }
                    .onDelete { offsets in
                        let ids = Set(offsets.map { store.settings.endpoints[$0].id })
                        store.delete(ids)
                    }
                }
            } header: {
                Text("接口配置")
            } footer: {
                if store.settings.endpoints.count > 1 {
                    Text("点选一个接口作为当前使用的接口。")
                }
            }
            .readingRowBackground()

            Section {
                Picker("男性角色", selection: $store.settings.maleVoiceID) {
                    Text("自动选择").tag("")
                    ForEach(SpeechVoiceCatalog.chineseVoices, id: \.identifier) { voice in
                        Text(SpeechVoiceCatalog.label(voice)).tag(voice.identifier)
                    }
                }
                Picker("女性角色", selection: $store.settings.femaleVoiceID) {
                    Text("自动选择").tag("")
                    ForEach(SpeechVoiceCatalog.chineseVoices, id: \.identifier) { voice in
                        Text(SpeechVoiceCatalog.label(voice)).tag(voice.identifier)
                    }
                }
                Toggle("同性别角色自动区分音调", isOn: $store.settings.variesCharacterPitch)
            } header: {
                Text("系统语音")
            } footer: {
                Text("使用系统语音朗读时生效。「自动选择」会挑一个同性别的中文声音；没有安装时用音调区分。可在 iOS 设置 › 辅助功能 › 朗读内容 › 声音 里下载更多中文声音。")
            }
            .readingRowBackground()

            Section {
                Picker("男性角色", selection: $store.settings.maleEngineID) {
                    Text("与默认朗读源相同").tag("")
                    ForEach(library.engines) { engine in
                        Text(engine.name).tag(String(engine.id))
                    }
                }
                Picker("女性角色", selection: $store.settings.femaleEngineID) {
                    Text("与默认朗读源相同").tag("")
                    ForEach(library.engines) { engine in
                        Text(engine.name).tag(String(engine.id))
                    }
                }
            } header: {
                Text("在线朗读源")
            } footer: {
                Text("使用在线朗读源时生效：男 / 女角色可以各用一个音色不同的朗读源，旁白仍用默认朗读源。")
            }
            .readingRowBackground()
        }
        .readingThemedListBackground()
        .navigationTitle("AI 多角色朗读")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    editing = AIRoleEndpoint()
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("添加接口")
            }
        }
        .task { await library.load() }
        .sheet(item: $editing) { endpoint in
            ReadingNavigationStack {
                AIRoleEndpointEditor(endpoint: endpoint) { saved, key in
                    store.upsert(saved, apiKey: key)
                }
            }
        }
        .alert("无法开启", isPresented: $showsNoEndpoint) {
            Button("确定", role: .cancel) {}
        } message: {
            Text("请先添加一个可用的 OpenAI 兼容接口配置（需要 Base URL 和模型名称）。")
        }
    }

    private func endpointRow(_ endpoint: AIRoleEndpoint) -> some View {
        let isActive = store.settings.activeEndpoint?.id == endpoint.id
        return Button {
            store.activate(endpoint.id)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isActive ? ReadingTheme.accent : ReadingTheme.secondaryInk)
                VStack(alignment: .leading, spacing: 3) {
                    Text(endpoint.displayName.isEmpty ? "未命名接口" : endpoint.displayName)
                        .foregroundStyle(ReadingTheme.ink)
                    Text("\(endpoint.model) · \(endpoint.baseURL)")
                        .font(AppFontStyle.caption.themed)
                        .foregroundStyle(ReadingTheme.secondaryInk)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Button {
                    editing = endpoint
                } label: {
                    Image(systemName: "info.circle")
                        .foregroundStyle(ReadingTheme.accent)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("编辑接口")
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("编辑", systemImage: "square.and.pencil") { editing = endpoint }
            Button("删除", systemImage: "trash", role: .destructive) { store.delete([endpoint.id]) }
        }
    }
}

private struct AIRoleEndpointEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var endpoint: AIRoleEndpoint
    @State private var apiKey: String
    @State private var testing = false
    @State private var testResult: String?
    @State private var testSucceeded = false
    let onSave: (AIRoleEndpoint, String) -> Void

    init(endpoint: AIRoleEndpoint, onSave: @escaping (AIRoleEndpoint, String) -> Void) {
        _endpoint = State(initialValue: endpoint)
        _apiKey = State(initialValue: AIRoleKeychain.key(for: endpoint.id))
        self.onSave = onSave
    }

    var body: some View {
        Form {
            Section("基本信息") {
                TextField("配置名称", text: $endpoint.name)
                TextField("Base URL，如 https://api.openai.com/v1", text: $endpoint.baseURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                TextField("模型名称", text: $endpoint.model)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
            }
            .readingRowBackground()

            Section {
                SecureField("API Key（可选）", text: $apiKey)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
            } header: {
                Text("密钥")
            } footer: {
                Text("API Key 仅保存在本机 Keychain，不包含在备份中。")
            }
            .readingRowBackground()

            Section {
                Stepper(value: $endpoint.concurrency, in: 1...8) {
                    valueRow("并发批数", "\(endpoint.concurrency)")
                }
                Stepper(value: $endpoint.batchCharacters, in: 1_000...32_000, step: 1_000) {
                    valueRow("单批字符上限", endpoint.batchCharacters.formatted())
                }
                Stepper(value: $endpoint.contextCharacters, in: 0...2_000, step: 40) {
                    valueRow("上下文窗口", "\(endpoint.contextCharacters)")
                }
            } header: {
                Text("分析参数")
            } footer: {
                Text("并发批数越高分析越快，但可能触发接口限流；上下文窗口越小，每次分析的输入 token 越少。")
            }
            .readingRowBackground()

            Section {
                Button {
                    test()
                } label: {
                    HStack {
                        Label("测试连接", systemImage: "bolt.horizontal.circle")
                        Spacer()
                        if testing { ProgressView() }
                    }
                }
                .disabled(testing || !endpoint.isUsable)
                if let testResult {
                    Text(testResult)
                        .font(AppFontStyle.footnote.themed)
                        .foregroundStyle(testSucceeded ? Color.green : Color.red)
                }
            } footer: {
                Text("Base URL 应为包含 /v1 的 API 根地址，App 会自动追加 /chat/completions。")
            }
            .readingRowBackground()
        }
        .readingThemedListBackground()
        .navigationTitle("添加接口")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") {
                    var value = endpoint
                    value.baseURL = value.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
                    value.model = value.model.trimmingCharacters(in: .whitespacesAndNewlines)
                    value.name = value.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    onSave(value, apiKey)
                    dismiss()
                }
                .disabled(!endpoint.isUsable)
            }
        }
    }

    private func valueRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).monospacedDigit().foregroundStyle(ReadingTheme.secondaryInk)
        }
    }

    private func test() {
        testing = true
        testResult = nil
        let analyzer = AIRoleAnalyzer(endpoint: endpoint, apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
        Task {
            do {
                let reply = try await analyzer.testConnection()
                testSucceeded = true
                testResult = "连接成功：\(reply.prefix(40))"
            } catch {
                testSucceeded = false
                testResult = "连接失败：\(error.localizedDescription)"
            }
            testing = false
        }
    }
}

private struct HttpTTSLoginRow: Decodable, Identifiable {
    var name = ""
    var type = "text"
    var action: String?
    var chars: [String?]?
    var `default`: String?
    var viewName: String?
    var id: String { "\(name)-\(type)" }

    private enum CodingKeys: String, CodingKey { case name, type, action, chars, `default`, viewName }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? ""
        type = try values.decodeIfPresent(String.self, forKey: .type) ?? "text"
        action = try values.decodeIfPresent(String.self, forKey: .action)
        chars = try values.decodeIfPresent([String?].self, forKey: .chars)
        `default` = try values.decodeIfPresent(String.self, forKey: .default)
        viewName = try values.decodeIfPresent(String.self, forKey: .viewName)
    }
}

private struct HttpTTSLoginView: View {
    @Environment(\.dismiss) private var dismiss
    let engine: HttpTTS
    let onSave: (String) -> Void
    @State private var rows: [HttpTTSLoginRow] = []
    @State private var values: [String: String] = [:]
    @State private var errorMessage: String?
    @State private var isRunning = false
    @State private var pendingFieldAction: Task<Void, Never>?

    var body: some View {
        Form {
            if rows.isEmpty, errorMessage == nil {
                ProgressView("正在生成登录表单…")
                    .readingRowBackground()
            }
            ForEach(rows) { row in
                switch row.type {
                case "password":
                    SecureField(label(for: row), text: binding(for: row))
                        .onChange(of: values[row.name]) { _ in scheduleFieldAction(row.action) }
                case "select":
                    Picker(label(for: row), selection: binding(for: row)) {
                        ForEach(options(for: row), id: \.self) { Text($0).tag($0) }
                    }
                    .onChange(of: values[row.name]) { _ in runAction(row.action) }
                case "toggle":
                    Picker(label(for: row), selection: binding(for: row)) {
                        ForEach(options(for: row), id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: values[row.name]) { _ in runAction(row.action) }
                case "button":
                    Button(label(for: row)) { runAction(row.action) }
                default:
                    TextField(label(for: row), text: binding(for: row))
                        .onChange(of: values[row.name]) { _ in scheduleFieldAction(row.action) }
                }
            }.readingRowBackground()
            if let errorMessage { Text(errorMessage).foregroundStyle(.red).font(AppFontStyle.footnote.themed).readingRowBackground() }
        }.readingThemedListBackground()
        .navigationTitle("登录 · \(engine.name)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(isRunning ? "执行中…" : "登录") { saveAndLogin() }.disabled(isRunning)
            }
        }
        .task { loadRows() }
        .onDisappear { pendingFieldAction?.cancel() }
    }

    private func loadRows() {
        do {
            values = decodeLoginInfo()
            let json = try renderedLoginUI()
            rows = try JSONDecoder().decode([HttpTTSLoginRow].self, from: Data(json.utf8))
            for row in rows where row.type != "button" && values[row.name] == nil {
                values[row.name] = row.default ?? options(for: row).first ?? ""
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func renderedLoginUI() throws -> String {
        guard var raw = engine.loginUi?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return "[]"
        }
        let script: String?
        if raw.hasPrefix("@js:") {
            script = String(raw.dropFirst(4))
        } else if raw.hasPrefix("<js>"), raw.hasSuffix("</js>") {
            script = String(raw.dropFirst(4).dropLast(5))
        } else {
            script = nil
        }
        if let script {
            let result = try JavaScriptRuleEvaluator().evaluate(
                script: script,
                result: .object(values.mapValues(JSONValue.string)),
                executionContext: .init(source: engine.bookSourceAdapter)
            )
            raw = result.value.stringValue
        }
        return raw
    }

    private func decodeLoginInfo() -> [String: String] {
        let raw = BookSourceRuntimeStore.shared.get(sourceID: engine.sourceKey, key: "loginInfo")
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object.mapValues { String(describing: $0) }
    }

    private func binding(for row: HttpTTSLoginRow) -> Binding<String> {
        Binding(get: { values[row.name] ?? row.default ?? "" }, set: { values[row.name] = $0 })
    }

    private func options(for row: HttpTTSLoginRow) -> [String] {
        let options = row.chars?.compactMap { $0 } ?? []
        return options.isEmpty ? [row.default ?? ""] : options
    }

    private func label(for row: HttpTTSLoginRow) -> String {
        guard let value = row.viewName, value.count >= 2,
              value.first == "'", value.last == "'" else { return row.name }
        return String(value.dropFirst().dropLast())
    }

    private func runAction(_ action: String?) {
        guard let action, !action.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isRunning = true
        errorMessage = nil
        let engine = engine
        let values = values
        Task { @MainActor in
            defer { isRunning = false }
            do {
                _ = try await Task.detached {
                    try JavaScriptRuleEvaluator().evaluate(
                        script: "\(engine.loginUrl ?? "")\n\(action)",
                        result: .object(values.mapValues(JSONValue.string)),
                        executionContext: .init(source: engine.bookSourceAdapter)
                    )
                }.value
                if engine.loginUi?.hasPrefix("@js:") == true { loadRows() }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func scheduleFieldAction(_ action: String?) {
        guard action?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { return }
        pendingFieldAction?.cancel()
        pendingFieldAction = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 600_000_000)
                runAction(action)
            } catch { }
        }
    }

    private func saveAndLogin() {
        isRunning = true
        errorMessage = nil
        do {
            let data = try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
            let raw = String(decoding: data, as: UTF8.self)
            BookSourceRuntimeStore.shared.put(sourceID: engine.sourceKey, key: "loginInfo", value: raw)
            let engine = engine
            let values = values
            Task { @MainActor in
                do {
                    if let login = engine.loginUrl?.trimmingCharacters(in: .whitespacesAndNewlines), !login.isEmpty {
                        _ = try await Task.detached {
                            try JavaScriptRuleEvaluator().evaluate(
                                script: "\(login)\nif (typeof login === 'function') login.apply(this);",
                                result: .object(values.mapValues(JSONValue.string)),
                                executionContext: .init(source: engine.bookSourceAdapter)
                            )
                        }.value
                    }
                    onSave(raw)
                    dismiss()
                } catch {
                    errorMessage = error.localizedDescription
                    isRunning = false
                }
            }
        } catch {
            errorMessage = error.localizedDescription
            isRunning = false
        }
    }
}

private struct HttpTTSJSONDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
