import SwiftUI
import TodoCore

/// Search (`/` or ⌘F): field plus open tasks grouped by project.
struct SearchView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var model = model
        let groups = model.searchGroups()
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
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
                .padding(.bottom, 20)

                if model.searchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text("Type to search task names and descriptions.")
                        .foregroundStyle(.secondary).padding(.leading, Theme.gutter)
                } else if groups.isEmpty {
                    Text("No results for “\(model.searchQuery)”")
                        .foregroundStyle(.secondary).padding(.leading, Theme.gutter)
                }
                GroupedTaskList(groups: groups)
            }
            .frame(maxWidth: Theme.contentMaxWidth, alignment: .leading)
            .padding(.horizontal, 32).padding(.top, 20)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Search")
        .onAppear { focused = true }
        .onChange(of: model.searchFocusRequest) { focused = true }
    }
}

/// Open tasks with a label, grouped by project.
struct LabelView: View {
    @Environment(AppModel.self) private var model
    @Environment(TodoStore.self) private var store
    let name: String

    var body: some View {
        let groups = model.labelGroups(name)
        let color = store.labels.first { $0.name == name }.map { Palette.color($0.color) } ?? .secondary
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "tag").foregroundStyle(color)
                    Text(name)
                }
                .font(.system(size: 26, weight: .bold))
                .padding(.leading, Theme.gutter)
                .padding(.top, 8).padding(.bottom, 18)
                if groups.isEmpty {
                    Text("No open tasks with this label.").foregroundStyle(.secondary).padding(.leading, Theme.gutter)
                }
                GroupedTaskList(groups: groups)
            }
            .frame(maxWidth: Theme.contentMaxWidth, alignment: .leading)
            .padding(.horizontal, 32).padding(.top, 12)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(name)
    }
}

struct GroupedTaskList: View {
    @Environment(AppModel.self) private var model
    let groups: [(project: Project, tasks: [TodoTask])]

    private func flatItem(_ t: TodoTask) -> RowItem {
        var r = model.rowItem(t)
        r.hasChildren = false
        return r
    }

    var body: some View {
        ForEach(groups, id: \.project.id) { g in
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: g.project.isInbox ? "tray" : "number")
                        .foregroundStyle(g.project.isInbox ? Color(hex: 0x246FE0) : Palette.color(g.project.color))
                    Text(g.project.name).font(.system(size: 14, weight: .bold))
                    Text("\(g.tasks.count)").font(.system(size: 13)).foregroundStyle(.secondary)
                }
                .padding(.leading, Theme.gutter)
                .padding(.vertical, 6)
                Divider().padding(.leading, Theme.gutter)
                ForEach(g.tasks) { t in
                    TaskRowView(item: flatItem(t)).id(t.id)
                }
            }
            .padding(.bottom, 18)
        }
    }
}
