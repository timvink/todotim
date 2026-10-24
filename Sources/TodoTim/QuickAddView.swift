import SwiftUI
import TodoCore

/// Quick Add (`q` / ⌘N): one line with Todoist syntax, the parsed result shown as chips.
struct QuickAddView: View {
    @Environment(AppModel.self) private var model
    @Environment(TodoStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var details = ""
    @FocusState private var focused: Bool

    private struct Resolved {
        var parsed: ParsedTask
        var project: Project
        var section: TodoCore.Section?
        var unknownProject: String?
    }

    private func resolve() -> Resolved {
        let projects = model.allProjects
        let defaultProject = model.currentProjectID.flatMap { store.project($0) } ?? store.inbox
        let firstPass = QuickAddParser.parse(text, projectNames: projects.map(\.name))
        let project = firstPass.projectName.flatMap { name in
            projects.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        } ?? defaultProject
        let sections = store.sections(in: project.id)
        let parsed = QuickAddParser.parse(text, projectNames: projects.map(\.name), sectionNames: sections.map(\.name))
        let section = parsed.sectionName.flatMap { name in
            sections.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        }
        let unknown = parsed.projectName.flatMap { name in
            projects.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame } ? nil : name
        }
        return Resolved(parsed: parsed, project: project, section: section, unknownProject: unknown)
    }

    var body: some View {
        let r = resolve()
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .leading) {
                    // Token highlights drawn behind the (transparent) text field, like Todoist.
                    Text(highlighted(r))
                        .font(.system(size: 16, weight: .semibold))
                        .lineLimit(1)
                        .allowsHitTesting(false)
                    TextField("e.g. Buy milk tomorrow p1 @errands #Shopping", text: $text)
                        .textFieldStyle(.plain)
                        .font(.system(size: 16, weight: .semibold))
                        .focused($focused)
                        .onSubmit(add)
                }
                TextField("Description", text: $details, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .lineLimit(1...4)
                chips(r).padding(.top, 8)
            }
            .padding(16)
            Divider()
            HStack {
                HStack(spacing: 4) {
                    Image(systemName: r.project.isInbox ? "tray" : "number")
                        .foregroundStyle(r.project.isInbox ? Color(hex: 0x246FE0) : Palette.color(r.project.color))
                    Text(r.project.name)
                    if let s = r.section { Text("/ \(s.name)").foregroundStyle(.secondary) }
                }
                .font(.system(size: 12))
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(SoftButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Add task", action: add)
                    .buttonStyle(AccentButtonStyle())
                    .disabled(r.parsed.content.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(12)
        }
        .frame(width: 600)
        .onAppear { focused = true }
    }

    private func highlighted(_ r: Resolved) -> AttributedString {
        let tokens = QuickAddParser.tokens(in: text, projectNames: model.allProjects.map(\.name),
                                           sectionNames: store.sections(in: r.project.id).map(\.name))
        var out = AttributedString()
        var cursor = text.startIndex
        for t in tokens where t.range.lowerBound >= cursor {
            var plain = AttributedString(String(text[cursor..<t.range.lowerBound]))
            plain.foregroundColor = .clear
            out += plain
            var tok = AttributedString(String(text[t.range]))
            tok.foregroundColor = .clear
            tok.backgroundColor = Theme.accent.opacity(0.22)
            out += tok
            cursor = t.range.upperBound
        }
        var rest = AttributedString(String(text[cursor...]))
        rest.foregroundColor = .clear
        out += rest
        return out
    }

    @ViewBuilder private func chips(_ r: Resolved) -> some View {
        HStack(spacing: 8) {
            if let due = r.parsed.due {
                ChipLabel(icon: "calendar", text: due.displayString(), tint: due.chipColor)
            } else {
                ChipLabel(icon: "calendar", text: "Date")
            }
            if let p = r.parsed.priority, p != .p4 {
                ChipLabel(icon: "flag.fill", text: "P\(p.rawValue)", tint: p.color)
            } else {
                ChipLabel(icon: "flag", text: "Priority")
            }
            ForEach(r.parsed.labels, id: \.self) { l in
                ChipLabel(icon: "tag", text: l, tint: Theme.accent)
            }
            if let name = r.unknownProject {
                ChipLabel(icon: "exclamationmark.triangle", text: "No project “\(name)”", tint: Theme.tomorrow)
            }
            Spacer()
        }
    }

    private func add() {
        let r = resolve()
        let content = r.parsed.content.trimmingCharacters(in: .whitespaces)
        guard !content.isEmpty else { return }
        let t = store.addTask(content: content, projectId: r.project.id, sectionId: r.section?.id,
                              description: details.trimmingCharacters(in: .whitespacesAndNewlines),
                              priority: r.parsed.priority ?? .p4, due: r.parsed.due, labels: r.parsed.labels)
        dismiss()
        model.showToast("Task added to \(r.project.name)", undo: nil)
        if model.currentProjectID == r.project.id { model.selectedTaskID = t.id }
    }
}

struct ShortcutsHelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Keyboard shortcuts").font(.system(size: 16, weight: .bold))
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
            Divider()
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .top), GridItem(.flexible(), alignment: .top)],
                          alignment: .leading, spacing: 20) {
                    ForEach(ShortcutCatalog.groups, id: \.title) { group in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(group.title).font(.system(size: 13, weight: .bold))
                            ForEach(group.items) { item in
                                HStack {
                                    Text(item.action).font(.system(size: 12))
                                    Spacer()
                                    Text(item.keys)
                                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08)))
                                }
                            }
                        }
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 680, height: 560)
    }
}
