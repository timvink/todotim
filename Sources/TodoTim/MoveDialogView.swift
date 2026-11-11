import AppKit
import SwiftUI
import TodoCore

/// The open move dialog (`m` / `v`): what is moved, the query, its ranked targets and the
/// highlighted row. Owned by `AppModel` while the dialog shows; `KeyRouter` steps the highlight.
@MainActor
@Observable
final class MoveDialogState {
    /// The tasks to move, in list order.
    let taskIDs: [EntityID]
    var query = ""
    private(set) var targets: [MoveTarget] = []
    /// Index into `targets`.
    private(set) var highlight = 0
    /// Bumped when the keyboard moves the highlight, so the list scrolls it into view (hover
    /// never scrolls).
    private(set) var scrollRequest = 0
    /// The query words, for marking matches in titles.
    private(set) var words: [String] = []
    /// Where the mouse was when the highlight last followed it: rows that slide under a still
    /// pointer while the list scrolls must not take the highlight.
    @ObservationIgnored private var lastMouse = NSEvent.mouseLocation
    @ObservationIgnored private var computedQuery: String?
    @ObservationIgnored private var computedVersion = -1

    init(taskIDs: [EntityID]) { self.taskIDs = taskIDs }

    /// Recomputes the targets when the query or any project, section or task changed. The highlight goes
    /// to the first row that is not where the task already is.
    func refresh(_ store: TodoStore) {
        let version = store.nameVersion &+ store.structureVersion
        guard computedQuery != query || computedVersion != version else { return }
        let queryChanged = computedQuery != query
        computedQuery = query
        computedVersion = version
        let previous = targets.indices.contains(highlight) ? targets[highlight].id : nil
        targets = store.moveTargets(for: taskIDs, query: query)
        words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        if !queryChanged, let previous, let i = targets.firstIndex(where: { $0.id == previous }) {
            highlight = i
        } else {
            highlight = targets.firstIndex { !$0.isCurrent } ?? 0
            scrollRequest += 1
        }
    }

    var highlighted: MoveTarget? { targets.indices.contains(highlight) ? targets[highlight] : nil }

    /// ↓ / ↑ (and ⌃J / ⌃K): the next or previous row, stopping at the ends.
    func step(_ delta: Int) {
        guard !targets.isEmpty else { return }
        let next = max(0, min(targets.count - 1, highlight + delta))
        if next != highlight { highlight = next }
        scrollRequest += 1
    }

    /// The pointer is over row `index`: highlight it, unless only the list moved under it.
    func hover(_ index: Int) {
        let mouse = NSEvent.mouseLocation
        guard mouse != lastMouse else { return }
        lastMouse = mouse
        if highlight != index, targets.indices.contains(index) { highlight = index }
    }
}

/// The move dialog: a field, then sections, projects and tasks to move the task to, grouped and
/// ranked by `TodoStore.moveTargets`. Shown by `ModalLayer`, like Quick Add.
struct MoveDialogView: View {
    @Environment(AppModel.self) private var model
    @Environment(TodoStore.self) private var store
    @Bindable var state: MoveDialogState
    @FocusState private var focused: Bool

