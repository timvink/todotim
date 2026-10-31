import SwiftUI
import TodoCore

/// Quick Add (`q` / ⌘N): one line with Todoist syntax. While typing, each recognised token gets
/// a fill in the color of what it means: the date in its due color, a priority in its flag
/// color, `#Project` and `/Section` in the project's color, `@label` in the label's color.
struct QuickAddView: View {
    @Environment(AppModel.self) private var model
    @Environment(TodoStore.self) private var store
    @State private var text = ""
    @State private var details = ""
    /// Width of the input line. Token fills are only drawn while the text fits: a longer line
    /// scrolls inside the field, and the fills would no longer sit behind their tokens.
    @State private var inputWidth: CGFloat = 0
    @FocusState private var focused: Bool

    private struct Resolved {
        var parsed: ParsedTask
        var project: Project
        var section: TodoCore.Section?
        var unknownProject: String?
        var unknownSection: String?
        /// The line with each token marked by its fill (drawn by `TokenFillRenderer`).
        var highlighted: Text
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
        func findSection(_ name: String?) -> TodoCore.Section? {
            name.flatMap { n in sections.first { $0.name.caseInsensitiveCompare(n) == .orderedSame } }
        }
        let section = findSection(parsed.sectionName)
        let unknownProject = parsed.projectName.flatMap { find($0) == nil ? $0 : nil }
        let unknownSection = parsed.sectionName.flatMap { section == nil ? $0 : nil }

        // Each token in the color of its meaning; a project or section that does not exist
        // takes the warning yellow of the note below the field.
        let tokens = QuickAddParser.tokens(in: text, projectNames: projectNames, sectionNames: sections.map(\.name))
        let labels = store.labels
        let fills = tokens.map { token -> (range: Range<String.Index>, color: Color) in
            let value = String(text[token.range].dropFirst())
            let color: Color = switch token.kind {
            case .date: parsed.due?.chipColor ?? Ctp.overlay1.color
            case .priority: (Int(value).flatMap(Priority.init(rawValue:)) ?? .p4).color
            case .project: find(value).map(Self.color) ?? Theme.tomorrow
            case .section: findSection(value) == nil ? Theme.tomorrow : Self.color(project)
            // A new label is created with the default color.
            case .label: Palette.color(labels.first { $0.name == value }?.color ?? "charcoal")
            }
            return (token.range, color)
        }
        return Resolved(parsed: parsed, project: project, section: section, unknownProject: unknownProject,
                        unknownSection: unknownSection, highlighted: Self.highlighted(text, fills))
    }

    private static func color(_ project: Project) -> Color {
        project.isInbox ? Theme.inbox : Palette.color(project.color)
    }

