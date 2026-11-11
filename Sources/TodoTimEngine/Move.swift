import Foundation
import TodoCore

/// The move dialog (`m`, `v`): ranked targets for a query, and moving tasks to one of them with undo.
extension Engine {
    /// `moveTargets`: TodoCore's ranked targets as JSON rows, with the UTF-16 ranges of the query's
    /// words in each title (QML strings index in UTF-16) for highlighting.
    func moveTargetsJSON(_ ids: [EntityID], query: String) -> JSON {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return .array(store.moveTargets(for: ids, query: query).map { t in
            [
                "id": .string(t.id), "kind": .string(t.kind.rawValue), "group": .string(Self.groupName(t.group)),
                "projectId": .string(t.projectId), "sectionId": .string(t.sectionId), "parentId": .string(t.parentId),
                "title": .string(t.title), "projectName": .string(t.projectName),
                "projectColor": t.projectIsInbox ? .null : .string(ProjectColor.hex(t.projectColor)),
                "projectIsInbox": .bool(t.projectIsInbox), "sectionName": .string(t.sectionName),
                "isCurrent": .bool(t.isCurrent),
                "matches": .array(Self.matchRanges(of: words, in: t.title).map { [.int($0.start), .int($0.end)] }),
            ]
        })
    }

    nonisolated static func groupName(_ g: MoveTarget.Group) -> String {
        switch g {
        case .currentProject: "currentProject"
        case .sections: "sections"
        case .projects: "projects"
        case .tasks: "tasks"
        }
    }

    /// Every case-insensitive occurrence of each word in `title`, merged, as UTF-16 offsets
    /// (`start` inclusive, `end` exclusive).
    nonisolated static func matchRanges(of words: [String], in title: String) -> [(start: Int, end: Int)] {
        var ranges: [(start: Int, end: Int)] = []
        for word in words where !word.isEmpty {
            var from = title.startIndex
            while from < title.endIndex,
                  let r = title.range(of: word, options: .caseInsensitive, range: from..<title.endIndex, locale: .current) {
                let start = title.utf16.distance(from: title.utf16.startIndex, to: r.lowerBound.samePosition(in: title.utf16) ?? title.utf16.startIndex)
                let end = title.utf16.distance(from: title.utf16.startIndex, to: r.upperBound.samePosition(in: title.utf16) ?? title.utf16.endIndex)
                if end > start { ranges.append((start, end)) }
                from = r.upperBound > r.lowerBound ? r.upperBound : title.index(after: r.lowerBound)
            }
        }
        ranges.sort { $0.start != $1.start ? $0.start < $1.start : $0.end < $1.end }
        var merged: [(start: Int, end: Int)] = []
        for r in ranges {
            if let last = merged.last, r.start <= last.end {
                merged[merged.count - 1].end = max(last.end, r.end)
            } else {
                merged.append(r)
            }
        }
        return merged
    }

    /// Finds the target the client picked among the ones TodoCore offers for `ids`, so the move
    /// follows the same rules as the list (no completed, deleted or moved tasks as parents). The
    /// target is looked up by the query that lists it: its section name or task content.
    func resolveMoveTarget(_ ids: [EntityID], _ json: JSON?) throws -> MoveTarget {
        guard let json, let kind = json["kind"]?.string.flatMap(MoveTarget.Kind.init(rawValue:)) else {
            throw EngineError("Unknown move target")
        }
        let wanted: String
        let query: String
        switch kind {
        case .project:
            guard let pid = json["projectId"]?.string, store.project(pid) != nil else { throw EngineError("Unknown project") }
            wanted = "p:" + pid
            query = ""
        case .section:
            guard let pid = json["projectId"]?.string, let sid = json["sectionId"]?.string,
                  let s = store.sections(in: pid).first(where: { $0.id == sid }) else { throw EngineError("Unknown section") }
            wanted = "s:" + sid
            query = s.name
        case .task:
            guard let parentId = json["parentId"]?.string, let parent = store.task(parentId) else {
                throw EngineError("The task no longer exists")
            }
            wanted = "t:" + parentId
            query = parent.content
        }
        let found = store.moveTargets(for: ids, query: query, taskLimit: .max).first { $0.id == wanted }
            ?? (query.isEmpty ? nil : store.moveTargets(for: ids, query: "").first { $0.id == wanted })
        guard let found else { throw EngineError("The tasks cannot be moved there") }
        return found
    }

    /// `moveTasks`: moves `ids` to the end of `target` as one undo step that puts every moved task
    /// (and its sub-tasks, which follow it) back where it was.
    func moveTasks(_ ids: [EntityID], to target: MoveTarget, selection: JSON) throws -> JSON {
        var seen = Set<EntityID>()
        let live = ids.filter { seen.insert($0).inserted && store.task($0) != nil }
        struct Place { var projectId: EntityID; var sectionId: EntityID?; var parentId: EntityID?; var order: Double }
        var before: [EntityID: Place] = [:]
        for id in live {
            for tid in [id] + store.descendantIDs(of: id) {
                if let t = store.task(tid) {
                    before[tid] = Place(projectId: t.projectId, sectionId: t.sectionId, parentId: t.parentId, order: t.order)
                }
            }
        }
        let parentWasCollapsed = target.parentId.flatMap { store.task($0)?.collapsed } ?? false

        let moved = store.moveTasks(live, to: target)
        guard !moved.isEmpty else { throw EngineError("The tasks cannot be moved there") }

        let restore: () -> Void = { [weak self] in
            guard let store = self?.store else { return }
            store.performBatch {
                // Parents first, so a restored sub-task follows its parent; places that are gone since
                // (a deleted project, section or parent) fall back to the nearest live one.
                // `updateTask` must not change the location, so the order is restored with `moveTask`'s
                // location and then the saved order.
                let ordered = before.sorted { a, b in (a.value.parentId == nil ? 0 : 1, a.key) < (b.value.parentId == nil ? 0 : 1, b.key) }
                for (id, p) in ordered where store.task(id) != nil {
                    guard store.project(p.projectId) != nil else { continue }
                    let section = p.sectionId.flatMap { sid in store.sections(in: p.projectId).contains { $0.id == sid } ? sid : nil }
                    let parent = p.parentId.flatMap { store.task($0) != nil ? $0 : nil }
                    store.moveTask(id, projectId: p.projectId, sectionId: section, parentId: parent)
                    store.updateTask(id) { $0.order = p.order }
                }
                if parentWasCollapsed, let pid = target.parentId { store.updateTask(pid) { $0.collapsed = true } }
            }
        }

        // Count the selected tasks that moved, including selected sub-tasks that went with a parent.
        var carried = Set(moved)
        for id in moved { carried.formUnion(store.descendantIDs(of: id)) }
        let count = live.filter(carried.contains).count
        let message: String
        if target.kind == .task {
            let parent = "“" + Self.shortened(target.title) + "”"
            message = count == 1 ? "Made a sub-task of " + parent : "\(count) tasks made sub-tasks of " + parent
        } else {
            let place = target.kind == .section ? target.projectName + " / " + target.title : target.projectName
            message = count == 1 ? "Moved to " + place : "\(count) tasks moved to " + place
        }
        return pushUndo(message, restore: restore, selection: selection,
                        extra: ["ids": .array(moved.map { .string($0) }), "projectId": .string(target.projectId)])
    }

    /// A title short enough for a toast.
    nonisolated static func shortened(_ s: String, limit: Int = 40) -> String {
        s.count > limit ? String(s.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…" : s
    }
}
