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
        @Bindable var model = model
        List(selection: $model.sidebar) {
            Button { model.showQuickAdd = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(Theme.accent)
                    Text("Add task")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
            }
            .buttonStyle(.plain)
            .padding(.vertical, 4)
            .selectionDisabled()

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).frame(width: 18)
                Text("Search")
            }
            .tag(SidebarItem.search)
            row(store.inbox, icon: "tray")
                .tag(SidebarItem.project(store.inbox.id))

            SwiftUI.Section {
                ForEach(store.projects) { p in
                    row(p, icon: "number")
                        .tag(SidebarItem.project(p.id))
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
                    .help("Add project")
                }
            }

            if !store.labels.isEmpty {
                SwiftUI.Section("Labels") {
                    ForEach(store.labels) { l in
                        HStack(spacing: 8) {
                            Image(systemName: "tag")
                                .foregroundStyle(Palette.color(l.color))
                                .frame(width: 18)
                            Text(l.name)
                            Spacer()
                            let n = store.openTaskCount(label: l.name)
                            if n > 0 { Text("\(n)").foregroundStyle(.secondary).font(.system(size: 12)) }
                        }
                        .tag(SidebarItem.label(l.name))
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

    private func row(_ p: Project, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(p.isInbox ? Color(hex: 0x246FE0) : Palette.color(p.color))
                .frame(width: 18)
            Text(p.name).lineLimit(1)
            Spacer()
            let n = store.openTaskCount(projectId: p.id)
            if n > 0 { Text("\(n)").foregroundStyle(.secondary).font(.system(size: 12)) }
        }
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { ids, _ in
            model.drop(ids, projectId: p.id, sectionId: nil)
        }
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
