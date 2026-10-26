import AppKit
import SwiftUI
import TodoCore

/// Where a dragged task would land, relative to rows of the current list.
enum DropTarget: Equatable {
    /// Sibling right before / after the anchor task.
    case before(EntityID)
    case after(EntityID)
    /// First subtask of an expanded parent (hovering the bottom half of the parent row).
    case firstChild(EntityID)
    /// Top or bottom of a section's (or the project's unsectioned) top-level tasks.
    case sectionStart(projectId: EntityID, sectionId: EntityID?)
    case sectionEnd(projectId: EntityID, sectionId: EntityID?)
}

/// State of the in-app task drag. Only `TaskListView` observes it (to insert the placeholder
/// and dim the dragged row), so moving over rows does not invalidate the rows themselves.
@MainActor
@Observable
final class DragState {
    private(set) var draggingID: EntityID?
    /// Current drop position; nil = no placeholder.
    var target: DropTarget?
    /// The dragged task and its descendants: never valid anchors.
    @ObservationIgnored private(set) var excluded: Set<EntityID> = []
    /// Height of the dragged row, used for the placeholder slot.
    @ObservationIgnored private(set) var rowHeight: CGFloat = 38
    /// The drag started in the task panel's sub-task list, which shows its own placeholder.
    @ObservationIgnored private(set) var inPanel = false
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var releasedTicks = 0

    /// `trackMouse: false` is for the debug test hook, which drags without a mouse.
    func begin(_ id: EntityID, excluded: Set<EntityID>, rowHeight: CGFloat, inPanel: Bool = false, trackMouse: Bool = true) {
        self.excluded = excluded
        self.inPanel = inPanel
        self.rowHeight = max(30, rowHeight)
        target = nil
        draggingID = id
        // SwiftUI reports no event when a drag is cancelled (dropped outside any target), so
        // poll the mouse button while a drag is active and clean up shortly after release.
        releasedTicks = 0
        timer?.invalidate()
        guard trackMouse else { return }
        let t = Timer(timeInterval: 0.12, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func end() {
        timer?.invalidate()
        timer = nil
        guard draggingID != nil || target != nil else { return }
        withAnimation(.easeOut(duration: 0.12)) {
            target = nil
            draggingID = nil
        }
        excluded = []
        inPanel = false
    }

    /// Sets the target with a short animation so the rows slide to make room.
    func setTarget(_ new: DropTarget?) {
        guard new != target else { return }
        withAnimation(.easeInOut(duration: 0.14)) { target = new }
    }

    private func poll() {
        if NSEvent.pressedMouseButtons & 1 == 0 {
            releasedTicks += 1
            // A drop is delivered on mouse-up; give `performDrop` time to run first.
            if releasedTicks >= 3 { end() }
        } else {
            releasedTicks = 0
        }
    }
}

/// Mutable height box written by `onGeometryChange`; a plain reference, so layout changes do not
/// invalidate the row.
final class HeightBox {
    var value: CGFloat = 38
}

/// Drop delegate of a task row: the top half places the dragged task before the row, the bottom
/// half after it (or as the first subtask when the row is an expanded parent).
struct TaskRowDropDelegate: DropDelegate {
    let model: AppModel
    let item: RowItem
    let collapsed: Bool
    let height: HeightBox

    func validateDrop(info: DropInfo) -> Bool { model.drag.draggingID != nil && !model.drag.inPanel }
    func dropEntered(info: DropInfo) { update(info) }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        update(info)
        return DropProposal(operation: .move)
    }
    func performDrop(info: DropInfo) -> Bool {
        update(info)
        return model.performDrop()
    }

    private func update(_ info: DropInfo) {
        let drag = model.drag
        guard drag.draggingID != nil else { return }
        if drag.excluded.contains(item.id) {
            // Over the dragged row itself (or its subtasks): it would stay where it is.
            drag.setTarget(nil)
            return
        }
        if info.location.y < height.value / 2 {
            drag.setTarget(.before(item.id))
        } else if item.hasChildren && !collapsed {
            drag.setTarget(.firstChild(item.id))
        } else {
            drag.setTarget(.after(item.id))
        }
    }
}

/// Drop delegate of a sub-task row in the task panel: the top half places the dragged sub-task
/// before the row, the bottom half after it. Completed sub-tasks are not anchors, since open
/// siblings are ordered among themselves.
struct SubtaskDropDelegate: DropDelegate {
    let model: AppModel
    let task: TodoTask
    let height: HeightBox

