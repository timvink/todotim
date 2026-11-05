import Foundation
import TodoCore

/// Quick Add resolution, as in the Mac app's `QuickAddView`: parses the line against the known
/// projects, then against the sections of the project it names (or the default project).
@MainActor
struct QuickAddResolution {
    var parsed: ParsedTask
    var project: Project
    var section: TodoCore.Section?
    /// Parent for a sub-task; only kept while the line names no other project.
    var parentId: EntityID?
    var unknownProject: String?
    var unknownSection: String?
    var tokens: [ParsedToken]
    var text: String

    /// `defaultSectionId` and `parentId` (from where Quick Add was opened) apply while the line
    /// names no project and no section.
    init(text: String, store: TodoStore, defaultProjectId: EntityID?, defaultSectionId: EntityID?, parentId: EntityID?,
         now: Date, calendar: Calendar) {
        let projects = [store.inbox] + store.projects
        let projectNames = projects.map(\.name)
        func find(_ name: String?) -> Project? {
            name.flatMap { n in projects.first { $0.name.caseInsensitiveCompare(n) == .orderedSame } }
        }
        var project = defaultProjectId.flatMap { store.project($0) } ?? store.inbox
        var sections = store.sections(in: project.id)
        var parsed = QuickAddParser.parse(text, now: now, calendar: calendar, projectNames: projectNames,
                                          sectionNames: sections.map(\.name))
        var movedProject = false
        if let p = find(parsed.projectName), p.id != project.id {
            project = p
            movedProject = true
            sections = store.sections(in: p.id)
            parsed = QuickAddParser.parse(text, now: now, calendar: calendar, projectNames: projectNames,
                                          sectionNames: sections.map(\.name))
        }
        let named = parsed.sectionName.flatMap { n in sections.first { $0.name.caseInsensitiveCompare(n) == .orderedSame } }
        var section = named
        var parent: EntityID?
        if !movedProject && parsed.sectionName == nil {
            if let parentId, let p = store.task(parentId), p.projectId == project.id {
                parent = parentId
                section = sections.first { $0.id == p.sectionId }
            } else if let defaultSectionId {
                section = sections.first { $0.id == defaultSectionId }
            }
        }
        self.parsed = parsed
        self.project = project
        self.section = section
        self.parentId = parent
        self.unknownProject = parsed.projectName.flatMap { find($0) == nil ? $0 : nil }
        self.unknownSection = parsed.sectionName.flatMap { named == nil ? $0 : nil }
        self.tokens = QuickAddParser.tokens(in: text, now: now, calendar: calendar, projectNames: projectNames,
                                            sectionNames: sections.map(\.name))
        self.text = text
    }

    var content: String { parsed.content.trimmingCharacters(in: .whitespaces) }

    /// Preview for the UI: tokens as UTF-16 offsets (QML string indices) with what each resolved to.
    func json(store: TodoStore, now: Date, calendar: Calendar) -> JSON {
        let labelColors = Dictionary(store.labels.map { ($0.name, ProjectColor.hex($0.color)) }, uniquingKeysWith: { a, _ in a })
        let tokenJSON: [JSON] = tokens.map { token in
            let start = text.utf16.distance(from: text.startIndex, to: token.range.lowerBound)
            let end = text.utf16.distance(from: text.startIndex, to: token.range.upperBound)
            let value = String(text[token.range].dropFirst())
            var known = true
            var color: JSON = .null
            switch token.kind {
            case .project:
                known = unknownProject == nil
                color = known ? RowBuilder.projectColor(project) : .null
            case .section:
                known = unknownSection == nil
                color = known ? RowBuilder.projectColor(project) : .null
            case .label:
                color = .string(labelColors[value] ?? ProjectColor.hex("charcoal"))
            case .date, .priority:
                break
            }
            return ["start": .int(start), "end": .int(end), "kind": .string(token.kind.rawValue), "known": .bool(known),
                    "color": color]
        }
        return [
            "content": .string(content),
            "priority": parsed.priority.map { .int($0.rawValue) } ?? .null,
            "due": parsed.due.map { RowBuilder.dueJSON($0, now: now, calendar: calendar) } ?? .null,
            "noDate": .bool(parsed.noDate),
            "labels": .array(parsed.labels.map { .string($0) }),
            "project": ["id": .string(project.id), "name": .string(project.name), "color": RowBuilder.projectColor(project)],
            "section": section.map { ["id": .string($0.id), "name": .string($0.name)] } ?? .null,
            "parentId": .string(parentId),
            "parent": parentId.flatMap { store.task($0) }.map { ["id": .string($0.id), "content": .string($0.content)] } ?? .null,
            "unknownProject": .string(unknownProject),
            "unknownSection": .string(unknownSection),
            "tokens": .array(tokenJSON),
        ]
    }
}
