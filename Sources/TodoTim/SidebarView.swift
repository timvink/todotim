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
        // No `List(selection:)`: its highlight uses the system accent color, so rows draw their
        // own neutral selection (`SidebarRow`).
        List {
            AccountMenu()
                .sidebarRowInsets(top: 0, bottom: 6)

            SidebarButtonRow(action: { model.showQuickAdd = true }) {
                ZStack {
                    Circle().fill(Theme.accent)
                    Image(systemName: "plus")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.onAccent)
                }
                .frame(width: Theme.checkbox, height: Theme.checkbox)
                .frame(width: Sidebar.iconWidth)
                Text("Add task")
                    .font(Fonts.bodySemibold)
                    .foregroundStyle(Theme.accent)
                Spacer()
            }
            .help("Add task (Q)")

            SidebarRow(item: .search) { _ in
                Image(systemName: "magnifyingglass")
                    .font(Fonts.icon)
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: Sidebar.iconWidth)
                Text("Search")
                Spacer()
            }
            SidebarRow(item: .project(store.inbox.id), dropProjectId: store.inbox.id) { state in
                projectLabel(store.inbox, state: state)
            }

            SidebarHeader(title: "Projects") {
                Button { model.showAddProject = true } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 22, height: 20, alignment: .trailing)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointerStyle(.link)
                .help("Add project (⇧⌘N)")
            }
            ForEach(store.projects) { p in
                SidebarRow(item: .project(p.id), dropProjectId: p.id) { state in
                    projectLabel(p, state: state)
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
                    SidebarRow(item: .label(l.name)) { _ in
                        Image(systemName: "tag")
                            .font(Fonts.icon)
                            .foregroundStyle(Palette.color(l.color))
                            .frame(width: Sidebar.iconWidth)
                        Text(l.name).lineLimit(1)
                        Spacer()
                        SidebarCount(n: store.openTaskCount(label: l.name))
                    }
                    .contextMenu {
                        Button("Rename…") { labelName = l.name; renamingLabel = l }
                        Menu("Color") { colorMenu(current: l.color) { key in store.updateLabel(l.id) { $0.color = key } } }
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
        .scrollContentBackground(.hidden)
        // Rows set their own height; the default minimum would space them unevenly.
        .environment(\.defaultMinListRowHeight, 10)
        // The first row (the account) is level with the list's first task, under the title band.
        .padding(.top, 28)
        .safeAreaInset(edge: .bottom, spacing: 0) { SyncStatusView() }
        .background(Theme.sidebar)
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

    @ViewBuilder private func projectLabel(_ p: Project, state: SidebarRowState) -> some View {
        ProjectIcon(p, fill: state.selected ? 1 : state.dropTargeted ? 0.6 : state.hovering ? 0.3 : 0)
            .frame(width: Sidebar.iconWidth)
        Text(p.name).lineLimit(1)
        Spacer()
        SidebarCount(n: store.openTaskCount(projectId: p.id))
    }

    @ViewBuilder private func projectMenu(_ p: Project) -> some View {
        Button("Edit Project…") { editingProject = p }
        Menu("Color") { colorMenu(current: p.color) { key in store.updateProject(p.id) { $0.color = key } } }
        Divider()
        Button("Delete Project…", role: .destructive) { deletingProject = p }
    }

    @ViewBuilder private func colorMenu(current: String, pick: @escaping (String) -> Void) -> some View {
        ForEach(Palette.pickerEntries) { e in
            Button { pick(e.key) } label: {
                SwiftUI.Label { Text(Palette.name(e.key)) } icon: { Image(nsImage: Palette.swatch(e.key)) }
            }
        }
    }
}

/// The account button at the top of the sidebar: avatar, name and a chevron opening a menu. The
/// name and picture are the macOS user's; the menu names the sync account when there is one.
private struct AccountMenu: View {
    @Environment(AppModel.self) private var model
    @State private var hovering = false
    @State private var picture = AccountMenu.loadedPicture
    private static let name = NSFullUserName().isEmpty ? NSUserName() : NSFullUserName()
    /// The account picture at the avatar's pixel size. Reading the user record takes several
    /// milliseconds, so it loads off the main thread after the first frame (initials until then).
    nonisolated(unsafe) private static var loadedPicture: CGImage?

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
                Text(Self.name).font(Fonts.bodySemibold).foregroundStyle(Theme.text).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.tertiaryText)
            }
            .padding(.horizontal, Sidebar.padding).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: Sidebar.radius, style: .continuous)
                .fill(hovering ? Theme.hover : .clear))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .pointerStyle(.link)
        .onHover { h in withAnimation(Theme.hoverAnimation) { hovering = h } }
        .task {
            guard picture == nil else { return }
            let side = Int(Sidebar.iconWidth * 2)
            guard let image = await Task.detached(priority: .utility, operation: { Self.readPicture(side: side) }).value
            else { return }
            Self.loadedPicture = image
            picture = image
        }
    }

    /// The user's picture, scaled once to fill a `side`-pixel square.
    private nonisolated static func readPicture(side: Int) -> CGImage? {
        guard let source = CBIdentity(name: NSUserName(), authority: .default())?.image?
                .cgImage(forProposedRect: nil, context: nil, hints: nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        let w = CGFloat(source.width), h = CGFloat(source.height), scale = CGFloat(side) / min(w, h)
        ctx.interpolationQuality = .high
        ctx.draw(source, in: CGRect(x: (CGFloat(side) - w * scale) / 2, y: (CGFloat(side) - h * scale) / 2,
                                    width: w * scale, height: h * scale))
        return ctx.makeImage()
    }

    @ViewBuilder private var avatar: some View {
        if let picture {
            Image(decorative: picture, scale: 2).resizable().scaledToFill()
        } else {
            let initials = Self.name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()
            Circle().fill(Ctp.surface1.color)
                .overlay(Text(initials.uppercased()).font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.text))
        }
    }
}

