import Foundation
import TodoCore

extension Engine {
    /// Runs one request. Returns the reply's result, or nil when the reply is sent later (async).
    func perform(_ cmd: String, _ r: JSON, id: JSON) throws -> JSON? {
        switch cmd {
        case "hello":
            pushSync()
            return [
                "version": .string(Engine.version), "dataDir": .string(paths.dataDir.path),
                "palette": RowBuilder.palette, "startupError": .string(startupError),
            ]

        // MARK: View
        case "setView":
            guard let v = ViewSpec(r["view"]) else { throw EngineError("Unknown view") }
            view = v
            return .null
        case "setShowCompleted":
            let pid = try string(r, "projectId")
            if r["show"]?.bool == true { showCompleted.insert(pid) } else { showCompleted.remove(pid) }
            saveUIState()
            return .null
        case "setSectionCollapsed":
            let sid = try string(r, "id")
            if r["collapsed"]?.bool == true { collapsedSections.insert(sid) } else { collapsedSections.remove(sid) }
            saveUIState()
            return .null
        case "targets":
            return RowBuilder.targets(store)

        // MARK: Tasks
        case "parseQuickAdd":
            let q = quickAdd(r)
            return q.json(store: store, now: now(), calendar: calendar)
        case "quickAdd":
            let q = quickAdd(r)
            guard !q.content.isEmpty else { throw EngineError("Type a task name") }
            let description = (r["description"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let index = r["atTop"]?.bool == true ? 0 : r["index"]?.int
            let t = store.addTask(content: q.content, projectId: q.project.id, sectionId: q.section?.id, parentId: q.parentId,
                                  at: index, description: description, priority: q.parsed.priority ?? .p4,
                                  due: q.parsed.due, labels: q.parsed.labels)
            if let pid = q.parentId, store.task(pid)?.collapsed == true { store.updateTask(pid) { $0.collapsed = false } }
            if let sid = q.section?.id, collapsedSections.remove(sid) != nil { saveUIState() }
            return ["taskId": .string(t.id), "projectId": .string(q.project.id), "projectName": .string(q.project.name)]
        case "getTask":
            return try taskDetail(try task(r))
        case "updateTask":
            let t = try task(r)
            try updateTask(t.id, r)
            return try taskDetail(try task(r))
        case "toggleComplete":
            return try toggleComplete(try task(r))
        case "deleteTask":
            return deleteTask(try task(r))
        case "undo":
            guard let entry = undoStack.popLast() else { throw EngineError("Nothing to undo") }
            entry.restore()
            return ["message": .string(entry.message)]
        case "moveTask":
            let t = try task(r)
            let pid = try string(r, "projectId")
            guard store.project(pid) != nil else { throw EngineError("Unknown project") }
            let sid = r["sectionId"]?.string
            if let sid, !store.sections(in: pid).contains(where: { $0.id == sid }) { throw EngineError("Unknown section") }
            let parentId = r["parentId"]?.string
            store.moveTask(t.id, projectId: pid, sectionId: sid, parentId: parentId, at: r["index"]?.int)
            return ["projectName": .string(store.project(pid)?.name)]
        case "indentTask":
            store.indentTask(try task(r).id)
            return .null
        case "outdentTask":
            store.outdentTask(try task(r).id)
            return .null
        case "shiftTask":
            store.shiftTask(try task(r).id, by: r["delta"]?.int ?? 0)
            return .null
        case "setTaskCollapsed":
            let t = try task(r)
            let collapsed = r["collapsed"]?.bool ?? !t.collapsed
            store.updateTask(t.id) { $0.collapsed = collapsed }
            return .null
        case "parseDate":
            let text = (r["text"]?.string ?? "").trimmingCharacters(in: .whitespaces)
            guard let result = DateParser.parsePhrase(text, now: now(), calendar: calendar) else { return .null }
            if let due = result.dueDate { return ["due": RowBuilder.dueJSON(due, now: now(), calendar: calendar)] }
            return ["noDate": true]

        // MARK: Projects, sections, labels
        case "addProject":
            let name = try nonEmpty(r, "name")
            let p = store.addProject(name: name, color: r["color"]?.string ?? "charcoal")
            return ["id": .string(p.id)]
        case "updateProject":
            let pid = try string(r, "id")
            guard let p = store.project(pid), !p.isInbox else { throw EngineError("The Inbox cannot be changed") }
            let name = r["name"]?.string?.trimmingCharacters(in: .whitespaces)
            let color = r["color"]?.string
            store.updateProject(pid) { p in
                if let name, !name.isEmpty { p.name = name }
                if let color { p.color = color }
            }
            return .null
        case "deleteProject":
            let pid = try string(r, "id")
            guard let p = store.project(pid), !p.isInbox else { throw EngineError("The Inbox cannot be deleted") }
            store.deleteProject(pid)
            return .null
        case "moveProject":
            store.moveProject(try string(r, "id"), to: r["index"]?.int ?? 0)
            return .null
        case "addSection":
            let pid = try string(r, "projectId")
            guard store.project(pid) != nil else { throw EngineError("Unknown project") }
            let s = store.addSection(projectId: pid, name: try nonEmpty(r, "name"), at: r["index"]?.int)
            return ["id": .string(s.id)]
        case "renameSection":
            let name = try nonEmpty(r, "name")
            store.updateSection(try string(r, "id")) { $0.name = name }
            return .null
        case "deleteSection":
            store.deleteSection(try string(r, "id"))
            return .null
        case "moveSection":
            store.moveSection(try string(r, "id"), to: r["index"]?.int ?? 0)
            return .null
        case "addLabel":
            let l = store.addLabel(name: try nonEmpty(r, "name"), color: r["color"]?.string ?? "charcoal")
            return ["id": .string(l.id)]
        case "updateLabel":
            let lid = try string(r, "id")
            let name = r["name"]?.string?.trimmingCharacters(in: .whitespaces)
            let color = r["color"]?.string
            let oldName = store.labels.first { $0.id == lid }?.name
            store.updateLabel(lid) { l in
                if let name, !name.isEmpty { l.name = name }
                if let color { l.color = color }
            }
            if case .label(let current) = view, current == oldName, let name, !name.isEmpty { view = .label(name) }
            return .null
        case "deleteLabel":
            store.deleteLabel(try string(r, "id"))
            return .null

        // MARK: Sync
        case "syncNow":
            Task { @MainActor in
                await self.sync.syncNow()
                self.reply(id, result: self.syncJSON())
            }
            return nil
        case "getSyncSettings":
            let s = sync.settings
            return ["serverURL": .string(s.serverURL), "username": .string(s.username), "enabled": .bool(s.enabled),
                    "managed": .string(sync.managedConfigPath), "hasPassword": .bool(sync.storedPassword() != nil)]
        case "configureSync":
            let settings = SyncSettings(serverURL: (r["serverURL"]?.string ?? "").trimmingCharacters(in: .whitespaces),
                                        username: (r["username"]?.string ?? "").trimmingCharacters(in: .whitespaces),
                                        enabled: r["enabled"]?.bool ?? false)
            let password = r["password"]?.string.flatMap { $0.isEmpty ? nil : $0 }
            sync.configure(settings, password: password)
            return syncJSON()
        case "testConnection":
            let settings = SyncSettings(serverURL: (r["serverURL"]?.string ?? "").trimmingCharacters(in: .whitespaces),
                                        username: (r["username"]?.string ?? "").trimmingCharacters(in: .whitespaces),
                                        enabled: true)
            var password = r["password"]?.string ?? ""
            if password.isEmpty, settings.credentialAccount == sync.settings.credentialAccount {
                password = sync.storedPassword() ?? ""
            }
            Task { @MainActor in
                let error = await self.sync.testConnection(settings, password: password)
                self.reply(id, result: ["error": .string(error)])
            }
            return nil

        default:
            throw EngineError("Unknown command \(cmd)")
        }
    }

    // MARK: - Helpers

    func string(_ r: JSON, _ key: String) throws -> String {
        guard let s = r[key]?.string else { throw EngineError("Missing \(key)") }
        return s
    }

    func nonEmpty(_ r: JSON, _ key: String) throws -> String {
        let s = try string(r, key).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { throw EngineError("Enter a name") }
        return s
    }

    func task(_ r: JSON) throws -> TodoTask {
        let id = try string(r, "id")
        guard let t = store.task(id), !t.deleted else { throw EngineError("The task no longer exists") }
        return t
    }

    func quickAdd(_ r: JSON) -> QuickAddResolution {
        QuickAddResolution(text: r["text"]?.string ?? "", store: store, defaultProjectId: r["projectId"]?.string,
                           defaultSectionId: r["sectionId"]?.string, parentId: r["parentId"]?.string,
                           now: now(), calendar: calendar)
    }

    func updateTask(_ id: EntityID, _ r: JSON) throws {
        var due: DueDate??
        if let d = r["due"] {
            if d.isNull {
                due = .some(nil)
            } else if let s = d.string, DueDate(date: s).day(calendar: calendar) != nil {
                due = .some(DueDate(date: s))
            } else {
                throw EngineError("Invalid date")
            }
        }
        if let text = r["dueText"]?.string {
            guard let result = DateParser.parsePhrase(text.trimmingCharacters(in: .whitespaces), now: now(), calendar: calendar)
            else { throw EngineError("Unknown date “\(text)”") }
            due = .some(result.dueDate)
        }
        var priority: Priority?
        if let p = r["priority"]?.int {
            guard let value = Priority(rawValue: p) else { throw EngineError("Invalid priority") }
            priority = value
        }
        let labels = r["labels"]?.array.map { $0.compactMap(\.string).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        let content = r["content"]?.string.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let content, content.isEmpty { throw EngineError("Type a task name") }
        let description = r["description"]?.string
        store.updateTask(id) { t in
            if let content { t.content = content }
            if let description { t.description = description }
            if let priority { t.priority = priority }
            if let due { t.due = due }
            if let labels {
                var seen = Set<String>()
                t.labels = labels.filter { seen.insert($0.lowercased()).inserted }
            }
        }
    }

    func taskDetail(_ t: TodoTask) throws -> JSON {
        let builder = RowBuilder(store: store, now: now(), calendar: calendar, showCompleted: true, collapsedSections: [])
        let project = store.project(t.projectId)
        let section = t.sectionId.flatMap { sid in store.sections(in: t.projectId).first { $0.id == sid } }
        let parent = t.parentId.flatMap { store.task($0) }
        let subtasks = store.subtasks(of: t.id, includeCompleted: true)
        return [
            "id": .string(t.id), "content": .string(t.content), "description": .string(t.description),
            "priority": .int(t.priority.rawValue), "due": builder.dueJSON(t.due), "completed": .bool(t.isCompleted),
            "labels": .array(t.labels.map(builder.labelJSON)),
            "projectId": .string(t.projectId), "project": project.map { ["name": .string($0.name), "color": RowBuilder.projectColor($0)] } ?? .null,
            "sectionId": .string(t.sectionId), "section": .string(section?.name),
            "parentId": .string(t.parentId), "parent": parent.map { ["id": .string($0.id), "content": .string($0.content)] } ?? .null,
            "subtasks": .array(subtasks.map { s in
                ["id": .string(s.id), "content": .string(s.content), "completed": .bool(s.isCompleted),
                 "priority": .int(s.priority.rawValue)]
            }),
            "repeat": .string(t.recurrence.map(Recurrence.summary)),
        ]
    }

    /// Completes (with undo) or reopens a task, like the Mac app's `AppModel.toggleComplete`.
    func toggleComplete(_ t: TodoTask) throws -> JSON {
        if t.isCompleted {
            store.toggleComplete(t.id)
            return ["completed": false, "toast": .null]
        }
        if let rule = t.recurrence, Recurrence.advance(rule, from: t.due ?? DueDate(now(), calendar: calendar), calendar: calendar) != nil {
            store.toggleComplete(t.id, calendar: calendar)
            let restore: () -> Void = { [weak self] in
                self?.store.updateTask(t.id) { $0.due = t.due; $0.recurrence = t.recurrence }
            }
            let label = store.task(t.id)?.due?.displayString(now: now(), calendar: calendar) ?? "date set"
            return pushUndo("Next due \(label)", restore: restore, extra: ["completed": false])
        }
        let affected = ([t.id] + store.descendantIDs(of: t.id)).filter { store.task($0)?.isCompleted == false }
        store.toggleComplete(t.id, calendar: calendar)
        let restore: () -> Void = { [weak self] in
            guard let self else { return }
            self.store.performBatch {
                for id in affected { self.store.updateTask(id) { $0.isCompleted = false; $0.completedAt = nil } }
            }
        }
        let message = affected.count == 1 ? "1 task completed" : "\(affected.count) tasks completed"
        return pushUndo(message, restore: restore, extra: ["completed": true])
    }

    func deleteTask(_ t: TodoTask) -> JSON {
        let affected = [t.id] + store.descendantIDs(of: t.id)
        store.deleteTask(t.id)
        let restore: () -> Void = { [weak self] in
            guard let self else { return }
            self.store.performBatch {
                for id in affected { self.store.updateTask(id) { $0.deleted = false } }
            }
        }
        return pushUndo(affected.count == 1 ? "1 task deleted" : "\(affected.count) tasks deleted", restore: restore, extra: [:])
    }

    private func pushUndo(_ message: String, restore: @escaping () -> Void, extra: [String: JSON]) -> JSON {
        undoStack.append(UndoEntry(message: message, restore: restore))
        if undoStack.count > 50 { undoStack.removeFirst(undoStack.count - 50) }
        var result = extra
        result["toast"] = ["message": .string(message), "undo": true]
        return .object(result)
    }
}