    var body: some View {
        let r = current()
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                TextField("", text: $text)
                    .textFieldStyle(.plain)
                    .foregroundStyle(Theme.text)
                    .focused($focused)
                    .onSubmit(add)
                    // The fills are laid out by the same text in the same font, behind the
                    // field, which draws the text itself.
                    .background(alignment: .leading) {
                        r.highlighted
                            .lineLimit(1)
                            .fixedSize()
                            .textRenderer(TokenFillRenderer(maxWidth: inputWidth))
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                    .fieldPrompt("e.g. Buy milk tomorrow p1 @errands #Shopping", show: text.isEmpty)
                    .font(Fonts.quickAdd)
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { inputWidth = $0 }
                TextField("", text: $details, axis: .vertical)
                    .textFieldStyle(.plain)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1...4)
                    .fieldPrompt("Description", show: details.isEmpty)
                    .font(Fonts.body)
                warnings(r)
            }
            .padding(16)
            Hairline()
            footer(r)
        }
        .onAppear { focused = true }
    }

    /// The text as one `Text`, each token marked with its fill color.
    private static func highlighted(_ text: String, _ fills: [(range: Range<String.Index>, color: Color)]) -> Text {
        var pieces: [Text] = []
        var cursor = text.startIndex
        for (index, fill) in fills.enumerated() where fill.range.lowerBound >= cursor {
            pieces.append(Text(verbatim: String(text[cursor..<fill.range.lowerBound])))
            pieces.append(Text(verbatim: String(text[fill.range])).customAttribute(TokenFill(index: index, color: fill.color)))
            cursor = fill.range.upperBound
        }
        pieces.append(Text(verbatim: String(text[cursor...])))
        var line = LocalizedStringKey.StringInterpolation(literalCapacity: 0, interpolationCount: pieces.count)
        for piece in pieces { line.appendInterpolation(piece) }
        return Text(LocalizedStringKey(stringInterpolation: line))
    }

    /// What the line refers to that does not exist, in the warning yellow.
    @ViewBuilder private func warnings(_ r: Resolved) -> some View {
        if r.unknownProject != nil || r.unknownSection != nil {
            HStack(spacing: 8) {
                if let name = r.unknownProject {
                    ChipLabel(icon: "exclamationmark.triangle", text: "No project “\(name)”", tint: Theme.tomorrow)
                }
                if let name = r.unknownSection {
                    ChipLabel(icon: "exclamationmark.triangle", text: "No section “\(name)” in \(r.project.name)",
                              tint: Theme.tomorrow)
                }
            }
            .padding(.top, 4)
        }
    }

    /// Where the task goes, and the one button (Esc and a click outside close Quick Add).
    private func footer(_ r: Resolved) -> some View {
        HStack(spacing: 6) {
            ProjectIcon(r.project)
            HStack(spacing: 4) {
                Text(r.project.name).foregroundStyle(Theme.text)
                if let s = r.section { Text("/ \(s.name)").foregroundStyle(Theme.secondaryText) }
            }
            Spacer(minLength: 12)
            Button("Add ⏎", action: add)
                .buttonStyle(AccentButtonStyle())
                .disabled(r.parsed.content.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .font(Fonts.body)
        .lineLimit(1)
        .padding(.horizontal, 16)
        .frame(height: 40)
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

/// Marks a token in Quick Add's highlight text. `index` keeps the runs of one token together.
private struct TokenFill: TextAttribute {
    let index: Int
    let color: Color
}

/// Draws only the fills behind tokens: an 18 % fill of the token's color, radius 4.
private struct TokenFillRenderer: TextRenderer {
    /// Nothing is drawn when the line is wider than this (the field then scrolls its text).
    var maxWidth: CGFloat
    /// Horizontal room around the token; small enough that the fills of two tokens one space
    /// apart do not touch.
    private static let outset: CGFloat = 1

    var displayPadding: EdgeInsets {
        EdgeInsets(top: 0, leading: Self.outset, bottom: 0, trailing: Self.outset)
    }

    func draw(layout: Text.Layout, in ctx: inout GraphicsContext) {
        // A few points of slack for the caret after the last character, which also scrolls.
        guard layout.count == 1, let line = layout.first,
              line.typographicBounds.width + 4 <= maxWidth else { return }
        var shapes: [(fill: TokenFill, rect: CGRect)] = []
        for run in line {
            guard let fill = run[TokenFill.self] else { continue }
            let rect = run.typographicBounds.rect
            if let last = shapes.last, last.fill.index == fill.index {
                shapes[shapes.count - 1].rect = last.rect.union(rect)
            } else {
                shapes.append((fill, rect))
            }
        }
        for shape in shapes {
            let path = RoundedRectangle(cornerRadius: 4, style: .continuous)
                .path(in: shape.rect.insetBy(dx: -Self.outset, dy: 0))
            ctx.fill(path, with: .color(shape.fill.color.opacity(0.18)))
        }
    }
}

struct ShortcutsHelpView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Keyboard shortcuts")
                    .font(Fonts.panelTitle)
                    .foregroundStyle(Theme.text)
                Spacer()
                Button { model.showShortcuts = false } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(QuietIconButtonStyle())
                .help("Close (Esc)")
            }
            .padding(.leading, 20).padding(.trailing, 12).padding(.vertical, 12)
            Hairline()
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 32, alignment: .top),
                                    GridItem(.flexible(), alignment: .top)],
                          alignment: .leading, spacing: 24) {
                    ForEach(ShortcutCatalog.groups, id: \.title) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(group.title)
                                .font(Fonts.bodySemibold)
                                .foregroundStyle(Theme.text)
                                .padding(.bottom, 2)
                            ForEach(group.items) { item in
                                HStack(spacing: 8) {
                                    Text(item.action)
                                        .font(Fonts.body)
                                        .foregroundStyle(Theme.text)
                                    Spacer(minLength: 8)
                                    Text(item.keys)
                                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                                        .foregroundStyle(Theme.secondaryText)
                                        .padding(.horizontal, 8).padding(.vertical, 3)
                                        .background(Capsule().fill(Theme.field))
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

/// An icon-only button that is quiet until hovered (the shortcuts list's close button).
private struct QuietIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        QuietIcon(configuration: configuration)
    }

    private struct QuietIcon: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(Fonts.icon)
                .foregroundStyle(hovering ? Theme.text : Theme.secondaryText)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(configuration.isPressed ? Theme.selection : hovering ? Theme.hover : .clear))
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .animation(Theme.hoverAnimation, value: hovering)
                .pointerStyle(.link)
        }
    }
}
