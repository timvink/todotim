import SwiftUI
import TodoCore

/// Round checkbox: a ring in the priority color; shows a check on hover. Completing fills it with
/// a small pop and a ring that bursts outward, so the row leaves after the check has registered.
struct CheckCircle: View {
    let priority: Priority
    let completed: Bool
    var size: CGFloat = Theme.checkbox
    let action: () -> Void
    @State private var hovering = false
    /// Between the click and the completion: drawn as completed.
    @State private var checking = false
    @State private var bursts = 0

    var body: some View {
        let color = priority.color
        let filled = completed || checking
        Button(action: tap) {
            ZStack {
                Circle().fill(filled ? color : color.opacity(priority == .p4 ? 0 : 0.12))
                Circle().strokeBorder(color, lineWidth: 1.5)
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.55, weight: .bold))
                    .foregroundStyle(filled ? Theme.onAccent : color)
                    .opacity(filled || hovering ? 1 : 0)
            }
            .frame(width: size, height: size)
            .scaleEffect(checking ? 1.15 : 1)
            .background {
                Circle().stroke(color, lineWidth: 1.5)
                    .keyframeAnimator(initialValue: Burst(), trigger: bursts) { ring, v in
                        ring.scaleEffect(v.scale).opacity(v.opacity)
                    } keyframes: { _ in
                        KeyframeTrack(\.scale) {
                            LinearKeyframe(1, duration: 0.001)
                            CubicKeyframe(1.6, duration: 0.28)
                        }
                        KeyframeTrack(\.opacity) {
                            LinearKeyframe(0.6, duration: 0.001)
                            LinearKeyframe(0, duration: 0.28)
                        }
                    }
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .onHover { hovering = $0 }
        .help(completed ? "Reopen task" : "Complete task")
    }

    private struct Burst {
        var scale: CGFloat = 1
        var opacity: Double = 0
    }

