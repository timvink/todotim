import QuartzCore
import SwiftUI
import TodoCore

/// Main pane for a project (or the Inbox): its title pinned at the top, unsectioned tasks, then
/// sections.
struct ProjectView: View {
    @Environment(AppModel.self) private var model
    @Environment(TodoStore.self) private var store
    let projectId: EntityID

    var body: some View {
        // Rebuilt only when structure, sections, parents' collapsed state or view inputs change;
        // never on selection changes (rows observe the selection themselves).
        let name = store.project(projectId)?.name ?? ""
        TaskListView(items: model.display().items) {
            ProjectTitle(projectId: projectId)
        }
        .navigationTitle(name)
    }
}

/// Renders a flattened `DisplayItem` list in one `LazyVStack`, so only rows near the viewport
/// are built, under a title bar pinned in the band beside the window buttons. Shared by project,
/// label and search views.
struct TaskListView<Header: View>: View {
    @Environment(AppModel.self) private var model
    let items: [DisplayItem]
    var topPadding: CGFloat = 4
    @ViewBuilder let header: Header
    @State private var visible = VisibleRows()
    @State private var scrolled = false

    var body: some View {
        // Reads the drag state here only, so a drag invalidates this body (an O(rows) pass)
        // but not the rows.
        let drag = model.drag
        let dragging = drag.draggingID
        let gap = Self.gap(in: items, target: dragging == nil || drag.inPanel ? nil : drag.target)
        VStack(spacing: 0) {
            ListTitleBar(scrolled: scrolled) { header }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(items) { item in
                            VStack(alignment: .leading, spacing: 0) {
                                let open = gap != nil && gap?.beforeID == item.id
                                DropSlot(open: open, depth: gap?.depth ?? 0, height: drag.rowHeight)
                                DisplayItemView(item: item)
                                    .opacity(dragging != nil && item.id == dragging ? 0.45 : 1)
                            }
                        }
                        DropSlot(open: gap != nil && gap?.beforeID == nil, depth: gap?.depth ?? 0, height: drag.rowHeight)
                    }
                    .scrollTargetLayout()
                    .frame(maxWidth: Theme.contentMaxWidth, alignment: .leading)
                    .padding(.horizontal, Theme.contentPadding)
                    .padding(.top, topPadding)
                    .padding(.bottom, 80)
                    .frame(maxWidth: .infinity)
                }
                .onScrollGeometryChange(for: Bool.self) { geo in
                    geo.contentOffset.y + geo.contentInsets.top > 1
                } action: { _, isScrolled in
                    scrolled = isScrolled
                }
                .onScrollTargetVisibilityChange(idType: String.self, threshold: 0.9) { ids in
                    visible.ids = Set(ids)
                }
                .background { SelectionScroller(proxy: proxy, visible: visible) }
            }
        }
        // The title bar takes the band beside the window buttons instead of a toolbar.
        .ignoresSafeArea(.container, edges: .top)
        .onAppear { Perf.firstListAppeared() }
    }
}

/// The band at the top of the list, level with the window buttons: the page title on the task
/// column's grid, and a hairline once the list scrolls under it.
struct ListTitleBar<Content: View>: View {
    @Environment(AppModel.self) private var model
    let scrolled: Bool
    @ViewBuilder let content: Content
    @State private var width: CGFloat = 0

    var body: some View {
        let sidebarHidden = model.columnVisibility == .detailOnly
        content
            .padding(.leading, Theme.gutter + Theme.rowInset + (sidebarHidden ? buttonsOverlap : 0))
            .frame(maxWidth: Theme.contentMaxWidth, alignment: .leading)
            .padding(.horizontal, Theme.contentPadding)
            .frame(maxWidth: .infinity)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
            .frame(height: Theme.titleBarHeight)
            .overlay(alignment: .topLeading) {
                if sidebarHidden {
                    // Level with the window buttons, just after them.
                    Button { withAnimation(Theme.motion) { model.columnVisibility = .all } } label: {
                        Image(systemName: "sidebar.left")
                            .font(Fonts.icon)
                            .foregroundStyle(Theme.tertiaryText)
                            .frame(width: 28, height: 26)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Show sidebar (⌃⌘S)")
                    .padding(.leading, 74)
                }
            }
        .overlay(alignment: .bottom) {
            Hairline().opacity(scrolled ? 1 : 0).animation(Theme.hoverAnimation, value: scrolled)
        }
    }

    /// How far the title must move right to clear the window buttons and the sidebar button when
    /// the sidebar is hidden; zero unless the window is narrow (the column is centered).
    private var buttonsOverlap: CGFloat {
        let column = min(width, Theme.contentMaxWidth + 2 * Theme.contentPadding)
        let titleX = (width - column) / 2 + Theme.contentPadding + Theme.gutter + Theme.rowInset
        return max(0, 112 - titleX)
    }
}

/// A project's pinned title with its "…" menu; also a drop target for the top of the list.
private struct ProjectTitle: View {
    @Environment(AppModel.self) private var model
    @Environment(TodoStore.self) private var store
    let projectId: EntityID

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(store.project(projectId)?.name ?? "")
                .font(Fonts.pageTitle)
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            Spacer(minLength: 12)
            moreMenu
        }
        .contentShape(Rectangle())
        .onDrop(of: [.text], delegate: FixedDropDelegate(model: model, target: .sectionStart(projectId: projectId, sectionId: nil)))
    }

    private var moreMenu: some View {
        Menu {
            Toggle("Show completed tasks", isOn: Binding(
                get: { model.showsCompleted(projectId) },
                set: { on in
                    if on { model.showCompletedProjects.insert(projectId) }
                    else { model.showCompletedProjects.remove(projectId) }
                }))
            Button("Add section") { model.sectionEditor = SectionEditorTarget(projectId: projectId, index: nil) }
        } label: {
            Image(systemName: "ellipsis")
                .font(Fonts.icon)
                .frame(width: 28, height: 24)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .tint(Theme.tertiaryText)
        .fixedSize()
        .pointerStyle(.link)
        .help("More actions")
    }
}

