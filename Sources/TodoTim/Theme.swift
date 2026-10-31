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

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    /// A color that follows the appearance: `dark` in Dark Mode, `light` otherwise.
    static func adaptive(dark: NSColor, light: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }
}

/// The Catppuccin palette (https://catppuccin.com/palette, values from catppuccin/palette's
/// palette.json): Mocha in Dark Mode, Latte in Light Mode. Every color in the app comes from here.
enum Ctp: Int, CaseIterable {
    case rosewater, flamingo, pink, mauve, red, maroon, peach, yellow, green, teal, sky, sapphire, blue, lavender
    case text, subtext1, subtext0, overlay2, overlay1, overlay0, surface2, surface1, surface0, base, mantle, crust

    private var hex: (mocha: UInt32, latte: UInt32) {
        switch self {
        case .rosewater: (0xF5E0DC, 0xDC8A78)
        case .flamingo: (0xF2CDCD, 0xDD7878)
        case .pink: (0xF5C2E7, 0xEA76CB)
        case .mauve: (0xCBA6F7, 0x8839EF)
        case .red: (0xF38BA8, 0xD20F39)
        case .maroon: (0xEBA0AC, 0xE64553)
        case .peach: (0xFAB387, 0xFE640B)
        case .yellow: (0xF9E2AF, 0xDF8E1D)
        case .green: (0xA6E3A1, 0x40A02B)
        case .teal: (0x94E2D5, 0x179299)
        case .sky: (0x89DCEB, 0x04A5E5)
        case .sapphire: (0x74C7EC, 0x209FB5)
        case .blue: (0x89B4FA, 0x1E66F5)
        case .lavender: (0xB4BEFE, 0x7287FD)
        case .text: (0xCDD6F4, 0x4C4F69)
        case .subtext1: (0xBAC2DE, 0x5C5F77)
        case .subtext0: (0xA6ADC8, 0x6C6F85)
        case .overlay2: (0x9399B2, 0x7C7F93)
        case .overlay1: (0x7F849C, 0x8C8FA1)
        case .overlay0: (0x6C7086, 0x9CA0B0)
        case .surface2: (0x585B70, 0xACB0BE)
        case .surface1: (0x45475A, 0xBCC0CC)
        case .surface0: (0x313244, 0xCCD0DA)
        case .base: (0x1E1E2E, 0xEFF1F5)
        case .mantle: (0x181825, 0xE6E9EF)
        case .crust: (0x11111B, 0xDCE0E8)
        }
    }

    /// Built once: views read these on every update.
    private static let nsColors: [NSColor] = allCases.map { $0.make(alpha: 1) }
    private static let colors: [Color] = nsColors.map { Color(nsColor: $0) }

    var color: Color { Self.colors[rawValue] }
    var nsColor: NSColor { Self.nsColors[rawValue] }

    /// The same color at `alpha`, still following the appearance.
    func nsColor(alpha: CGFloat) -> NSColor { make(alpha: alpha) }

    private func make(alpha: CGFloat) -> NSColor {
        .adaptive(dark: NSColor(hex: hex.mocha, alpha: alpha), light: NSColor(hex: hex.latte, alpha: alpha))
    }
}

/// Project and label colors. The stored keys are Todoist's palette (`ProjectColor`, also written to
/// the server as hex); on screen each key shows as its nearest Catppuccin color.
enum Palette {
    typealias Entry = ProjectColor.Entry

    static var entries: [Entry] { ProjectColor.entries }

    /// The colors offered when picking one, in this order. Other keys still display.
    static let pickerKeys = ["red", "orange", "yellow", "green", "mint_green", "sky_blue", "blue", "grape",
                             "lavender", "magenta", "taupe", "charcoal"]
    static var pickerEntries: [Entry] { pickerKeys.map(ProjectColor.entry) }

    /// The key's display name in Catppuccin terms.
    static func name(_ key: String) -> String {
        switch ctp(key) {
        case .red: "Red"
        case .maroon: "Maroon"
        case .peach: "Peach"
        case .yellow: "Yellow"
        case .green: "Green"
        case .teal: "Teal"
        case .sky: "Sky"
        case .sapphire: "Sapphire"
        case .blue: "Blue"
        case .mauve: "Mauve"
        case .lavender: "Lavender"
        case .pink: "Pink"
        case .flamingo: "Flamingo"
        case .rosewater: "Rosewater"
        case .overlay2: "Grey"
        default: "Slate"
        }
    }

