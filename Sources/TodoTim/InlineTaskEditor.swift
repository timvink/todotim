import SwiftUI
import TodoCore

/// Todoist's inline "Add task" box. Enter adds the task and keeps the editor open
/// for the next one; Esc or Cancel closes it. The title accepts quick-add syntax.
struct InlineTaskEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(TodoStore.self) private var store
    let depth: Int

    @State private var title = ""
    @State private var details = ""
    @State private var due: DueDate?
    @State private var priority: Priority = .p4
    @State private var labels: [String] = []
    @State private var projectId: EntityID = TodoStore.inboxID
    @State private var sectionId: EntityID?
    @State private var showDate = false
    @State private var showLabels = false
    @FocusState private var focus: Field?

    private enum Field { case title, details }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                TextField("Task name", text: $title)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .semibold))
                    .focused($focus, equals: .title)
                    .onSubmit(submit)
                TextField("Description", text: $details, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .lineLimit(1...6)
                    .focused($focus, equals: .details)
                HStack(spacing: 8) {
                    Button { showDate = true } label: {
                        ChipLabel(icon: "calendar", text: due?.displayString() ?? "Date", tint: due?.chipColor ?? .secondary)
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showDate, arrowEdge: .bottom) {
                        DueDatePicker(due: due) { due = $0; showDate = false }
                    }
                    PriorityMenu(priority: $priority)
                        .padding(.horizontal, 7).padding(.vertical, 4)
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.15)))
                    Button { showLabels = true } label: {
                        ChipLabel(icon: "tag", text: labels.isEmpty ? "Labels" : labels.joined(separator: ", "),
                                  tint: labels.isEmpty ? .secondary : Theme.accent)
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showLabels, arrowEdge: .bottom) {
                        LabelsPicker(selection: $labels).environment(store)
                    }
                }
                .padding(.top, 6)
            }
            .padding(10)
            Divider()
            HStack {
                if model.editor?.parentId == nil {
                    ProjectSectionMenu(projectId: projectId, sectionId: sectionId) { p, s in
                        projectId = p
                        sectionId = s
                    }
                }
                Spacer()
                Button("Cancel") { model.editor = nil }
                    .buttonStyle(SoftButtonStyle())
                Button("Add task", action: submit)
                    .buttonStyle(AccentButtonStyle())
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(8)
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(focus != nil ? 0.3 : 0.15)))
        .padding(.leading, CGFloat(depth) * Theme.indent + Theme.gutter)
        .padding(.vertical, 8)
        .onExitCommand { model.editor = nil }
        .onAppear {
            if let e = model.editor {
                projectId = e.projectId
                sectionId = e.sectionId
            }
            focus = .title
        }
    }

    private func submit() {
        let raw = title.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty, let target = model.editor else { return }
        let projectNames = model.allProjects.map(\.name)
        let parsed = QuickAddParser.parse(raw, projectNames: projectNames,
                                          sectionNames: store.sections(in: projectId).map(\.name))
        var pid = projectId, sid = sectionId
        if let name = parsed.projectName,
           let p = model.allProjects.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            pid = p.id
            sid = nil
        }
        if let name = parsed.sectionName,
           let s = store.sections(in: pid).first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            sid = s.id
        }
        let content = parsed.content.isEmpty ? raw : parsed.content
        let inPlace = pid == target.projectId && sid == target.sectionId
        let parentId = inPlace ? target.parentId : nil
        store.addTask(content: content, projectId: pid, sectionId: sid, parentId: parentId,
                      at: inPlace ? target.nextIndex : nil,
                      description: details.trimmingCharacters(in: .whitespacesAndNewlines),
                      priority: priority != .p4 ? priority : (parsed.priority ?? .p4),
                      due: due ?? parsed.due,
                      labels: Array(NSOrderedSet(array: labels + parsed.labels)) as? [String] ?? labels)
        if inPlace, let i = target.nextIndex { model.editor?.nextIndex = i + 1 }
        if !inPlace, let name = store.project(pid)?.name { model.showToast("Task added to \(name)", undo: nil) }
        title = ""
        details = ""
        due = nil
        priority = .p4
        labels = []
        focus = .title
    }
}
