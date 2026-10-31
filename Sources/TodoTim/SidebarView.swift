import Collaboration
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
            AccountMenu()
                .sidebarRowInsets(top: 2, bottom: 6)

            SidebarButtonRow(action: { model.showQuickAdd = true }) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.accent)
                    .frame(width: Sidebar.iconWidth)
                Text("Add task")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Spacer()
            }
            .help("Add task (Q)")

            SidebarRow(item: .search) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).frame(width: Sidebar.iconWidth)
                Text("Search")
                Spacer()
            }
            SidebarRow(item: .project(store.inbox.id), dropProjectId: store.inbox.id) {
                projectLabel(store.inbox, icon: "tray")
            }

            SidebarHeader(title: "My Projects") {
                Button { model.showAddProject = true } label: {
                    Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointerStyle(.link)
                .help("Add project")
            }
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

            if !store.labels.isEmpty {
                SidebarHeader(title: "Labels") { EmptyView() }
                ForEach(store.labels) { l in
                    SidebarRow(item: .label(l.name)) {
                        Image(systemName: "tag")
                            .foregroundStyle(Palette.color(l.color))
                            .frame(width: Sidebar.iconWidth)
                        Text(l.name).lineLimit(1)
                        Spacer()
                        SidebarCount(n: store.openTaskCount(label: l.name))
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
        .listStyle(.sidebar)
        // Rows set their own height; the default minimum would space them unevenly.
        .environment(\.defaultMinListRowHeight, 10)
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
            .frame(width: Sidebar.iconWidth)
        Text(p.name).lineLimit(1)
        Spacer()
        SidebarCount(n: store.openTaskCount(projectId: p.id))
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

/// Todoist's account button at the top of the sidebar: avatar, name and a chevron opening a menu.
/// The name and picture are the macOS user's; the menu names the sync account when there is one.
private struct AccountMenu: View {
    @Environment(AppModel.self) private var model
    @State private var hovering = false
    private static let name = NSFullUserName().isEmpty ? NSUserName() : NSFullUserName()
    private static let picture: NSImage? = CBIdentity(name: NSUserName(), authority: .default())?.image

    var body: some View {
        Menu {
            let s = model.sync.settings
            if s.enabled, let account = s.credentialAccount {
                Text("Syncing as \(account)")
                Button("Sync Now") { model.syncNow() }
                Divider()
            }
            SettingsLink { Text("Settings…") }
            Button("Import from Todoist…") { model.showImportTodoist = true }
        } label: {
            HStack(spacing: Sidebar.spacing) {
                avatar.frame(width: Sidebar.iconWidth, height: Sidebar.iconWidth).clipShape(Circle())
                Text(Self.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, Sidebar.padding).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: Sidebar.radius, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.06 : 0)))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .pointerStyle(.link)
        .onHover { hovering = $0 }
    }

    @ViewBuilder private var avatar: some View {
        if let image = Self.picture {
            Image(nsImage: image).resizable().scaledToFill()
        } else {
            let initials = Self.name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()
            Circle().fill(Theme.accent)
                .overlay(Text(initials.uppercased()).font(.system(size: 9, weight: .semibold)).foregroundStyle(.white))
        }
    }
}

/// Shared sidebar metrics: every row puts its icon in the same column, so icons, the avatar and the
/// section headings line up.
enum Sidebar {
    static let iconWidth: CGFloat = 20
    static let spacing: CGFloat = 9
    /// Inner horizontal padding of a row (its highlight extends this far past the content).
    static let padding: CGFloat = 8
    static let radius: CGFloat = 7
    static let rowInsets = EdgeInsets(top: 1, leading: 10, bottom: 1, trailing: 10)
    /// Horizontal inset the sidebar list adds outside the row insets.
    static let listInset: CGFloat = 16
}

extension View {
    func sidebarRowInsets(top: CGFloat = 1, bottom: CGFloat = 1) -> some View {
        listRowInsets(EdgeInsets(top: top, leading: Sidebar.rowInsets.leading, bottom: bottom, trailing: Sidebar.rowInsets.trailing))
            .listRowSeparator(.hidden)
    }
}

/// Open-task count at the trailing edge of a sidebar row; nothing when zero.
private struct SidebarCount: View {
    let n: Int
    var body: some View {
        if n > 0 {
            Text("\(n)").font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
        }
    }
}

/// Section heading ("My Projects", "Labels"), aligned with the rows' icons; the accessory (an add
/// button) sits where the counts are and shows on hover.
private struct SidebarHeader<Accessory: View>: View {
    let title: String
    @ViewBuilder let accessory: Accessory
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            accessory
                .foregroundStyle(.secondary)
                .opacity(hovering ? 1 : 0)
        }
        .frame(height: 20)
        .padding(.leading, Sidebar.padding)
        .padding(.trailing, Sidebar.padding - 4)
        .padding(.top, 14)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .sidebarRowInsets(top: 0, bottom: 0)
        .selectionDisabled()
        .moveDisabled(true)
    }
}

/// The hover and selection chrome shared by sidebar rows.
private struct SidebarRowBackground: View {
    var selected = false
    var hovering = false
    var dropTargeted = false

    var body: some View {
        RoundedRectangle(cornerRadius: Sidebar.radius, style: .continuous)
            .fill(dropTargeted ? Theme.accent.opacity(0.24)
                : selected ? Theme.selection
                : Color.primary.opacity(hovering ? 0.06 : 0))
            .overlay {
                if dropTargeted {
                    RoundedRectangle(cornerRadius: Sidebar.radius, style: .continuous)
                        .strokeBorder(Theme.accent.opacity(0.7), lineWidth: 1.5)
                }
            }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// A sidebar row that runs an action instead of selecting a view ("Add task").
private struct SidebarButtonRow<Content: View>: View {
    let action: () -> Void
    @ViewBuilder let content: Content
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Sidebar.spacing) { content }
                .padding(.horizontal, Sidebar.padding)
                .padding(.vertical, 6)
                .background(SidebarRowBackground(hovering: hovering))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .onHover { hovering = $0 }
        .sidebarRowInsets()
        .moveDisabled(true)
    }
}

/// Sidebar row with a tinted selection (red title), a hover background and, for projects, a drop
/// target for dragged tasks that highlights while targeted.
private struct SidebarRow<Content: View>: View {
    @Environment(AppModel.self) private var model
    let item: SidebarItem
    var dropProjectId: EntityID?
    @ViewBuilder let content: Content
    @State private var hovering = false
    @State private var dropTargeted = false

    var body: some View {
        let selected = model.sidebar == item
        HStack(spacing: Sidebar.spacing) { content }
            .font(.system(size: 13))
            .foregroundStyle(selected ? Theme.accent : Color.primary)
            .padding(.horizontal, Sidebar.padding)
            .padding(.vertical, 6)
            .background(SidebarRowBackground(selected: selected, hovering: hovering, dropTargeted: dropTargeted))
            .contentShape(Rectangle())
            .pointerStyle(.link)
            .onHover { hovering = $0 }
            .onTapGesture { model.sidebar = item }
            .sidebarRowInsets()
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
            color = project.map { ProjectColor.entry($0.color).key } ?? "charcoal"
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
        // Lines up with the rows' icons and counts (the list adds its own inset).
        .padding(.horizontal, Sidebar.listInset + Sidebar.rowInsets.leading + Sidebar.padding)
        .padding(.vertical, 10)
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
