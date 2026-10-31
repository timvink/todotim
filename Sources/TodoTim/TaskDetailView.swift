import AppKit
import SwiftUI
import TodoCore

/// The task panel, shown over the main window (see `ModalLayer`): a header with the project,
/// ⌃/⌄, "…" and close; then title, description, date, priority, labels and sub-tasks.
/// ↑/↓/j/k move to the previous/next task.
struct TaskDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(TodoStore.self) private var store
    /// The largest size; the panel is as tall as its content, up to `size.height`.
    let size: CGSize
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        // The size is set here, behind a GeometryReader (which never asks its content for a
        // size), so a keystroke never re-measures the whole panel. Only a change in the content's
        // height (a new line, a sub-task) resizes it.
        GeometryReader { _ in
            if let id = model.detailTaskID, let task = store.task(id) {
                // Not `.id(id)`: moving to the next task updates the panel in place, which is much
                // cheaper than rebuilding it. Per-task state is reset in `TaskDetailContent`.
                TaskDetailContent(task: task) { h in
                    if abs(h - contentHeight) > 0.5 { contentHeight = h }
                }
            } else {
                Color.clear.onAppear { model.detailTaskID = nil }
            }
        }
        .frame(width: size.width, height: min(size.height, max(240, contentHeight)))
    }
}

