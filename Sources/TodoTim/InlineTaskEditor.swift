import SwiftUI
import TodoCore

/// Todoist's inline "Add task" box. Enter adds the task and keeps the editor open
/// for the next one; Esc or Cancel closes it. The title accepts quick-add syntax.
struct InlineTaskEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(TodoStore.self) private var store
    let depth: Int

    @State private var showDate = false
    @State private var showLabels = false
    @FocusState private var focus: Field?

    private enum Field { case title, details }

    var body: some View {
        @Bindable var draft = model.editorDraft
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                TextField("", text: $draft.title)
                    .textFieldStyle(.plain)
                    .foregroundStyle(Theme.text)
                    .focused($focus, equals: .title)
                    .onSubmit(submit)
                    .fieldPrompt("Task name", show: draft.title.isEmpty)
                    .font(Fonts.bodySemibold)
                TextField("", text: $draft.details, axis: .vertical)
                    .textFieldStyle(.plain)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1...6)
                    .focused($focus, equals: .details)
                    .fieldPrompt("Description", show: draft.details.isEmpty)
                    .font(Fonts.body)
                HStack(spacing: 8) {
                    Button { showDate = true } label: {
                        ChipLabel(icon: "calendar", text: draft.due?.displayString() ?? "Date",
                                  tint: draft.due?.chipColor ?? Theme.secondaryText)
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showDate, arrowEdge: .bottom) {
                        DueDatePicker(due: draft.due) { draft.due = $0; showDate = false }
                    }
                    PriorityMenu(priority: $draft.priority)
                    Button { showLabels = true } label: {
                        ChipLabel(icon: "tag", text: draft.labels.isEmpty ? "Labels" : draft.labels.joined(separator: ", "),
                                  tint: draft.labels.isEmpty ? Theme.secondaryText : Theme.text)
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showLabels, arrowEdge: .bottom) {
                        LabelsPicker(selection: $draft.labels).environment(store)
                    }
                }
                .padding(.top, 8)
            }
            .padding(12)
            Hairline()
            HStack(spacing: 8) {
                if model.editor?.parentId == nil {
                    ProjectSectionMenu(projectId: draft.projectId, sectionId: draft.sectionId) { p, s in
                        draft.projectId = p
                        draft.sectionId = s
                    }
                }
                Spacer()
                Button("Cancel") { model.editor = nil }
                    .buttonStyle(SoftButtonStyle())
                Button("Add task", action: submit)
                    .buttonStyle(AccentButtonStyle())
                    .disabled(draft.title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            // The project menu's own 8 pt inset puts its icon under the title.
            .padding(.leading, 4).padding(.trailing, 8).padding(.vertical, 8)
        }
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous)
            .strokeBorder(focus != nil ? Theme.accent : Ctp.surface1.color, lineWidth: 1)
            .animation(Theme.hoverAnimation, value: focus != nil))
        .padding(.leading, CGFloat(depth) * Theme.indent + Theme.gutter)
        .padding(.vertical, 8)
        .onExitCommand { model.editor = nil }
        .onAppear { focus = .title }
    }

    private func submit() {
        let draft = model.editorDraft
        let projectId = draft.projectId, sectionId = draft.sectionId
        let priority = draft.priority, due = draft.due, labels = draft.labels
        let raw = draft.title.trimmingCharacters(in: .whitespaces)
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
                      description: draft.details.trimmingCharacters(in: .whitespacesAndNewlines),
                      priority: priority != .p4 ? priority : (parsed.priority ?? .p4),
                      due: due ?? parsed.due,
                      labels: Array(NSOrderedSet(array: labels + parsed.labels)) as? [String] ?? labels)
        if inPlace, let i = target.nextIndex { model.editor?.nextIndex = i + 1 }
        if !inPlace, let name = store.project(pid)?.name { model.showToast("Task added to \(name)", undo: nil) }
        draft.clearFields()
        focus = .title
    }
}
