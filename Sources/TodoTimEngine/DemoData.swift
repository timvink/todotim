import Foundation
import TodoCore

/// The README screenshot's demo data (as the Mac app's `TODOTIM_SEED=1` and the Android debug
/// app's `DemoActivity`), for `todotim-engine --seed-demo` with an empty database.
@MainActor
enum DemoData {
    static func seed(_ store: TodoStore, now: Date = Date(), calendar: Calendar = .current) {
        let inbox = TodoStore.inboxID
        func day(_ n: Int) -> DueDate { DueDate(calendar.date(byAdding: .day, value: n, to: now)!, calendar: calendar) }
        let weekend = DateParser.parse("this weekend", now: now, calendar: calendar) ?? day(0)

        let groceries = store.addTask(content: "Buy groceries", projectId: inbox, due: day(0), labels: ["errands"])
        store.addTask(content: "Milk", projectId: inbox, parentId: groceries.id)
        store.addTask(content: "Bread", projectId: inbox, parentId: groceries.id)
        let eggs = store.addTask(content: "Eggs", projectId: inbox, parentId: groceries.id)
        store.toggleComplete(eggs.id)
        store.addTask(content: "Call the dentist", projectId: inbox,
                      description: "Ask about the appointment on Thursday\nBring insurance card", priority: .p1, due: day(-1))
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
        store.addTask(content: "Rake leaves", projectId: home.id, sectionId: garden.id, due: weekend)

        let side = store.addProject(name: "Side project", color: "grape")
        store.addTask(content: "Sketch app icon", projectId: side.id, labels: ["design"])
        store.addProject(name: "Reading list", color: "orange")
    }
}
