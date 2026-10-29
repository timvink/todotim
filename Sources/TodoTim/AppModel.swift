import AppKit
import SwiftUI
import TodoCore

enum SidebarItem: Hashable {
    case search
    case project(EntityID)
    case label(String)
}

/// Where the inline "Add task" editor is open.
struct EditorTarget: Equatable {
    var projectId: EntityID
    var sectionId: EntityID?
    var parentId: EntityID?
    var atTop = false
    /// Insert position among open siblings for the next task; nil = at the end.
    var nextIndex: Int?
}

struct SectionEditorTarget: Equatable {
    var projectId: EntityID
    /// Index among sections; nil = at the end.
    var index: Int?
}

enum TaskPopover: Equatable { case date, labels, move }

struct ToastInfo: Identifiable {
    let id = UUID()
    var message: String
    var undo: (() -> Void)?
}

/// UI state shared by all views and the keyboard router. Data lives in `TodoStore`.
@MainActor
@Observable
final class AppModel {
    let store: TodoStore
    let sync: SyncController

    var sidebar: SidebarItem? = .project(TodoStore.inboxID) {
        didSet {
            guard sidebar != oldValue else { return }
            selectedTaskID = nil
            editor = nil
            sectionEditor = nil
            popover = nil
        }
    }

    var selectedTaskID: EntityID? {
        didSet {
            guard selectedTaskID != oldValue else { return }
            if popover != nil { popover = nil }
            if hasSelection != (selectedTaskID != nil) { hasSelection = selectedTaskID != nil }
        }
    }

    /// Task shown in the detail sheet.
    var detailTaskID: EntityID? {
        didSet {
            guard detailTaskID != oldValue else { return }
            if oldValue != nil { flushDetailEdits() }
            if popover != nil { popover = nil }
        }
    }

    /// `selectedTaskID != nil`, as its own observable value so menus and other views that only
    /// care whether something is selected are not invalidated by every j/k press.
    private(set) var hasSelection = false
    /// Whether menu task actions have a target (open sheet or selection). Cheap; does not read the store.
    var hasActionTask: Bool { detailTaskID != nil || hasSelection }
    var showQuickAdd = false
    var showShortcuts = false
    var showAddProject = false
    var showImportTodoist = false
    var confirmDeleteTaskID: EntityID?
    var showCompletedProjects: Set<EntityID> = []
    /// Collapsed sections, saved per device in UserDefaults (not synced, not in the database).
    var collapsedSections: Set<EntityID> = [] {
        didSet {
            guard collapsedSections != oldValue else { return }
            defaults.set(collapsedSections.sorted(), forKey: Self.collapsedSectionsKey)
        }
    }
    static let collapsedSectionsKey = "collapsedSectionIDs"
    /// Drag-to-reorder state; observed only by the task list and the sidebar.
    @ObservationIgnored let drag = DragState()
    /// Whether an in-window modal (task view, Quick Add, shortcuts) covers the window.
    var hasModal: Bool { detailTaskID != nil || showQuickAdd || showShortcuts }
    var editor: EditorTarget? {
        didSet {
            guard let e = editor else { return }
            if let o = oldValue, o.projectId == e.projectId, o.sectionId == e.sectionId, o.parentId == e.parentId { return }
            editorDraft.reset(projectId: e.projectId, sectionId: e.sectionId)
        }
    }
    /// Draft of the inline "Add task" editor. Kept here, not in view state, because the editor
    /// row lives in a lazy list and may be destroyed while scrolled out of view.
    @ObservationIgnored let editorDraft = InlineEditorDraft()
    var sectionEditor: SectionEditorTarget?
    var renamingSectionID: EntityID?
    var popover: TaskPopover?
    var toast: ToastInfo?
    /// Shown once at launch when the local database or the config file could not be loaded.
    var startupError: String?
    /// Opened by Help › TodoTim on GitHub (`repository` in the config file).
    @ObservationIgnored var repositoryURL = AppConfig.defaultRepository
    var searchQuery = ""
    /// Incremented to ask the search field to take focus.
    var searchFocusRequest = 0

    @ObservationIgnored weak var mainWindow: NSWindow?
    @ObservationIgnored weak var undoManager: UndoManager?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    /// Commits the open task sheet's pending title/description draft (set by the sheet).
    @ObservationIgnored var detailFlush: (taskID: EntityID, flush: () -> Void)?
    /// Rows of the list currently on screen; see `display()`.
    @ObservationIgnored private var displayCache: DisplayModel?

    @ObservationIgnored private let defaults: UserDefaults

