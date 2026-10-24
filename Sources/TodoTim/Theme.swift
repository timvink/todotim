import AppKit
import SwiftUI
import TodoCore

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

/// Todoist's project/label color palette, keyed by lowercase name (stored in `Project.color`).
enum Palette {
    struct Entry: Identifiable {
        let key: String
        let name: String
        let hex: UInt32
        var id: String { key }
        var color: Color { Color(hex: hex) }
    }

    static let entries: [Entry] = [
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

    /// Accepts "olive_green", "olive green", "olivegreen" and "mint" (Todoist's short names).
    private static let byKey: [String: Entry] = Dictionary(uniqueKeysWithValues: entries.map { ($0.key, $0) })

    static func entry(_ key: String) -> Entry {
        if let e = byKey[key] { return e }
        let k = key.lowercased().replacingOccurrences(of: " ", with: "_")
        if let e = entries.first(where: { $0.key == k }) { return e }
        let squashed = k.replacingOccurrences(of: "_", with: "")
        if let e = entries.first(where: { $0.key.replacingOccurrences(of: "_", with: "") == squashed }) { return e }
        if k == "mint" { return entries.first { $0.key == "mint_green" }! }
        return entries.first { $0.key == "charcoal" }!
    }

    static func color(_ key: String) -> Color { entry(key).color }

    /// Non-template image so menus keep the color.
    static func swatch(_ key: String, size: CGFloat = 12) -> NSImage {
        let hex = entry(key).hex
        let ns = NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                         blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            ns.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        img.isTemplate = false
        return img
    }
}

enum Theme {
    /// Todoist brand red, used for primary buttons and accents.
    static let accent = Color(hex: 0xDC4C3E)
    static let overdue = Color(hex: 0xD1453B)
    static let today = Color(hex: 0x058527)
    static let tomorrow = Color(hex: 0xAD6200)
    static let thisWeek = Color(hex: 0x692EC2)
    static let contentMaxWidth: CGFloat = 820
    /// Width of the chevron gutter left of the checkbox.
    static let gutter: CGFloat = 26
    static let indent: CGFloat = 28
}

extension Priority {
    var color: Color {
        switch self {
        case .p1: Color(hex: 0xD1453B)
        case .p2: Color(hex: 0xEB8909)
        case .p3: Color(hex: 0x246FE0)
        case .p4: Color.secondary
        }
    }

    var title: String { "Priority \(rawValue)" }
}

extension DueDate {
    /// Todoist chip color: red overdue, green today, orange tomorrow, purple this week.
    var chipColor: Color {
        if isOverdue() { return Theme.overdue }
        let cal = Calendar.current
        guard let d = day(calendar: cal) else { return .secondary }
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: d).day ?? 99
        switch days {
        case ..<0: return Theme.overdue
        case 0: return Theme.today
        case 1: return Theme.tomorrow
        case 2...6: return Theme.thisWeek
        default: return .secondary
        }
    }

    static func offset(days: Int) -> DueDate {
        DueDate(Calendar.current.date(byAdding: .day, value: days, to: Date())!)
    }

    /// Monday of next week (Todoist "Next week"). Same rule as typing "next week".
    static var nextWeek: DueDate { DateParser.parse("next week") ?? .offset(days: 7) }

    /// Todoist "This weekend": the coming Saturday, or today on a Saturday or Sunday. Same rule
    /// as typing "this weekend".
    static var weekend: DueDate { DateParser.parse("this weekend") ?? .offset(days: 0) }
}

/// Todoist-style red filled button.
struct AccentButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.accent.opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)))
    }
}

/// Grey secondary button (Todoist "Cancel").
struct SoftButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(configuration.isPressed ? 0.14 : 0.08)))
    }
}

/// Small outlined chip (date / priority / labels in the task editor).
struct ChipLabel: View {
    let icon: String
    let text: String
    var tint: Color = .secondary
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 11))
            Text(text).font(.system(size: 12))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 7).padding(.vertical, 4)
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.15)))
        .contentShape(Rectangle())
    }
}

/// Gives SwiftUI views access to their hosting NSWindow.
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { if let w = v.window { onWindow(w) } }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { if let w = nsView.window { onWindow(w) } }
    }
}
