import Foundation

/// SHA-1 (FIPS 180-4), used only to derive name-based UUIDs (v5) for stable ids. Not for security.
/// Portable so TodoCore does not need CryptoKit.
enum SHA1 {
    static func hash(_ message: [UInt8]) -> [UInt8] {
        var h: [UInt32] = [0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0]
        var data = message
        let bitLength = UInt64(message.count) * 8
        data.append(0x80)
        while data.count % 64 != 56 { data.append(0) }
        for i in (0..<8).reversed() { data.append(UInt8(truncatingIfNeeded: bitLength >> (UInt64(i) * 8))) }
        var w = [UInt32](repeating: 0, count: 80)
        for chunk in stride(from: 0, to: data.count, by: 64) {
            for i in 0..<16 {
                let j = chunk + i * 4
                w[i] = UInt32(data[j]) << 24 | UInt32(data[j + 1]) << 16 | UInt32(data[j + 2]) << 8 | UInt32(data[j + 3])
            }
            for i in 16..<80 {
                let x = w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16]
                w[i] = x << 1 | x >> 31
            }
            var (a, b, c, d, e) = (h[0], h[1], h[2], h[3], h[4])
            for i in 0..<80 {
                let f: UInt32, k: UInt32
                switch i {
                case 0..<20: f = (b & c) | (~b & d); k = 0x5A827999
                case 20..<40: f = b ^ c ^ d; k = 0x6ED9EBA1
                case 40..<60: f = (b & c) | (b & d) | (c & d); k = 0x8F1BBCDC
                default: f = b ^ c ^ d; k = 0xCA62C1D6
                }
                let t = (a << 5 | a >> 27) &+ f &+ e &+ k &+ w[i]
                e = d; d = c; c = b << 30 | b >> 2; b = a; a = t
            }
            h[0] &+= a; h[1] &+= b; h[2] &+= c; h[3] &+= d; h[4] &+= e
        }
        return h.flatMap { v in (0..<4).reversed().map { UInt8(truncatingIfNeeded: v >> (UInt32($0) * 8)) } }
    }
}

/// Name-based UUID (RFC 4122 version 5), lowercased.
func uuidV5(namespace: UUID, name: String) -> String {
    var input = withUnsafeBytes(of: namespace.uuid) { Array($0) }
    input.append(contentsOf: Array(name.utf8))
    var bytes = Array(SHA1.hash(input).prefix(16))
    bytes[6] = (bytes[6] & 0x0F) | 0x50  // version 5
    bytes[8] = (bytes[8] & 0x3F) | 0x80  // RFC 4122 variant
    let uuid = bytes.withUnsafeBytes { $0.loadUnaligned(as: uuid_t.self) }
    return UUID(uuid: uuid).uuidString.lowercased()
}