    static func ctp(_ key: String) -> Ctp {
        switch ProjectColor.entry(key).key {
        case "berry_red": .maroon
        case "red": .red
        case "orange": .peach
        case "yellow": .yellow
        case "olive_green", "lime_green", "green": .green
        case "mint_green", "teal": .teal
        case "sky_blue": .sky
        case "light_blue": .sapphire
        case "blue": .blue
        case "grape", "violet": .mauve
        case "lavender": .lavender
        case "magenta": .pink
        case "salmon": .flamingo
        case "taupe": .rosewater
        case "grey": .overlay2
        default: .overlay1
        }
    }

    static func color(_ key: String) -> Color { ctp(key).color }

    /// Non-template image so menus keep the color.
    static func swatch(_ key: String, size: CGFloat = 12) -> NSImage {
        let ns = ctp(key).nsColor
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
    // MARK: Surfaces

    static let background = Ctp.base.color
    static let sidebar = Ctp.mantle.color
    /// The line between the sidebar and the list.
    static let divider = Ctp.crust.color
    /// Task panel, Quick Add, shortcuts and the toast.
    static let panel = Ctp.base.color
    static let panelBorder = Ctp.surface1.color
    /// Popovers, menus and text fields.
    static let field = Ctp.surface0.color
    static let hover = Color(nsColor: Ctp.surface0.nsColor(alpha: 0.55))
    /// The selected row (list and sidebar): a neutral fill, the text keeps its color.
    static let selection = Color(nsColor: .adaptive(dark: Ctp.surface0.nsColor, light: Ctp.surface0.nsColor(alpha: 0.75)))
    static let separator = Ctp.surface0.color
    /// Behind the panels.
    static let scrim = Color(nsColor: .adaptive(dark: Ctp.crust.nsColor(alpha: 0.55), light: Ctp.text.nsColor(alpha: 0.18)))
    static let shadow = Color(nsColor: .adaptive(dark: NSColor(white: 0, alpha: 0.45), light: NSColor(white: 0, alpha: 0.14)))

    // MARK: Text

    static let text = Ctp.text.color
    /// Descriptions, counts, placeholders.
    static let secondaryText = Ctp.subtext0.color
    /// Hints and completed titles.
    static let tertiaryText = Ctp.overlay1.color
    static let disabledText = Ctp.overlay0.color

    // MARK: Accent and meaning

    /// The one accent: filled buttons, "Add task", focus, caret and selection, the drop slot.
    /// Warm, and never confused with red, which only means overdue, p1, destructive or error.
    static let accent = Ctp.peach.color
    /// Text and glyphs on `accent`.
    static let onAccent = Color(nsColor: .adaptive(dark: NSColor(hex: 0x11111B), light: NSColor(hex: 0xEFF1F5)))
    static let overdue = Ctp.red.color
    static let today = Ctp.green.color
    static let tomorrow = Ctp.yellow.color
    static let thisWeek = Ctp.mauve.color
    static let later = Ctp.subtext0.color
    static let inbox = Ctp.lavender.color
    static let link = Ctp.blue.color
    static let danger = Ctp.red.color

    // MARK: Metrics

    /// Reading width of the task column.
    static let contentMaxWidth: CGFloat = 740
    /// Horizontal margin of the task column.
    static let contentPadding: CGFloat = 32
    /// Width of the chevron gutter left of the checkbox.
    static let gutter: CGFloat = 24
    /// Width of the drag-handle column left of the chevron gutter, shown on row hover.
    static let grip: CGFloat = 16
    static let indent: CGFloat = 24
    /// Horizontal inset of a task row's content, so the checkbox starts at `gutter + rowInset`.
    static let rowInset: CGFloat = 8
    static let checkbox: CGFloat = 16
    /// Corner radius of row pills (list and sidebar hover and selection).
    static let rowRadius: CGFloat = 8
    /// Height of the pinned title bar at the top of the list.
    static let titleBarHeight: CGFloat = 52

    // MARK: Motion

    /// Rows appearing, leaving and moving (complete, collapse, reorder): quick, no overshoot.
    /// None with Reduce Motion.
    static var motion: Animation? { reduceMotion ? nil : .snappy(duration: 0.24, extraBounce: 0) }
    static let hoverAnimation = Animation.easeOut(duration: 0.10)
    /// Panels and Quick Add opening; closing is quicker and only fades.
    static var panelIn: Animation { reduceMotion ? .easeOut(duration: 0.08) : .spring(duration: 0.26, bounce: 0.1) }
    static let panelOut = Animation.easeIn(duration: 0.12)

    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
}

/// The type scale: 13 pt body everywhere, 11 pt for metadata, rounded only for page titles.
enum Fonts {
    static let body = Font.system(size: 13)
    static let bodyMedium = Font.system(size: 13, weight: .medium)
    static let bodySemibold = Font.system(size: 13, weight: .semibold)
    static let meta = Font.system(size: 11, weight: .medium)
    static let small = Font.system(size: 11)
    static let pageTitle = Font.system(size: 22, weight: .semibold, design: .rounded)
    static let panelTitle = Font.system(size: 17, weight: .semibold)
    static let sidebarHeading = Font.system(size: 11, weight: .semibold)
    static let quickAdd = Font.system(size: 16, weight: .medium)
    /// Glyphs beside 13 pt text.
    static let icon = Font.system(size: 14)
    /// Glyphs beside 11 pt text.
    static let smallIcon = Font.system(size: 11)
}

/// A 1 pt rule (under the pinned title, between panel areas).
struct Hairline: View {
    var body: some View {
        Rectangle().fill(Theme.separator).frame(height: 1)
    }
}

extension Priority {
    var color: Color {
        switch self {
        case .p1: Ctp.red.color
        case .p2: Ctp.yellow.color
        case .p3: Ctp.blue.color
        case .p4: Ctp.overlay0.color
        }
    }

