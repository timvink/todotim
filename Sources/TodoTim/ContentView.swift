import SwiftUI
import TodoCore

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(TodoStore.self) private var store
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 270, max: 380)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor))
                .overlay(alignment: .bottomLeading) { ToastView().padding(20) }
        }
        .tint(Theme.accent)
        .toolbar(removing: .title)
        .toolbarBackground(.hidden, for: .windowToolbar)
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
        Text("Select a project").foregroundStyle(.secondary)
    }
}

/// Dimmed backdrop and centred panel for the in-window modals. Clicking the backdrop closes the
/// panel; Esc is handled by `KeyRouter`. Only this small body depends on which modal is open.
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
                    TaskDetailView(size: CGSize(width: min(720, size.width - 40),
                                                height: max(320, min(size.height - 96, 960))))
                        .modalPanel()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if quickAdd {
                    Backdrop { model.showQuickAdd = false }
                    QuickAddView()
                        .frame(width: min(620, size.width - 40))
                        .modalPanel()
                        .padding(.top, max(60, size.height * 0.16))
                }
                if shortcuts {
                    Backdrop { model.showShortcuts = false }
                    ShortcutsHelpView()
                        .frame(width: min(680, size.width - 40), height: max(300, min(560, size.height - 96)))
                        .modalPanel()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(width: size.width, height: size.height)
        }
        .animation(.easeOut(duration: 0.12), value: detail)
        .animation(.easeOut(duration: 0.12), value: quickAdd)
        .animation(.easeOut(duration: 0.12), value: shortcuts)
    }
}

private struct Backdrop: View {
    let close: () -> Void
    var body: some View {
        Color.black.opacity(0.4)
            .contentShape(Rectangle())
            .onTapGesture(perform: close)
            .transition(.opacity)
    }
}

extension View {
    /// Rounded, shadowed panel used by the in-window modals.
    func modalPanel() -> some View {
        self
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.12)))
            .shadow(color: .black.opacity(0.3), radius: 24, y: 8)
            .transition(.opacity.combined(with: .scale(scale: 0.98)))
    }
}

/// Todoist-style "1 task completed  Undo" toast.
struct ToastView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let toast = model.toast {
            HStack(spacing: 14) {
                Text(toast.message).font(.system(size: 13))
                if let undo = toast.undo {
                    Button("Undo") {
                        undo()
                        model.toast = nil
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                }
                Button { model.toast = nil } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .windowBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12)))
            .shadow(color: .black.opacity(0.2), radius: 8, y: 2)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .id(toast.id)
        }
    }
}
