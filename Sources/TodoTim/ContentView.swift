import SwiftUI
import TodoCore

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(TodoStore.self) private var store
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: $model.columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 360)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.background)
                .overlay(alignment: .bottomLeading) { ToastView().padding(20) }
        }
        .tint(Theme.accent)
        .toolbar(removing: .title)
        .background(WindowAccessor { window in
            if model.mainWindow !== window { model.mainWindow = window }
        })
        .onAppear { model.undoManager = undoManager }
        .onChange(of: undoManager) { _, um in model.undoManager = um }
        // Task view, Quick Add and the shortcuts list are panels inside the window, like Todoist.
        .overlay { ModalLayer().ignoresSafeArea() }
        .sheet(isPresented: $model.showAddProject) {
            ProjectFormView(project: nil).environment(model).environment(store)
        }
        .sheet(isPresented: $model.showImportTodoist) {
            ImportTodoistView().environment(store)
        }
        .alert("Problem at launch", isPresented: Binding(get: { model.startupError != nil },
                                                                 set: { if !$0 { model.startupError = nil } })) {
            Button("OK", role: .cancel) { model.startupError = nil }
        } message: {
            Text(model.startupError ?? "")
        }
        .alert("Delete task?", isPresented: Binding(get: { model.confirmDeleteTaskID != nil },
                                                    set: { if !$0 { model.confirmDeleteTaskID = nil } })) {
            Button("Delete", role: .destructive) {
                if let id = model.confirmDeleteTaskID { model.deleteTask(id) }
                model.confirmDeleteTaskID = nil
            }
            Button("Cancel", role: .cancel) { model.confirmDeleteTaskID = nil }
        } message: {
            if let id = model.confirmDeleteTaskID, let t = store.task(id) {
                Text("“\(t.content)” and its sub-tasks will be deleted.")
            }
        }
    }

    @ViewBuilder private var detail: some View {
        switch model.sidebar {
        case .project(let id):
            if store.project(id) != nil {
                ProjectView(projectId: id).id(id)
            } else {
                emptyState
            }
        case .label(let name):
            LabelView(name: name).id(name)
        case .search:
            SearchView()
        case nil:
            emptyState
        }
    }

    private var emptyState: some View {
        Text("Select a project").font(Fonts.body).foregroundStyle(Theme.tertiaryText)
    }
}

/// Dimmed backdrop and panel for the in-window modals. Clicking the backdrop closes the panel;
/// Esc is handled by `KeyRouter`. Only this small body depends on which modal is open. Panels are
/// anchored near the top, so they grow downwards instead of jumping when their content changes.
private struct ModalLayer: View {
    @Environment(AppModel.self) private var model
    @Environment(TodoStore.self) private var store

    var body: some View {
        let detail = model.detailTaskID != nil
        let quickAdd = model.showQuickAdd
        let shortcuts = model.showShortcuts
        GeometryReader { geo in
            let size = geo.size
            ZStack(alignment: .top) {
                if detail {
                    Backdrop { model.detailTaskID = nil }
                    // Below the list's pinned title, so the panel never covers where you are.
                    TaskDetailView(size: CGSize(width: min(600, size.width - 48),
                                                height: max(240, min(size.height - Theme.titleBarHeight - 40, 680))))
                        .modalPanel()
                        .padding(.top, Theme.titleBarHeight)
                }
                if quickAdd {
                    Backdrop { model.showQuickAdd = false }
                    QuickAddView()
                        .frame(width: min(560, size.width - 48))
                        .modalPanel(lift: 8)
                        .padding(.top, max(56, size.height * 0.14))
                }
                if shortcuts {
                    Backdrop { model.showShortcuts = false }
                    ShortcutsHelpView()
                        .frame(width: min(640, size.width - 48), height: max(300, min(560, size.height - 96)))
                        .modalPanel()
                        .padding(.top, Theme.titleBarHeight)
                }
            }
            .frame(width: size.width, height: size.height, alignment: .top)
        }
        .animation(detail ? Theme.panelIn : Theme.panelOut, value: detail)
        .animation(quickAdd ? Theme.panelIn : Theme.panelOut, value: quickAdd)
        .animation(shortcuts ? Theme.panelIn : Theme.panelOut, value: shortcuts)
    }
}

private struct Backdrop: View {
    let close: () -> Void
    var body: some View {
        Theme.scrim
            .contentShape(Rectangle())
            .onTapGesture(perform: close)
            .transition(.opacity)
    }
}

extension View {
    /// Rounded, shadowed panel used by the in-window modals. It opens with a slight zoom (and
    /// `lift`, rising into place) and closes with a fade.
    func modalPanel(lift: CGFloat = 0) -> some View {
        self
            .background(Theme.panel)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.panelBorder))
            .shadow(color: Theme.shadow, radius: 28, y: 10)
            .transition(.asymmetric(
                insertion: .opacity.combined(with: .scale(scale: 0.97, anchor: .top)).combined(with: .offset(y: -lift)),
                removal: .opacity))
    }
}

/// Todoist-style "1 task completed  Undo" toast.
struct ToastView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let toast = model.toast {
                content(toast)
                    .id(toast.id)
                    .transition(.offset(y: 8).combined(with: .opacity))
            }
        }
        .animation(Theme.reduceMotion ? .easeOut(duration: 0.08) : .snappy(duration: 0.2), value: model.toast?.id)
    }

    private func content(_ toast: ToastInfo) -> some View {
        HStack(spacing: 14) {
            Text(toast.message).font(Fonts.body).foregroundStyle(Theme.text)
            if let undo = toast.undo {
                Button("Undo") {
                    undo()
                    model.toast = nil
                }
                .buttonStyle(.plain)
                .font(Fonts.bodySemibold)
                .foregroundStyle(Theme.accent)
                .pointerStyle(.link)
            }
            Button { model.toast = nil } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.tertiaryText)
            .help("Dismiss")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Ctp.surface0.color))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.panelBorder))
        .shadow(color: Theme.shadow, radius: 14, y: 4)
    }
}