    init(store: TodoStore, sync: SyncController, defaults: UserDefaults = .standard) {
        self.store = store
        self.sync = sync
        self.defaults = defaults
        collapsedSections = Set(defaults.stringArray(forKey: Self.collapsedSectionsKey) ?? [])
    }

    // MARK: - Derived

    var currentProjectID: EntityID? {
        if case .project(let id) = sidebar { return id }
        return nil
    }

    var allProjects: [Project] { [store.inbox] + store.projects }

    /// True while a text field / text view in the key window has keyboard focus.
    var isEditingText: Bool {
        let window = NSApp.keyWindow ?? mainWindow.map { $0.attachedSheet ?? $0 }
        guard let tv = window?.firstResponder as? NSTextView else { return false }
        return tv.isEditable
    }

    /// The task keyboard/menu actions apply to: the open detail sheet's task, else the selection.
    var actionTaskID: EntityID? {
        if let id = detailTaskID, store.task(id) != nil { return id }
        if let id = selectedTaskID, store.task(id) != nil { return id }
        return nil
    }

    /// Palette keys for label names ("" when the label does not exist).
    func labelColorKeys(_ names: [String]) -> [String] {
        guard !names.isEmpty else { return [] }
        let labels = store.labels
        return names.map { n in labels.first { $0.name == n }?.color ?? "" }
    }

    func showsCompleted(_ projectId: EntityID) -> Bool { showCompletedProjects.contains(projectId) }

    /// Commits any pending edit in the task sheet.
    func flushDetailEdits() { detailFlush?.flush() }

    /// Flattened rows of the current view. List views call this from `body` (so it is rebuilt
    /// whenever anything it read changes); keyboard navigation reuses the last result as long as
    /// the store structure and the view inputs are unchanged.
    func display() -> DisplayModel {
        let key = currentDisplayKey()
        var builder = DisplayBuilder(model: self, store: store)
        let d = Perf.measureIfSlow("build rows") { builder.build(key) }
        displayCache = d
        return d
    }

    /// Cached rows for navigation: rebuilt only when the structure or view inputs changed.
    func cachedDisplay() -> DisplayModel {
        let key = currentDisplayKey()
        if let c = displayCache, c.key == key { return c }
        return display()
    }

    private func currentDisplayKey() -> DisplayKey {
        DisplayKey(structureVersion: store.structureVersion, sidebar: sidebar, editor: editor,
                   collapsedSections: collapsedSections, showCompleted: showCompletedProjects,
                   searchQuery: sidebar == .search ? searchQuery : "")
    }

    /// Task ids in on-screen order for the current view (used by ↑/↓ navigation).
    func visibleTaskIDs() -> [EntityID] { cachedDisplay().taskIDs }

    // MARK: - Navigation

    func moveSelection(_ delta: Int) {
        let d = cachedDisplay()
        let ids = d.taskIDs
        guard !ids.isEmpty else { return }
        guard let cur = selectedTaskID, let i = d.position[cur] else {
            selectedTaskID = delta > 0 ? ids.first : ids.last
            return
        }
        selectedTaskID = ids[max(0, min(ids.count - 1, i + delta))]
    }

    /// Vim `gg` / `G`: selects the first or last task of the selected task's section (the run of
    /// task rows between section or group headers). Without a selection, the first or last task.
    func moveSelectionToSectionEdge(last: Bool) {
        let d = cachedDisplay()
        guard !d.taskIDs.isEmpty else { return }
        guard let cur = selectedTaskID, let at = d.items.firstIndex(where: { $0.id == cur }) else {
            selectedTaskID = last ? d.taskIDs.last : d.taskIDs.first
            return
        }
        func isBoundary(_ item: DisplayItem) -> Bool {
            switch item {
            case .sectionHeader, .groupHeader, .projectHeader, .labelHeader: true
            default: false
            }
        }
        var edge = cur
        for item in last ? Array(d.items[at...]) : d.items[...at].reversed() {
            if isBoundary(item) { break }
            if case .task(let r) = item { edge = r.id }
        }
        selectedTaskID = edge
    }

    /// Moves the detail sheet to the previous/next task in the list.
    func moveDetail(_ delta: Int) {
        guard let cur = detailTaskID else { return }
        let d = cachedDisplay()
        let ids = d.taskIDs
        if let i = d.position[cur] {
            let j = i + delta
            guard j >= 0, j < ids.count else { return }
            detailTaskID = ids[j]
            selectedTaskID = ids[j]
        } else if let t = store.task(cur), let pid = t.parentId {
            // A subtask opened from the sheet that is hidden in the list: walk its siblings.
            let sibs = store.subtaskIDs(of: pid, includeCompleted: true)
            if let i = sibs.firstIndex(of: cur), sibs.indices.contains(i + delta) {
                detailTaskID = sibs[i + delta]
            }
        }
    }

