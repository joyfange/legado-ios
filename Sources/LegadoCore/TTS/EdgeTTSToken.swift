import Foundation

/// 微软 Edge「大声朗读」接口的 Sec-MS-GEC v2 令牌（与 rany2/edge-tts 的 drm.py 逐步一致）。
/// 令牌 = CS64 摘要 + "-" + 加盐 SHA-256，按 5 分钟取整的 Windows 文件时间计算。
public enum EdgeTTSToken {
    public static let trustedClientToken = "6A5AA1D4EAFF4E9FB37E23D68491D6F4"
    public static let chromiumFullVersion = "143.0.3650.75"
    public static var version: String { "2-\(chromiumFullVersion)" }

    public static func generate(unixTime: TimeInterval = Date().timeIntervalSince1970) -> String {
        var seconds = Int64(unixTime.rounded(.down)) + 11_644_473_600
        seconds -= seconds % 300
        let ticks = seconds * 10_000_000
        let data = Array("\(ticks)\(trustedClientToken)".utf8)
        let digest = sha256(data)
        let (lo, hi) = cs64(data, digest: digest)
        var cs = [UInt8]()
        for word in [lo, hi] { cs += [UInt8(word & 0xFF), UInt8((word >> 8) & 0xFF), UInt8((word >> 16) & 0xFF), UInt8(word >> 24)] }
        return hex(cs) + "-" + hex(digest)
    }

    private static func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02X", $0) }.joined() }

    // MARK: SHA-256（从内置的中间状态继续）

    private static let initial: [UInt32] = [0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A, 0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19]
    private static let midState: [UInt32] = [0xFD9FBEA2, 0x91243CE7, 0xBE499094, 0xCD2E1E0A, 0x6C006F49, 0x04BD35AB, 0xFEB0A7E4, 0x03EFFBD2]
    private static let schedule: [UInt32] = [0xEB24BF9E, 0x1558691F, 0xA0C09EE2, 0x0CFA32BA, 0xA622EE8C, 0xD1DD9491, 0xC0DD25A0, 0xF9E70AB6, 0xF0C31573, 0x7058CE4E, 0x7188E606, 0x00E5AB33, 0xD258B060, 0x72766564]
    private static let roundK: [UInt32] = [0x428A2F98, 0x71374491, 0xB5C0FBCF, 0xE9B5DBA5, 0x3956C25B, 0x59F111F1, 0x923F82A4, 0xAB1C5ED5, 0xD807AA98, 0x12835B01, 0x243185BE, 0x550C7DC3, 0x72BE5D74, 0x80DEB1FE, 0x9BDC06A7, 0xC19BF174, 0xE49B69C1, 0xEFBE4786, 0x0FC19DC6, 0x240CA1CC, 0x2DE92C6F, 0x4A7484AA, 0x5CB0A9DC, 0x76F988DA, 0x983E5152, 0xA831C66D, 0xB00327C8, 0xBF597FC7, 0xC6E00BF3, 0xD5A79147, 0x06CA6351, 0x14292967, 0x27B70A85, 0x2E1B2138, 0x4D2C6DFC, 0x53380D13, 0x650A7354, 0x766A0ABB, 0x81C2C92E, 0x92722C85, 0xA2BFE8A1, 0xA81A664B, 0xC24B8B70, 0xC76C51A3, 0xD192E819, 0xD6990624, 0xF40E3585, 0x106AA070, 0x19A4C116, 0x1E376C08, 0x2748774C, 0x34B0BCB5, 0x391C0CB3, 0x4ED8AA4A, 0x5B9CCA4F, 0x682E6FF3, 0x748F82EE, 0x78A5636F, 0x84C87814, 0x8CC70208, 0x90BEFFFA, 0xA4506CEB, 0xBEF9A3F7, 0xC67178F2]
    private static let adjustment: UInt32 = 0xC9DC06A7
    private static let sigma0Adjustment: UInt32 = 0x059C0B80
    private static let sigma1Adjustment: UInt32 = 0x000B92C0

    @inline(__always) private static func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
    @inline(__always) private static func smallSigma0(_ x: UInt32) -> UInt32 { rotr(x, 7) ^ rotr(x, 18) ^ (x >> 3) }
    @inline(__always) private static func smallSigma1(_ x: UInt32) -> UInt32 { rotr(x, 17) ^ rotr(x, 19) ^ (x >> 10) }

    private static func expand(_ words: inout [UInt32], from first: Int) {
        for index in first..<64 {
            words.append(smallSigma1(words[index - 2]) &+ words[index - 7] &+ smallSigma0(words[index - 15]) &+ words[index - 16])
        }
    }

    private static func rounds(_ state: [UInt32], _ words: [UInt32], firstRound: Int) -> [UInt32] {
        var a = state[0], b = state[1], c = state[2], d = state[3]
        var e = state[4], f = state[5], g = state[6], h = state[7]
        for index in firstRound..<64 {
            let k = (firstRound == 14 && index == 14) ? adjustment : roundK[index]
            let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
            let ch = g ^ (e & (f ^ g))
            let t1 = h &+ s1 &+ ch &+ k &+ words[index]
            let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
            let maj = (a & b) | (c & (a | b))
            let t2 = s0 &+ maj
            h = g; g = f; f = e; e = d &+ t1
            d = c; c = b; b = a; a = t1 &+ t2
        }
        return [a, b, c, d, e, f, g, h]
    }