/// Fully visible row ids and the last scroll time. A plain reference so that scrolling does not
/// invalidate any view.
final class VisibleRows {
    var ids: Set<String> = []
    var lastScroll: CFTimeInterval = 0
}

/// Keeps the selected row on screen. Lives in its own view so that only this tiny body depends on
/// the selection, not the list.
private struct SelectionScroller: View {
    @Environment(AppModel.self) private var model
    let proxy: ScrollViewProxy
    let visible: VisibleRows

    var body: some View {
        Color.clear
            .onChange(of: model.selectedTaskID) { _, id in
                guard let id, !visible.ids.contains(id) else { return }
                let now = CACurrentMediaTime()
                // While a key is held, jump without animation instead of restarting one per press.
                let repeating = now - visible.lastScroll < 0.25
                visible.lastScroll = now
                if repeating {
                    proxy.scrollTo(id)
                } else {
                    withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id) }
                }
            }
    }
}

private struct DisplayItemView: View {
    @Environment(AppModel.self) private var model
    let item: DisplayItem

    var body: some View {
        switch item {
        case .emptyState(let pid):
            EmptyStateView(projectId: pid)
        case .task(let r):
            TaskRowHost(item: r).equatable()
        case .editor(let depth):
            InlineTaskEditor(depth: depth)
        case .addTask(let pid, let sid):
            AddTaskRow {
                model.selectedTaskID = nil
                model.editor = EditorTarget(projectId: pid, sectionId: sid)
            }
            .onDrop(of: [.text], delegate: FixedDropDelegate(model: model, target: .sectionEnd(projectId: pid, sectionId: sid)))
        case .sectionGap(let pid, let index):
            AddSectionGap(projectId: pid, index: index)
        case .sectionHeader(let section, let count, let collapsed):
            SectionHeaderView(section: section, count: count, collapsed: collapsed)
        case .groupHeader(let pid, let count):
            GroupHeaderView(projectId: pid, count: count)
        case .message(let text):
            Text(text)
                .font(Fonts.body)
                .foregroundStyle(Theme.tertiaryText)
                .padding(.leading, Theme.gutter + Theme.rowInset)
                .padding(.vertical, 8)
        }
    }
}

/// A project without open tasks: a quiet line, or a small celebration when tasks were done today.
private struct EmptyStateView: View {
    @Environment(TodoStore.self) private var store
    let projectId: EntityID

    var body: some View {
        let done = doneToday
        Text(done > 0 ? "All clear — \(done) done today" : "Nothing here yet — press Q to add a task")
            .font(.system(size: 15, weight: .medium, design: .rounded))
            .foregroundStyle(done > 0 ? Theme.today : Theme.tertiaryText)
            .padding(.leading, Theme.gutter + Theme.rowInset)
            .padding(.top, 10).padding(.bottom, 14)
    }

    /// Only computed while the project is empty.
    private var doneToday: Int {
        let start = Calendar.current.startOfDay(for: Date())
        return store.db.tasks.values.reduce(0) { n, t in
            n + (t.projectId == projectId && !t.deleted && t.isCompleted && (t.completedAt ?? .distantPast) >= start ? 1 : 0)
        }
    }
}

struct AddTaskRow: View {
    var title = "Add task"
    /// Where the row's pill starts; the list's rows start after the chevron gutter.
    var leading: CGFloat = Theme.gutter
    /// Width of the column the plus is centered in (the checkbox column it lines up with).
    var column: CGFloat = Theme.checkbox
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(Theme.accent.opacity(hovering ? 1 : 0))
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(hovering ? Theme.onAccent : Theme.accent)
                }
                .frame(width: Theme.checkbox, height: Theme.checkbox)
                .frame(width: column)
                Text(title)
                    .font(Fonts.body)
                    .foregroundStyle(hovering ? Theme.accent : Theme.tertiaryText)
                Spacer()
            }
            .padding(.horizontal, Theme.rowInset)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous).fill(hovering ? Theme.hover : .clear))
            .padding(.leading, leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .onHover { h in withAnimation(Theme.hoverAnimation) { hovering = h } }
    }
}