fileprivate struct TaskDetailContent: View {
    @Environment(AppModel.self) private var model
    @Environment(TodoStore.self) private var store
    let task: TodoTask
    /// Reports the panel's natural height (header and content).
    let onHeight: (CGFloat) -> Void

    @State private var newSubtask = ""
    @State private var addingSubtask = false
    /// The move popover opened from the header (else from the project row).
    @State private var moveFromHeader = false
    @FocusState private var focus: DetailField?

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            ScrollView {
                content
                    .padding(.horizontal, Self.inset)
                    .padding(.top, 18)
                    .padding(.bottom, 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { h in
                        onHeight(h + Self.headerHeight + 1)
                    }
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
        HStack(spacing: 2) {
            if let p = store.project(task.projectId) {
                Button {
                    moveFromHeader = true
                    model.popover = .move
                } label: {
                    HStack(spacing: 7) {
                        ProjectIcon(p, fill: 1, size: 9)
                        Text(p.name)
                        if let s = sectionName {
                            Text("/").foregroundStyle(Theme.tertiaryText)
                            Text(s)
                        }
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.horizontal, 8)
                    .frame(height: 26)
                    .contentShape(Rectangle())
                }
                .buttonStyle(HoverButtonStyle())
                .help("Move to project (V)")
                .popover(isPresented: popoverBinding(.move, header: true), arrowEdge: .bottom) { movePicker }
            }
            Spacer()
            headerButton("chevron.up", help: "Previous task (↑ / K)") { model.moveDetail(-1) }
            headerButton("chevron.down", help: "Next task (↓ / J)") { model.moveDetail(1) }
            Spacer().frame(width: 10)
            Menu {
                TaskMenuItems(task: task)
            } label: {
                Image(systemName: "ellipsis").font(Fonts.body).frame(width: 28, height: 26)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .tint(Theme.tertiaryText)
            .fixedSize()
            .pointerStyle(.link)
            .help("More actions")
            headerButton("xmark", help: "Close (Esc)") { model.detailTaskID = nil }
        }
        // The project button's icon lines up with the content column below.
        .padding(.leading, Self.inset - 8).padding(.trailing, 10)
        .frame(height: Self.headerHeight)
    }

    static let headerHeight: CGFloat = 40

    /// Horizontal padding of the panel's content.
    static let inset: CGFloat = 24
    /// The panel's grid: checkboxes and icons are centered in a column this wide at the content's
    /// leading edge, text starts `columnGap` after it, and row pills reach `pillInset` past it.
    static let column: CGFloat = 20
    static let columnGap: CGFloat = 10
    static let pillInset: CGFloat = 8

    private var sectionName: String? {
        guard let sid = task.sectionId else { return nil }
        return store.sections(in: task.projectId).first { $0.id == sid }?.name
    }

    private func headerButton(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(HoverButtonStyle())
        .foregroundStyle(Theme.tertiaryText)
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
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.turn.left.up").font(Fonts.smallIcon)
                        Text(String(RichText.render(parent.content).characters)).lineLimit(1)
                    }
                    .font(Fonts.meta)
                    .foregroundStyle(Theme.secondaryText)
                }
                .buttonStyle(.plain)
                .pointerStyle(.link)
                .help("Open the parent task")
                .padding(.bottom, 10)
            }
            HStack(alignment: .top, spacing: Self.columnGap) {
                CheckCircle(priority: task.priority, completed: task.isCompleted, size: Self.column) {
                    model.setCompleted(task.id, !task.isCompleted)
                }
                .frame(width: Self.column, height: 24)
                DetailTextFields(taskID: task.id, content: task.content, description: task.description,
                                 isCompleted: task.isCompleted, focus: $focus)
                    .id(task.id)
            }
            .padding(.bottom, 12)
            attributes
            subtasks.padding(.top, 20)
        }
    }

    /// Date, priority and labels as rows on the panel's grid. The project is the header button.
    private var attributes: some View {
        VStack(alignment: .leading, spacing: 0) {
            attributeRow(popover: popoverBinding(.date)) { model.popover = .date } label: {
                Image(systemName: "calendar")
                    .foregroundStyle(task.due?.chipColor ?? Theme.tertiaryText)
                    .frame(width: Self.column)
                if let due = task.due {
                    Text(due.displayString()).foregroundStyle(due.chipColor)
                    if let rule = task.recurrence {
                        SwiftUI.Label(Recurrence.summary(rule), systemImage: "repeat")
                            .font(Fonts.meta)
                            .foregroundStyle(Theme.secondaryText)
                    }
                    Spacer()
                    Button { store.updateTask(task.id) { $0.due = nil } } label: {
                        Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                            .frame(width: 22, height: 22).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.tertiaryText)
                    .help("Remove date")
                } else {
                    Text("Date").foregroundStyle(Theme.tertiaryText)
                }
            } popoverContent: {
                DueDatePicker(due: task.due) { due in
                    store.updateTask(task.id) { $0.due = due }
                    model.popover = nil
                }
            }
            Menu {
                ForEach(Priority.allCases, id: \.self) { p in
                    Button { model.setPriority(p, for: task.id) } label: {
                        SwiftUI.Label { Text(p.title) } icon: { Image(nsImage: PriorityMenu.flag(p)) }
                    }
                }
            } label: {
                HStack(spacing: Self.columnGap) {
                    Image(systemName: task.priority == .p4 ? "flag" : "flag.fill")
                        .foregroundStyle(task.priority == .p4 ? Theme.tertiaryText : task.priority.color)
                        .frame(width: Self.column)
                    // Normal priority reads as an empty field, like "Date".
                    Text(task.priority == .p4 ? "Priority" : task.priority.title)
                        .foregroundStyle(task.priority == .p4 ? Theme.tertiaryText : Theme.text)
                    Spacer()
                }
                .attributeRowStyle()
            }
            .menuStyle(.button)
            .buttonStyle(HoverButtonStyle())
            .menuIndicator(.hidden)
            .pointerStyle(.link)
            .padding(.horizontal, -Self.pillInset)
            attributeRow(popover: popoverBinding(.labels)) { model.popover = .labels } label: {
                Image(systemName: "tag").foregroundStyle(Theme.tertiaryText).frame(width: Self.column)
                if task.labels.isEmpty {
                    Text("Labels").foregroundStyle(Theme.tertiaryText)
                } else {
                    FlowRow(task.labels) { name in
                        HStack(spacing: 4) {
                            Text(name)
                            Button {
                                store.updateTask(task.id) { $0.labels.removeAll { $0 == name } }
                            } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                            .buttonStyle(.plain)
                            .help("Remove label")
                        }
                        .font(Fonts.meta)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(labelColor(name).opacity(0.15)))
                        .foregroundStyle(labelColor(name))
                    }
                }
            } popoverContent: {
                LabelsPicker(selection: Binding(
                    get: { store.task(task.id)?.labels ?? [] },
                    set: { new in store.updateTask(task.id) { $0.labels = new } }))
                .environment(store)
            }
        }
    }

    private func attributeRow<Label: View, Pop: View>(
        popover: Binding<Bool>, action: @escaping () -> Void,
        @ViewBuilder label: () -> Label, @ViewBuilder popoverContent: @escaping () -> Pop
    ) -> some View {
        Button(action: action) {
            HStack(spacing: Self.columnGap) {
                label()
            }
            .attributeRowStyle()
        }
        .buttonStyle(HoverButtonStyle())
        .popover(isPresented: popover, arrowEdge: .bottom, content: popoverContent)
        .padding(.horizontal, -Self.pillInset)
    }

    private var subtasks: some View {
        let subs = store.subtasks(of: task.id, includeCompleted: true)
        let done = subs.filter(\.isCompleted).count
        return VStack(alignment: .leading, spacing: 0) {
            if !subs.isEmpty {
                HStack(spacing: 8) {
                    Text("Sub-tasks").font(Fonts.bodySemibold).foregroundStyle(Theme.text)
                    Text("\(done)/\(subs.count)")
                        .font(Fonts.meta).monospacedDigit()
                        .foregroundStyle(done == subs.count ? Theme.today : Theme.tertiaryText)
                }
                .padding(.bottom, 6)
                Hairline().padding(.bottom, 4)
            }
            let drag = model.drag
            let gap = subtaskGap(subs.map(\.id), target: drag.inPanel ? drag.target : nil)
            ForEach(subs) { s in
                slot(open: gap == .some(s.id), drag.rowHeight)
                SubtaskRow(task: s)
                    .opacity(drag.inPanel && drag.draggingID == s.id ? 0.45 : 1)
            }
            slot(open: gap == .some(nil), drag.rowHeight)
            if addingSubtask {
                HStack(spacing: 8) {
                    TextField("Sub-task name", text: $newSubtask,
                              prompt: Text("Sub-task name").foregroundStyle(Theme.tertiaryText))
                        .textFieldStyle(.plain)
                        .font(Fonts.body)
                        .foregroundStyle(Theme.text)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.field))
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.accent.opacity(0.7)))
                        .focused($focus, equals: .subtask)
                        .onSubmit(addSubtask)
                        .onExitCommand { addingSubtask = false }
                    Button("Add", action: addSubtask).buttonStyle(AccentButtonStyle())
                        .disabled(newSubtask.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Cancel") { addingSubtask = false }.buttonStyle(SoftButtonStyle())
                }
                .padding(.vertical, 6)
                .onAppear { focus = .subtask }
            } else {
                AddTaskRow(title: "Add sub-task", leading: -Self.pillInset, column: Self.column) { addingSubtask = true }
            }
        }
    }

    private func slot(open: Bool, _ height: CGFloat) -> some View {
        DropSlot(open: open, depth: 0, height: height, inset: -Self.pillInset)
    }

    /// The sub-task the drop slot opens before (`.some(nil)`: after the last one); nil when closed.
    private func subtaskGap(_ ids: [EntityID], target: DropTarget?) -> EntityID?? {
        switch target {
        case .before(let id) where ids.contains(id): return .some(id)
        case .after(let id):
            guard let i = ids.firstIndex(of: id) else { return nil }
            return .some(i + 1 < ids.count ? ids[i + 1] : nil)
        default: return nil
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
        store.labels.first { $0.name == name }.map { Palette.color($0.color) } ?? Theme.secondaryText
    }
}

