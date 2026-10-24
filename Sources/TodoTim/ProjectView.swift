import SwiftUI
import TodoCore

/// Main pane for a project (or the Inbox): title, unsectioned tasks, then sections.
struct ProjectView: View {
    @Environment(AppModel.self) private var model
    @Environment(TodoStore.self) private var store
    let project: Project

    var body: some View {
        let sections = store.sections(in: project.id)
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(project.name)
                            .font(.system(size: 26, weight: .bold))
                        Spacer()
                        moreMenu
                    }
                    .padding(.leading, Theme.gutter)
                    .padding(.top, 8).padding(.bottom, 18)

                    TaskArea(projectId: project.id, sectionId: nil)

                    ForEach(Array(sections.enumerated()), id: \.element.id) { i, s in
                        AddSectionGap(projectId: project.id, index: i)
                        SectionHeaderView(section: s)
                        if !model.collapsedSections.contains(s.id) {
                            TaskArea(projectId: project.id, sectionId: s.id)
                        }
                    }
                    AddSectionGap(projectId: project.id, index: nil)
                    Spacer(minLength: 80)
                }
                .frame(maxWidth: Theme.contentMaxWidth, alignment: .leading)
                .padding(.horizontal, 32)
                .padding(.top, 12)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: model.selectedTaskID) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) }
            }
        }
        .navigationTitle(project.name)
    }

    private var moreMenu: some View {
        Menu {
            Toggle("Show completed tasks", isOn: Binding(
                get: { model.showsCompleted(project.id) },
                set: { on in
                    if on { model.showCompletedProjects.insert(project.id) }
                    else { model.showCompletedProjects.remove(project.id) }
                }))
            Button("Add section") { model.sectionEditor = SectionEditorTarget(projectId: project.id, index: nil) }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 15))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More actions")
    }
}

/// Rows of one area (project top or a section) plus the "Add task" row.
struct TaskArea: View {
    @Environment(AppModel.self) private var model
    let projectId: EntityID
    let sectionId: EntityID?

    var body: some View {
        let items = model.rows(projectId: projectId, sectionId: sectionId)
        let editorAtEnd = model.editor.map {
            $0.parentId == nil && $0.projectId == projectId && $0.sectionId == sectionId && !$0.atTop
        } ?? false
        VStack(alignment: .leading, spacing: 0) {
            ForEach(items) { item in
                switch item {
                case .task(let r):
                    TaskRowView(item: r).id(r.id)
                case .editor(let depth):
                    InlineTaskEditor(depth: depth)
                }
            }
            if !editorAtEnd {
                AddTaskRow {
                    model.selectedTaskID = nil
                    model.editor = EditorTarget(projectId: projectId, sectionId: sectionId)
                }
                .dropDestination(for: String.self) { ids, _ in
                    model.drop(ids, projectId: projectId, sectionId: sectionId)
                }
            }
        }
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
        .onHover { hovering = $0 }
    }
}

struct SectionHeaderView: View {
    @Environment(AppModel.self) private var model
    @Environment(TodoStore.self) private var store
    let section: TodoCore.Section
    @State private var hovering = false
    @State private var name = ""
    @State private var confirmDelete = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        let collapsed = model.collapsedSections.contains(section.id)
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
                    let count = store.tasks(projectId: section.projectId, sectionId: section.id).count
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
        .dropDestination(for: String.self) { ids, _ in
            model.drop(ids, projectId: section.projectId, sectionId: section.id)
        }
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