    func openTask(_ id: EntityID) {
        selectedTaskID = id
        detailTaskID = id
    }

    func openSelected() {
        if let id = selectedTaskID { detailTaskID = id }
    }

    func goToInbox() { sidebar = .project(TodoStore.inboxID) }

    /// ⌘1 = Inbox, ⌘2… = projects in sidebar order.
    func goToProject(number n: Int) {
        let ps = allProjects
        guard n >= 1, n <= ps.count else { return }
        sidebar = .project(ps[n - 1].id)
    }

    func focusSearch() {
        sidebar = .search
        searchFocusRequest += 1
    }

    func clearSelection() {
        if popover != nil { popover = nil; return }
        if editor != nil { editor = nil; return }
        if sectionEditor != nil { sectionEditor = nil; return }
        selectedTaskID = nil
    }

    // MARK: - Editing entry points

    /// Todoist `a` / `A`: open the inline editor in the section of the selected task.
    func addTaskInCurrentSection(atTop: Bool) {
        guard let pid = currentProjectID else { showQuickAdd = true; return }
        var sectionId: EntityID?
        if let id = selectedTaskID, let t = store.task(id), t.projectId == pid {
            sectionId = t.sectionId
        }
        if let s = sectionId { collapsedSections.remove(s) }
        selectedTaskID = nil
        editor = EditorTarget(projectId: pid, sectionId: sectionId, parentId: nil, atTop: atTop, nextIndex: atTop ? 0 : nil)
    }

    func addSubtask(to parentId: EntityID) {
        guard let p = store.task(parentId) else { return }
        if p.collapsed { store.updateTask(parentId) { $0.collapsed = false } }
        editor = EditorTarget(projectId: p.projectId, sectionId: p.sectionId, parentId: parentId)
    }

    func addSectionAtEnd() {
        guard let pid = currentProjectID else { return }
        sectionEditor = SectionEditorTarget(projectId: pid, index: nil)
    }

    func showPopover(_ kind: TaskPopover) {
        guard let id = selectedTaskID, store.task(id) != nil else { return }
        popover = kind
    }

    // MARK: - Task actions

    func setPriority(_ p: Priority, for id: EntityID? = nil) {
        guard let id = id ?? actionTaskID else { return }
        store.updateTask(id) { $0.priority = p }
    }

    func toggleCollapsed(_ id: EntityID) {
        store.updateTask(id) { $0.collapsed.toggle() }
    }

    /// Completes (or reopens) a task. Completing shows an undo toast.
    func toggleComplete(_ id: EntityID) {
        guard let t = store.task(id) else { return }
        if t.isCompleted {
            store.toggleComplete(id)
            return
        }
        if let rule = t.recurrence, Recurrence.advance(rule, from: t.due ?? DueDate(Date())) != nil {
            // A repeating task moves to its next date instead.
            store.toggleComplete(id)
            let restore: () -> Void = { [weak self] in
                self?.store.updateTask(id) { $0.due = t.due; $0.recurrence = t.recurrence }
            }
            registerUndo("Complete Task", restore)
            showToast("Next due \(store.task(id)?.due?.displayString() ?? "date set")", undo: restore)
            return
        }
        let affected = ([id] + store.descendantIDs(of: id)).filter { store.task($0)?.isCompleted == false }
        if selectedTaskID == id, !showsCompleted(t.projectId) { selectedTaskID = neighbor(of: id) }
        // Completing the task in the detail sheet closes it and returns to the list.
        if detailTaskID == id { detailTaskID = nil }
        store.toggleComplete(id)
        let restore: () -> Void = { [weak self] in
            guard let self else { return }
            self.store.performBatch {
                for tid in affected { self.store.updateTask(tid) { $0.isCompleted = false; $0.completedAt = nil } }
            }
        }
        registerUndo("Complete Task", restore)
        showToast(affected.count == 1 ? "1 task completed" : "\(affected.count) tasks completed", undo: restore)
    }

    func requestDelete(_ id: EntityID? = nil) {
        guard let id = id ?? actionTaskID else { return }
        confirmDeleteTaskID = id
    }