    var nsColor: NSColor {
        switch self {
        case .p1: Ctp.red.nsColor
        case .p2: Ctp.yellow.nsColor
        case .p3: Ctp.blue.nsColor
        case .p4: Ctp.overlay1.nsColor
        }
    }

    var title: String { "Priority \(rawValue)" }
}

extension DueDate {
    /// Red overdue, green today, yellow tomorrow, mauve this week, quiet later.
    var chipColor: Color {
        if isOverdue() { return Theme.overdue }
        let cal = Calendar.current
        guard let d = day(calendar: cal) else { return Theme.later }
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: d).day ?? 99
        switch days {
        case ..<0: return Theme.overdue
        case 0: return Theme.today
        case 1: return Theme.tomorrow
        case 2...6: return Theme.thisWeek
        default: return Theme.later
        }
    }

    static func offset(days: Int) -> DueDate {
        DueDate(Calendar.current.date(byAdding: .day, value: days, to: Date())!)
    }

    /// Monday of next week. Same rule as typing "next week".
    static var nextWeek: DueDate { DateParser.parse("next week") ?? .offset(days: 7) }

    /// The coming Saturday, or today on a Saturday or Sunday. Same rule as typing "this weekend".
    static var weekend: DueDate { DateParser.parse("this weekend") ?? .offset(days: 0) }
}

/// The filled accent button (Add, Save).
struct AccentButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Fonts.bodySemibold)
            .foregroundStyle(Theme.onAccent)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Theme.accent.opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Theme.hoverAnimation, value: configuration.isPressed)
            .pointerStyle(isEnabled ? .link : nil)
    }
}

/// The quiet secondary button (Cancel).
struct SoftButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Fonts.bodySemibold)
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(configuration.isPressed ? Ctp.surface1.color : Ctp.surface0.color))
            .pointerStyle(.link)
    }
}

/// Small chip (date / priority / labels in the editors).
struct ChipLabel: View {
    let icon: String
    let text: String
    var tint: Color = Theme.secondaryText
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(Fonts.smallIcon)
            Text(text).font(Fonts.meta)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.field))
        .contentShape(Rectangle())
        .pointerStyle(.link)
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

/// A project's icon: a ring in its color, filled when the project is selected (`fill` 1) or
/// hovered (`fill` 0.3). The inbox is a tray.
struct ProjectIcon: View {
    let colorKey: String
    let isInbox: Bool
    var fill: Double = 0
    /// Diameter of the ring; the tray glyph matches it optically.
    var size: CGFloat = 12

    init(_ project: Project, fill: Double = 0, size: CGFloat = 12) {
        self.init(colorKey: project.color, isInbox: project.isInbox, fill: fill, size: size)
    }

    init(colorKey: String, isInbox: Bool, fill: Double = 0, size: CGFloat = 12) {
        self.colorKey = colorKey
        self.isInbox = isInbox
        self.fill = fill
        self.size = size
    }

    var body: some View {
        if isInbox {
            Image(systemName: "tray")
                .font(.system(size: size + 2))
                .foregroundStyle(Theme.inbox)
        } else {
            let color = Palette.color(colorKey)
            ZStack {
                Circle().fill(color.opacity(fill))
                Circle().strokeBorder(color, lineWidth: 1.5)
            }
            .frame(width: size, height: size)
        }
    }
}

/// A label's color dot, shown before its name in task rows.
struct LabelDot: View {
    let color: Color
    var body: some View {
        Circle().fill(color).frame(width: 6, height: 6)
    }
}
