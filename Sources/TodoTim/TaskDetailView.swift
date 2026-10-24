import AppKit
import SwiftUI
import TodoCore

/// Todoist's task view, shown as a panel over the main window (see `ModalLayer`): project
/// header with ⌃/⌄, "…" and close; one column with title, description, project, date, priority,
/// labels and sub-tasks. ↑/↓/j/k move to the previous/next task.
struct TaskDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(TodoStore.self) private var store
    let size: CGSize

    var body: some View {
        // A fixed size behind a GeometryReader (which never asks its content for a size), so a
        // keystroke never re-measures the whole panel.
        GeometryReader { _ in
            if let id = model.detailTaskID, let task = store.task(id) {
                // Not `.id(id)`: moving to the next task updates the panel in place, which is much
                // cheaper than rebuilding it. Per-task state is reset in `TaskDetailContent`.
                TaskDetailContent(task: task)
            } else {
                Color.clear.onAppear { model.detailTaskID = nil }
            }
        }
        .frame(width: size.width, height: size.height)
    }
}

private struct TaskDetailContent: View {
    @Environment(AppModel.self) private var model
    @Environment(TodoStore.self) private var store
    let task: TodoTask

    @State private var newSubtask = ""
    @State private var addingSubtask = false
    /// The move popover opened from the header (else from the project row).
    @State private var moveFromHeader = false
    @FocusState private var focus: DetailField?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                content
                    .padding(.horizontal, 28)
                    .padding(.top, 20)
                    .padding(.bottom, 32)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear {
            // Keep focus out of the title so ↑/↓/j/k navigate between tasks.
            DispatchQueue.main.async { model.mainWindow?.makeFirstResponder(nil) }
        }
        .onChange(of: task.id) {
            newSubtask = ""
            addingSubtask = false
        }
        .onChange(of: model.popover) { _, p in if p == nil { moveFromHeader = false } }
    }

    private func popoverBinding(_ kind: TaskPopover, header: Bool = false) -> Binding<Bool> {
        Binding(get: { model.popover == kind && (kind != .move || moveFromHeader == header) },
                set: { if !$0, model.popover == kind { model.popover = nil } })
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 4) {
            if let p = store.project(task.projectId) {
                Button {
                    moveFromHeader = true
                    model.popover = .move
                } label: {
                    HStack(spacing: 6) {
                        projectIcon(p)
                        Text(p.name).font(.system(size: 13))
                        if let s = sectionName {
                            Text("/").foregroundStyle(.secondary)
                            Text(s).font(.system(size: 13)).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 6).padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(HoverButtonStyle())
                .help("Move to project (V)")
                .popover(isPresented: popoverBinding(.move, header: true), arrowEdge: .bottom) { movePicker }
            }
            Spacer()
            headerButton("chevron.up", help: "Previous task (↑ / K)") { model.moveDetail(-1) }
            headerButton("chevron.down", help: "Next task (↓ / J)") { model.moveDetail(1) }
            Menu {
                TaskMenuItems(task: task)
            } label: {
                Image(systemName: "ellipsis").frame(width: 28, height: 26)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .pointerStyle(.link)
            .help("More actions")
            headerButton("xmark", help: "Close (Esc)") { model.detailTaskID = nil }
        }
        .padding(.leading, 14).padding(.trailing, 10).padding(.vertical, 8)
    }

    private var sectionName: String? {
        guard let sid = task.sectionId else { return nil }
        return store.sections(in: task.projectId).first { $0.id == sid }?.name
    }

    private func projectIcon(_ p: Project) -> some View {
        Image(systemName: p.isInbox ? "tray" : "number")
            .foregroundStyle(p.isInbox ? Color(hex: 0x246FE0) : Palette.color(p.color))
    }

    private func headerButton(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(HoverButtonStyle())
        .foregroundStyle(.secondary)
        .help(help)
    }

    private var movePicker: some View {
        MovePicker(current: (task.projectId, task.sectionId)) { pid, sid in
            model.popover = nil
            model.move(task.id, toProject: pid, section: sid)
        }
        .environment(model).environment(store)
    }

    // MARK: Body

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let pid = task.parentId, let parent = store.task(pid) {
                Button { model.detailTaskID = parent.id } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.turn.left.up")
                        Text(String(RichText.render(parent.content).characters)).lineLimit(1)
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .pointerStyle(.link)
                .padding(.bottom, 10)
            }
            HStack(alignment: .top, spacing: 12) {
                CheckCircle(priority: task.priority, completed: task.isCompleted, size: 22) { model.toggleComplete(task.id) }
                    .padding(.top, 3)
                DetailTextFields(taskID: task.id, content: task.content, description: task.description,
                                 isCompleted: task.isCompleted, focus: $focus)
                    .id(task.id)
            }
            .padding(.bottom, 14)
            Divider()
            attributes
            subtasks.padding(.top, 18)
        }
    }

    /// Project, date, priority and labels as Todoist-style list rows.
    private var attributes: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let p = store.project(task.projectId) {
                attributeRow(popover: popoverBinding(.move)) {
                    moveFromHeader = false
                    model.popover = .move
                } label: {
                    projectIcon(p).frame(width: 20)
                    Text(p.name)
                    if let s = sectionName { Text("/ \(s)").foregroundStyle(.secondary) }
                } popoverContent: { movePicker }
            }
            Divider()
            attributeRow(popover: popoverBinding(.date)) { model.popover = .date } label: {
                Image(systemName: "calendar").frame(width: 20)
                    .foregroundStyle(task.due?.chipColor ?? .secondary)
                if let due = task.due {
                    Text(due.displayString()).foregroundStyle(due.chipColor)
                    Spacer()
                    Button { store.updateTask(task.id) { $0.due = nil } } label: {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                            .frame(width: 20, height: 20).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Remove date")
                } else {
                    Text("Date").foregroundStyle(.secondary)
                }
            } popoverContent: {
                DueDatePicker(due: task.due) { due in
                    store.updateTask(task.id) { $0.due = due }
                    model.popover = nil
                }
            }
            Divider()
            Menu {
                ForEach(Priority.allCases, id: \.self) { p in
                    Button { model.setPriority(p, for: task.id) } label: {
                        SwiftUI.Label { Text(p.title) } icon: { Image(nsImage: PriorityMenu.flag(p)) }
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: task.priority == .p4 ? "flag" : "flag.fill").frame(width: 20)
                        .foregroundStyle(task.priority == .p4 ? Color.secondary : task.priority.color)
                    Text(task.priority.title)
                    Spacer()
                }
                .font(.system(size: 13))
                .padding(.horizontal, 6).padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(HoverButtonStyle())
            .menuIndicator(.hidden)
            .pointerStyle(.link)
            Divider()
            attributeRow(popover: popoverBinding(.labels)) { model.popover = .labels } label: {
                Image(systemName: "tag").frame(width: 20).foregroundStyle(.secondary)
                if task.labels.isEmpty {
                    Text("Add labels").foregroundStyle(.secondary)
                } else {
                    FlowRow(task.labels) { name in
                        HStack(spacing: 3) {
                            Text(name)
                            Button {
                                store.updateTask(task.id) { $0.labels.removeAll { $0 == name } }
                            } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                            .buttonStyle(.plain)
                        }
                        .font(.system(size: 12))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Capsule().fill(labelColor(name).opacity(0.18)))
                        .foregroundStyle(labelColor(name))
                    }
                }
            } popoverContent: {
                LabelsPicker(selection: Binding(
                    get: { store.task(task.id)?.labels ?? [] },
                    set: { new in store.updateTask(task.id) { $0.labels = new } }))
                .environment(store)
            }
            Divider()
        }
        .padding(.top, 6)
    }

    private func attributeRow<Label: View, Pop: View>(
        popover: Binding<Bool>, action: @escaping () -> Void,
        @ViewBuilder label: () -> Label, @ViewBuilder popoverContent: @escaping () -> Pop
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                label()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .font(.system(size: 13))
            .padding(.horizontal, 6).padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverButtonStyle())
        .popover(isPresented: popover, arrowEdge: .bottom, content: popoverContent)
    }

    private var subtasks: some View {
        let subs = store.subtasks(of: task.id, includeCompleted: true)
        let done = subs.filter(\.isCompleted).count
        return VStack(alignment: .leading, spacing: 0) {
            if !subs.isEmpty {
                HStack(spacing: 6) {
                    Text("Sub-tasks").font(.system(size: 13, weight: .semibold))
                    Text("\(done)/\(subs.count)").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .padding(.bottom, 6)
                Divider()
            }
            ForEach(subs) { s in
                VStack(spacing: 0) {
                    HStack(alignment: .top, spacing: 10) {
                        CheckCircle(priority: s.priority, completed: s.isCompleted) { model.toggleComplete(s.id) }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(RichText.render(s.content))
                                .font(.system(size: 13))
                                .strikethrough(s.isCompleted)
                                .foregroundStyle(s.isCompleted ? .secondary : .primary)
                                .richTextLinks(tint: s.isCompleted ? .secondary : .primary)
                            let progress = store.subtaskProgress(of: s.id)
                            TaskMetaRow(task: s, labelColors: model.labelColorKeys(s.labels),
                                        subtaskTotal: progress.total, subtaskDone: progress.done)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())
                    .pointerStyle(.link)
                    .onTapGesture { model.detailTaskID = s.id }
                    .contextMenu { TaskMenuItems(task: s) }
                    Divider()
                }
            }
            if addingSubtask {
                HStack(spacing: 8) {
                    TextField("Sub-task name", text: $newSubtask)
                        .textFieldStyle(.roundedBorder)
                        .focused($focus, equals: .subtask)
                        .onSubmit(addSubtask)
                        .onExitCommand { addingSubtask = false }
                    Button("Add", action: addSubtask).buttonStyle(AccentButtonStyle())
                        .disabled(newSubtask.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Cancel") { addingSubtask = false }.buttonStyle(SoftButtonStyle())
                }
                .padding(.vertical, 8)
                .onAppear { focus = .subtask }
            } else {
                AddTaskRow(title: "Add sub-task") { addingSubtask = true }
                    .padding(.leading, -Theme.gutter)
            }
        }
    }

    private func addSubtask() {
        let raw = newSubtask.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return }
        let parsed = QuickAddParser.parse(raw)
        store.addTask(content: parsed.content.isEmpty ? raw : parsed.content, projectId: task.projectId, parentId: task.id,
                      priority: parsed.priority ?? .p4, due: parsed.due, labels: parsed.labels)
        newSubtask = ""
        focus = .subtask
    }

    private func labelColor(_ name: String) -> Color {
        store.labels.first { $0.name == name }.map { Palette.color($0.color) } ?? .secondary
    }
}

