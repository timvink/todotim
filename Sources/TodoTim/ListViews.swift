import SwiftUI
import TodoCore

/// Search (`/` or ⌘F): field plus open tasks grouped by project.
struct SearchView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search tasks", text: $model.searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 18))
                    .focused($focused)
                    .onExitCommand { focused = false }
                    .onSubmit {
                        focused = false
                        model.selectedTaskID = model.visibleTaskIDs().first
                    }
                if !model.searchQuery.isEmpty {
                    Button { model.searchQuery = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
            .padding(.leading, Theme.gutter)
            .frame(maxWidth: Theme.contentMaxWidth, alignment: .leading)
            .padding(.horizontal, 32).padding(.top, 20)
            .frame(maxWidth: .infinity)
            SearchResults()
        }
        .navigationTitle("Search")
        .onAppear { focused = true }
        .onChange(of: model.searchFocusRequest) { focused = true }
    }
}

/// Separate view so that only the results (not the field) depend on the store.
private struct SearchResults: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        TaskListView(items: model.display().items, topPadding: 20)
    }
}

/// Open tasks with a label, grouped by project.
struct LabelView: View {
    @Environment(AppModel.self) private var model
    let name: String

    var body: some View {
        TaskListView(items: model.display().items, title: name)
            .navigationTitle(name)
    }
}

struct LabelHeaderView: View {
    @Environment(TodoStore.self) private var store
    let name: String

    var body: some View {
        let color = store.labels.first { $0.name == name }.map { Palette.color($0.color) } ?? .secondary
        HStack(spacing: 8) {
            Image(systemName: "tag").foregroundStyle(color)
            Text(name)
        }
        .font(.system(size: 26, weight: .bold))
        .padding(.leading, Theme.gutter)
        .padding(.top, 8).padding(.bottom, 18)
    }
}

/// "# Project  12" heading above a project's results in label and search views.
struct GroupHeaderView: View {
    @Environment(TodoStore.self) private var store
    let projectId: EntityID
    let count: Int

    var body: some View {
        if let p = store.project(projectId) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: p.isInbox ? "tray" : "number")
                        .foregroundStyle(p.isInbox ? Color(hex: 0x246FE0) : Palette.color(p.color))
                    Text(p.name).font(.system(size: 14, weight: .bold))
                    Text("\(count)").font(.system(size: 13)).foregroundStyle(.secondary)
                }
                .padding(.leading, Theme.gutter)
                .padding(.vertical, 6)
                Divider().padding(.leading, Theme.gutter)
            }
            .padding(.top, 18)
        }
    }
}