/// Shared sidebar metrics: every row puts its icon in the same column, so icons, the avatar, the
/// Add task disc, the headings and the footer line up.
enum Sidebar {
    static let iconWidth: CGFloat = 20
    static let spacing: CGFloat = 8
    /// Inner horizontal padding of a row (its highlight extends this far past the content).
    static let padding: CGFloat = 8
    static let radius = Theme.rowRadius
    static let rowInsets = EdgeInsets(top: 1, leading: 10, bottom: 1, trailing: 10)
    /// Horizontal inset the sidebar list adds outside the row insets.
    static let listInset: CGFloat = 16
    /// From the sidebar's edge to a row's content (icons on the left, counts on the right).
    static let contentInset = listInset + rowInsets.leading + padding
}

extension View {
    func sidebarRowInsets(top: CGFloat = 1, bottom: CGFloat = 1) -> some View {
        listRowInsets(EdgeInsets(top: top, leading: Sidebar.rowInsets.leading, bottom: bottom, trailing: Sidebar.rowInsets.trailing))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

/// Open-task count at the trailing edge of a sidebar row; nothing when zero.
private struct SidebarCount: View {
    let n: Int
    var body: some View {
        if n > 0 {
            Text("\(n)").font(Fonts.meta).monospacedDigit().foregroundStyle(Theme.tertiaryText)
                .contentTransition(.numericText(countsDown: true))
                .animation(Theme.motion, value: n)
        }
    }
}

/// Section heading ("Projects", "Labels"): small caps aligned with the rows' icons; the accessory
/// (an add button) ends where the counts end.
private struct SidebarHeader<Accessory: View>: View {
    let title: String
    @ViewBuilder let accessory: Accessory
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            Text(title.uppercased())
                .font(Fonts.sidebarHeading)
                .tracking(0.6)
                .foregroundStyle(Theme.tertiaryText)
            Spacer()
            accessory
                .foregroundStyle(hovering ? Theme.text : Theme.tertiaryText)
        }
        .frame(height: 20)
        .padding(.horizontal, Sidebar.padding)
        .padding(.top, 16).padding(.bottom, 2)
        .contentShape(Rectangle())
        .onHover { h in withAnimation(Theme.hoverAnimation) { hovering = h } }
        .sidebarRowInsets(top: 0, bottom: 0)
        .selectionDisabled()
        .moveDisabled(true)
    }
}

