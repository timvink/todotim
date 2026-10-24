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
        .sheet(isPresented: Binding(get: { model.detailTaskID != nil }, set: { if !$0 { model.detailTaskID = nil } })) {
            TaskDetailView()
                .environment(model).environment(store)
        }
        .sheet(isPresented: $model.showQuickAdd) {
            QuickAddView().environment(model).environment(store)
        }
        .sheet(isPresented: $model.showShortcuts) {
            ShortcutsHelpView()
        }
        .sheet(isPresented: $model.showAddProject) {
            ProjectFormView(project: nil).environment(model).environment(store)
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