/// Plain button with a light rounded hover background (task view header and rows).
struct HoverButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverBody(configuration: configuration)
    }

    private struct HoverBody: View {
        let configuration: Configuration
        @State private var hovering = false
        var body: some View {
            configuration.label
                .background(RoundedRectangle(cornerRadius: 5)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.12 : hovering ? 0.06 : 0)))
                .pointerStyle(.link)
                .onHover { hovering = $0 }
        }
    }
}

enum DetailField { case title, details, subtask }

/// Title and description of the task sheet. Typing edits a local draft; it is written to the
/// store after a short pause, when the sheet closes or moves to another task, and on quit, so a
/// keystroke only redraws this view. When the task changes elsewhere (sync) while the sheet is
/// open, fields the user has not edited take the new value; an edited field keeps the draft,
/// which is then saved (local edit wins).
private struct DetailTextFields: View {
    @Environment(AppModel.self) private var model
    @Environment(TodoStore.self) private var store
    let taskID: EntityID
    let content: String
    let description: String
    let isCompleted: Bool
    var focus: FocusState<DetailField?>.Binding

    @State private var title: String
    @State private var details: String
    /// Store values the drafts were last synchronised with (title compared trimmed).
    @State private var baseTitle: String
    @State private var baseDetails: String
    @State private var commitTask: Task<Void, Never>?

