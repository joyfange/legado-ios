import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum EdgeTTSError: LocalizedError {
    case rejected(String)
    case noAudio
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .rejected(let detail): "微软朗读接口拒绝了请求：\(detail)"
        case .noAudio: "微软朗读接口没有返回音频"
        case .timedOut: "微软朗读接口超时，请检查网络"
        }
    }
}

/// 内置的微软 Edge「大声朗读」（不依赖第三方转发服务器）。
/// 朗读源网址写成 `edge://tts?v=发言人&r=语速百分比&p=音调` 时由 `HttpTTSService` 直接走这里。
public enum EdgeTTSClient {
    public static let scheme = "edge"

    public struct Options: Sendable, Equatable {
        public var voice: String
        public var ratePercent: Int
        public var pitchHz: Int
        public var volumePercent: Int

        public init(voice: String = "zh-CN-XiaoxiaoNeural", ratePercent: Int = 0, pitchHz: Int = 0, volumePercent: Int = 0) {
            self.voice = voice
            self.ratePercent = ratePercent
            self.pitchHz = pitchHz
            self.volumePercent = volumePercent
        }

        /// 从 `edge://tts?v=…&r=…&p=…` 读出参数，缺省用晓晓、正常语速。
        public init(url: URL) {
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            func value(_ name: String) -> String? {
                items.first { $0.name == name }?.value?.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let voice = value("v").flatMap { $0.isEmpty ? nil : $0 } ?? "zh-CN-XiaoxiaoNeural"
            let rate = value("r").flatMap { Double($0) }.map { Int($0.rounded()) } ?? 0
            let pitch = value("p").flatMap { Double($0) }.map { Int($0.rounded()) } ?? 0
            self.init(voice: voice, ratePercent: min(max(rate, -90), 200), pitchHz: min(max(pitch, -50), 50))
        }
    }

    public static func isEdgeURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == scheme
    }

