import AppKit
import SwiftUI
import TodoCore

/// Popover shown for the selected task by `t` / `l` / `v` (and the row's calendar button).
struct TaskPopoverContent: View {
    @Environment(AppModel.self) private var model
    @Environment(TodoStore.self) private var store
    let taskID: EntityID
    let kind: TaskPopover

    var body: some View {
        if let task = store.task(taskID) {
            switch kind {
            case .date:
                DueDatePicker(due: task.due) { due in
                    store.updateTask(taskID) { $0.due = due }
                    model.popover = nil
                }
            case .labels:
                LabelsPicker(selection: Binding(
                    get: { store.task(taskID)?.labels ?? [] },
                    set: { new in store.updateTask(taskID) { $0.labels = new } }))
            case .move:
                MovePicker(current: (task.projectId, task.sectionId)) { pid, sid in
                    model.popover = nil
                    model.move(taskID, toProject: pid, section: sid)
                }
            }
        }
    }
}

/// Todoist's date picker: type a date, quick choices, and a calendar.
struct DueDatePicker: View {
    let due: DueDate?
    let onPick: (DueDate?) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        let parsed = DateParser.parse(text)
        VStack(alignment: .leading, spacing: 0) {
            PickerField(prompt: "Type a date", text: $text, focused: $focused) {
                if let parsed { onPick(parsed) }
            }
            if !text.isEmpty {
                // What Enter picks.
                HStack(spacing: 8) {
                    Image(systemName: "calendar").font(Fonts.icon).frame(width: 18)
                    Text(parsed.map { "\($0.displayString())  ·  \($0.date)" } ?? "No match").font(Fonts.body)
                }
                .foregroundStyle(parsed?.chipColor ?? Theme.secondaryText)
                .padding(.horizontal, PickerStyle.rowPadding)
                .frame(height: PickerStyle.rowHeight)
            }
            VStack(spacing: 0) {
                quick("Today", icon: "calendar.badge.clock", color: Theme.today, .offset(days: 0))
                quick("Tomorrow", icon: "sun.max", color: Theme.tomorrow, .offset(days: 1))
                quick("This weekend", icon: "sofa", color: Ctp.blue.color, .weekend)
                quick("Next week", icon: "arrow.right.circle", color: Theme.thisWeek, .nextWeek)
                quick("No date", icon: "nosign", color: Ctp.overlay1.color, nil)
            }
            .padding(.vertical, 4)
            PickerRule()
            MonthCalendar(selected: due) { onPick($0) }
        }
        .pickerSurface(width: 250)
        .onAppear { focused = true }
    }

    private func quick(_ title: String, icon: String, color: Color, _ value: DueDate?) -> some View {
        Button { onPick(value) } label: {
            PickerRow(title) {
                Image(systemName: icon).foregroundStyle(color)
            } trailing: {
                if let d = value?.day() {
                    Text(d.formatted(.dateTime.weekday(.abbreviated)))
                        .font(Fonts.meta)
                        .foregroundStyle(Theme.secondaryText)
                }
            }
        }
        .buttonStyle(HoverRowButtonStyle())
    }
}

/// A month to pick a day from, in theme colors (the system calendar draws its own box in
/// system colors). Today's number is green, like "Today"; the task's date is a peach disc.
private struct MonthCalendar: View {
    let selected: DueDate?
    let onPick: (DueDate) -> Void
    /// First day of the month shown.
    @State private var month: Date

    init(selected: DueDate?, onPick: @escaping (DueDate) -> Void) {
        self.selected = selected
        self.onPick = onPick
        let cal = Calendar.current
        let shown = selected?.day() ?? Date()
        _month = State(initialValue: cal.dateInterval(of: .month, for: shown)?.start ?? cal.startOfDay(for: shown))
    }