    static let commitDelay: Duration = .milliseconds(300)

    init(taskID: EntityID, content: String, description: String, isCompleted: Bool,
         focus: FocusState<DetailField?>.Binding) {
        self.taskID = taskID
        self.content = content
        self.description = description
        self.isCompleted = isCompleted
        self.focus = focus
        _title = State(initialValue: content)
        _details = State(initialValue: description)
        _baseTitle = State(initialValue: content)
        _baseDetails = State(initialValue: description)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Task name", text: $title, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 20, weight: .bold))
                .strikethrough(isCompleted)
                .focused(focus, equals: .title)
                .onSubmit { commit(); focus.wrappedValue = nil }
                .onExitCommand { commit(); focus.wrappedValue = nil }
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "text.alignleft").foregroundStyle(.secondary).font(.system(size: 12)).padding(.top, 2)
                TextField("Description", text: $details, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .lineLimit(1...20)
                    .focused(focus, equals: .details)
                    .onExitCommand { commit(); focus.wrappedValue = nil }
            }
        }
        .onChange(of: title) { scheduleCommit() }
        .onChange(of: details) { scheduleCommit() }
        .onChange(of: content) { _, new in
            if trimmed(title) == baseTitle, trimmed(title) != new { title = new }
            baseTitle = new
        }
        .onChange(of: description) { _, new in
            if details == baseDetails, details != new { details = new }
            baseDetails = new
        }
        .onAppear { model.detailFlush = (taskID, { commit() }) }
        .onDisappear {
            commit()
            // The next task's sheet may already have registered itself.
            if model.detailFlush?.taskID == taskID { model.detailFlush = nil }
        }
    }

    private func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func scheduleCommit() {
        commitTask?.cancel()
        commitTask = Task {
            try? await Task.sleep(for: Self.commitDelay)
            guard !Task.isCancelled else { return }
            commit()
        }
    }

    /// Writes edited fields only, so an untouched field never overwrites a newer remote value.
    private func commit() {
        commitTask?.cancel()
        commitTask = nil
        let newTitle = trimmed(title)
        let titleEdited = !newTitle.isEmpty && newTitle != baseTitle
        let detailsEdited = details != baseDetails
        guard titleEdited || detailsEdited, store.task(taskID) != nil else { return }
        let newDetails = details
        store.updateTask(taskID) {
            if titleEdited { $0.content = newTitle }
            if detailsEdited { $0.description = newDetails }
        }
        if titleEdited { baseTitle = newTitle }
        if detailsEdited { baseDetails = newDetails }
    }
}

/// Simple wrapping row for chips.
struct FlowRow<Item: Hashable, Content: View>: View {
    let items: [Item]
    let content: (Item) -> Content
    init(_ items: [Item], @ViewBuilder content: @escaping (Item) -> Content) {
        self.items = items
        self.content = content
    }

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(items, id: \.self) { content($0) }
        }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 240
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > width, x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
        return CGSize(width: width, height: subviews.isEmpty ? 0 : y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
    }
}
