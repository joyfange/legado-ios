import Foundation
import Testing
@testable import LegadoCore

struct EdgeTTSTests {
    @Test func tokenMatchesReferenceImplementation() {
        // 参考值来自 rany2/edge-tts 的 generate_sec_ms_gec_v2。
        #expect(EdgeTTSToken.generate(unixTime: 1_700_000_000) == "2CD23A2CA0B2595A-F3C846C370E05F9CC83ACC5F995C5F5D87A4D0F14CE8936A0F902E64099E38A2")
        #expect(EdgeTTSToken.generate(unixTime: 1_795_243_045) == "05F2734A060C8347-EF06E08FA4B85ACDB865FB951CD8BA8EEE05592A4B2A69077CA46AB221CFB101")
        #expect(EdgeTTSToken.generate(unixTime: 0) == "52BC7A17B50DFEC9-28C4394775C8751CD2F6859C030C06DB1489ACAB3B3A7651831FC26895177ED6")
    }

    @Test func edgeURLCarriesVoiceAndRate() throws {
        let url = try #require(URL(string: "edge://tts?v=zh-CN-YunxiNeural&r=30&p=0"))
        #expect(EdgeTTSClient.isEdgeURL(url))
        let options = EdgeTTSClient.Options(url: url)
        #expect(options.voice == "zh-CN-YunxiNeural")
        #expect(options.ratePercent == 30)
        let fallback = EdgeTTSClient.Options(url: try #require(URL(string: "edge://tts")))
        #expect(fallback.voice == "zh-CN-XiaoxiaoNeural")
        #expect(fallback.ratePercent == 0)
    }

    @Test func ssmlEscapesTextAndSplitsLongInput() {
        let ssml = EdgeTTSClient.ssml("a<b & 'c'", options: .init())
        #expect(ssml.contains("a&lt;b &amp; &apos;c&apos;"))
        #expect(ssml.contains("rate='+0%'"))
        let long = String(repeating: "字", count: 2500)
        let parts = EdgeTTSClient.chunks(long)
        #expect(parts.count == 3)
        #expect(parts.joined() == long)
    }
}