    var body: some View {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let chosen = selected?.day()
        // Blank cells before the 1st, so the weeks start on the calendar's first weekday.
        let lead = (cal.component(.weekday, from: month) - cal.firstWeekday + 7) % 7
        let count = cal.range(of: .day, in: .month, for: month)?.count ?? 30
        VStack(spacing: 2) {
            HStack(spacing: 2) {
                Text(month.formatted(.dateTime.month(.wide).year()))
                    .font(Fonts.bodySemibold)
                    .foregroundStyle(Theme.text)
                Spacer()
                step("chevron.left", help: "Previous month", by: -1)
                step("chevron.right", help: "Next month", by: 1)
            }
            .padding(.leading, 8)
            .frame(height: PickerStyle.rowHeight)
            Grid(horizontalSpacing: 0, verticalSpacing: 2) {
                GridRow {
                    ForEach(0..<7, id: \.self) { i in
                        let day = cal.date(byAdding: .day, value: i - lead, to: month) ?? month
                        Text(day.formatted(.dateTime.weekday(.short)))
                            .font(Fonts.meta)
                            .foregroundStyle(Theme.tertiaryText)
                            .frame(maxWidth: .infinity, minHeight: 20)
                    }
                }
                // Always six weeks, so the popover keeps its height from month to month.
                ForEach(0..<6, id: \.self) { week in
                    GridRow {
                        ForEach(0..<7, id: \.self) { weekday in
                            let n = week * 7 + weekday - lead
                            if n >= 0, n < count, let day = cal.date(byAdding: .day, value: n, to: month) {
                                DayButton(number: n + 1, isToday: day == today, isChosen: day == chosen,
                                          isPast: day < today) { onPick(DueDate(day)) }
                                    .accessibilityLabel(day.formatted(date: .complete, time: .omitted))
                            } else {
                                Color.clear.frame(height: DayButton.size)
                            }
                        }
                    }
                }
            }
        }
        .padding(6)
    }

    private func step(_ icon: String, help: String, by months: Int) -> some View {
        Button {
            month = Calendar.current.date(byAdding: .month, value: months, to: month) ?? month
        } label: {
            Image(systemName: icon)
        }
        .buttonStyle(PickerIconButtonStyle())
        .help(help)
    }
}

/// One day of `MonthCalendar`: a disc while hovered, peach when it is the task's date.
private struct DayButton: View {
    static let size: CGFloat = 28
    let number: Int
    let isToday: Bool
    let isChosen: Bool
    let isPast: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text("\(number)")
                .font(isToday || isChosen ? Fonts.bodySemibold : Fonts.body)
                .monospacedDigit()
                .foregroundStyle(isChosen ? Theme.onAccent : isToday ? Theme.today : isPast ? Theme.tertiaryText : Theme.text)
                .frame(width: Self.size, height: Self.size)
                .background(Circle().fill(isChosen ? Theme.accent : hovering ? PickerStyle.hover : .clear))
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .onHover { hovering = $0 }
        .animation(Theme.hoverAnimation, value: hovering)
    }
}

/// A small icon button inside a picker popover (the calendar's month arrows).
private struct PickerIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        IconButton(configuration: configuration)
    }

    private struct IconButton: View {
        let configuration: Configuration
        @State private var hovering = false
        var body: some View {
            configuration.label
                .font(Fonts.icon)
                .foregroundStyle(hovering ? Theme.text : Theme.secondaryText)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(configuration.isPressed ? PickerStyle.pressed : hovering ? PickerStyle.hover : .clear))
                .contentShape(Rectangle())
                .pointerStyle(.link)
                .onHover { hovering = $0 }
                .animation(Theme.hoverAnimation, value: hovering)
        }
    }
}

/// Checklist of labels with a filter field that can create new labels.
struct LabelsPicker: View {
    @Environment(TodoStore.self) private var store
    @Binding var selection: [String]
    @State private var filter = ""
    @FocusState private var focused: Bool