    static func escapeXML(_ text: String) -> String {
        var output = ""
        output.reserveCapacity(text.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": output += "&amp;"
            case "<": output += "&lt;"
            case ">": output += "&gt;"
            case "\"": output += "&quot;"
            case "'": output += "&apos;"
            default:
                let value = scalar.value
                if (value < 0x20 && value != 0x09 && value != 0x0A && value != 0x0D) || (value >= 0xFFFE && value <= 0xFFFF) {
                    output += " "
                } else {
                    output.unicodeScalars.append(scalar)
                }
            }
        }
        return output
    }

    /// 单次请求的 SSML 不能太长（接口上限约 4 KB），按字节切成几段依次合成，再拼成一段 mp3。
    static func chunks(_ text: String, maxBytes: Int = 3000) -> [String] {
        var result: [String] = []
        var current = ""
        var currentBytes = 0
        for character in text {
            let size = String(character).utf8.count
            if currentBytes + size > maxBytes, !current.isEmpty {
                result.append(current)
                current = ""
                currentBytes = 0
            }
            current.append(character)
            currentBytes += size
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result.append(current) }
        return result
    }

    static func ssml(_ text: String, options: Options) -> String {
        let rate = options.ratePercent >= 0 ? "+\(options.ratePercent)%" : "\(options.ratePercent)%"
        let pitch = options.pitchHz >= 0 ? "+\(options.pitchHz)Hz" : "\(options.pitchHz)Hz"
        let volume = options.volumePercent >= 0 ? "+\(options.volumePercent)%" : "\(options.volumePercent)%"
        return "<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='en-US'>"
            + "<voice name='\(escapeXML(options.voice))'><prosody pitch='\(pitch)' rate='\(rate)' volume='\(volume)'>"
            + escapeXML(text)
            + "</prosody></voice></speak>"
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "EEE MMM dd yyyy HH:mm:ss 'GMT+0000 (Coordinated Universal Time)'"
        return formatter.string(from: Date())
    }

    private static func connectionID() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// 服务器时间与本机时间的偏差（被拒绝时按服务器的 Date 校正后重试）。
    nonisolated(unsafe) private static var clockSkew: TimeInterval = 0

    public static func synthesize(text: String, options: Options) async throws -> Data {
        var audio = Data()
        for part in chunks(text) {
            try Task.checkCancellation()
            do {
                audio.append(try await synthesizeChunk(part, options: options))
            } catch EdgeTTSError.rejected {
                await adjustClockSkew()
                audio.append(try await synthesizeChunk(part, options: options))
            }
        }
        guard !audio.isEmpty else { throw EdgeTTSError.noAudio }
        return audio
    }

    private static func adjustClockSkew() async {
        guard let url = URL(string: "https://speech.platform.bing.com/") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 10
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              let date = http.value(forHTTPHeaderField: "Date") else { return }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let server = formatter.date(from: date) {
            clockSkew = server.timeIntervalSince1970 - Date().timeIntervalSince1970
        }
    }

    private static func synthesizeChunk(_ text: String, options: Options) async throws -> Data {
        let token = EdgeTTSToken.generate(unixTime: Date().timeIntervalSince1970 + clockSkew)
        let address = "wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1"
            + "?TrustedClientToken=\(EdgeTTSToken.trustedClientToken)"
            + "&ConnectionId=\(connectionID())"
            + "&Sec-MS-GEC=\(token)"
            + "&Sec-MS-GEC-Version=\(EdgeTTSToken.version)"
        guard let url = URL(string: address) else { throw EdgeTTSError.noAudio }
        let major = EdgeTTSToken.chromiumFullVersion.split(separator: ".").first.map(String.init) ?? "143"
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold", forHTTPHeaderField: "Origin")
        request.setValue(
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/\(major).0.0.0 Safari/537.36 Edg/\(major).0.0.0",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("muid=\(connectionID().uppercased());", forHTTPHeaderField: "Cookie")

        let socket = URLSession.shared.webSocketTask(with: request)
        socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil) }
        let now = timestamp()
        let config = "X-Timestamp:\(now)\r\nContent-Type:application/json; charset=utf-8\r\nPath:speech.config\r\n\r\n"
            + #"{"context":{"synthesis":{"audio":{"metadataoptions":{"sentenceBoundaryEnabled":"false","wordBoundaryEnabled":"false"},"outputFormat":"audio-24khz-48kbitrate-mono-mp3"}}}}"#
            + "\r\n"
        let ssmlMessage = "X-RequestId:\(connectionID())\r\nContent-Type:application/ssml+xml\r\nX-Timestamp:\(now)Z\r\nPath:ssml\r\n\r\n"
            + ssml(text, options: options)
        do {
            try await socket.send(.string(config))
            try await socket.send(.string(ssmlMessage))
        } catch {
            throw EdgeTTSError.rejected(error.localizedDescription)
        }

        var audio = Data()
        let deadline = Date().addingTimeInterval(60)
        while true {
            try Task.checkCancellation()
            if Date() > deadline { throw EdgeTTSError.timedOut }
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await socket.receive()
            } catch {
                if audio.isEmpty { throw EdgeTTSError.rejected(error.localizedDescription) }
                break
            }
            switch message {
            case .string(let text):
                if text.contains("Path:turn.end") { return try finished(audio) }
            case .data(let data):
                guard data.count >= 2 else { continue }
                let bytes = [UInt8](data.prefix(2))
                let headerLength = Int(bytes[0]) << 8 | Int(bytes[1])
                guard data.count >= 2 + headerLength else { continue }
                let header = String(decoding: data.subdata(in: 2..<(2 + headerLength)), as: UTF8.self)
                if header.contains("Path:audio") {
                    audio.append(data.subdata(in: (2 + headerLength)..<data.count))
                }
            @unknown default:
                continue
            }
        }
        return try finished(audio)
    }

    private static func finished(_ audio: Data) throws -> Data {
        guard !audio.isEmpty else { throw EdgeTTSError.noAudio }
        return audio
    }
}
