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
    /// The drag the mouse poll ended, kept briefly: when the main thread is busy, SwiftUI can
    /// deliver the drop after the poll has seen the button go up.
    @ObservationIgnored private var released: (id: EntityID, target: DropTarget?, excluded: Set<EntityID>, inPanel: Bool, at: Date)?

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
        released = nil
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
        released = nil
        guard draggingID != nil || target != nil else { return }
        withAnimation(Self.slotAnimation) {
            target = nil
            draggingID = nil
        }
        excluded = []
        inPanel = false
    }

    /// The motion of the drop slot: quick, without overshoot, so rows glide out of the way.
    static var slotAnimation: Animation? { Theme.reduceMotion ? nil : .snappy(duration: 0.2, extraBounce: 0) }

    /// Sets the target with an animation so the rows slide to make room.
    func setTarget(_ new: DropTarget?) {
        guard new != target else { return }
        withAnimation(Self.slotAnimation) { target = new }
    }

    /// Restores a drag the mouse poll ended less than a second ago, so a late drop still lands.
    /// Called by the drop delegates before they look at the drag.
    func resumeIfJustReleased() {
        guard draggingID == nil, let r = released, Date().timeIntervalSince(r.at) < 1 else { return }
        released = nil
        excluded = r.excluded
        inPanel = r.inPanel
        target = r.target
        draggingID = r.id
    }

    private func poll() {
        if NSEvent.pressedMouseButtons & 1 == 0 {
            releasedTicks += 1
            // A drop is delivered on mouse-up; give `performDrop` time to run first.
            if releasedTicks >= 3, let id = draggingID {
                let r = (id: id, target: target, excluded: excluded, inPanel: inPanel, at: Date())
                end()
                released = r
            } else if releasedTicks >= 3 {
                end()
            }
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

/// Drop delegate of a task row. The top band places the dragged task before the row, the middle
/// band makes it the row's first subtask, and the bottom band places it after the row: as a
/// sibling, or as the first subtask when the row is an expanded parent or the pointer is at least
/// one indent right of the row's checkbox (Todoist's drag-right-to-indent).
struct TaskRowDropDelegate: DropDelegate {
    let model: AppModel
    let item: RowItem
    let collapsed: Bool
    let height: HeightBox

    func validateDrop(info: DropInfo) -> Bool {
        model.drag.resumeIfJustReleased()
        return model.drag.draggingID != nil && !model.drag.inPanel
    }
    func dropEntered(info: DropInfo) { update(info) }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        update(info)
        return DropProposal(operation: .move)
    }
    func performDrop(info: DropInfo) -> Bool {
        model.drag.resumeIfJustReleased()
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
        drag.setTarget(Self.target(for: item, collapsed: collapsed, at: info.location, height: height.value))
    }

    /// `location` is in the row's coordinates, whose origin is the drag-handle column.
    static func target(for item: RowItem, collapsed: Bool, at location: CGPoint, height: CGFloat) -> DropTarget {
        let y = location.y / max(height, 1)
        if y < 0.3 { return .before(item.id) }
        if y < 0.7 { return .firstChild(item.id) }
        let checkbox = Theme.grip + Theme.gutter + CGFloat(item.depth) * Theme.indent
        if (item.hasChildren && !collapsed) || location.x >= checkbox + Theme.indent {
            return .firstChild(item.id)
        }
        return .after(item.id)
    }
}

/// Drop delegate of a sub-task row in the task panel: the top half places the dragged sub-task
/// before the row, the bottom half after it. Completed sub-tasks are not anchors, since open
/// siblings are ordered among themselves.
struct SubtaskDropDelegate: DropDelegate {
    let model: AppModel
    let task: TodoTask
    let height: HeightBox

    func validateDrop(info: DropInfo) -> Bool {
        model.drag.resumeIfJustReleased()
        return model.drag.draggingID != nil && model.drag.inPanel
    }
    func dropEntered(info: DropInfo) { update(info) }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        update(info)
        return DropProposal(operation: .move)
    }
    func performDrop(info: DropInfo) -> Bool {
        model.drag.resumeIfJustReleased()
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
    func validateDrop(info: DropInfo) -> Bool {
        model.drag.resumeIfJustReleased()
        return model.drag.draggingID != nil && (target == nil || !model.drag.inPanel)
    }
    func dropEntered(info: DropInfo) { if let target { model.drag.setTarget(target) } }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        if let target { model.drag.setTarget(target) }
        return DropProposal(operation: .move)
    }
    func performDrop(info: DropInfo) -> Bool { model.performDrop(target) }
}

/// The drop slot's fill: a row-height rounded rectangle where the task will land.
struct DropPlaceholderView: View {
    @Environment(AppModel.self) private var model
    let depth: Int
    let height: CGFloat
    /// Leading inset at depth 0; the task panel's rows have no chevron gutter.
    var inset: CGFloat = Theme.gutter - 4

    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Theme.accent.opacity(0.07))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Theme.accent.opacity(0.32), lineWidth: 1))
            .frame(height: height - 6)
            .padding(.vertical, 3)
            .padding(.leading, CGFloat(depth) * Theme.indent + inset)
            .onDrop(of: [.text], delegate: FixedDropDelegate(model: model, target: nil))
    }
}

/// Where the drop slot opens: before the item with `beforeID` (nil = after the last item),
/// at `depth`.
struct DropGap: Equatable {
    var beforeID: String?
    var depth: Int
}

extension TaskListView {
    /// The slot for the current target among `items`. O(rows), only while a drag is over the list.
    static func gap(in items: [DisplayItem], target: DropTarget?) -> DropGap? {
        guard let target else { return nil }
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
        guard let at else { return nil }
        return DropGap(beforeID: at < items.count ? items[at].id : nil, depth: d)
    }
}

/// The space a drop would fill, kept in the layout at zero height when closed so that opening,
/// closing and moving it animate as rows sliding apart.
struct DropSlot: View {
    let open: Bool
    let depth: Int
    let height: CGFloat
    var inset: CGFloat = Theme.gutter - 4

    var body: some View {
        // The placeholder (and its drop delegate) only exists while open; the frame animates.
        Color.clear
            .frame(height: open ? height : 0)
            .overlay {
                if open {
                    DropPlaceholderView(depth: depth, height: height, inset: inset)
                        .transition(.opacity)
                }
            }
            .clipped()
    }
}