    var body: some View {
        let q = filter.trimmingCharacters(in: .whitespaces)
        let labels = store.labels
        let shown = q.isEmpty ? labels : labels.filter { $0.name.localizedCaseInsensitiveContains(q) }
        let exists = labels.contains { $0.name.caseInsensitiveCompare(q) == .orderedSame }
        VStack(alignment: .leading, spacing: 0) {
            PickerField(prompt: "Type a label", text: $filter, focused: $focused) {
                if let first = shown.first, !q.isEmpty, first.name.caseInsensitiveCompare(q) == .orderedSame {
                    toggle(first.name)
                } else if !q.isEmpty, !exists {
                    selection.append(q)
                } else if let first = shown.first {
                    toggle(first.name)
                }
                filter = ""
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(shown) { entry in
                        let isOn = selection.contains(entry.name)
                        Button { toggle(entry.name) } label: {
                            PickerRow(entry.name) {
                                Image(systemName: "tag").foregroundStyle(Palette.color(entry.color))
                            } trailing: {
                                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                                    .font(Fonts.icon)
                                    .foregroundStyle(isOn ? Theme.accent : Theme.tertiaryText)
                            }
                        }
                        .buttonStyle(HoverRowButtonStyle())
                    }
                    if !q.isEmpty, !exists {
                        Button {
                            selection.append(q)
                            filter = ""
                        } label: {
                            PickerRow("Create label “\(q)”", tint: Theme.accent) {
                                Image(systemName: "plus").foregroundStyle(Theme.accent)
                            }
                        }
                        .buttonStyle(HoverRowButtonStyle())
                    }
                    if shown.isEmpty, q.isEmpty {
                        Text("No labels yet. Type to create one.")
                            .font(Fonts.body)
                            .foregroundStyle(Theme.secondaryText)
                            .padding(.horizontal, PickerStyle.rowPadding)
                            .frame(height: PickerStyle.rowHeight)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 260)
        }
        .pickerSurface(width: 240)
        .onAppear { focused = true }
    }

    private func toggle(_ name: String) {
        if let i = selection.firstIndex(of: name) { selection.remove(at: i) } else { selection.append(name) }
    }
}

/// Searchable list of projects and sections (Todoist's "Move to…").
struct MovePicker: View {
    @Environment(AppModel.self) private var model
    @Environment(TodoStore.self) private var store
    let current: (EntityID, EntityID?)
    let onPick: (EntityID, EntityID?) -> Void
    @State private var filter = ""
    @FocusState private var focused: Bool

    private struct Choice: Identifiable {
        let project: Project
        let section: TodoCore.Section?
        var id: String { project.id + "/" + (section?.id ?? "") }
        var title: String { section?.name ?? project.name }
    }

    var body: some View {
        let q = filter.trimmingCharacters(in: .whitespaces)
        let choices = model.allProjects.flatMap { p in
            [Choice(project: p, section: nil)] + store.sections(in: p.id).map { Choice(project: p, section: $0) }
        }.filter {
            q.isEmpty || $0.title.localizedCaseInsensitiveContains(q) || $0.project.name.localizedCaseInsensitiveContains(q)
        }
        VStack(alignment: .leading, spacing: 0) {
            PickerField(prompt: "Type a project name", text: $filter, focused: $focused) {
                if let c = choices.first { onPick(c.project.id, c.section?.id) }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(choices) { c in
                        let isCurrent = current.0 == c.project.id && current.1 == c.section?.id
                        Button { onPick(c.project.id, c.section?.id) } label: {
                            // A section sits under its project's name.
                            PickerRow(c.title, indent: c.section == nil ? 0 : PickerStyle.iconWidth + 8) {
                                if c.section == nil {
                                    ProjectIcon(c.project)
                                } else {
                                    Image(systemName: "rectangle.split.1x2").foregroundStyle(Theme.tertiaryText)
                                }
                            } trailing: {
                                if isCurrent {
                                    Image(systemName: "checkmark").font(Fonts.icon).foregroundStyle(Theme.accent)
                                }
                            }
                        }
                        .buttonStyle(HoverRowButtonStyle())
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 300)
        }
        .pickerSurface(width: 260)
        .onAppear { focused = true }
    }
}

/// A row in a picker popover: a pill (radius 6, inset 4 pt) while hovered.
struct HoverRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverRow(configuration: configuration)
    }

    private struct HoverRow: View {
        let configuration: Configuration
        @State private var hovering = false
        var body: some View {
            configuration.label
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(configuration.isPressed ? PickerStyle.pressed : hovering ? PickerStyle.hover : .clear)
                    .padding(.horizontal, 4))
                .contentShape(Rectangle())
                .pointerStyle(.link)
                .onHover { hovering = $0 }
                .animation(Theme.hoverAnimation, value: hovering)
        }
    }
}