struct SectionHeaderView: View {
    @Environment(AppModel.self) private var model
    @Environment(TodoStore.self) private var store
    let section: TodoCore.Section
    let count: Int
    let collapsed: Bool
    @State private var hovering = false
    @State private var name = ""
    @State private var confirmDelete = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Button {
                    withAnimation(Theme.motion) {
                        if collapsed { model.collapsedSections.remove(section.id) } else { model.collapsedSections.insert(section.id) }
                    }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.tertiaryText)
                        .rotationEffect(.degrees(collapsed ? 0 : 90))
                        .frame(width: Theme.gutter, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointerStyle(.link)
                .help(collapsed ? "Show section" : "Hide section")

                if model.renamingSectionID == section.id {
                    TextField("Section name", text: $name)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.field))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.accent.opacity(0.7)))
                        .font(Fonts.bodySemibold)
                        .focused($nameFocused)
                        .onSubmit(commitRename)
                        .onExitCommand { model.renamingSectionID = nil }
                        .onAppear { name = section.name; nameFocused = true }
                    Button("Save", action: commitRename).buttonStyle(AccentButtonStyle()).padding(.leading, 8)
                    Button("Cancel") { model.renamingSectionID = nil }.buttonStyle(SoftButtonStyle()).padding(.leading, 6)
                } else {
                    Text(section.name)
                        .font(Fonts.bodySemibold)
                        .foregroundStyle(Theme.text)
                        .padding(.leading, Theme.rowInset)
                    if count > 0 {
                        Text("\(count)")
                            .font(Fonts.meta)
                            .monospacedDigit()
                            .foregroundStyle(Theme.tertiaryText)
                            .padding(.leading, 8)
                    }
                    Spacer()
                    Menu {
                        menuItems
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(Fonts.body)
                            .frame(width: 24, height: 22)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .tint(Theme.tertiaryText)
                    .fixedSize()
                    .pointerStyle(.link)
                    .opacity(hovering ? 1 : 0)
                    .padding(.trailing, 4)
                }
            }
            .padding(.vertical, 4)
            Hairline().padding(.leading, Theme.gutter)
        }
        .padding(.top, 8)
        .contentShape(Rectangle())
        .onHover { h in withAnimation(Theme.hoverAnimation) { hovering = h } }
        .contextMenu { menuItems }
        .onDrop(of: [.text], delegate: FixedDropDelegate(
            model: model, target: .sectionStart(projectId: section.projectId, sectionId: section.id)))
        .alert("Delete section?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { store.deleteSection(section.id) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("“\(section.name)” and all its tasks will be deleted.")
        }
    }

    @ViewBuilder private var menuItems: some View {
        Button("Add task") {
            model.collapsedSections.remove(section.id)
            model.editor = EditorTarget(projectId: section.projectId, sectionId: section.id)
        }
        Button("Rename section") { model.renamingSectionID = section.id }
        Divider()
        Button("Delete section", role: .destructive) { confirmDelete = true }
    }

    private func commitRename() {
        let n = name.trimmingCharacters(in: .whitespaces)
        if !n.isEmpty { store.updateSection(section.id) { $0.name = n } }
        model.renamingSectionID = nil
    }
}

/// The hover-revealed "—— Add section ——" line between sections, and the editor it opens.
struct AddSectionGap: View {
    @Environment(AppModel.self) private var model
    @Environment(TodoStore.self) private var store
    let projectId: EntityID
    let index: Int?
    @State private var hovering = false
    @State private var name = ""
    @FocusState private var focused: Bool

    private var isEditing: Bool {
        model.sectionEditor == SectionEditorTarget(projectId: projectId, index: index)
    }

    var body: some View {
        if isEditing {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Name this section", text: $name)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.field))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.accent.opacity(0.7)))
                    .font(Fonts.bodySemibold)
                    .focused($focused)
                    .onSubmit(add)
                    .onExitCommand { model.sectionEditor = nil }
                HStack(spacing: 8) {
                    Button("Add section", action: add)
                        .buttonStyle(AccentButtonStyle())
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Cancel") { model.sectionEditor = nil }
                        .buttonStyle(SoftButtonStyle())
                }
            }
            .padding(.leading, Theme.gutter)
            .padding(.vertical, 12)
            .onAppear { name = ""; focused = true }
        } else {
            Button {
                model.sectionEditor = SectionEditorTarget(projectId: projectId, index: index)
            } label: {
                HStack(spacing: 10) {
                    Rectangle().fill(Theme.accent.opacity(0.5)).frame(height: 1)
                    Text("Add section")
                        .font(Fonts.meta)
                        .foregroundStyle(Theme.accent)
                    Rectangle().fill(Theme.accent.opacity(0.5)).frame(height: 1)
                }
                .opacity(hovering ? 1 : 0)
                .padding(.leading, Theme.gutter)
                .frame(height: 16)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .onHover { hovering = $0 }
        }
    }

    private func add() {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        store.addSection(projectId: projectId, name: n, at: index)
        model.sectionEditor = nil
    }
}