    static let rowHeight: CGFloat = 32
    static let headerHeight: CGFloat = 28
    static let listPadding: CGFloat = 6
    /// About nine and a half rows: a cut-off row shows that the list scrolls.
    static let maxListHeight: CGFloat = 320

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                subject
                TextField("", text: $state.query)
                    .textFieldStyle(.plain)
                    .foregroundStyle(Theme.text)
                    .focused($focused)
                    .onSubmit { model.performMove(state.highlighted) }
                    .fieldPrompt("Move to a section, project or task…", show: state.query.isEmpty)
                    .font(Fonts.quickAdd)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 14)
            Hairline()
            list
            Hairline()
            footer
        }
        .onAppear {
            state.refresh(store)
            focused = true
        }
        .onChange(of: state.query) { state.refresh(store) }
        .onChange(of: store.structureVersion) { state.refresh(store) }
        .onChange(of: store.nameVersion) { state.refresh(store) }
    }

    /// What is moved: "Move “Title”" or "Move 3 tasks".
    private var subject: some View {
        HStack(spacing: 4) {
            Text("Move").foregroundStyle(Theme.secondaryText)
            if state.taskIDs.count == 1, let t = store.task(state.taskIDs[0]) {
                Text("“\(t.content)”").foregroundStyle(Theme.text).truncationMode(.middle)
            } else {
                Text("\(state.taskIDs.count) tasks").foregroundStyle(Theme.text)
            }
        }
        .font(Fonts.meta)
        .lineLimit(1)
    }

    // MARK: List

    private struct Entry: Identifiable {
        enum Kind { case header(MoveTarget.Group, String), row(Int) }
        let kind: Kind
        let id: String
    }

    /// Rows with a header before each group.
    private func entries(_ targets: [MoveTarget]) -> [Entry] {
        var out: [Entry] = []
        out.reserveCapacity(targets.count + 4)
        var group: MoveTarget.Group?
        for (i, t) in targets.enumerated() {
            if t.group != group {
                group = t.group
                out.append(Entry(kind: .header(t.group, title(of: t.group, first: t)), id: "h\(t.group.rawValue)"))
            }
            out.append(Entry(kind: .row(i), id: t.id))
        }
        return out
    }

    private func title(of group: MoveTarget.Group, first: MoveTarget) -> String {
        switch group {
        case .currentProject: "In \(first.projectName)"
        case .sections: "Sections"
        case .projects: "Projects"
        case .tasks: "Tasks"
        }
    }

    @ViewBuilder private var list: some View {
        let targets = state.targets
        if targets.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(Fonts.icon).frame(width: MoveRow.iconColumn)
                Text("No matches for “\(state.query.trimmingCharacters(in: .whitespaces))”")
                    .lineLimit(1).truncationMode(.middle)
            }
            .font(Fonts.body)
            .foregroundStyle(Theme.secondaryText)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: Self.rowHeight + 2 * Self.listPadding, alignment: .leading)
        } else {
            let entries = entries(targets)
            let headers = entries.count - targets.count
            let height = CGFloat(targets.count) * Self.rowHeight + CGFloat(headers) * Self.headerHeight
                - (Self.headerHeight - MoveGroupHeader.firstHeight) + 2 * Self.listPadding
            // In the empty-query list, the project's sections sit under it.
            let nested = targets.first.map { $0.kind == .project && $0.group == .currentProject } ?? false
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { n, entry in
                            switch entry.kind {
                            case .header(_, let title):
                                MoveGroupHeader(title: title, first: n == 0).id(entry.id)
                            case .row(let i):
                                let t = targets[i]
                                MoveRow(target: t, words: state.words, highlighted: i == state.highlight,
                                        indent: nested && t.group == .currentProject && t.kind == .section,
                                        showsContext: t.group != .currentProject)
                                    .id(entry.id)
                                    .onContinuousHover { phase in
                                        if case .active = phase { state.hover(i) }
                                    }
                                    .onTapGesture { model.performMove(t) }
                            }
                        }
                    }
                    .padding(.vertical, Self.listPadding)
                }
                .scrollIndicators(.automatic)
                .frame(height: min(height, Self.maxListHeight))
                .onChange(of: state.scrollRequest) {
                    scrollToHighlight(proxy, entries: entries)
                }
            }
        }
    }

    /// Keeps the highlighted row in view. The first row of a group brings its header along, and
    /// the first row of the list scrolls to the very top.
    private func scrollToHighlight(_ proxy: ScrollViewProxy, entries: [Entry]) {
        guard let row = state.highlighted else { return }
        guard let n = entries.firstIndex(where: { $0.id == row.id }) else { return }
        if n <= 1 {
            proxy.scrollTo(entries[0].id, anchor: .top)
        } else if case .header = entries[n - 1].kind {
            proxy.scrollTo(entries[n - 1].id)
            proxy.scrollTo(row.id)
        } else {
            proxy.scrollTo(row.id)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 16) {
            hint("↑ ↓", "Choose")
            hint("↩", "Move")
            hint("esc", "Close")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(height: 36)
    }

    private func hint(_ keys: String, _ action: String) -> some View {
        HStack(spacing: 6) {
            Text(keys)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.secondaryText)
                .padding(.horizontal, 6)
                .frame(height: 18)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Theme.field))
            Text(action).font(Fonts.small).foregroundStyle(Theme.tertiaryText)
        }
    }
}

/// A group's title above its rows, like the sidebar's headings.
private struct MoveGroupHeader: View {
    let title: String
    let first: Bool
    /// The first header sits closer to the field's rule.
    static let firstHeight: CGFloat = 22

    var body: some View {
        Text(title.uppercased())
            .font(Fonts.sidebarHeading)
            .tracking(0.6)
            .foregroundStyle(Theme.tertiaryText)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 16)
            .padding(.bottom, 6)
            .frame(maxWidth: .infinity, minHeight: first ? Self.firstHeight : MoveDialogView.headerHeight,
                   maxHeight: first ? Self.firstHeight : MoveDialogView.headerHeight, alignment: .bottomLeading)
            .accessibilityAddTraits(.isHeader)
    }
}