/// Metrics and colors of the picker popovers. The popover is `Theme.field`, so its rows hover,
/// and its rules sit, one step lighter: `surface1`, the color of a field's border.
private enum PickerStyle {
    static let rowHeight: CGFloat = 28
    /// Content inset of a row: 8 pt inside its hover pill, which is inset 4 pt.
    static let rowPadding: CGFloat = 12
    static let iconWidth: CGFloat = 18
    static let hover = Ctp.surface1.color
    static let pressed = Ctp.surface2.color
    static let rule = Ctp.surface1.color
}

private extension View {
    /// A picker popover's surface: flat `Theme.field`, no material.
    func pickerSurface(width: CGFloat) -> some View {
        frame(width: width)
            .presentationBackground(Theme.field)
            .background(PopoverFrameFill())
    }
}

/// Fills the popover's frame, arrow included, with `Theme.field`: `presentationBackground`
/// only covers the content, and the arrow kept the system material.
private struct PopoverFrameFill: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Only in a popover's window; its frame view is the content view's superview.
            guard let window, String(describing: type(of: window)).contains("Popover"),
                  let content = window.contentView, let frame = content.superview,
                  !frame.subviews.contains(where: { $0 is Fill }) else { return }
            let fill = Fill(frame: frame.bounds)
            fill.autoresizingMask = [.width, .height]
            frame.addSubview(fill, positioned: .below, relativeTo: content)
        }
    }

    private final class Fill: NSView {
        override func draw(_ dirtyRect: NSRect) {
            Ctp.surface0.nsColor.setFill()  // Theme.field
            dirtyRect.fill()
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            needsDisplay = true
        }
    }
}

/// A 1 pt rule inside a picker popover.
private struct PickerRule: View {
    var body: some View {
        Rectangle().fill(PickerStyle.rule).frame(height: 1)
    }
}

/// The text field at the top of a picker, with a peach border while it has focus.
private struct PickerField: View {
    let prompt: String
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    let onSubmit: () -> Void

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .foregroundStyle(Theme.text)
            .focused(focused)
            .onSubmit(onSubmit)
            .fieldPrompt(prompt, show: text.isEmpty)
            .font(Fonts.body)
            .padding(.horizontal, 8)
            .frame(height: PickerStyle.rowHeight)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.field))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(focused.wrappedValue ? Theme.accent : Ctp.surface1.color, lineWidth: 1))
            .padding([.horizontal, .top], 4)
    }
}

/// A picker row, 28 pt tall: a 14 pt icon, the 13 pt title and an optional trailing view.
private struct PickerRow<Icon: View, Trailing: View>: View {
    let title: String
    let indent: CGFloat
    let tint: Color
    let icon: Icon
    let trailing: Trailing

    init(_ title: String, indent: CGFloat = 0, tint: Color = Theme.text,
         @ViewBuilder icon: () -> Icon, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.indent = indent
        self.tint = tint
        self.icon = icon()
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 8) {
            icon.font(Fonts.icon).frame(width: PickerStyle.iconWidth)
            Text(title).font(Fonts.body).foregroundStyle(tint).lineLimit(1)
            Spacer(minLength: 8)
            trailing
        }
        .padding(.leading, PickerStyle.rowPadding + indent)
        .padding(.trailing, PickerStyle.rowPadding)
        .frame(height: PickerStyle.rowHeight)
        .contentShape(Rectangle())
    }
}

extension PickerRow where Trailing == EmptyView {
    init(_ title: String, indent: CGFloat = 0, tint: Color = Theme.text, @ViewBuilder icon: () -> Icon) {
        self.init(title, indent: indent, tint: tint, icon: icon, trailing: { EmptyView() })
    }
}

