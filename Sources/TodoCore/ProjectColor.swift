import Foundation

/// Todoist's project/label color palette, keyed by lowercase name (stored in `Project.color` and
/// `Label.color`). CalDAV stores colors as hex (`#RRGGBB`); `key(hex:)` maps any other color to
/// the nearest palette entry.
public enum ProjectColor {
    public struct Entry: Identifiable, Sendable {
        public let key: String
        public let name: String
        public let hex: UInt32
        public var id: String { key }
    }

    public static let entries: [Entry] = [
        Entry(key: "berry_red", name: "Berry Red", hex: 0xB8255F),
        Entry(key: "red", name: "Red", hex: 0xDB4035),
        Entry(key: "orange", name: "Orange", hex: 0xFF9933),
        Entry(key: "yellow", name: "Yellow", hex: 0xFAD000),
        Entry(key: "olive_green", name: "Olive Green", hex: 0xAFB83B),
        Entry(key: "lime_green", name: "Lime Green", hex: 0x7ECC49),
        Entry(key: "green", name: "Green", hex: 0x299438),
        Entry(key: "mint_green", name: "Mint Green", hex: 0x6ACCBC),
        Entry(key: "teal", name: "Teal", hex: 0x158FAD),
        Entry(key: "sky_blue", name: "Sky Blue", hex: 0x14AAF5),
        Entry(key: "light_blue", name: "Light Blue", hex: 0x96C3EB),
        Entry(key: "blue", name: "Blue", hex: 0x4073FF),
        Entry(key: "grape", name: "Grape", hex: 0x884DFF),
        Entry(key: "violet", name: "Violet", hex: 0xAF38EB),
        Entry(key: "lavender", name: "Lavender", hex: 0xEB96EB),
        Entry(key: "magenta", name: "Magenta", hex: 0xE05194),
        Entry(key: "salmon", name: "Salmon", hex: 0xFF8D85),
        Entry(key: "charcoal", name: "Charcoal", hex: 0x808080),
        Entry(key: "grey", name: "Grey", hex: 0xB8B8B8),
        Entry(key: "taupe", name: "Taupe", hex: 0xCCAC93),
    ]

    private static let byKey: [String: Entry] = Dictionary(uniqueKeysWithValues: entries.map { ($0.key, $0) })

    /// Accepts "olive_green", "olive green", "olivegreen" and "mint" (Todoist's short names);
    /// anything else is charcoal.
    public static func entry(_ key: String) -> Entry {
        if let e = byKey[key] { return e }
        let k = key.lowercased().replacingOccurrences(of: " ", with: "_")
        if let e = byKey[k] { return e }
        let squashed = k.replacingOccurrences(of: "_", with: "")
        if let e = entries.first(where: { $0.key.replacingOccurrences(of: "_", with: "") == squashed }) { return e }
        if k == "mint" { return byKey["mint_green"]! }
        return byKey["charcoal"]!
    }

    /// "#DB4035".
    public static func hex(_ key: String) -> String { String(format: "#%06X", entry(key).hex) }

    /// Palette key nearest to `#RRGGBB` or `#RRGGBBAA` (alpha ignored); nil when not a hex color.
    public static func key(hex: String) -> String? {
        var s = Substring(hex.trimmingCharacters(in: .whitespaces))
        guard s.hasPrefix("#") else { return nil }
        s = s.dropFirst()
        guard s.count == 6 || s.count == 8, let v = UInt32(s.prefix(6), radix: 16) else { return nil }
        func distance(_ a: UInt32, _ b: UInt32) -> Int {
            let dr = Int(a >> 16 & 0xFF) - Int(b >> 16 & 0xFF)
            let dg = Int(a >> 8 & 0xFF) - Int(b >> 8 & 0xFF)
            let db = Int(a & 0xFF) - Int(b & 0xFF)
            return 2 * dr * dr + 4 * dg * dg + 3 * db * db
        }
        return entries.min { distance($0.hex, v) < distance($1.hex, v) }?.key
    }
}
