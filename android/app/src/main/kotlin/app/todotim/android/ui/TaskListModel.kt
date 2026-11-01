package app.todotim.android.ui

import app.todotim.android.data.TodoSnapshot
import app.todotim.core.EntityID
import app.todotim.core.Project
import app.todotim.core.TodoTask

/** One row of a task list: a group header or a task. */
sealed interface ListItem {
    val key: String

    /** A bold group header: a section in a project, or a project in search results. */
    data class Header(
        override val key: String,
        val title: String,
        val count: Int,
        /** Shown as a coloured `#` before the title (search results). */
        val project: Project? = null,
    ) : ListItem

    data class TaskItem(
        val task: TodoTask,
        val depth: Int,
        val subtaskCount: Int,
        val completedSubtaskCount: Int,
        /** The project, when the row should name it (lists that span projects). */
        val project: Project?,
    ) : ListItem {
        override val key: String get() = task.id
        val hasSubtasks: Boolean get() = subtaskCount > 0
    }
}

/** Builds the rows the screens show from a [TodoSnapshot]. Pure, so it is easy to test and preview. */
object TaskLists {
    /** A project: its tasks without section, then each section (header) with its tasks; subtasks indented. */
    fun project(s: TodoSnapshot, projectId: EntityID, showCompleted: Boolean): List<ListItem> {
        val out = mutableListOf<ListItem>()
        val topLevel = s.childrenOf[null].orEmpty().filter { it.projectId == projectId }
        val sectionIds = s.sections.map { it.id }.toSet()
        topLevel.filter { it.sectionId == null || it.sectionId !in sectionIds }
            .forEach { addTree(s, it, 0, showCompleted, null, out) }
        for (section in s.sections.filter { it.projectId == projectId }.sortedBy { it.order }) {
            val tasks = topLevel.filter { it.sectionId == section.id }
            val rows = mutableListOf<ListItem>()
            tasks.forEach { addTree(s, it, 0, showCompleted, null, rows) }
            out += ListItem.Header("section-${section.id}", section.name, tasks.count { !it.isCompleted })
            out += rows
        }
        return out
    }

    /** Open tasks carrying [label], in project order. */
    fun label(s: TodoSnapshot, label: String, showCompleted: Boolean): List<ListItem> =
        s.tasks.filter { label in it.labels && (showCompleted || !it.isCompleted) }
            .sortedWith(projectOrder(s))
            .map { taskItem(s, it, 0, s.projectsById[it.projectId]) }

    /** Open tasks whose title or description contains [query], grouped by project. */
    fun search(s: TodoSnapshot, query: String): List<ListItem> {
        val q = query.trim()
        if (q.isEmpty()) return emptyList()
        val matches = s.tasks.filter {
            !it.isCompleted && (it.content.contains(q, ignoreCase = true) || it.description.contains(q, ignoreCase = true))
        }
        return matches.groupBy { it.projectId }
            .mapNotNull { (id, tasks) -> s.projectsById[id]?.let { it to tasks } }
            .sortedWith(compareBy({ !it.first.isInbox }, { it.first.order }))
            .flatMap { (project, tasks) ->
                listOf(ListItem.Header("project-${project.id}", project.name, tasks.size, project)) +
                    tasks.sortedWith(projectOrder(s)).map { taskItem(s, it, 0, null) }
            }
    }

    /** Open tasks per project id, subtasks included. */
    fun openCounts(s: TodoSnapshot): Map<EntityID, Int> =
        s.tasks.filter { !it.isCompleted }.groupingBy { it.projectId }.eachCount()

    /** Open tasks per label name. */
    fun labelCounts(s: TodoSnapshot): Map<String, Int> =
        s.tasks.filter { !it.isCompleted }.flatMap { it.labels }.groupingBy { it }.eachCount()

    private fun projectOrder(s: TodoSnapshot): Comparator<TodoTask> = compareBy(
        { s.projectsById[it.projectId]?.order ?: Double.MAX_VALUE },
        { it.sectionId?.let { id -> s.sectionsById[id]?.order } ?: -1.0 },
        { it.order },
    )

    private fun addTree(s: TodoSnapshot, task: TodoTask, depth: Int, showCompleted: Boolean, project: Project?, out: MutableList<ListItem>) {
        if (task.isCompleted && !showCompleted) return
        out += taskItem(s, task, depth, project)
        if (task.collapsed) return
        s.childrenOf[task.id].orEmpty().forEach { addTree(s, it, depth + 1, showCompleted, project, out) }
    }

    private fun taskItem(s: TodoSnapshot, task: TodoTask, depth: Int, project: Project?): ListItem.TaskItem {
        val children = s.childrenOf[task.id].orEmpty()
        return ListItem.TaskItem(task, depth, children.size, children.count { it.isCompleted }, project)
    }
}
