import Observation
import SwiftUI
import TodoCore

/// Inputs that determine the rows of the current view, besides task content.
struct DisplayKey: Equatable {
    var structureVersion: Int
    var sidebar: SidebarItem?
    var editor: EditorTarget?
    var collapsedSections: Set<EntityID>
    var showCompleted: Set<EntityID>
    var searchQuery: String
}

/// One task row. Holds structure only; the row view reads the task itself from the store, so
/// editing a task's title redraws that row and nothing else.
struct RowItem: Equatable, Identifiable {
    var id: EntityID
    var depth: Int
    var subtaskDone: Int
    var subtaskTotal: Int
    /// True when the task has subtasks that would be shown when expanded.
    var hasChildren: Bool
    /// Show "Project ›" at the right (label and search views).
    var showProject = false
}

/// Everything a task list shows, flattened into one array so it can be rendered by a single
/// `LazyVStack` (offscreen rows are never built).
enum DisplayItem: Equatable, Identifiable {
    case projectHeader(EntityID)
    case labelHeader(String)
    case task(RowItem)
    case editor(depth: Int)
    case addTask(projectId: EntityID, sectionId: EntityID?)
    case sectionGap(projectId: EntityID, index: Int?)
    case sectionHeader(TodoCore.Section, count: Int, collapsed: Bool)
    case groupHeader(projectId: EntityID, count: Int)
    case message(String)

    /// Task rows use the bare task id so `ScrollViewProxy.scrollTo(taskID)` finds them.
    var id: String {
        switch self {
        case .projectHeader: "__header"
        case .labelHeader: "__header"
        case .task(let r): r.id
        case .editor: "__editor"
        case .addTask(_, let sid): "__add/" + (sid ?? "")
        case .sectionGap(_, let i): "__gap/" + (i.map(String.init) ?? "end")
        case .sectionHeader(let s, _, _): "__section/" + s.id
        case .groupHeader(let pid, _): "__group/" + pid
        case .message: "__message"
        }
    }
}

struct DisplayModel {
    var key: DisplayKey
    var items: [DisplayItem]
    /// Task ids in on-screen order, and each id's position, for j/k navigation.
    var taskIDs: [EntityID]
    var position: [EntityID: Int]
}

/// Builds a `DisplayModel` from the store's indexed queries: O(rows), each task's children
/// queried once.
@MainActor
struct DisplayBuilder {
    let model: AppModel
    let store: TodoStore
    private var items: [DisplayItem] = []
    private var taskIDs: [EntityID] = []

    init(model: AppModel, store: TodoStore) {
        self.model = model
        self.store = store
    }

    mutating func build(_ key: DisplayKey) -> DisplayModel {
        items.reserveCapacity(256)
        switch key.sidebar {
        case .project(let pid): buildProject(pid, key)
        case .label(let name): buildLabel(name)
        case .search: buildSearch(key.searchQuery)
        case nil: break
        }
        var position: [EntityID: Int] = [:]
        position.reserveCapacity(taskIDs.count)
        for (i, id) in taskIDs.enumerated() { position[id] = i }
        return DisplayModel(key: key, items: items, taskIDs: taskIDs, position: position)
    }

    // MARK: Project

    private mutating func buildProject(_ pid: EntityID, _ key: DisplayKey) {
        guard store.project(pid) != nil else { return }
        let showCompleted = key.showCompleted.contains(pid)
        items.append(.projectHeader(pid))
        appendArea(pid, nil, showCompleted: showCompleted, editor: key.editor)
        for (i, s) in store.sections(in: pid).enumerated() {
            items.append(.sectionGap(projectId: pid, index: i))
            let collapsed = key.collapsedSections.contains(s.id)
            items.append(.sectionHeader(s, count: store.openTaskCount(projectId: pid, sectionId: s.id),
                                        collapsed: collapsed))
            if !collapsed { appendArea(pid, s.id, showCompleted: showCompleted, editor: key.editor) }
        }
        items.append(.sectionGap(projectId: pid, index: nil))
    }

    private mutating func appendArea(_ pid: EntityID, _ sid: EntityID?, showCompleted: Bool, editor: EditorTarget?) {
        let editorHere = editor.map { $0.parentId == nil && $0.projectId == pid && $0.sectionId == sid } ?? false
        if editorHere, editor?.atTop == true { items.append(.editor(depth: 0)) }
        for id in store.taskIDs(projectId: pid, sectionId: sid, includeCompleted: showCompleted) {
            appendTree(id, depth: 0, showCompleted: showCompleted, editor: editor)
        }
        if editorHere, editor?.atTop == false { items.append(.editor(depth: 0)) }
        if !(editorHere && editor?.atTop == false) { items.append(.addTask(projectId: pid, sectionId: sid)) }
    }

    private mutating func appendTree(_ id: EntityID, depth: Int, showCompleted: Bool, editor: EditorTarget?) {
        let progress = store.subtaskProgress(of: id)
        let shown = showCompleted ? progress.total : progress.total - progress.done
        items.append(.task(RowItem(id: id, depth: depth, subtaskDone: progress.done, subtaskTotal: progress.total,
                                   hasChildren: shown > 0)))
        taskIDs.append(id)
        // Only parents are read here, so the list is not invalidated by edits to leaf tasks.
        if shown > 0, store.task(id)?.collapsed == false {
            for c in store.subtaskIDs(of: id, includeCompleted: showCompleted) {
                appendTree(c, depth: depth + 1, showCompleted: showCompleted, editor: editor)
            }
        }
        if editor?.parentId == id { items.append(.editor(depth: depth + 1)) }
    }

    // MARK: Label and search

    private mutating func buildLabel(_ name: String) {
        items.append(.labelHeader(name))
        appendGroups(store.tasks(withLabel: name), empty: "No open tasks with this label.")
    }

    private mutating func buildSearch(_ query: String) {
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            items.append(.message("Type to search task names and descriptions."))
            return
        }
        appendGroups(store.search(query), empty: "No results for “\(query)”")
    }

    /// Flat rows grouped by project, in sidebar order.
    private mutating func appendGroups(_ tasks: [TodoTask], empty: String) {
        guard !tasks.isEmpty else {
            items.append(.message(empty))
            return
        }
        var byProject: [EntityID: [EntityID]] = [:]
        for t in tasks { byProject[t.projectId, default: []].append(t.id) }
        for p in model.allProjects {
            guard let ids = byProject[p.id] else { continue }
            items.append(.groupHeader(projectId: p.id, count: ids.count))
            for id in ids {
                let progress = store.subtaskProgress(of: id)
                items.append(.task(RowItem(id: id, depth: 0, subtaskDone: progress.done, subtaskTotal: progress.total,
                                           hasChildren: false, showProject: true)))
                taskIDs.append(id)
            }
        }
    }
}

/// State of the inline "Add task" editor (see `AppModel.editorDraft`).
@MainActor
@Observable
final class InlineEditorDraft {
    var title = ""
    var details = ""
    var due: DueDate?
    var priority: Priority = .p4
    var labels: [String] = []
    var projectId: EntityID = TodoStore.inboxID
    var sectionId: EntityID?

    func reset(projectId: EntityID, sectionId: EntityID?) {
        clearFields()
        self.projectId = projectId
        self.sectionId = sectionId
    }

    /// Clears what the user typed, keeping the chosen project and section.
    func clearFields() {
        title = ""
        details = ""
        due = nil
        priority = .p4
        labels = []
    }
}