    private static func be32(_ bytes: ArraySlice<UInt8>) -> UInt32 {
        bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    private static func initState(_ prefix: [UInt8]) -> [UInt32] {
        var words = [UInt32](repeating: 0, count: 14)
        words.append(be32(prefix[0..<3]))
        words.append(be32(prefix[3..<7]))
        for index in 16..<30 {
            var value = schedule[index - 16]
            if index - 2 >= 14 {
                let s = smallSigma1(words[index - 2])
                value = value &+ (index == 16 ? s ^ sigma1Adjustment : s)
            }
            if index - 7 >= 14 { value = value &+ words[index - 7] }
            if index - 15 >= 14 {
                let s = smallSigma0(words[index - 15])
                value = value &+ (index == 29 ? s ^ sigma0Adjustment : s)
            }
            words.append(value)
        }
        words.append(smallSigma1(words[28]) &+ words[23] &+ smallSigma0(words[15]) &+ words[14] &+ adjustment &- roundK[14])
        expand(&words, from: 31)
        let working = rounds(midState, words, firstRound: 14)
        return zip(initial, working).map { $0 &+ $1 }
    }

    static func sha256(_ data: [UInt8]) -> [UInt8] {
        precondition(data.count >= 7)
        let length = 57 + data.count
        var padded = Array(data[7...])
        padded.append(0x80)
        let zeros = ((55 - length) % 64 + 64) % 64
        padded += [UInt8](repeating: 0, count: zeros)
        let bits = UInt64(length * 8)
        for shift in stride(from: 56, through: 0, by: -8) { padded.append(UInt8((bits >> UInt64(shift)) & 0xFF)) }
        var state = initState(Array(data[0..<7]))
        var offset = 0
        while offset < padded.count {
            var words = (0..<16).map { be32(padded[(offset + $0 * 4)..<(offset + $0 * 4 + 4)]) }
            expand(&words, from: 16)
            let working = rounds(state, words, firstRound: 0)
            state = zip(state, working).map { $0 &+ $1 }
            offset += 64
        }
        var out = [UInt8]()
        for word in state { out += [UInt8(word >> 24), UInt8((word >> 16) & 0xFF), UInt8((word >> 8) & 0xFF), UInt8(word & 0xFF)] }
        return out
    }

    // MARK: CS64

    private static let cs64Coefficients: [UInt32] = [0xE82E91B1, 0x44DE24C6, 0x3BEB65BC, 0xC89C5933, 0x8D1EC211, 0x314EF5D5, 0xE92491B1, 0xF0A5B9D5, 0x06064CF3, 0xDA79FA60, 0xBED20560, 0x89F9C9F8, 0x35FA38C6, 0xCB49E3C6]
    private static let cs64Offsets: [UInt32] = [0xB32700D0, 0x88DFF51D, 0x29514038, 0xB328CBDF, 0xD405B4D5, 0x26E55F3C, 0x607801C6, 0x82B2C1FB, 0xFA51A3DA, 0x207CC464, 0x3C3C74F3, 0xD2D14B61, 0xBB04A2C1, 0xC5626167]

    @inline(__always) private static func rol16(_ x: UInt32) -> UInt32 { (x << 16) | (x >> 16) }

    static func cs64(_ data: [UInt8], digest: [UInt8]) -> (UInt32, UInt32) {
        func le32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
            UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24
        }
        let keyA = le32(digest, 0) | 1
        let keyB = le32(digest, 4) | 1
        let factors = [keyA &* 0x82893933, keyB &* 0x82893933]
        var terms = cs64Coefficients.enumerated().map { $0.element &* factors[$0.offset % 2] }
        var offsets = cs64Offsets
        var bytes = [UInt8(0)] + data
        while bytes.count % 4 != 0 { bytes.append(0) }
        var words = stride(from: 0, to: bytes.count, by: 4).map { le32(bytes, $0) }
        if words.count % 2 == 1 { words.append(0) }
        for (index, word) in words.enumerated() {
            var term = word &* (index % 2 == 0 ? keyA : keyB)
            var offset = rol16(word) &* (index % 2 == 0 ? 0xEF0569FB : 0xC31713DB)
            if index == 0 {
                term = term &+ (0xF2F90B1A &* factors[0])
                offset = offset &+ 0x0B1A0000
            }
            terms.append(term)
            offsets.append(offset)
        }
        var swapAcc: UInt32 = 0, swapLast: UInt32 = 0, state: UInt32 = 0, acc: UInt32 = 0
        var index = 0
        while index < terms.count {
            let x = terms[index], y = terms[index + 1]
            var t = rol16(offsets[index] &+ x)
            var q = t &* 0x76F50F34
            swapAcc = swapAcc &+ (rol16(q) &* 0xC3EFEA97 &+ q)
            t = rol16(offsets[index + 1] &+ y)
            q = t &* 0x1881CE3C
            swapLast = rol16(q) &* 0x35BD1EC9 &+ q
            swapAcc = swapAcc &+ swapLast

            state = state &* keyA &+ x
            state = rol16(state) &* 0xCF98B111
            state = rol16(state) &* 0x87085B9F
            state = rol16(state) &* 0x12CEB96D
            state = rol16(state) &* 0x257E1D83
            acc = acc &+ state
            t = state &* keyB &+ y
            t = rol16(t) &* 0xA27416F5
            t = rol16(t) &* 0xD38396FF
            state = rol16(rol16(t) &* 0x7C932B89) &* 0xBFA49F69
            acc = acc &+ state
            index += 2
        }
        return (swapLast ^ state, swapAcc ^ acc)
    }
}
