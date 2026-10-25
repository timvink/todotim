import QuartzCore
import SwiftUI
import TodoCore

/// Main pane for a project (or the Inbox): title, unsectioned tasks, then sections.
struct ProjectView: View {
    @Environment(AppModel.self) private var model
    @Environment(TodoStore.self) private var store
    let projectId: EntityID

    var body: some View {
        // Rebuilt only when structure, sections, parents' collapsed state or view inputs change;
        // never on selection changes (rows observe the selection themselves).
        let name = store.project(projectId)?.name ?? ""
        TaskListView(items: model.display().items, title: name)
            .navigationTitle(name)
    }
}

/// Renders a flattened `DisplayItem` list in one `LazyVStack`, so only rows near the viewport
/// are built. Shared by project, label and search views.
struct TaskListView: View {
    @Environment(AppModel.self) private var model
    let items: [DisplayItem]
    /// Shown centred in the toolbar once the list's own large title has scrolled away.
    var title: String = ""
    var topPadding: CGFloat = 12
    @State private var visible = VisibleRows()
    @State private var titleScrolledAway = false

    var body: some View {
        // Reads the drag state here only, so a drag invalidates this body (an O(rows) pass)
        // but not the rows.
        let drag = model.drag
        let dragging = drag.draggingID
        let shown = Self.withPlaceholder(items, target: dragging == nil ? nil : drag.target)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(shown) { item in
                        if case .dropPlaceholder(let depth) = item {
                            DropPlaceholderView(depth: depth, height: drag.rowHeight)
                                .transition(.opacity)
                        } else {
                            DisplayItemView(item: item)
                                .opacity(dragging != nil && item.id == dragging ? 0.35 : 1)
                        }
                    }
                }
                .scrollTargetLayout()
                .frame(maxWidth: Theme.contentMaxWidth, alignment: .leading)
                .padding(.horizontal, 32)
                .padding(.top, topPadding)
                .padding(.bottom, 80)
                .frame(maxWidth: .infinity)
            }
            .onScrollGeometryChange(for: Bool.self) { geo in
                geo.contentOffset.y + geo.contentInsets.top > 60
            } action: { _, scrolled in
                titleScrolledAway = scrolled
            }
            .onScrollTargetVisibilityChange(idType: String.self, threshold: 0.9) { ids in
                visible.ids = Set(ids)
            }
            .background { SelectionScroller(proxy: proxy, visible: visible) }
        }
        // Opaque strip under the (transparent) toolbar, like Todoist: rows scroll under it instead
        // of under the window buttons. A zero-height view at the top of the safe area whose
        // background extends up to the window edge covers exactly the toolbar area of this column.
        .overlay(alignment: .top) {
            Color.clear.frame(height: 0)
                .background(alignment: .bottom) {
                    Color(nsColor: .textBackgroundColor).ignoresSafeArea(edges: .top)
                }
                .overlay(alignment: .top) { if titleScrolledAway { Divider() } }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .opacity(titleScrolledAway && !title.isEmpty ? 1 : 0)
                    .animation(.easeOut(duration: 0.15), value: titleScrolledAway)
            }
        }
        .onAppear { Perf.firstListAppeared() }
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
        case .projectHeader(let pid):
            ProjectHeaderView(projectId: pid)
        case .labelHeader(let name):
            LabelHeaderView(name: name)
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
            Text(text).foregroundStyle(.secondary).padding(.leading, Theme.gutter)
        case .dropPlaceholder:
            EmptyView()  // rendered by TaskListView
        }
    }
}

private struct ProjectHeaderView: View {
    @Environment(AppModel.self) private var model
    @Environment(TodoStore.self) private var store
    let projectId: EntityID

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(store.project(projectId)?.name ?? "")
                .font(.system(size: 26, weight: .bold))
            Spacer()
            moreMenu
        }
        .padding(.leading, Theme.gutter)
        .padding(.top, 8).padding(.bottom, 18)
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
            Image(systemName: "ellipsis").font(.system(size: 15))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .pointerStyle(.link)
        .help("More actions")
    }
}

struct AddTaskRow: View {
    var title = "Add task"
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(hovering ? Theme.accent : .clear)
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: hovering ? .bold : .regular))
                        .foregroundStyle(hovering ? .white : Theme.accent)
                }
                .frame(width: 18, height: 18)
                Text(title)
                    .font(.system(size: 14))
                    .foregroundStyle(hovering ? Theme.accent : .secondary)
                Spacer()
            }
            .padding(.leading, Theme.gutter)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .onHover { hovering = $0 }
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
                    if collapsed { model.collapsedSections.remove(section.id) } else { model.collapsedSections.insert(section.id) }
                } label: {
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: Theme.gutter, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointerStyle(.link)
                .opacity(hovering || collapsed ? 1 : 0.6)

                if model.renamingSectionID == section.id {
                    TextField("Section name", text: $name)
                        .textFieldStyle(.plain)
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.25)))
                        .font(.system(size: 14, weight: .bold))
                        .focused($nameFocused)
                        .onSubmit(commitRename)
                        .onExitCommand { model.renamingSectionID = nil }
                        .onAppear { name = section.name; nameFocused = true }
                    Button("Save", action: commitRename).buttonStyle(AccentButtonStyle()).padding(.leading, 8)
                    Button("Cancel") { model.renamingSectionID = nil }.buttonStyle(SoftButtonStyle()).padding(.leading, 6)
                } else {
                    Text(section.name)
                        .font(.system(size: 14, weight: .bold))
                    if count > 0 {
                        Text("\(count)")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 8)
                    }
                    Spacer()
                    Menu {
                        menuItems
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .pointerStyle(.link)
                    .opacity(hovering ? 1 : 0)
                }
            }
            .padding(.vertical, 6)
            Divider().padding(.leading, Theme.gutter)
        }
        .padding(.top, 8)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
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
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.25)))
                    .font(.system(size: 14, weight: .semibold))
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
                    Rectangle().fill(Theme.accent).frame(height: 1)
                    Text("Add section")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                    Rectangle().fill(Theme.accent).frame(height: 1)
                }
                .opacity(hovering ? 1 : 0)
                .padding(.leading, Theme.gutter)
                .frame(height: 22)
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