/// A sub-task in the task panel, on the panel's grid. Open sub-tasks show the drag handle on hover
/// and can be dragged among their siblings.
private struct SubtaskRow: View {
    @Environment(AppModel.self) private var model
    @Environment(TodoStore.self) private var store
    let task: TodoTask
    @State private var hovering = false
    @State private var height = HeightBox()

    var body: some View {
        let s = task
        HStack(alignment: .top, spacing: 0) {
            GripDots()
                .opacity(hovering && !s.isCompleted ? 1 : 0)
                .frame(width: Theme.grip, height: 28)
            HStack(alignment: .top, spacing: TaskDetailContent.columnGap) {
                CheckCircle(priority: s.priority, completed: s.isCompleted) { model.setCompleted(s.id, !s.isCompleted) }
                    .frame(width: TaskDetailContent.column, height: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(RichText.render(s.content))
                        .font(Fonts.body)
                        .strikethrough(s.isCompleted)
                        .foregroundStyle(s.isCompleted ? Theme.tertiaryText : Theme.text)
                        .richTextLinks(tint: s.isCompleted ? Theme.tertiaryText : Theme.text)
                        .frame(minHeight: 18)
                    let progress = store.subtaskProgress(of: s.id)
                    TaskMetaRow(task: s, labelColors: model.labelColorKeys(s.labels),
                                subtaskTotal: progress.total, subtaskDone: progress.done)
                }
                Spacer()
            }
            .padding(.vertical, 5)
            .padding(.horizontal, TaskDetailContent.pillInset)
            .background(RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous).fill(hovering ? Theme.hover : .clear))
        }
        .contentShape(Rectangle())
        .pointerStyle(.link)
        .onHover { h in withAnimation(Theme.hoverAnimation) { hovering = h } }
        .onTapGesture { model.detailTaskID = s.id }
        .contextMenu { TaskMenuItems(task: s) }
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { [height] h in height.value = h }
        .modifier(SubtaskDragModifier(model: model, task: s, height: height))
        .onDrop(of: [.text], delegate: SubtaskDropDelegate(model: model, task: s, height: height))
        .padding(.leading, -(Theme.grip + TaskDetailContent.pillInset))
    }
}

