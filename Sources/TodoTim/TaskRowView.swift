import SwiftUI
import TodoCore

/// Round checkbox: priority-colored ring with a tinted fill; shows a check on hover. Completing
/// fills it with a small pop first, so the row leaves after the check has registered.
struct CheckCircle: View {
    let priority: Priority
    let completed: Bool
    var size: CGFloat = 18
    let action: () -> Void
    @State private var hovering = false
    /// Between the click and the completion: drawn as completed.
    @State private var checking = false

    var body: some View {
        let color = priority == .p4 ? Color.secondary : priority.color
        let filled = completed || checking
        Button(action: tap) {
            ZStack {
                Circle().fill(filled ? color : color.opacity(priority == .p4 ? 0 : 0.14))
                Circle().strokeBorder(color, lineWidth: priority == .p4 ? 1 : 1.6)
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.5, weight: .bold))
                    .foregroundStyle(filled ? Color.white : color)
                    .opacity(filled || hovering ? 1 : 0)
                    .scaleEffect(checking ? 1.1 : 1)
            }
            .frame(width: size, height: size)
            .scaleEffect(checking ? 1.12 : 1)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .onHover { hovering = $0 }
        .help(completed ? "Reopen task" : "Complete task")
    }

    private func tap() {
        guard !completed else { return action() }
        guard !checking else { return }
        withAnimation(Theme.reduceMotion ? nil : .spring(duration: 0.2, bounce: 0.4)) { checking = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            action()
            checking = false
        }
    }
}

/// Reads the row's task and selection state. Only this small body depends on the selection, so
/// j/k re-renders the hosts of the rows on screen while `TaskRowView` (equatable) redraws only
/// the old and new selected row.
struct TaskRowHost: View, Equatable {
    @Environment(AppModel.self) private var model
    @Environment(TodoStore.self) private var store
    let item: RowItem

    nonisolated static func == (a: Self, b: Self) -> Bool { a.item == b.item }

    var body: some View {
        if let task = store.task(item.id) {
            let selected = model.selectedTaskID == item.id
            TaskRowView(item: item, task: task, isSelected: selected,
                        popover: selected && model.detailTaskID == nil ? model.popover : nil,
                        labelColors: model.labelColorKeys(task.labels),
                        project: item.showProject ? store.project(task.projectId).map(ProjectBadge.init) : nil)
                .equatable()
        }
    }
}

struct ProjectBadge: Equatable {
    var name: String
    var color: String
    var isInbox: Bool
    init(_ p: Project) { name = p.name; color = p.color; isInbox = p.isInbox }
}