struct SidebarRowState {
    var selected = false
    var hovering = false
    var dropTargeted = false
}

/// The hover, selection and drop-target pill shared by sidebar rows.
private struct SidebarRowBackground: View {
    var state = SidebarRowState()

    var body: some View {
        RoundedRectangle(cornerRadius: Sidebar.radius, style: .continuous)
            .fill(state.selected || state.dropTargeted ? Theme.selection : state.hovering ? Theme.hover : .clear)
            .overlay {
                if state.dropTargeted {
                    RoundedRectangle(cornerRadius: Sidebar.radius, style: .continuous)
                        .strokeBorder(Theme.accent, lineWidth: 1)
                }
            }
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
                .frame(height: 28)
                .background(SidebarRowBackground(state: SidebarRowState(hovering: hovering)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .onHover { h in withAnimation(Theme.hoverAnimation) { hovering = h } }
        .sidebarRowInsets()
        .moveDisabled(true)
    }
}

/// Sidebar row with a neutral selection pill (the text keeps its color), a hover pill and, for
/// projects, a drop target for dragged tasks.
private struct SidebarRow<Content: View>: View {
    @Environment(AppModel.self) private var model
    let item: SidebarItem
    var dropProjectId: EntityID?
    @ViewBuilder let content: (SidebarRowState) -> Content
    @State private var hovering = false
    @State private var dropTargeted = false

    var body: some View {
        let state = SidebarRowState(selected: model.sidebar == item, hovering: hovering, dropTargeted: dropTargeted)
        HStack(spacing: Sidebar.spacing) { content(state) }
            .font(Fonts.body)
            .foregroundStyle(Theme.text)
            .padding(.horizontal, Sidebar.padding)
            .frame(height: 28)
            .background(SidebarRowBackground(state: state))
            .contentShape(Rectangle())
            .pointerStyle(.link)
            .onHover { h in withAnimation(Theme.hoverAnimation) { hovering = h } }
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
                withAnimation(Theme.hoverAnimation) { targeted = on }
                // Leaving the list for the sidebar: remove the list placeholder.
                if on { model.drag.setTarget(nil) }
            }
        } else {
            content
        }
    }
}