/// Completed sub-tasks are not draggable (open siblings are ordered among themselves).
private struct SubtaskDragModifier: ViewModifier {
    let model: AppModel
    let task: TodoTask
    let height: HeightBox

    func body(content: Content) -> some View {
        if task.isCompleted {
            content
        } else {
            content.onDrag {
                MainActor.assumeIsolated { model.beginDrag(task.id, rowHeight: height.value, inPanel: true) }
                return NSItemProvider(object: task.id as NSString)
            } preview: {
                DragPreview(task: task)
            }
        }
    }
}

/// Plain button with a rounded hover pill (task panel header and rows).
struct HoverButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverBody(configuration: configuration)
    }

    private struct HoverBody: View {
        let configuration: Configuration
        @State private var hovering = false
        var body: some View {
            configuration.label
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(configuration.isPressed ? Theme.selection : hovering ? Theme.hover : .clear))
                .pointerStyle(.link)
                .onHover { h in withAnimation(Theme.hoverAnimation) { hovering = h } }
        }
    }
}

private extension View {
    /// An attribute row of the task panel: 32 pt tall whatever it holds (text, a clear button or
    /// label chips), with its pill reaching `pillInset` past the grid.
    func attributeRowStyle() -> some View {
        frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            .font(Fonts.body)
            .padding(.horizontal, TaskDetailContent.pillInset)
            .contentShape(Rectangle())
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
                .font(Fonts.panelTitle)
                .foregroundStyle(isCompleted ? Theme.tertiaryText : Theme.text)
                .strikethrough(isCompleted)
                .frame(minHeight: 24)
                .focused(focus, equals: .title)
                .onSubmit { commit(); focus.wrappedValue = nil }
                .onExitCommand { commit(); focus.wrappedValue = nil }
            TextField("Description", text: $details,
                      prompt: Text("Add a description").foregroundStyle(Theme.tertiaryText), axis: .vertical)
                .textFieldStyle(.plain)
                .font(Fonts.body)
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1...20)
                .focused(focus, equals: .details)
                .onExitCommand { commit(); focus.wrappedValue = nil }
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