extension View {
    /// `prompt` in `Theme.secondaryText` behind an empty plain text field. Apply the font after
    /// this so the prompt gets it too. (macOS draws a `TextField` prompt in the system
    /// placeholder color, whatever color the prompt's `Text` has.)
    func fieldPrompt(_ prompt: String, show: Bool) -> some View {
        background(alignment: .topLeading) {
            if show {
                Text(prompt)
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityLabel(Text(prompt))
    }
}

/// The project and section of the inline editor, as a menu of every project and its sections.
struct ProjectSectionMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(TodoStore.self) private var store
    let projectId: EntityID
    let sectionId: EntityID?
    let onPick: (EntityID, EntityID?) -> Void

    var body: some View {
        let project = store.project(projectId) ?? store.inbox
        let section = sectionId.flatMap { id in store.sections(in: projectId).first { $0.id == id } }
        Menu {
            ForEach(model.allProjects) { p in
                Button { onPick(p.id, nil) } label: {
                    SwiftUI.Label { Text(p.name) } icon: { Image(nsImage: MenuImages.project(p)) }
                }
                ForEach(store.sections(in: p.id)) { s in
                    Button("      \(s.name)") { onPick(p.id, s.id) }
                }
            }
        } label: {
            HStack(spacing: 6) {
                ProjectIcon(project)
                HStack(spacing: 4) {
                    Text(project.name).foregroundStyle(Theme.text)
                    if let section { Text("/ \(section.name)").foregroundStyle(Theme.secondaryText) }
                }
                Image(systemName: "chevron.down").font(Fonts.icon).foregroundStyle(Theme.tertiaryText)
            }
            .font(Fonts.body)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .frame(height: 28)
        }
        .menuStyle(.button)
        .buttonStyle(MenuLabelButtonStyle())
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Project and section")
    }
}

/// The priority chip of the inline editor, as a menu of the four priorities.
struct PriorityMenu: View {
    @Binding var priority: Priority
    var compact = true

    var body: some View {
        Menu {
            ForEach(Priority.allCases, id: \.self) { p in
                Button { priority = p } label: {
                    SwiftUI.Label { Text(p.title) } icon: { Image(nsImage: Self.flag(p)) }
                }
            }
        } label: {
            ChipLabel(icon: priority == .p4 ? "flag" : "flag.fill",
                      text: compact && priority == .p4 ? "Priority" : "P\(priority.rawValue)",
                      tint: priority == .p4 ? Theme.secondaryText : priority.color)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    /// A menu item's flag in the priority's color (not a template, so the menu keeps the color).
    static func flag(_ p: Priority) -> NSImage {
        let config = NSImage.SymbolConfiguration(paletteColors: [p.nsColor])
        let img = NSImage(systemSymbolName: p == .p4 ? "flag" : "flag.fill", accessibilityDescription: p.title)?
            .withSymbolConfiguration(config) ?? NSImage()
        img.isTemplate = false
        return img
    }
}

/// A menu's label in an editor: a pill while hovered.
private struct MenuLabelButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        MenuLabel(configuration: configuration)
    }

    private struct MenuLabel: View {
        let configuration: Configuration
        @State private var hovering = false
        var body: some View {
            configuration.label
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(configuration.isPressed ? Theme.selection : hovering ? Theme.hover : .clear))
                .contentShape(Rectangle())
                .pointerStyle(.link)
                .onHover { hovering = $0 }
                .animation(Theme.hoverAnimation, value: hovering)
        }
    }
}

/// Project icons for menus, which draw only images: the ring in the project's color, or the
/// inbox tray in lavender, like `ProjectIcon`. Not templates, so the menu keeps the colors.
private enum MenuImages {
    static func project(_ p: Project) -> NSImage {
        if p.isInbox {
            let config = NSImage.SymbolConfiguration(paletteColors: [Ctp.lavender.nsColor])
            let img = NSImage(systemSymbolName: "tray", accessibilityDescription: nil)?
                .withSymbolConfiguration(config) ?? NSImage()
            img.isTemplate = false
            return img
        }
        let color = Palette.ctp(p.color).nsColor
        // A 12 pt ring with a 1.5 pt line, centred in 14 pt.
        let img = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 1.75, dy: 1.75))
            ring.lineWidth = 1.5
            color.setStroke()
            ring.stroke()
            return true
        }
        img.isTemplate = false
        return img
    }
}
