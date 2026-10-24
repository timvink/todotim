import SwiftUI
import TodoCore

/// Round Todoist checkbox: priority-colored ring with a tinted fill; shows a check on hover.
struct CheckCircle: View {
    let priority: Priority
    let completed: Bool
    var size: CGFloat = 18
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let color = priority == .p4 ? Color.secondary : priority.color
        Button(action: action) {
            ZStack {
                Circle().fill(completed ? color : color.opacity(priority == .p4 ? 0 : 0.14))
                Circle().strokeBorder(color, lineWidth: priority == .p4 ? 1 : 1.6)
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.5, weight: .bold))
                    .foregroundStyle(completed ? Color.white : color)
                    .opacity(completed || hovering ? 1 : 0)
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(completed ? "Reopen task" : "Complete task")
    }
}

struct TaskRowView: View {
    @Environment(AppModel.self) private var model
    @Environment(TodoStore.self) private var store
    let item: RowItem
    /// Show "# Project" at the right (label and search views).
    var showProject = false
    @State private var hovering = false

    var body: some View {
        let t = item.task
        let selected = model.selectedTaskID == t.id
        HStack(alignment: .top, spacing: 0) {
            chevron(t)
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 10) {
                    CheckCircle(priority: t.priority, completed: t.isCompleted) { model.toggleComplete(t.id) }
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(t.content)
                            .font(.system(size: 14))
                            .strikethrough(t.isCompleted)
                            .foregroundStyle(t.isCompleted ? .secondary : .primary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let line = t.description.split(separator: "\n", omittingEmptySubsequences: true).first {
                            Text(String(line))
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        TaskMetaRow(task: t, subtaskTotal: item.subtaskTotal, subtaskDone: item.subtaskDone)
                    }
                    Spacer(minLength: 8)
                    if showProject, let p = store.project(t.projectId) {
                        HStack(spacing: 4) {
                            Text(p.name).font(.system(size: 12)).foregroundStyle(.secondary)
                            Image(systemName: p.isInbox ? "tray" : "number")
                                .font(.system(size: 11))
                                .foregroundStyle(p.isInbox ? Color(hex: 0x246FE0) : Palette.color(p.color))
                        }
                        .padding(.top, 2)
                    }
                    actions(t)
                        .opacity(hovering ? 1 : 0)
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 4)
                Divider()
            }
        }
        .padding(.leading, CGFloat(item.depth) * Theme.indent)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(selected ? Theme.accent.opacity(0.10) : .clear)
                .padding(.leading, CGFloat(item.depth) * Theme.indent + Theme.gutter - 4)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { model.openTask(t.id) }
        .contextMenu { TaskMenuItems(task: t) }
        .popover(isPresented: popoverBinding(t.id), arrowEdge: .bottom) {
            TaskPopoverContent(taskID: t.id, kind: model.popover ?? .date)
                .environment(model).environment(store)
        }
        .draggable(t.id) {
            Text(t.content)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .windowBackgroundColor)))
        }
        .dropDestination(for: String.self) { ids, _ in model.drop(ids, before: t) }
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

    private func popoverBinding(_ id: EntityID) -> Binding<Bool> {
        Binding(
            get: { model.selectedTaskID == id && model.popover != nil && model.detailTaskID == nil },
            set: { if !$0 { model.popover = nil } })
    }
}

/// Subtask count, due chip and labels under the task title.
struct TaskMetaRow: View {
    @Environment(TodoStore.self) private var store
    let task: TodoTask
    var subtaskTotal = 0
    var subtaskDone = 0

    var body: some View {
        let hasMeta = subtaskTotal > 0 || task.due != nil || !task.labels.isEmpty
        if hasMeta {
            HStack(spacing: 10) {
                if subtaskTotal > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.triangle.branch").font(.system(size: 10))
                        Text("\(subtaskDone)/\(subtaskTotal)")
                    }
                    .foregroundStyle(.secondary)
                }
                if let due = task.due {
                    HStack(spacing: 3) {
                        Image(systemName: "calendar").font(.system(size: 10))
                        Text(due.displayString())
                    }
                    .foregroundStyle(task.isCompleted ? .secondary : due.chipColor)
                }
                ForEach(task.labels, id: \.self) { name in
                    let color = store.labels.first { $0.name == name }.map { Palette.color($0.color) } ?? .secondary
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