    func deleteTask(_ id: EntityID) {
        let affected = [id] + store.descendantIDs(of: id)
        if selectedTaskID == id { selectedTaskID = neighbor(of: id) }
        if detailTaskID == id { detailTaskID = nil }
        store.deleteTask(id)
        let restore: () -> Void = { [weak self] in
            guard let self else { return }
            self.store.performBatch {
                for tid in affected { self.store.updateTask(tid) { $0.deleted = false } }
            }
        }
        registerUndo("Delete Task", restore)
        showToast("1 task deleted", undo: restore)
    }

    func indent() { if let id = actionTaskID { store.indentTask(id) } }
    func outdent() { if let id = actionTaskID { store.outdentTask(id) } }
    func shift(_ delta: Int) { if let id = actionTaskID { store.shiftTask(id, by: delta) } }

    func move(_ id: EntityID, toProject pid: EntityID, section sid: EntityID?) {
        guard let t = store.task(id), t.projectId != pid || t.sectionId != sid || t.parentId != nil else { return }
        store.moveTask(id, projectId: pid, sectionId: sid, parentId: nil)
        let name = store.project(pid)?.name ?? ""
        showToast("Task moved to \(name)", undo: nil)
    }

    /// Starts a drag of a task row (called when the drag session begins).
    func beginDrag(_ id: EntityID, rowHeight: CGFloat, inPanel: Bool = false, trackMouse: Bool = true) {
        drag.begin(id, excluded: Set([id] + store.descendantIDs(of: id)), rowHeight: rowHeight, inPanel: inPanel,
                   trackMouse: trackMouse)
    }

    /// Moves the dragged task to `target` (or the current drop target). Returns false when
    /// there is nothing to move.
    @discardableResult
    func performDrop(_ target: DropTarget? = nil) -> Bool {
        defer { drag.end() }
        guard let id = drag.draggingID, let target = target ?? drag.target, store.task(id) != nil else { return false }
        switch target {
        case .before(let anchor), .after(let anchor):
            guard let a = store.task(anchor), !drag.excluded.contains(anchor) else { return false }
            let sibs = a.parentId.map { store.subtaskIDs(of: $0) }
                ?? store.taskIDs(projectId: a.projectId, sectionId: a.sectionId)
            let others = sibs.filter { $0 != id }
            var index = others.firstIndex(of: anchor)
            if case .after = target { index = index.map { $0 + 1 } }
            store.moveTask(id, projectId: a.projectId, sectionId: a.sectionId, parentId: a.parentId, at: index)
        case .firstChild(let parent):
            guard let p = store.task(parent), !drag.excluded.contains(parent) else { return false }
            store.moveTask(id, projectId: p.projectId, sectionId: p.sectionId, parentId: parent, at: 0)
            // Show where the task went.
            if p.collapsed { store.updateTask(parent) { $0.collapsed = false } }
        case .sectionStart(let pid, let sid):
            store.moveTask(id, projectId: pid, sectionId: sid, parentId: nil, at: 0)
        case .sectionEnd(let pid, let sid):
            store.moveTask(id, projectId: pid, sectionId: sid, parentId: nil)
        }
        return true
    }

    /// Drop handler: appends dragged tasks to a section (or project when `sectionId` is nil).
    func drop(_ ids: [String], projectId: EntityID, sectionId: EntityID?) -> Bool {
        var moved = false
        defer { drag.end() }
        for id in ids where store.task(id) != nil {
            store.moveTask(id, projectId: projectId, sectionId: sectionId, parentId: nil)
            moved = true
        }
        if moved, ids.count == 1, store.task(ids[0])?.projectId != currentProjectID, let name = store.project(projectId)?.name {
            showToast("Task moved to \(name)", undo: nil)
        }
        return moved
    }

    private func neighbor(of id: EntityID) -> EntityID? {
        let d = cachedDisplay()
        let ids = d.taskIDs
        guard let i = d.position[id] else { return nil }
        let descendants = Set(store.descendantIDs(of: id))
        if let next = ids[(i + 1)...].first(where: { !descendants.contains($0) }) { return next }
        return i > 0 ? ids[i - 1] : nil
    }

    // MARK: - Undo / toast

    private func registerUndo(_ name: String, _ restore: @escaping () -> Void) {
        guard let um = mainWindow?.undoManager ?? undoManager else { return }
        um.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                restore()
                model.toast = nil
            }
        }
        um.setActionName(name)
    }

    func showToast(_ message: String, undo: (() -> Void)?) {
        let info = ToastInfo(message: message, undo: undo)
        toast = info
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled, let self, self.toast?.id == info.id else { return }
            withAnimation { self.toast = nil }
        }
    }

    // MARK: - Sync

    func syncNow() {
        Task { await sync.syncNow() }
    }
}
