import AppKit
import SwiftUI
import TodoCore

/// Todoist's task modal: title, description and sub-tasks on the left; project, date,
/// priority and labels on the right. ↑/↓ in the header move to the previous/next task.
struct TaskDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(TodoStore.self) private var store

    var body: some View {
        // A fixed size behind a GeometryReader (which never asks its content for a size): otherwise
        // the sheet re-measured its whole content (both scroll views) on every keystroke.
        GeometryReader { _ in
            if let id = model.detailTaskID, let task = store.task(id) {
                // Not `.id(id)`: moving to the next task updates the sheet in place, which is much
                // cheaper than rebuilding it. Per-task state is reset in `TaskDetailContent`.
                TaskDetailContent(task: task)
            } else {
                Color.clear.onAppear { model.detailTaskID = nil }
            }
        }
        .frame(width: 860, height: 620)
    }
}

private struct TaskDetailContent: View {
    @Environment(AppModel.self) private var model
    @Environment(TodoStore.self) private var store
    let task: TodoTask

    @State private var dateText = ""
    @State private var newSubtask = ""
    @State private var addingSubtask = false
    @State private var showLabels = false
    @FocusState private var focus: DetailField?


    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(alignment: .top, spacing: 0) {
                ScrollView {
                    mainColumn.padding(24)
                }
                .frame(maxWidth: .infinity)
                Divider()
                ScrollView {
                    sideColumn.padding(16)
                }
                .frame(width: 270)
                .background(Color.primary.opacity(0.03))
            }
        }
        .onAppear {
            // Keep focus out of the title so ↑/↓/j/k navigate between tasks.
            DispatchQueue.main.async { (NSApp.keyWindow ?? model.mainWindow?.attachedSheet)?.makeFirstResponder(nil) }
        }
        .onChange(of: task.id) {
            dateText = ""
            newSubtask = ""
            addingSubtask = false
            showLabels = false
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            if let p = store.project(task.projectId) {
                Image(systemName: p.isInbox ? "tray" : "number")
                    .foregroundStyle(p.isInbox ? Color(hex: 0x246FE0) : Palette.color(p.color))
                Text(p.name).font(.system(size: 13))
                if let sid = task.sectionId, let s = store.sections(in: p.id).first(where: { $0.id == sid }) {
                    Text("/").foregroundStyle(.secondary)
                    Text(s.name).font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            headerButton("chevron.up", help: "Previous task (↑ / K)") { model.moveDetail(-1) }
            headerButton("chevron.down", help: "Next task (↓ / J)") { model.moveDetail(1) }
            Menu {
                TaskMenuItems(task: task)
            } label: {
                Image(systemName: "ellipsis").frame(width: 26, height: 24)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            headerButton("xmark", help: "Close (Esc)") { model.detailTaskID = nil }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private func headerButton(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 26, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }

    // MARK: Main column

    private var mainColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let pid = task.parentId, let parent = store.task(pid) {
                Button { model.detailTaskID = parent.id } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.turn.left.up")
                        Text(parent.content).lineLimit(1)
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            HStack(alignment: .top, spacing: 12) {
                CheckCircle(priority: task.priority, completed: task.isCompleted, size: 22) { model.toggleComplete(task.id) }
                    .padding(.top, 3)
                DetailTextFields(taskID: task.id, content: task.content, description: task.description,
                                 isCompleted: task.isCompleted, focus: $focus)
                    .id(task.id)
            }
            subtasks.padding(.leading, 34)
        }
    }

    private var subtasks: some View {
        let subs = store.subtasks(of: task.id, includeCompleted: true)
        let done = subs.filter(\.isCompleted).count
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("Sub-tasks").font(.system(size: 13, weight: .semibold))
                if !subs.isEmpty {
                    Text("\(done)/\(subs.count)").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 6)
            Divider()
            ForEach(subs) { s in
                VStack(spacing: 0) {
                    HStack(alignment: .top, spacing: 10) {
                        CheckCircle(priority: s.priority, completed: s.isCompleted) { model.toggleComplete(s.id) }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.content)
                                .font(.system(size: 13))
                                .strikethrough(s.isCompleted)
                                .foregroundStyle(s.isCompleted ? .secondary : .primary)
                            let progress = store.subtaskProgress(of: s.id)
                            TaskMetaRow(task: s, labelColors: model.labelColorKeys(s.labels),
                                        subtaskTotal: progress.total, subtaskDone: progress.done)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())
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

    // MARK: Side column

    private var sideColumn: some View {
        VStack(alignment: .leading, spacing: 18) {
            field("Project") {
                ProjectSectionMenu(projectId: task.projectId, sectionId: task.sectionId) { pid, sid in
                    store.moveTask(task.id, projectId: pid, sectionId: sid, parentId: nil)
                }
            }
            Divider()
            field("Date") {
                VStack(alignment: .leading, spacing: 8) {
                    if let due = task.due {
                        HStack(spacing: 4) {
                            Image(systemName: "calendar")
                            Text(due.displayString())
                            Spacer()
                            Button { store.updateTask(task.id) { $0.due = nil } } label: {
                                Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help("Remove date")
                        }
                        .font(.system(size: 13))
                        .foregroundStyle(due.chipColor)
                    }
                    TextField("Type a date, e.g. next fri", text: $dateText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                        .focused($focus, equals: DetailField.date)
                        .onSubmit {
                            if let d = DateParser.parse(dateText) {
                                store.updateTask(task.id) { $0.due = d }
                                dateText = ""
                            }
                        }
                    if !dateText.isEmpty {
                        Text(DateParser.parse(dateText).map { "→ \($0.displayString())" } ?? "No match")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 6) {
                        quickDate("Today", .offset(days: 0))
                        quickDate("Tomorrow", .offset(days: 1))
                    }
                    HStack(spacing: 6) {
                        quickDate("Next week", .nextWeek)
                        quickDate("No date", nil)
                    }
                }
            }
            Divider()
            field("Priority") {
                PriorityMenu(priority: Binding(get: { task.priority }, set: { p in model.setPriority(p, for: task.id) }),
                             compact: false)
            }
            Divider()
            field("Labels") {
                VStack(alignment: .leading, spacing: 6) {
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
                    Button { showLabels = true } label: {
                        ChipLabel(icon: "plus", text: "Add label")
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showLabels, arrowEdge: .leading) {
                        LabelsPicker(selection: Binding(
                            get: { store.task(task.id)?.labels ?? [] },
                            set: { new in store.updateTask(task.id) { $0.labels = new } }))
                        .environment(store)
                    }
                }
            }
            Divider()
            Text("Created \(task.createdAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private func labelColor(_ name: String) -> Color {
        store.labels.first { $0.name == name }.map { Palette.color($0.color) } ?? .secondary
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    private func quickDate(_ title: String, _ value: DueDate?) -> some View {
        Button { store.updateTask(task.id) { $0.due = value } } label: {
            Text(title).font(.system(size: 12))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.08)))
        }
        .buttonStyle(.plain)
    }
}

enum DetailField { case title, details, date, subtask }

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
                .font(.system(size: 20, weight: .semibold))
                .strikethrough(isCompleted)
                .focused(focus, equals: .title)
                .onSubmit { commit(); focus.wrappedValue = nil }
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "text.alignleft").foregroundStyle(.secondary).font(.system(size: 12)).padding(.top, 2)
                TextField("Description", text: $details, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .lineLimit(1...20)
                    .focused(focus, equals: .details)
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
