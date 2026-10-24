import Foundation
import TodoCore

/// Sample content for `TODOTIM_SEED=1` (development and screenshots only) and
/// `TODOTIM_SEED=large` (performance testing).
@MainActor
enum SampleData {
    static func seed(_ store: TodoStore) {
        let inbox = TodoStore.inboxID
        let day = { (n: Int) in DueDate.offset(days: n) }

        let groceries = store.addTask(content: "Buy groceries", projectId: inbox, due: day(0), labels: ["errands"])
        store.addTask(content: "Milk", projectId: inbox, parentId: groceries.id)
        store.addTask(content: "Bread", projectId: inbox, parentId: groceries.id)
        let eggs = store.addTask(content: "Eggs", projectId: inbox, parentId: groceries.id)
        store.toggleComplete(eggs.id)
        store.addTask(content: "Call the dentist", projectId: inbox, description: "Ask about the appointment on Thursday\nBring insurance card",
                      priority: .p1, due: day(-1))
        store.addTask(content: "Read 'The Pragmatic Programmer'", projectId: inbox, priority: .p3, labels: ["reading"])
        store.addTask(content: "Renew passport", projectId: inbox, priority: .p2, due: day(1))

        let work = store.addProject(name: "Work", color: "blue")
        store.addTask(content: "Prepare quarterly review", projectId: work.id, priority: .p1, due: day(3), labels: ["focus"])
        let planning = store.addSection(projectId: work.id, name: "Planning")
        let roadmap = store.addTask(content: "Draft 2027 roadmap", projectId: work.id, sectionId: planning.id,
                                    description: "Collect input from the team first", priority: .p2, due: day(9))
        store.addTask(content: "Interview product owners", projectId: work.id, parentId: roadmap.id)
        store.addTask(content: "Write summary", projectId: work.id, parentId: roadmap.id, labels: ["focus"])
        store.addTask(content: "Book offsite venue", projectId: work.id, sectionId: planning.id, due: day(5))
        let ops = store.addSection(projectId: work.id, name: "Operations")
        store.addTask(content: "Rotate API keys", projectId: work.id, sectionId: ops.id, priority: .p1, due: day(-3))
        store.addTask(content: "Update on-call schedule", projectId: work.id, sectionId: ops.id, priority: .p3)

        let home = store.addProject(name: "Home", color: "green")
        store.addTask(content: "Fix the leaking tap", projectId: home.id, priority: .p2, labels: ["errands"])
        let garden = store.addSection(projectId: home.id, name: "Garden")
        store.addTask(content: "Plant tulip bulbs", projectId: home.id, sectionId: garden.id, due: day(2))
        store.addTask(content: "Rake leaves", projectId: home.id, sectionId: garden.id, due: DueDate.weekend)

        store.addProject(name: "Side project", color: "grape")
        _ = store.addTask(content: "Sketch app icon", projectId: store.projects.last!.id, labels: ["design"])
        store.addProject(name: "Reading list", color: "orange")
    }
}

extension SampleData {
    /// Heavy-user fixture for `TODOTIM_SEED=large` (performance testing): 5,000 tasks in the
    /// Inbox (1,000) and 50 projects with 3 sections each, ~20% subtasks, ~10% completed,
    /// 15 labels and a spread of due dates. Deterministic, built directly as a `Database`
    /// so seeding does not depend on per-insert store cost.
    static func seedLarge(_ store: TodoStore, taskCount: Int = 5_000, projectCount: Int = 50, inboxCount: Int = 1_000) {
        var rng = SplitMix64(seed: 42)
        var db = store.db
        let now = Date()
        let colors = Palette.entries.map(\.key)
        let labelNames = ["errands", "focus", "reading", "design", "home", "calls", "waiting", "someday",
                          "email", "quick", "deep-work", "review", "health", "finance", "travel"]
        for (i, name) in labelNames.enumerated() {
            let l = TodoCore.Label(name: name, color: colors[i % colors.count], order: Double(i + 1))
            db.labels[l.id] = l
        }
        var areas: [(projectId: EntityID, sectionId: EntityID?)] = []
        for p in 0..<projectCount {
            let project = Project(name: "Project \(p + 1)", color: colors[p % colors.count], order: Double(p + 1))
            db.projects[project.id] = project
            areas.append((project.id, nil))
            for s in 0..<3 {
                let section = TodoCore.Section(projectId: project.id, name: "Section \(s + 1)", order: Double(s + 1))
                db.sections[section.id] = section
                areas.append((project.id, section.id))
            }
        }
        let words = ["Review", "Write", "Call", "Plan", "Fix", "Buy", "Read", "Draft", "Send", "Update",
                     "Book", "Clean", "Prepare", "Check", "Organise", "Email", "Schedule", "Research"]
        let objects = ["report", "invoice", "the garden", "quarterly plan", "slides", "dentist", "groceries",
                       "API keys", "roadmap", "newsletter", "car service", "tax return", "team offsite", "budget"]
        var lastTopLevel: [String: TodoTask] = [:]
        var orderCounter: [String: Double] = [:]
        for i in 0..<taskCount {
            let inInbox = i < inboxCount
            let area = inInbox ? (projectId: TodoStore.inboxID, sectionId: nil) : areas[Int(rng.next() % UInt64(areas.count))]
            let areaKey = area.projectId + "/" + (area.sectionId ?? "")
            var parent: TodoTask?
            if let last = lastTopLevel[areaKey], rng.next() % 5 == 0 { parent = last }
            let siblingKey = parent?.id ?? areaKey
            let order = (orderCounter[siblingKey] ?? 0) + 1
            orderCounter[siblingKey] = order
            let r = rng.next()
            let due: DueDate? = r % 3 == 0 ? DueDate.offset(days: Int(r % 40) - 10) : nil
            var labels: [String] = []
            if r % 4 == 0 { labels.append(labelNames[Int(r / 7 % UInt64(labelNames.count))]) }
            if r % 11 == 0 { labels.append(labelNames[Int(r / 13 % UInt64(labelNames.count))]) }
            let completed = rng.next() % 10 == 0
            let description = r % 6 == 0 ? "Notes for task \(i)\nSecond line with more detail" : ""
            let t = TodoTask(projectId: area.projectId, sectionId: area.sectionId, parentId: parent?.id,
                             content: "\(words[i % words.count]) \(objects[(i / words.count) % objects.count]) #\(i)",
                             description: description, priority: Priority(rawValue: Int(r % 4) + 1) ?? .p4,
                             due: due, labels: Array(Set(labels)).sorted(), isCompleted: completed,
                             completedAt: completed ? now : nil, order: order,
                             createdAt: now.addingTimeInterval(Double(i)), updatedAt: now)
            db.tasks[t.id] = t
            if parent == nil { lastTopLevel[areaKey] = t }
        }
        store.replaceDatabase(db)
    }
}

/// Small deterministic PRNG for fixtures.
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