/// Add / edit project dialog: a name and a color.
struct ProjectFormView: View {
    @Environment(AppModel.self) private var model
    @Environment(TodoStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let project: Project?
    @State private var name = ""
    @State private var color = "blue"
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                ProjectIcon(colorKey: color, isInbox: false, fill: 1, size: 14)
                Text(project == nil ? "New project" : "Edit project")
                    .font(Fonts.panelTitle)
                    .foregroundStyle(Theme.text)
            }
            TextField("Name", text: $name, prompt: Text("Project name").foregroundStyle(Theme.tertiaryText))
                .textFieldStyle(.plain)
                .font(Fonts.body)
                .foregroundStyle(Theme.text)
                .focused($nameFocused)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).fill(Theme.field))
                .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                    .strokeBorder(nameFocused ? Theme.accent : Ctp.surface1.color))
                .onSubmit(save)
            VStack(alignment: .leading, spacing: 8) {
                Text("Color").font(Fonts.meta).foregroundStyle(Theme.secondaryText)
                HStack(spacing: 8) {
                    ForEach(Palette.pickerEntries) { e in
                        let selected = Palette.ctp(e.key) == Palette.ctp(color)
                        Button { color = e.key } label: {
                            Circle().fill(Palette.color(e.key))
                                .frame(width: 18, height: 18)
                                .padding(3)
                                .overlay(Circle().strokeBorder(selected ? Theme.text : .clear, lineWidth: 2))
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .pointerStyle(.link)
                        .help(Palette.name(e.key))
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(SoftButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button(project == nil ? "Add project" : "Save", action: save)
                    .buttonStyle(AccentButtonStyle())
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
        .background(Theme.panel)
        .onAppear {
            name = project?.name ?? ""
            color = project.map { ProjectColor.entry($0.color).key } ?? "blue"
            nameFocused = true
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

/// The sidebar's footer: sync state and the sync and settings buttons, on the rows' grid and at
/// the rows' type size. "Synced" with a green cloud once the server has every change, "Sync
/// pending" with a cloud in the text color while local changes wait for a sync. Background syncs
/// with nothing to send do not show; the first sync and one you ask for (⌘R) turn the glyph.
struct SyncStatusView: View {
    @Environment(AppModel.self) private var model
    @Environment(SyncController.self) private var sync
    @Environment(\.openSettings) private var openSettings

    private enum Phase: Equatable { case off, failed, syncing, pending, synced, notSynced }

    var body: some View {
        let phase = self.phase
        HStack(spacing: Sidebar.spacing) {
            icon(phase)
                .font(Fonts.icon)
                .frame(width: Sidebar.iconWidth)
                .transition(.opacity)
                .id(phase)
            Text(text(phase))
                .font(Fonts.body)
                .foregroundStyle(phase == .failed ? Theme.danger : Theme.secondaryText)
                .lineLimit(1)
                .truncationMode(.tail)
                .contentTransition(.opacity)
            Spacer(minLength: 4)
            FooterButton(icon: "arrow.triangle.2.circlepath", help: "Sync now (⌘R)") { model.syncNow() }
                .disabled(phase == .off)
            FooterButton(icon: "gearshape", help: "Settings (⌘,)") { openSettings() }
                .padding(.trailing, -6)
        }
        .padding(.leading, Sidebar.contentInset)
        .padding(.trailing, Sidebar.contentInset)
        .frame(height: 44)
        .background(Theme.sidebar)
        .help(helpText(phase))
        .animation(Theme.reduceMotion ? nil : .easeOut(duration: 0.2), value: phase)
    }

    private var phase: Phase {
        switch sync.status {
        case .disabled: .off
        case .error: .failed
        case .syncing where sync.lastSync == nil || model.userSyncInProgress: .syncing
        case .syncing, .idle: sync.hasPendingChanges ? .pending : sync.lastSync == nil ? .notSynced : .synced
        }
    }

    @ViewBuilder private func icon(_ phase: Phase) -> some View {
        switch phase {
        case .off: Image(systemName: "icloud.slash").foregroundStyle(Theme.disabledText)
        case .failed: Image(systemName: "exclamationmark.icloud").foregroundStyle(Theme.danger)
        case .syncing: SpinningSyncGlyph()
        case .pending: Image(systemName: "icloud").foregroundStyle(Theme.text)
        case .synced: Image(systemName: "icloud").foregroundStyle(Theme.synced)
        case .notSynced: Image(systemName: "icloud").foregroundStyle(Theme.tertiaryText)
        }
    }

    private func text(_ phase: Phase) -> String {
        switch phase {
        case .off: "Sync off"
        case .failed: "Sync failed"
        case .syncing: "Syncing…"
        case .pending: "Sync pending"
        case .synced: "Synced"
        case .notSynced: "Not synced yet"
        }
    }

    private func helpText(_ phase: Phase) -> String {
        if case .error(let message) = sync.status { return message }
        switch phase {
        case .pending: return "Changes not on the server yet"
        case .synced:
            guard let last = sync.lastSync else { return "Synced" }
            let date: Date.FormatStyle.DateStyle = Calendar.current.isDateInToday(last) ? .omitted : .abbreviated
            return "Last synced \(last.formatted(date: date, time: .shortened))"
        default: return text(phase)
        }
    }
}

/// The sync glyph turning once every 1.2 s (still, in the accent color, with Reduce Motion).
private struct SpinningSyncGlyph: View {
    @State private var turning = false

    var body: some View {
        Image(systemName: "arrow.triangle.2.circlepath")
            .foregroundStyle(Theme.accent)
            .rotationEffect(.degrees(turning ? 360 : 0))
            .onAppear {
                guard !Theme.reduceMotion else { return }
                withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { turning = true }
            }
    }
}

/// A 24 × 24 glyph button in the sidebar footer.
private struct FooterButton: View {
    let icon: String
    let help: String
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(Fonts.icon)
                .foregroundStyle(!isEnabled ? Theme.disabledText : hovering ? Theme.text : Theme.secondaryText)
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).fill(hovering && isEnabled ? Theme.hover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}