    private func tap() {
        guard !completed else { return action() }
        guard !checking else { return }
        if !Theme.reduceMotion { bursts += 1 }
        withAnimation(Theme.reduceMotion ? nil : .spring(duration: 0.2, bounce: 0.45)) { checking = true }
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
            // No selection pill while the task panel is open: it would peek out beside the panel.
            TaskRowView(item: item, task: task, isSelected: selected && model.detailTaskID == nil,
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
        let pillStart = Theme.grip + CGFloat(item.depth) * Theme.indent + Theme.gutter
        HStack(alignment: .top, spacing: 0) {
            // The drag handle, shown on hover. It sits in a column left of the row's normal frame
            // (see the negative padding below), so the layout is unchanged.
            GripDots()
                .opacity(hovering ? 1 : 0)
                .frame(width: Theme.grip, height: Self.lineHeight)
            chevron(t)
            HStack(alignment: .top, spacing: 10) {
                CheckCircle(priority: t.priority, completed: t.isCompleted) { model.setCompleted(t.id, !t.isCompleted) }
                    .frame(height: Self.firstLine)
                VStack(alignment: .leading, spacing: 2) {
                    Text(RichText.render(t.content))
                        .font(Fonts.body)
                        .strikethrough(t.isCompleted)
                        .foregroundStyle(t.isCompleted ? Theme.tertiaryText : Theme.text)
                        .richTextLinks(tint: t.isCompleted ? Theme.tertiaryText : Theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(minHeight: Self.firstLine)
                    if let line = t.description.split(separator: "\n", omittingEmptySubsequences: true).first {
                        Text(RichText.render(String(line)))
                            .font(Fonts.small)
                            .foregroundStyle(Theme.secondaryText)
                            .richTextLinks(tint: Theme.secondaryText)
                            .lineLimit(1)
                    }
                    TaskMetaRow(task: t, labelColors: labelColors,
                                subtaskTotal: item.subtaskTotal, subtaskDone: item.subtaskDone)
                }
                Spacer(minLength: 8)
                if let p = project {
                    HStack(spacing: 5) {
                        Text(p.name).font(Fonts.meta).foregroundStyle(Theme.secondaryText)
                        ProjectIcon(colorKey: p.color, isInbox: p.isInbox, size: 9)
                    }
                    .frame(height: Self.firstLine)
                }
                // The action buttons (and their menu) are only built while hovering; their space is
                // always reserved, so hovering never moves the text.
                ZStack(alignment: .trailing) {
                    Color.clear.frame(width: 76, height: Self.firstLine)
                    if hovering { actions(t).transition(.opacity) }
                }
            }
            .padding(.vertical, Self.verticalPadding)
            .padding(.horizontal, Theme.rowInset)
        }
        .padding(.leading, CGFloat(item.depth) * Theme.indent)
        .background(alignment: .leading) {
            RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous)
                .fill(isSelected ? Theme.selection : hovering ? Theme.hover : .clear)
                .padding(.leading, pillStart)
        }
        .background {
            if item.depth > 0 || item.expanded {
                ThreadLines(depth: item.depth, lastAtDepth: item.lastAtDepth, expanded: item.expanded,
                            hasChevron: item.hasChildren, centerY: Self.verticalPadding + Self.firstLine / 2)
                    .stroke(Ctp.surface1.color, lineWidth: 1)
            }
        }
        .contentShape(Rectangle())
        .pointerStyle(.link)
        .onHover { h in withAnimation(Theme.hoverAnimation) { hovering = h } }
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

    /// Height of the title's first line; the checkbox, chevron and project badge center on it.
    static let firstLine: CGFloat = 18
    static let verticalPadding: CGFloat = 5
    static let lineHeight = firstLine + 2 * verticalPadding

    @ViewBuilder private func chevron(_ t: TodoTask) -> some View {
        if item.hasChildren {
            Button { model.toggleCollapsed(t.id) } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.tertiaryText)
                    .rotationEffect(.degrees(t.collapsed ? 0 : 90))
                    .frame(width: Theme.gutter, height: Self.lineHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(t.collapsed ? "Show sub-tasks" : "Hide sub-tasks")
        } else {
            Color.clear.frame(width: Theme.gutter, height: 1)
        }
    }

    private func actions(_ t: TodoTask) -> some View {
        HStack(spacing: 2) {
            RowIconButton(icon: "pencil", help: "Open task (↩)") { model.openTask(t.id) }
            RowIconButton(icon: "calendar", help: "Set date (T)") {
                model.selectedTaskID = t.id
                model.popover = .date
            }
            Menu {
                TaskMenuItems(task: t)
            } label: {
                Image(systemName: "ellipsis")
                    .font(Fonts.body)
                    .frame(width: 24, height: 22)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .tint(Theme.tertiaryText)
            .fixedSize()
            .help("More")
        }
        .frame(height: Self.firstLine)
    }
}

/// A 24 × 22 glyph button in a task row: quiet until hovered.
private struct RowIconButton: View {
    let icon: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(Fonts.body)
                .foregroundStyle(hovering ? Theme.text : Theme.tertiaryText)
                .frame(width: 24, height: 22)
                .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).fill(hovering ? Theme.hover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// The sub-task threads: a 1 pt line at each parent's checkbox runs down past its sub-tasks and
/// stops level with the last one's checkbox. Drawn in the row's own coordinates (the grip column
/// starts at x = 0).
struct ThreadLines: Shape {
    let depth: Int
    let lastAtDepth: [Bool]
    let expanded: Bool
    /// The row shows a chevron, which sits on its parent's thread: the thread breaks around it.
    let hasChevron: Bool
    /// Center of the checkbox, from the row's top.
    let centerY: CGFloat

    static func x(_ depth: Int) -> CGFloat {
        Theme.grip + CGFloat(depth) * Theme.indent + Theme.gutter + Theme.rowInset + Theme.checkbox / 2
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        func line(_ x: CGFloat, _ from: CGFloat, _ to: CGFloat) {
            guard to > from else { return }
            p.move(to: CGPoint(x: x, y: rect.minY + from))
            p.addLine(to: CGPoint(x: x, y: rect.minY + to))
        }
        let h = rect.height
        for k in 0..<min(depth, lastAtDepth.count) {
            let last = lastAtDepth[k]
            let x = Self.x(k)
            if k == depth - 1 {
                // The parent's thread reaches this row's checkbox, and continues if siblings follow.
                let end = last ? centerY : h
                if hasChevron {
                    line(x, 0, centerY - 8)
                    if !last { line(x, centerY + 8, h) }
                } else {
                    line(x, 0, end)
                }
            } else if !last {
                line(x, 0, h)
            }
        }
        if expanded { line(Self.x(depth), centerY + Theme.checkbox / 2 + 3, h) }
        return p
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
            Text(RichText.render(task.content)).font(Fonts.body).foregroundStyle(Theme.text).lineLimit(1)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(minWidth: 220, maxWidth: 420, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous).fill(Ctp.surface0.color))
        .overlay(RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous).strokeBorder(Ctp.surface1.color))
        .shadow(color: Theme.shadow, radius: 14, y: 6)
        // Picked up like a card: a slight tilt, with room for it and the shadow in the image.
        .rotationEffect(.degrees(Theme.reduceMotion ? 0 : 1.5))
        .padding(16)
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
            HStack(spacing: 8) {
                if subtaskTotal > 0 {
                    // Green once every sub-task is done.
                    HStack(spacing: 3) {
                        SubtaskIcon().frame(width: 11, height: 11)
                        Text("\(subtaskDone)/\(subtaskTotal)").monospacedDigit()
                            .contentTransition(.numericText())
                            .animation(Theme.motion, value: subtaskDone)
                    }
                    .foregroundStyle(subtaskDone == subtaskTotal ? Theme.today : Theme.secondaryText)
                }
                if let due = task.due {
                    HStack(spacing: 3) {
                        Image(systemName: "calendar").font(Fonts.smallIcon)
                        Text(due.displayString())
                        if let rule = task.recurrence {
                            Image(systemName: "repeat").font(Fonts.smallIcon).help(Recurrence.summary(rule))
                        }
                    }
                    .foregroundStyle(task.isCompleted ? Theme.tertiaryText : due.chipColor)
                }
                ForEach(Array(task.labels.enumerated()), id: \.element) { i, name in
                    let color = i < labelColors.count && !labelColors[i].isEmpty ? Palette.color(labelColors[i]) : Theme.tertiaryText
                    HStack(spacing: 4) {
                        LabelDot(color: color)
                        Text(name).foregroundStyle(Theme.secondaryText)
                    }
                }
            }
            .font(Fonts.meta)
            .lineLimit(1)
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

/// Six-dot drag handle (2 × 3).
struct GripDots: View {
    var body: some View {
        Canvas { ctx, size in
            let d: CGFloat = 3, gap: CGFloat = 3
            let w = d * 2 + gap, h = d * 3 + gap * 2
            let x0 = (size.width - w) / 2, y0 = (size.height - h) / 2
            for col in 0..<2 {
                for row in 0..<3 {
                    let r = CGRect(x: x0 + CGFloat(col) * (d + gap), y: y0 + CGFloat(row) * (d + gap), width: d, height: d)
                    ctx.fill(Path(ellipseIn: r), with: .color(Theme.tertiaryText))
                }
            }
        }
        .frame(width: 12, height: 18)
        .help("Drag to reorder")
    }
}

/// The sub-task glyph: a dot at the top left joined by a curved line to a dot at the bottom right.
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