struct TaskRowView: View, Equatable {
    @Environment(AppModel.self) private var model
    let item: RowItem
    let task: TodoTask
    let isSelected: Bool
    /// The open popover when this row is the selected one.
    let popover: TaskPopover?
    /// Palette keys parallel to `task.labels`.
    let labelColors: [String]
    /// Shown at the right in label and search views.
    let project: ProjectBadge?
    @State private var hovering = false
    /// Row height for drop half-detection and the placeholder; not observed.
    @State private var height = HeightBox()

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.item == b.item && a.task == b.task && a.isSelected == b.isSelected && a.popover == b.popover
            && a.labelColors == b.labelColors && a.project == b.project
    }

    var body: some View {
        let t = task
        HStack(alignment: .top, spacing: 0) {
            // Todoist-style drag handle, shown on hover. It sits in a column left of the
            // row's normal frame (see the negative padding below), so the layout is unchanged.
            GripDots()
                .opacity(hovering ? 1 : 0)
                .frame(width: Theme.grip, height: 34)
            chevron(t)
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 10) {
                    CheckCircle(priority: t.priority, completed: t.isCompleted) { model.setCompleted(t.id, !t.isCompleted) }
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(RichText.render(t.content))
                            .font(.system(size: 14))
                            .strikethrough(t.isCompleted)
                            .foregroundStyle(t.isCompleted ? .secondary : .primary)
                            .richTextLinks(tint: t.isCompleted ? .secondary : .primary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let line = t.description.split(separator: "\n", omittingEmptySubsequences: true).first {
                            Text(RichText.render(String(line)))
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .richTextLinks(tint: .secondary)
                                .lineLimit(1)
                        }
                        TaskMetaRow(task: t, labelColors: labelColors,
                                    subtaskTotal: item.subtaskTotal, subtaskDone: item.subtaskDone)
                    }
                    Spacer(minLength: 8)
                    if let p = project {
                        HStack(spacing: 4) {
                            Text(p.name).font(.system(size: 12)).foregroundStyle(.secondary)
                            Image(systemName: p.isInbox ? "tray" : "number")
                                .font(.system(size: 11))
                                .foregroundStyle(p.isInbox ? Color(hex: 0x246FE0) : Palette.color(p.color))
                        }
                        .padding(.top, 2)
                    }
                    // The action buttons (and their menu) are only built while hovering.
                    if hovering {
                        actions(t)
                    } else {
                        Color.clear.frame(width: 76, height: 22)
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, Theme.rowInset)
                Hairline()
            }
        }
        .padding(.leading, CGFloat(item.depth) * Theme.indent)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Theme.accent.opacity(0.10) : .clear)
                .padding(.leading, Theme.grip + CGFloat(item.depth) * Theme.indent + Theme.gutter - 4)
        )
        .contentShape(Rectangle())
        .pointerStyle(.link)
        .onHover { hovering = $0 }
        .onTapGesture { model.openTask(t.id) }
        .contextMenu { TaskMenuItems(task: t) }
        .popover(isPresented: Binding(get: { popover != nil }, set: { if !$0 { model.popover = nil } }),
                 arrowEdge: .bottom) {
            TaskPopoverContent(taskID: t.id, kind: popover ?? .date)
                .environment(model).environment(model.store)
        }
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { [height] h in height.value = h }
        .onDrag {
            MainActor.assumeIsolated { model.beginDrag(t.id, rowHeight: height.value) }
            return NSItemProvider(object: t.id as NSString)
        } preview: {
            DragPreview(task: t)
        }
        .modifier(RowDropModifier(enabled: project == nil, model: model, item: item, collapsed: t.collapsed, height: height))
        .padding(.leading, -Theme.grip)
    }

    @ViewBuilder private func chevron(_ t: TodoTask) -> some View {
        if item.hasChildren {
            Button { model.toggleCollapsed(t.id) } label: {
                Image(systemName: t.collapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: Theme.gutter, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            Color.clear.frame(width: Theme.gutter, height: 1)
        }
    }

    private func actions(_ t: TodoTask) -> some View {
        HStack(spacing: 2) {
            iconButton("pencil", help: "Edit task") { model.openTask(t.id) }
            iconButton("calendar", help: "Set due date (T)") {
                model.selectedTaskID = t.id
                model.popover = .date
            }
            Menu {
                TaskMenuItems(task: t)
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 24, height: 22)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .foregroundStyle(.secondary)
    }

    private func iconButton(_ name: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 13))
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Reorder drops apply to project lists only; label and search rows are drag sources only.
private struct RowDropModifier: ViewModifier {
    let enabled: Bool
    let model: AppModel
    let item: RowItem
    let collapsed: Bool
    let height: HeightBox

    func body(content: Content) -> some View {
        if enabled {
            content.onDrop(of: [.text], delegate: TaskRowDropDelegate(model: model, item: item, collapsed: collapsed, height: height))
        } else {
            content
        }
    }
}

/// The lifted card that follows the pointer while dragging a task.
struct DragPreview: View {
    let task: TodoTask
    var body: some View {
        HStack(spacing: 10) {
            CheckCircle(priority: task.priority, completed: task.isCompleted) {}
            Text(RichText.render(task.content)).font(.system(size: 14)).lineLimit(1)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(minWidth: 240, maxWidth: 420, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
    }
}

/// Subtask count, due chip and labels under the task title.
struct TaskMetaRow: View {
    let task: TodoTask
    /// Palette keys parallel to `task.labels` (see `AppModel.labelColorKeys`).
    let labelColors: [String]
    var subtaskTotal = 0
    var subtaskDone = 0

    var body: some View {
        let hasMeta = subtaskTotal > 0 || task.due != nil || !task.labels.isEmpty
        if hasMeta {
            HStack(spacing: 10) {
                if subtaskTotal > 0 {
                    HStack(spacing: 3) {
                        SubtaskIcon().frame(width: 12, height: 12)
                        Text("\(subtaskDone)/\(subtaskTotal)")
                    }
                    .foregroundStyle(.secondary)
                }
                if let due = task.due {
                    HStack(spacing: 3) {
                        Image(systemName: "calendar").font(.system(size: 10))
                        Text(due.displayString())
                        if let rule = task.recurrence {
                            Image(systemName: "repeat").font(.system(size: 10)).help(Recurrence.summary(rule))
                        }
                    }
                    .foregroundStyle(task.isCompleted ? .secondary : due.chipColor)
                }
                ForEach(Array(task.labels.enumerated()), id: \.element) { i, name in
                    let color = i < labelColors.count && !labelColors[i].isEmpty ? Palette.color(labelColors[i]) : .secondary
                    HStack(spacing: 2) {
                        Image(systemName: "tag").font(.system(size: 10))
                        Text(name)
                    }
                    .foregroundStyle(color)
                }
            }
            .font(.system(size: 12))
        }
    }
}

/// Shared items for a task's context menu and "…" menu.
struct TaskMenuItems: View {
    @Environment(AppModel.self) private var model
    @Environment(TodoStore.self) private var store
    let task: TodoTask

    var body: some View {
        Button("Open task") { model.openTask(task.id) }
        Button("Add sub-task") { model.addSubtask(to: task.id) }
        Divider()
        Menu("Due date") {
            Button("Today") { store.updateTask(task.id) { $0.due = .offset(days: 0) } }
            Button("Tomorrow") { store.updateTask(task.id) { $0.due = .offset(days: 1) } }
            Button("This weekend") { store.updateTask(task.id) { $0.due = .weekend } }
            Button("Next week") { store.updateTask(task.id) { $0.due = .nextWeek } }
            Divider()
            Button("No date") { store.updateTask(task.id) { $0.due = nil } }
        }
        Menu("Priority") {
            ForEach(Priority.allCases, id: \.self) { p in
                Toggle(p.title, isOn: Binding(get: { task.priority == p }, set: { _ in model.setPriority(p, for: task.id) }))
            }
        }
        Button("Labels…") { model.selectedTaskID = task.id; model.popover = .labels }
        Menu("Move to") {
            ForEach(model.allProjects) { p in
                let sections = store.sections(in: p.id)
                if sections.isEmpty {
                    Button(p.name) { model.move(task.id, toProject: p.id, section: nil) }
                } else {
                    Menu(p.name) {
                        Button("(No section)") { model.move(task.id, toProject: p.id, section: nil) }
                        ForEach(sections) { s in
                            Button(s.name) { model.move(task.id, toProject: p.id, section: s.id) }
                        }
                    }
                }
            }
        }
        Divider()
        Button(task.isCompleted ? "Reopen task" : "Complete task") { model.toggleComplete(task.id) }
        Button("Delete task…", role: .destructive) { model.requestDelete(task.id) }
    }
}

/// Six-dot drag handle (2 × 3), like Todoist's.
struct GripDots: View {
    var body: some View {
        Canvas { ctx, size in
            let d: CGFloat = 3, gap: CGFloat = 3
            let w = d * 2 + gap, h = d * 3 + gap * 2
            let x0 = (size.width - w) / 2, y0 = (size.height - h) / 2
            for col in 0..<2 {
                for row in 0..<3 {
                    let r = CGRect(x: x0 + CGFloat(col) * (d + gap), y: y0 + CGFloat(row) * (d + gap), width: d, height: d)
                    ctx.fill(Path(ellipseIn: r), with: .color(.secondary))
                }
            }
        }
        .frame(width: 12, height: 18)
        .help("Drag to reorder")
    }
}

/// Todoist's subtask glyph: a dot at the top left joined by a curved line to a dot at the
/// bottom right.
struct SubtaskIcon: View {
    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            let r = w * 0.17, lw = max(1, w * 0.1)
            let top = CGPoint(x: r + lw / 2, y: r + lw / 2)
            let end = CGPoint(x: w - r - lw / 2, y: h - r - lw / 2)
            ctx.stroke(Path(ellipseIn: CGRect(x: top.x - r, y: top.y - r, width: 2 * r, height: 2 * r)),
                       with: .foreground, lineWidth: lw)
            ctx.stroke(Path(ellipseIn: CGRect(x: end.x - r, y: end.y - r, width: 2 * r, height: 2 * r)),
                       with: .foreground, lineWidth: lw)
            var line = Path()
            line.move(to: CGPoint(x: top.x, y: top.y + r))
            line.addLine(to: CGPoint(x: top.x, y: end.y - r * 1.5))
            line.addQuadCurve(to: CGPoint(x: end.x - r, y: end.y), control: CGPoint(x: top.x, y: end.y))
            ctx.stroke(line, with: .foreground, lineWidth: lw)
        }
    }
}
