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
    /// Pointer x where the drag started, in list-row coordinates (every row shares the origin at
    /// the depth-0 drag handle); nil when unknown. Dragging an indent right of it nests.
    @ObservationIgnored private(set) var startX: CGFloat?
    /// The drag started in the task panel's sub-task list, which shows its own placeholder.
    @ObservationIgnored private(set) var inPanel = false
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var releasedTicks = 0
    /// The drag the mouse poll ended, kept briefly: when the main thread is busy, SwiftUI can
    /// deliver the drop after the poll has seen the button go up.
    @ObservationIgnored private var released: (id: EntityID, target: DropTarget?, excluded: Set<EntityID>, inPanel: Bool, at: Date)?

    /// `trackMouse: false` is for the debug test hook, which drags without a mouse.
    func begin(_ id: EntityID, excluded: Set<EntityID>, rowHeight: CGFloat, startX: CGFloat? = nil, inPanel: Bool = false,
               trackMouse: Bool = true) {
        self.excluded = excluded
        self.startX = startX
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

/// Last pointer x over a row, written by `onContinuousHover`; a plain reference like `HeightBox`.
final class PointerBox {
    var x: CGFloat?
}

/// Drop delegate of a task row. The top band places the dragged task before the row, the middle
/// band makes it the row's first subtask, and the bottom band places it after the row: as a
/// sibling, or as the first subtask when the row is an expanded parent or the pointer has moved at
/// least one indent right of where the drag started (Todoist's drag-right-to-indent).
struct TaskRowDropDelegate: DropDelegate {
    let model: AppModel
    let item: RowItem
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
        guard model.drag.draggingID != nil else { return }
        DropLayout.resolve(model, overRow: item.id, at: info.location, height: height.value)
    }

    /// `location` is in the row's coordinates, whose origin is the depth-0 drag-handle column.
    /// The indent is measured from `startX`, the pointer x where the drag began: rows are dragged
    /// by their title as often as by the handle, and the title already lies an indent right of
    /// the checkbox, so an absolute threshold would nest on every bottom band and leave no way to
    /// drop after the last sub-task. Without `startX`, the row's checkbox is the reference.
    static func target(for item: RowItem, collapsed: Bool, at location: CGPoint, height: CGFloat,
                       startX: CGFloat? = nil) -> DropTarget {
        let y = location.y / max(height, 1)
        if y < 0.3 { return .before(item.id) }
        if y < 0.7 { return .firstChild(item.id) }
        let reference = startX ?? (Theme.grip + Theme.gutter + CGFloat(item.depth) * Theme.indent)
        if (item.hasChildren && !collapsed) || location.x >= reference + Theme.indent {
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
    func dropEntered(info: DropInfo) { update(info) }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        update(info)
        return DropProposal(operation: .move)
    }
    func performDrop(info: DropInfo) -> Bool {
        model.drag.resumeIfJustReleased()
        if target == nil { update(info) }
        return model.performDrop(target)
    }

    private func update(_ info: DropInfo) {
        if let target {
            model.drag.setTarget(target)
        } else if model.drag.draggingID != nil, !model.drag.inPanel {
            // The list's placeholder; its origin is the list's leading edge, a handle column
            // right of the rows' origin.
            DropLayout.resolve(model, overSlotAt: CGPoint(x: info.location.x + Theme.grip, y: info.location.y))
        }
    }
}

/// Resolves the list's drop target from the pointer as if the drop slot were closed. Opening the
/// slot pushes every row below it down by the slot's height; measuring against that shifted layout
/// made the target depend on where the slot already was, so the rows slid away under the pointer:
/// coming from above, a row's lower band was skipped as the slot moved below it, which left no way
/// to drop after the last sub-task or as the last task. Here a row below the open slot counts the
/// pointer one slot height lower, and the slot itself stands for the top of the row below it, so
/// the target is a function of the pointer alone.
@MainActor
enum DropLayout {
    /// Where the slot for `target` opens among `items` (`items.count` = after the last) and its depth.
    static func slot(in items: [DisplayItem], target: DropTarget?) -> (index: Int, depth: Int)? {
        guard let target else { return nil }
        func index(of id: String) -> Int? { items.firstIndex { $0.id == id } }
        func depth(at i: Int) -> Int { if case .task(let r) = items[i] { return r.depth } else { return 0 } }
        switch target {
        case .before(let id):
            return index(of: id).map { ($0, depth(at: $0)) }
        case .after(let id):
            guard let i = index(of: id) else { return nil }
            // After the anchor's visible subtree (none when collapsed or childless).
            let base = depth(at: i)
            var j = i + 1
            while j < items.count, case .task(let r) = items[j], r.depth > base { j += 1 }
            return (j, base)
        case .firstChild(let id):
            return index(of: id).map { ($0 + 1, depth(at: $0) + 1) }
        case .sectionStart(_, let sid):
            if let sid { return index(of: "__section/" + sid).map { ($0 + 1, 0) } }
            // The project's own tasks start at the top (its title is pinned above the list).
            return (items.first?.id == "__empty" ? 1 : 0, 0)
        case .sectionEnd(_, let sid):
            return index(of: "__add/" + (sid ?? "")).map { ($0, 0) }
        }
    }

    /// Pointer over the task row `id`, at `location` in the row's coordinates.
    static func resolve(_ model: AppModel, overRow id: EntityID, at location: CGPoint, height: CGFloat) {
        let items = model.cachedDisplay().items
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        var y = location.y
        if let slot = slot(in: items, target: model.drag.target), slot.index <= i { y += model.drag.rowHeight }
        resolve(model, items: items, index: i, at: CGPoint(x: location.x, y: y), height: height)
    }

    /// Pointer over the open slot, at `location` from its top (x in row coordinates).
    static func resolve(_ model: AppModel, overSlotAt location: CGPoint) {
        let items = model.cachedDisplay().items
        guard let slot = slot(in: items, target: model.drag.target), slot.index < items.count else { return }
        resolve(model, items: items, index: slot.index, at: location, height: model.drag.rowHeight)
    }

    /// `location` is measured from the top of `items[index]` in the layout without the slot. Items
    /// further down are taken to be one dragged row high.
    private static func resolve(_ model: AppModel, items: [DisplayItem], index: Int, at location: CGPoint, height: CGFloat) {
        let drag = model.drag
        var i = index, y = location.y, h = max(height, 1)
        while y >= h, i + 1 < items.count {
            y -= h
            i += 1
            h = drag.rowHeight
        }
        switch items[i] {
        case .task(let r):
            // Over the dragged row itself (or its subtasks): it would stay where it is.
            if drag.excluded.contains(r.id) { drag.setTarget(nil); return }
            let collapsed = model.store.task(r.id)?.collapsed ?? false
            drag.setTarget(TaskRowDropDelegate.target(for: r, collapsed: collapsed, at: CGPoint(x: location.x, y: y),
                                                      height: h, startX: drag.startX))
        case .addTask(let pid, let sid):
            drag.setTarget(.sectionEnd(projectId: pid, sectionId: sid))
        case .sectionHeader(let section, _, _):
            drag.setTarget(.sectionStart(projectId: section.projectId, sectionId: section.id))
        default:
            break
        }
    }
}

/// The drop slot's fill: a row-height rounded rectangle where the task will land.
struct DropPlaceholderView: View {
    @Environment(AppModel.self) private var model
    let depth: Int
    let height: CGFloat
    /// Leading inset at depth 0 (where a row's pill starts); the task panel's rows have no
    /// chevron gutter.
    var inset: CGFloat = Theme.gutter

    var body: some View {
        RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous)
            .fill(Theme.hover)
            .overlay(RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous)
                .strokeBorder(Theme.accent.opacity(0.45), lineWidth: 1))
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
        guard let slot = DropLayout.slot(in: items, target: target) else { return nil }
        return DropGap(beforeID: slot.index < items.count ? items[slot.index].id : nil, depth: slot.depth)
    }
}

/// The space a drop would fill, kept in the layout at zero height when closed so that opening,
/// closing and moving it animate as rows sliding apart.
struct DropSlot: View {
    let open: Bool
    let depth: Int
    let height: CGFloat
    var inset: CGFloat = Theme.gutter

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
