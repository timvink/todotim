import Foundation

/// A place a task can be moved to with the move dialog (`m`): a section, a project (its area above
/// all sections), or another task (the moved task becomes its subtask).
public struct MoveTarget: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable {
        case section, project, task
    }

    /// The groups the dialog shows, in this order.
    public enum Group: Int, Comparable, Sendable {
        /// Sections of the moved task's project (with an empty query, that project itself comes first).
        case currentProject
        /// Sections of the other projects.
        case sections
        case projects
        case tasks

        public static func < (a: Group, b: Group) -> Bool { a.rawValue < b.rawValue }
    }

    public let kind: Kind
    public let group: Group
    public let projectId: EntityID
    /// The section moved into: the target section, or the target task's section.
    public let sectionId: EntityID?
    /// The task that becomes the parent (kind `.task`).
    public let parentId: EntityID?
    /// Section name, project name or task content.
    public let title: String
    public let projectName: String
    /// Project color key (`ProjectColor`).
    public let projectColor: String
    public let projectIsInbox: Bool
    /// The section a target task is in.
    public let sectionName: String?
    /// The moved task is already there (single task only).
    public let isCurrent: Bool

    public var id: String {
        switch kind {
        case .project: "p:" + projectId
        case .section: "s:" + (sectionId ?? "")
        case .task: "t:" + (parentId ?? "")
        }
    }
}

extension TodoStore {
    /// Move targets for `taskIDs`, ranked for the move dialog.
    ///
    /// With an empty query: the moved task's project, its sections (in order), then the other
    /// projects (sidebar order, inbox first). Tasks are only offered while typing.
    ///
    /// With a query: every whitespace-separated word must occur (case-insensitively) in the title
    /// or its context (project and section name), and at least one in the title, so "work meet"
    /// finds the section Meetings in Work while "work" alone does not list everything in Work.
    /// Results are grouped (sections of the current project, other sections, projects, tasks) and
    /// sorted alphabetically within a group. At most `taskLimit` tasks are returned.
    ///
    /// The moved tasks, their subtasks, completed tasks and deleted entities are never targets.
    public func moveTargets(for taskIDs: [EntityID], query: String, taskLimit: Int = 50) -> [MoveTarget] {
        let moving = taskIDs.compactMap { task($0) }
        let home = moving.first?.projectId ?? Self.inboxID
        let single = moving.count == 1 ? moving.first : nil
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        let matchers = words.map { TextMatcher($0) }
        let allProjects = [inbox] + projects

        func matches(_ title: String, context: [String]) -> Bool {
            guard !matchers.isEmpty else { return true }
            var inTitle = false
            for m in matchers {
                if m.matches(title) { inTitle = true } else if !context.contains(where: m.matches) { return false }
            }
            return inTitle
        }

        var result: [MoveTarget] = []
        for p in allProjects {
            let isHome = p.id == home
            let projectCurrent = single.map { $0.projectId == p.id && $0.sectionId == nil && $0.parentId == nil } ?? false
            if matches(p.name, context: []) {
                result.append(MoveTarget(kind: .project, group: words.isEmpty && isHome ? .currentProject : .projects,
                                         projectId: p.id, sectionId: nil, parentId: nil, title: p.name,
                                         projectName: p.name, projectColor: p.color, projectIsInbox: p.isInbox,
                                         sectionName: nil, isCurrent: projectCurrent))
            }
            // Other projects' sections only while typing.
            guard isHome || !words.isEmpty else { continue }
            for s in sections(in: p.id) where matches(s.name, context: [p.name]) {
                let current = single.map { $0.projectId == p.id && $0.sectionId == s.id && $0.parentId == nil } ?? false
                result.append(MoveTarget(kind: .section, group: isHome ? .currentProject : .sections,
                                         projectId: p.id, sectionId: s.id, parentId: nil, title: s.name,
                                         projectName: p.name, projectColor: p.color, projectIsInbox: p.isInbox,
                                         sectionName: nil, isCurrent: current))
            }
        }

        if !words.isEmpty {
            var excluded = Set(moving.map(\.id))
            for t in moving { excluded.formUnion(descendantIDs(of: t.id)) }
            let projectsByID = Dictionary(allProjects.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            var sectionNames: [EntityID: String] = [:]
            for p in allProjects { for s in sections(in: p.id) { sectionNames[s.id] = s.name } }
            var tasks: [MoveTarget] = []
            for t in db.tasks.values where !t.deleted && !t.isCompleted && !excluded.contains(t.id) {
                guard let p = projectsByID[t.projectId] else { continue }
                let sectionName = t.sectionId.flatMap { sectionNames[$0] }
                guard matches(t.content, context: [p.name] + (sectionName.map { [$0] } ?? [])) else { continue }
                tasks.append(MoveTarget(kind: .task, group: .tasks, projectId: p.id, sectionId: t.sectionId,
                                        parentId: t.id, title: t.content, projectName: p.name, projectColor: p.color,
                                        projectIsInbox: p.isInbox, sectionName: sectionName,
                                        isCurrent: single?.parentId == t.id))
            }
            tasks.sort(by: Self.alphabetical)
            result += tasks.prefix(taskLimit)
        }

        guard !words.isEmpty else {
            // Keep the natural order; only the groups move (the home project first).
            return result.enumerated().sorted { a, b in
                a.element.group != b.element.group ? a.element.group < b.element.group : a.offset < b.offset
            }.map(\.element)
        }
        return result.enumerated().sorted { a, b in
            if a.element.group != b.element.group { return a.element.group < b.element.group }
            if a.element.group == .tasks { return a.offset < b.offset }  // sorted above
            return Self.alphabetical(a.element, b.element)
        }.map(\.element)
    }

    nonisolated private static func alphabetical(_ a: MoveTarget, _ b: MoveTarget) -> Bool {
        switch a.title.localizedStandardCompare(b.title) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame:
            switch a.projectName.localizedStandardCompare(b.projectName) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return a.id < b.id
            }
        }
    }
}
