import SwiftUI
import TodoCore

/// Quick Add (`q` / ⌘N): one line with Todoist syntax, the parsed result shown as chips.
struct QuickAddView: View {
    @Environment(AppModel.self) private var model
    @Environment(TodoStore.self) private var store
    @State private var text = ""
    @State private var details = ""
    @FocusState private var focused: Bool

    private struct Resolved {
        var parsed: ParsedTask
        var project: Project
        var section: TodoCore.Section?
        var unknownProject: String?
        var highlighted: AttributedString
    }

    /// Parse result for the last text; a plain reference so filling it from `body` does not
    /// trigger another update. Parsing happens once per text change, not once per body.
    private final class Cache { var text: String?; var value: Resolved? }
    @State private var cache = Cache()

    private func current() -> Resolved {
        if cache.text == text, let v = cache.value { return v }
        let v = resolve(text)
        cache.text = text
        cache.value = v
        return v
    }

    /// Parses `text`. A second pass is only needed when "#Project" picks a project other than
    /// the default one, because "/Section" names depend on the project.
    private func resolve(_ text: String) -> Resolved {
        let projects = model.allProjects
        let projectNames = projects.map(\.name)
        let defaultProject = model.currentProjectID.flatMap { store.project($0) } ?? store.inbox
        func find(_ name: String?) -> Project? {
            name.flatMap { n in projects.first { $0.name.caseInsensitiveCompare(n) == .orderedSame } }
        }
        var project = defaultProject
        var sections = store.sections(in: project.id)
        var parsed = QuickAddParser.parse(text, projectNames: projectNames, sectionNames: sections.map(\.name))
        if let p = find(parsed.projectName), p.id != project.id {
            project = p
            sections = store.sections(in: p.id)
            parsed = QuickAddParser.parse(text, projectNames: projectNames, sectionNames: sections.map(\.name))
        }
        let section = parsed.sectionName.flatMap { name in
            sections.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        }
        let unknown = parsed.projectName.flatMap { find($0) == nil ? $0 : nil }
        let tokens = QuickAddParser.tokens(in: text, projectNames: projectNames, sectionNames: sections.map(\.name))
        return Resolved(parsed: parsed, project: project, section: section, unknownProject: unknown,
                        highlighted: Self.highlighted(text, tokens))
    }

    var body: some View {
        let r = current()
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .leading) {
                    // Token highlights drawn behind the (transparent) text field, like Todoist.
                    Text(r.highlighted)
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
                Button("Cancel") { model.showQuickAdd = false }
                    .buttonStyle(SoftButtonStyle())
                Button("Add task", action: add)
                    .buttonStyle(AccentButtonStyle())
                    .disabled(r.parsed.content.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(12)
        }
        .onAppear { focused = true }
    }

    private static func highlighted(_ text: String, _ tokens: [ParsedToken]) -> AttributedString {
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
        let r = current()
        let content = r.parsed.content.trimmingCharacters(in: .whitespaces)
        guard !content.isEmpty else { return }
        let t = store.addTask(content: content, projectId: r.project.id, sectionId: r.section?.id,
                              description: details.trimmingCharacters(in: .whitespacesAndNewlines),
                              priority: r.parsed.priority ?? .p4, due: r.parsed.due, labels: r.parsed.labels)
        model.showQuickAdd = false
        model.showToast("Task added to \(r.project.name)", undo: nil)
        if model.currentProjectID == r.project.id { model.selectedTaskID = t.id }
    }
}

struct ShortcutsHelpView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Keyboard shortcuts").font(.system(size: 16, weight: .bold))
                Spacer()
                Button { model.showShortcuts = false } label: {
                    Image(systemName: "xmark").frame(width: 26, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(HoverButtonStyle())
                .help("Close (Esc)")
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
    }
}
