import SwiftUI
import TodoCore

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Environment(TodoStore.self) private var store
    @State private var editingProject: Project?
    @State private var deletingProject: Project?
    @State private var renamingLabel: TodoCore.Label?
    @State private var labelName = ""

    var body: some View {
        // No `List(selection:)`: its highlight uses the system accent color (blue for most
        // users), so rows draw Todoist's tinted selection themselves (`SidebarRow`).
        List {
            Button { model.showQuickAdd = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(Theme.accent)
                    Text("Add task")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .padding(.vertical, 4)

            SidebarRow(item: .search) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).frame(width: 18)
                Text("Search")
                Spacer()
            }
            SidebarRow(item: .project(store.inbox.id), dropProjectId: store.inbox.id) {
                projectLabel(store.inbox, icon: "tray")
            }

            SwiftUI.Section {
                ForEach(store.projects) { p in
                    SidebarRow(item: .project(p.id), dropProjectId: p.id) {
                        projectLabel(p, icon: "number")
                    }
                    .contextMenu { projectMenu(p) }
                }
                .onMove { from, to in
                    guard let i = from.first else { return }
                    let id = store.projects[i].id
                    store.moveProject(id, to: to > i ? to - 1 : to)
                }
            } header: {
                HStack {
                    Text("My Projects")
                    Spacer()
                    Button { model.showAddProject = true } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.plain)
                    .pointerStyle(.link)
                    .help("Add project")
                }
            }

            if !store.labels.isEmpty {
                SwiftUI.Section("Labels") {
                    ForEach(store.labels) { l in
                        SidebarRow(item: .label(l.name)) {
                            Image(systemName: "tag")
                                .foregroundStyle(Palette.color(l.color))
                                .frame(width: 18)
                            Text(l.name)
                            Spacer()
                            let n = store.openTaskCount(label: l.name)
                            if n > 0 { Text("\(n)").foregroundStyle(.secondary).font(.system(size: 12)) }
                        }
                        .contextMenu {
                            Button("Rename…") { labelName = l.name; renamingLabel = l }
                            Menu("Color") {
                                ForEach(Palette.entries) { e in
                                    Button { store.updateLabel(l.id) { $0.color = e.key } } label: {
                                        SwiftUI.Label { Text(e.name) } icon: { Image(nsImage: Palette.swatch(e.key)) }
                                    }
                                }
                            }
                            Divider()
                            Button("Delete Label", role: .destructive) {
                                if model.sidebar == .label(l.name) { model.goToInbox() }
                                store.deleteLabel(l.id)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { SyncStatusView() }
        .sheet(item: $editingProject) { p in
            ProjectFormView(project: p).environment(model).environment(store)
        }
        .alert("Delete project?", isPresented: Binding(get: { deletingProject != nil }, set: { if !$0 { deletingProject = nil } }),
               presenting: deletingProject) { p in
            Button("Delete", role: .destructive) {
                if model.sidebar == .project(p.id) { model.goToInbox() }
                store.deleteProject(p.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: { p in
            Text("“\(p.name)” and all its tasks will be permanently deleted.")
        }
        .alert("Rename label", isPresented: Binding(get: { renamingLabel != nil }, set: { if !$0 { renamingLabel = nil } }),
               presenting: renamingLabel) { l in
            TextField("Label name", text: $labelName)
            Button("Save") {
                let name = labelName.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                let wasSelected = model.sidebar == .label(l.name)
                store.updateLabel(l.id) { $0.name = name }
                if wasSelected { model.sidebar = .label(name) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    @ViewBuilder private func projectLabel(_ p: Project, icon: String) -> some View {
        Image(systemName: icon)
            .foregroundStyle(p.isInbox ? Color(hex: 0x246FE0) : Palette.color(p.color))
            .frame(width: 18)
        Text(p.name).lineLimit(1)
        Spacer()
        let n = store.openTaskCount(projectId: p.id)
        if n > 0 { Text("\(n)").foregroundStyle(.secondary).font(.system(size: 12)) }
    }

    @ViewBuilder private func projectMenu(_ p: Project) -> some View {
        Button("Edit Project…") { editingProject = p }
        Menu("Color") {
            ForEach(Palette.entries) { e in
                Button { store.updateProject(p.id) { $0.color = e.key } } label: {
                    SwiftUI.Label { Text(e.name) } icon: { Image(nsImage: Palette.swatch(e.key)) }
                }
            }
        }
        Divider()
        Button("Delete Project…", role: .destructive) { deletingProject = p }
    }
}

/// Sidebar row with Todoist's selection (tinted background, red title), a hover background and,
/// for projects, a drop target for dragged tasks that highlights while targeted.
private struct SidebarRow<Content: View>: View {
    @Environment(AppModel.self) private var model
    let item: SidebarItem
    var dropProjectId: EntityID?
    @ViewBuilder let content: Content
    @State private var hovering = false
    @State private var dropTargeted = false

    var body: some View {
        let selected = model.sidebar == item
        HStack(spacing: 8) { content }
            .foregroundStyle(selected ? Theme.accent : Color.primary)
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6).fill(
                    dropTargeted ? Theme.accent.opacity(0.28)
                        : selected ? Theme.selection
                        : Color.primary.opacity(hovering ? 0.06 : 0))
            )
            .overlay {
                if dropTargeted { RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.accent.opacity(0.7), lineWidth: 1.5) }
            }
            .contentShape(Rectangle())
            .pointerStyle(.link)
            .onHover { hovering = $0 }
            .onTapGesture { model.sidebar = item }
            .listRowInsets(EdgeInsets(top: 1, leading: 4, bottom: 1, trailing: 4))
            .modifier(SidebarDropModifier(projectId: dropProjectId, targeted: $dropTargeted))
    }
}

private struct SidebarDropModifier: ViewModifier {
    @Environment(AppModel.self) private var model
    let projectId: EntityID?
    @Binding var targeted: Bool

    func body(content: Content) -> some View {
        if let projectId {
            content.dropDestination(for: String.self) { ids, _ in
                model.drop(ids, projectId: projectId, sectionId: nil)
            } isTargeted: { on in
                targeted = on
                // Leaving the list for the sidebar: remove the list placeholder.
                if on { model.drag.setTarget(nil) }
            }
        } else {
            content
        }
    }
}

/// Add / edit project dialog (name + color), like Todoist's.
struct ProjectFormView: View {
    @Environment(AppModel.self) private var model
    @Environment(TodoStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let project: Project?
    @State private var name = ""
    @State private var color = "charcoal"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(project == nil ? "Add project" : "Edit project")
                .font(.system(size: 16, weight: .bold))
                .padding(16)
            Divider()
            Form {
                TextField("Name", text: $name)
                    .onSubmit(save)
                Picker("Color", selection: $color) {
                    ForEach(Palette.entries) { e in
                        SwiftUI.Label { Text(e.name) } icon: { Image(nsImage: Palette.swatch(e.key)) }
                            .tag(e.key)
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(SoftButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button(project == nil ? "Add" : "Save", action: save)
                    .buttonStyle(AccentButtonStyle())
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(12)
        }
        .frame(width: 420)
        .onAppear {
            name = project?.name ?? ""
            color = project.map { Palette.entry($0.color).key } ?? "charcoal"
        }
    }

    private func save() {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        if let project {
            store.updateProject(project.id) { $0.name = n; $0.color = color }
        } else {
            let p = store.addProject(name: n, color: color)
            model.sidebar = .project(p.id)
        }
        dismiss()
    }
}

struct SyncStatusView: View {
    @Environment(AppModel.self) private var model
    @Environment(SyncController.self) private var sync
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        HStack(spacing: 6) {
            icon
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            Button { model.syncNow() } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Sync now (⌘R)")
            .disabled(!isEnabled)
            Button { openSettings() } label: { Image(systemName: "gearshape") }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Settings (⌘,)")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .help(helpText)
    }

    private var isEnabled: Bool {
        if case .disabled = sync.status { return false }
        return true
    }

    @ViewBuilder private var icon: some View {
        switch sync.status {
        case .disabled: Image(systemName: "icloud.slash").foregroundStyle(.secondary)
        case .idle: Image(systemName: "checkmark.icloud").foregroundStyle(.secondary)
        case .syncing: ProgressView().controlSize(.mini)
        case .error: Image(systemName: "exclamationmark.icloud").foregroundStyle(Theme.overdue)
        }
    }

    private var text: String {
        switch sync.status {
        case .disabled: return "Sync off"
        case .idle(let last):
            guard let last else { return "Not synced yet" }
            return "Synced \(last.formatted(.relative(presentation: .named)))"
        case .syncing: return "Syncing…"
        case .error(let msg): return "Sync error: \(msg)"
        }
    }

    private var helpText: String {
        if case .error(let msg) = sync.status { return msg }
        return text
    }
}
