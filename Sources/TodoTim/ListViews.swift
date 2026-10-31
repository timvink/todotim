import SwiftUI
import TodoCore

/// Search (`/` or ⌘F): the query is typed where the page title would be; open tasks grouped by
/// project below.
struct SearchView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TaskListView(items: model.display().items, topPadding: 8) {
            SearchField()
        }
        .navigationTitle("Search")
    }
}

/// Separate view so that only the field (not the results) depends on its focus.
private struct SearchField: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(focused ? Theme.accent : Theme.tertiaryText)
            TextField("Search", text: $model.searchQuery,
                      prompt: Text("Search").foregroundStyle(Theme.tertiaryText))
                .textFieldStyle(.plain)
                .font(Fonts.pageTitle)
                .foregroundStyle(Theme.text)
                .focused($focused)
                .onExitCommand { focused = false }
                .onSubmit {
                    focused = false
                    model.selectedTaskID = model.visibleTaskIDs().first
                }
            if !model.searchQuery.isEmpty {
                Button { model.searchQuery = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(Fonts.icon)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.tertiaryText)
                .help("Clear")
            }
        }
        .onAppear { focused = true }
        .onChange(of: model.searchFocusRequest) { focused = true }
    }
}

/// Open tasks with a label, grouped by project.
struct LabelView: View {
    @Environment(AppModel.self) private var model
    let name: String

    var body: some View {
        TaskListView(items: model.display().items) {
            LabelTitle(name: name)
        }
        .navigationTitle(name)
    }
}

private struct LabelTitle: View {
    @Environment(TodoStore.self) private var store
    let name: String

    var body: some View {
        let color = store.labels.first { $0.name == name }.map { Palette.color($0.color) } ?? Theme.tertiaryText
        HStack(spacing: 10) {
            Image(systemName: "tag").font(.system(size: 17, weight: .medium)).foregroundStyle(color)
            Text(name).font(Fonts.pageTitle).foregroundStyle(Theme.text).lineLimit(1)
        }
    }
}

/// A project's heading above its results in label and search views.
struct GroupHeaderView: View {
    @Environment(TodoStore.self) private var store
    let projectId: EntityID
    let count: Int

    var body: some View {
        if let p = store.project(projectId) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    ProjectIcon(p, size: 10)
                        .frame(width: Theme.checkbox)
                    Text(p.name).font(Fonts.bodySemibold).foregroundStyle(Theme.text)
                    Text("\(count)").font(Fonts.meta).monospacedDigit().foregroundStyle(Theme.tertiaryText)
                }
                .padding(.leading, Theme.gutter + Theme.rowInset)
                .padding(.vertical, 4)
                Hairline().padding(.leading, Theme.gutter)
            }
            .padding(.top, 14)
        }
    }
}