    func validateDrop(info: DropInfo) -> Bool { model.drag.draggingID != nil && model.drag.inPanel }
    func dropEntered(info: DropInfo) { update(info) }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        update(info)
        return DropProposal(operation: .move)
    }
    func performDrop(info: DropInfo) -> Bool {
        update(info)
        return model.performDrop()
    }

    private func update(_ info: DropInfo) {
        let drag = model.drag
        guard drag.draggingID != nil else { return }
        if drag.excluded.contains(task.id) || task.isCompleted {
            drag.setTarget(nil)
        } else {
            drag.setTarget(info.location.y < height.value / 2 ? .before(task.id) : .after(task.id))
        }
    }
}

/// Drop delegate with a fixed target (section header, "Add task" row, placeholder).
struct FixedDropDelegate: DropDelegate {
    let model: AppModel
    /// nil keeps the current target (used by the placeholder itself).
    let target: DropTarget?

    /// The placeholder (nil target) also serves the task panel; the fixed zones are the list's.
    func validateDrop(info: DropInfo) -> Bool { model.drag.draggingID != nil && (target == nil || !model.drag.inPanel) }
    func dropEntered(info: DropInfo) { if let target { model.drag.setTarget(target) } }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        if let target { model.drag.setTarget(target) }
        return DropProposal(operation: .move)
    }
    func performDrop(info: DropInfo) -> Bool { model.performDrop(target) }
}

/// Todoist's drop slot: a row-height rounded rectangle where the task will land.
struct DropPlaceholderView: View {
    @Environment(AppModel.self) private var model
    let depth: Int
    let height: CGFloat
    /// Leading inset at depth 0; the task panel's rows have no chevron gutter.
    var inset: CGFloat = Theme.gutter - 4

    var body: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(Theme.accent.opacity(0.10))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.accent.opacity(0.45), lineWidth: 1))
            .frame(height: height - 6)
            .padding(.vertical, 3)
            .padding(.leading, CGFloat(depth) * Theme.indent + inset)
            .onDrop(of: [.text], delegate: FixedDropDelegate(model: model, target: nil))
    }
}

extension TaskListView {
    /// `items` with the drop placeholder inserted at the current target. O(rows), only while
    /// a drag is over the list.
    static func withPlaceholder(_ items: [DisplayItem], target: DropTarget?) -> [DisplayItem] {
        guard let target else { return items }
        func index(of id: String) -> Int? { items.firstIndex { $0.id == id } }
        func depth(at i: Int) -> Int { if case .task(let r) = items[i] { return r.depth } else { return 0 } }
        var at: Int?
        var d = 0
        switch target {
        case .before(let id):
            if let i = index(of: id) { at = i; d = depth(at: i) }
        case .after(let id):
            if let i = index(of: id) {
                // After the anchor's visible subtree (none when collapsed or childless).
                let base = depth(at: i)
                var j = i + 1
                while j < items.count, case .task(let r) = items[j], r.depth > base { j += 1 }
                at = j; d = base
            }
        case .firstChild(let id):
            if let i = index(of: id) { at = i + 1; d = depth(at: i) + 1 }
        case .sectionStart(_, let sid):
            if let i = index(of: sid.map { "__section/" + $0 } ?? "__header") { at = i + 1 }
        case .sectionEnd(_, let sid):
            at = index(of: "__add/" + (sid ?? ""))
        }
        guard let at else { return items }
        var out = items
        out.insert(.dropPlaceholder(depth: d), at: at)
        return out
    }
}