/// One target: its icon, the title with the query's words marked, and where it is.
private struct MoveRow: View {
    let target: MoveTarget
    let words: [String]
    let highlighted: Bool
    /// A section under its project (the empty-query list).
    let indent: Bool
    /// The trailing "Project / Section"; left out in the current project's group, whose header
    /// names the project.
    let showsContext: Bool

    static let iconColumn: CGFloat = 20

    var body: some View {
        HStack(spacing: 8) {
            icon.frame(width: Self.iconColumn)
            TitleContextLayout {
                Text(Self.marked(target.title, words: words))
                    .font(Fonts.body)
                    .foregroundStyle(target.isCurrent ? Theme.secondaryText : Theme.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                trailing
            }
        }
        .padding(.leading, 8 + (indent ? Self.iconColumn + 8 : 0))
        .padding(.trailing, 10)
        .frame(height: MoveDialogView.rowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
            .fill(highlighted ? Theme.selection : .clear))
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .pointerStyle(.link)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(highlighted ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder private var icon: some View {
        switch target.kind {
        case .project:
            ProjectIcon(colorKey: target.projectColor, isInbox: target.projectIsInbox)
        case .section:
            Image(systemName: "rectangle.split.1x2")
                .font(.system(size: 13))
                .foregroundStyle(Theme.tertiaryText)
        case .task:
            Circle()
                .strokeBorder(Theme.tertiaryText, lineWidth: 1.25)
                .frame(width: 12, height: 12)
        }
    }

    /// Where the target is ("● Work / Planning"), or "✓ Current" for where the task already is.
    @ViewBuilder private var trailing: some View {
        if target.isCurrent {
            HStack(spacing: 4) {
                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                Text("Current")
            }
            .font(Fonts.meta)
            .foregroundStyle(Theme.accent)
        } else if showsContext, target.kind != .project {
            HStack(spacing: 5) {
                if target.kind == .section { Text("in").foregroundStyle(Theme.tertiaryText) }
                ContextDot(colorKey: target.projectColor, isInbox: target.projectIsInbox)
                Text(context).foregroundStyle(Theme.secondaryText).lineLimit(1).truncationMode(.tail)
            }
            .font(Fonts.small)
        }
    }

    private var context: String {
        if target.kind == .task, let s = target.sectionName { return "\(target.projectName) / \(s)" }
        return target.projectName
    }

    /// `title` with each occurrence of a query word in semibold accent.
    static func marked(_ title: String, words: [String]) -> AttributedString {
        var s = AttributedString(title)
        guard !words.isEmpty else { return s }
        for word in words {
            var start = s.startIndex
            while start < s.endIndex, let r = s[start...].range(of: word, options: .caseInsensitive) {
                s[r].font = Fonts.bodySemibold
                s[r].foregroundColor = Theme.accent
                guard r.upperBound > start else { break }
                start = r.upperBound
            }
        }
        return s
    }
}

/// The project's color as a 6 pt dot (a small tray for the inbox), before a context name.
private struct ContextDot: View {
    let colorKey: String
    let isInbox: Bool
    var body: some View {
        if isInbox {
            Image(systemName: "tray").font(.system(size: 9, weight: .medium)).foregroundStyle(Theme.inbox)
        } else {
            Circle().fill(Palette.color(colorKey)).frame(width: 6, height: 6)
        }
    }
}

/// A title and its trailing context on one line: the context gets its width up to 45 % of the
/// row, the title the rest, and each truncates in its own space.
private struct TitleContextLayout: Layout {
    var spacing: CGFloat = 12

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? subviews.reduce(0) { $0 + $1.sizeThatFits(.unspecified).width } + spacing
        let height = subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let title = subviews.first else { return }
        guard subviews.count > 1 else {
            title.place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading,
                        proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
            return
        }
        let context = subviews[1]
        let contextIdeal = context.sizeThatFits(.unspecified).width
        let contextWidth = contextIdeal > 0 ? min(contextIdeal, bounds.width * 0.45) : 0
        let titleWidth = max(0, bounds.width - contextWidth - (contextWidth > 0 ? spacing : 0))
        title.place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading,
                    proposal: ProposedViewSize(width: titleWidth, height: bounds.height))
        context.place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing,
                      proposal: ProposedViewSize(width: contextWidth, height: bounds.height))
    }
}
