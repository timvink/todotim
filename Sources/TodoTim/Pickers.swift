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
    @State private var day = Date()
    @FocusState private var focused: Bool

    var body: some View {
        let parsed = DateParser.parse(text)
        VStack(alignment: .leading, spacing: 0) {
            TextField("Type a date", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focused)
                .padding(10)
                .onSubmit {
                    if let parsed { onPick(parsed) }
                }
            if !text.isEmpty {
                HStack {
                    Image(systemName: "calendar")
                    Text(parsed.map { "\($0.displayString())  ·  \($0.date)" } ?? "No match")
                }
                .font(.system(size: 12))
                .foregroundStyle(parsed?.chipColor ?? .secondary)
                .padding(.horizontal, 10).padding(.bottom, 8)
            }
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                quick("Today", icon: "calendar.badge.clock", color: Theme.today, .offset(days: 0))
                quick("Tomorrow", icon: "sun.max", color: Theme.tomorrow, .offset(days: 1))
                quick("This weekend", icon: "sofa", color: Color(hex: 0x246FE0), .weekend)
                quick("Next week", icon: "arrow.right.circle", color: Theme.thisWeek, .nextWeek)
                quick("No date", icon: "nosign", color: .secondary, nil)
            }
            .padding(.vertical, 4)
            Divider()
            DatePicker("", selection: $day, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
                .padding(8)
                .frame(maxWidth: .infinity)
                .onChange(of: day) { _, d in onPick(DueDate(d)) }
        }
        .frame(width: 250)
        .onAppear {
            if let d = due?.day() { day = d }
            focused = true
        }
    }

    private func quick(_ title: String, icon: String, color: Color, _ value: DueDate?) -> some View {
        Button { onPick(value) } label: {
            HStack(spacing: 10) {
                Image(systemName: icon).foregroundStyle(color).frame(width: 18)
                Text(title).font(.system(size: 13))
                Spacer()
                if let value, let d = value.day() {
                    Text(d.formatted(.dateTime.weekday(.abbreviated)))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverRowButtonStyle())
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
        let names = store.labels.map(\.name)
        let shown = q.isEmpty ? names : names.filter { $0.localizedCaseInsensitiveContains(q) }
        VStack(alignment: .leading, spacing: 0) {
            TextField("Type a label", text: $filter)
                .textFieldStyle(.plain)
                .focused($focused)
                .padding(10)
                .onSubmit {
                    if let first = shown.first, q.isEmpty == false, first.caseInsensitiveCompare(q) == .orderedSame {
                        toggle(first)
                    } else if !q.isEmpty, !names.contains(where: { $0.caseInsensitiveCompare(q) == .orderedSame }) {
                        selection.append(q)
                    } else if let first = shown.first {
                        toggle(first)
                    }
                    filter = ""
                }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(shown, id: \.self) { name in
                        let color = store.labels.first { $0.name == name }.map { Palette.color($0.color) } ?? .secondary
                        Button { toggle(name) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "tag").foregroundStyle(color).frame(width: 18)
                                Text(name).font(.system(size: 13))
                                Spacer()
                                Image(systemName: selection.contains(name) ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(selection.contains(name) ? Theme.accent : .secondary)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(HoverRowButtonStyle())
                    }
                    if !q.isEmpty, !names.contains(where: { $0.caseInsensitiveCompare(q) == .orderedSame }) {
                        Button {
                            selection.append(q)
                            filter = ""
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "plus").frame(width: 18)
                                Text("Create label “\(q)”").font(.system(size: 13))
                                Spacer()
                            }
                            .foregroundStyle(Theme.accent)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(HoverRowButtonStyle())
                    }
                    if shown.isEmpty, q.isEmpty {
                        Text("No labels yet. Type to create one.")
                            .font(.system(size: 12)).foregroundStyle(.secondary).padding(10)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 260)
        }
        .frame(width: 240)
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
            TextField("Type a project name", text: $filter)
                .textFieldStyle(.plain)
                .focused($focused)
                .padding(10)
                .onSubmit { if let c = choices.first { onPick(c.project.id, c.section?.id) } }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(choices) { c in
                        Button { onPick(c.project.id, c.section?.id) } label: {
                            HStack(spacing: 8) {
                                if c.section == nil {
                                    Image(systemName: c.project.isInbox ? "tray" : "number")
                                        .foregroundStyle(c.project.isInbox ? Color(hex: 0x246FE0) : Palette.color(c.project.color))
                                        .frame(width: 18)
                                } else {
                                    Image(systemName: "rectangle.split.1x2")
                                        .foregroundStyle(.secondary)
                                        .frame(width: 18)
                                        .padding(.leading, 18)
                                }
                                Text(c.title).font(.system(size: 13))
                                Spacer()
                                if current.0 == c.project.id && current.1 == c.section?.id {
                                    Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                                }
                            }
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(HoverRowButtonStyle())
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 300)
        }
        .frame(width: 260)
        .onAppear { focused = true }
    }
}

struct HoverRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverRow(configuration: configuration)
    }

    private struct HoverRow: View {
        let configuration: Configuration
        @State private var hovering = false
        var body: some View {
            configuration.label
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(hovering ? 0.08 : 0)).padding(.horizontal, 4))
                .onHover { hovering = $0 }
        }
    }
}

/// "# Project / Section" menu button used by the editors and the task sheet.
struct ProjectSectionMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(TodoStore.self) private var store
    let projectId: EntityID
    let sectionId: EntityID?
    let onPick: (EntityID, EntityID?) -> Void

    var body: some View {
        let p = store.project(projectId)
        let s = sectionId.flatMap { id in store.sections(in: projectId).first { $0.id == id } }
        Menu {
            ForEach(model.allProjects) { proj in
                Button { onPick(proj.id, nil) } label: {
                    SwiftUI.Label { Text(proj.name) } icon: { Image(nsImage: Palette.swatch(proj.isInbox ? "blue" : proj.color)) }
                }
                ForEach(store.sections(in: proj.id)) { sec in
                    Button("      \(sec.name)") { onPick(proj.id, sec.id) }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: p?.isInbox == true ? "tray" : "number")
                    .foregroundStyle(p?.isInbox == true ? Color(hex: 0x246FE0) : Palette.color(p?.color ?? "charcoal"))
                Text(p?.name ?? "Inbox")
                if let s { Text("/ \(s.name)").foregroundStyle(.secondary) }
            }
            .font(.system(size: 12))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .tint(.primary)
        .fixedSize()
    }
}

/// Priority flag menu chip.
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
            HStack(spacing: 4) {
                Image(systemName: priority == .p4 ? "flag" : "flag.fill")
                Text(compact && priority == .p4 ? "Priority" : "P\(priority.rawValue)")
            }
            .font(.system(size: 12))
            .foregroundStyle(priority == .p4 ? Color.secondary : priority.color)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .tint(priority == .p4 ? Color.secondary : priority.color)
        .fixedSize()
    }

    static func flag(_ p: Priority) -> NSImage {
        let hex: UInt32 = switch p { case .p1: 0xD1453B; case .p2: 0xEB8909; case .p3: 0x246FE0; case .p4: 0x808080 }
        let color = NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        let config = NSImage.SymbolConfiguration(paletteColors: [color])
        let img = NSImage(systemSymbolName: p == .p4 ? "flag" : "flag.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(config) ?? NSImage()
        img.isTemplate = false
        return img
    }
}
