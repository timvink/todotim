package app.todotim.android.ui

import androidx.compose.ui.graphics.Color
import app.todotim.core.EntityID
import app.todotim.core.Project
import app.todotim.core.ProjectColor
import app.todotim.core.TodoTask
import app.todotim.core.store.Snapshot

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

/** Builds the rows the screens show from a core [Snapshot]. Pure, so it is easy to test and preview. */
object TaskLists {
    /** A project: its tasks without section, then each section (header) with its tasks; subtasks indented. */
    fun project(s: Snapshot, projectId: EntityID, showCompleted: Boolean): List<ListItem> {
        val out = mutableListOf<ListItem>()
        s.taskIds(projectId, null, showCompleted).forEach { addTree(s, it, 0, showCompleted, out) }
        for (section in s.sections(projectId)) {
            out += ListItem.Header("section-${section.id}", section.name, s.openCount(projectId, section.id))
            s.taskIds(projectId, section.id, showCompleted).forEach { addTree(s, it, 0, showCompleted, out) }
        }
        return out
    }

    /** Open tasks carrying [label], in project order. */
    fun label(s: Snapshot, label: String): List<ListItem> =
        s.tasksWithLabel(label).map { taskItem(s, it, 0, s.project(it.projectId)) }

    /** Open tasks whose title or description contains [query], grouped by project. */
    fun search(s: Snapshot, query: String): List<ListItem> {
        if (query.isBlank()) return emptyList()
        val matches = s.search(query)
        val counts = matches.groupingBy { it.projectId }.eachCount()
        val out = mutableListOf<ListItem>()
        var current: EntityID? = null
        for (t in matches) { // in project order, so each project's matches are together
            if (t.projectId != current) {
                current = t.projectId
                val project = s.project(t.projectId) ?: s.inbox
                out += ListItem.Header("project-${project.id}", project.name, counts.getValue(t.projectId), project)
            }
            out += taskItem(s, t, 0, null)
        }
        return out
    }

    private fun addTree(s: Snapshot, id: EntityID, depth: Int, showCompleted: Boolean, out: MutableList<ListItem>) {
        val task = s.task(id) ?: return
        out += taskItem(s, task, depth, null)
        if (task.collapsed) return
        s.subtaskIds(id, showCompleted).forEach { addTree(s, it, depth + 1, showCompleted, out) }
    }

    private fun taskItem(s: Snapshot, task: TodoTask, depth: Int, project: Project?): ListItem.TaskItem {
        val (done, total) = s.subtaskProgress(task.id)
        return ListItem.TaskItem(task, depth, total, done, project)
    }
}

/** The palette colour of a project or label colour key. */
fun paletteColor(key: String): Color = Color(0xFF000000.toInt() or ProjectColor.entry(key).hex)
