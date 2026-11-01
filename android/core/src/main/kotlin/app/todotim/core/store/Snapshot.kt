package app.todotim.core.store

import app.todotim.core.EntityID
import app.todotim.core.INBOX_ID
import app.todotim.core.Ids
import app.todotim.core.Label
import app.todotim.core.Project
import app.todotim.core.Section
import app.todotim.core.SyncLimits
import app.todotim.core.TextMatcher
import app.todotim.core.TodoTask

/** A place for top-level tasks: a project, and a section in it (null: above all sections). */
data class AreaKey(val projectId: EntityID, val sectionId: EntityID?)

/**
 * The read model the UI binds to: an immutable view of the [Database] at one moment, with the structure
 * repaired for display (docs/caldav.md, "Structure TodoTim cannot show is left alone"):
 *
 * - a subtask whose parent is unknown, in another project, part of a cycle, or deeper than
 *   [SyncLimits.MAX_TASK_DEPTH] shows as a top-level task;
 * - a top-level task in a section its project does not have shows without a section; a subtask shows in its
 *   root task's section;
 * - a task in an unknown project shows in the inbox.
 *
 * [task] and the lists return tasks with that repaired `projectId`/`sectionId`/`parentId`. The database keeps
 * the raw values, so the repair is never written to the server. Lists are sorted by `order`, then creation time,
 * then id, and include completed tasks only when asked.
 */
class Snapshot private constructor(
    /** Live projects, the inbox first, then by order. */
    val projects: List<Project>,
    private val sectionsByProject: Map<EntityID, List<Section>>,
    /** Labels by order: the server's, then names that tasks use without a label entry. */
    val labels: List<Label>,
    private val tasksById: Map<EntityID, TodoTask>,
    private val top: Map<AreaKey, List<EntityID>>,
    private val children: Map<EntityID, List<EntityID>>,
    private val openByProject: Map<EntityID, Int>,
    private val openTopByArea: Map<AreaKey, Int>,
    /** Tasks with changes the server has not seen yet (new, edited or deleted). */
    val unsyncedCount: Int,
    /** Epoch milliseconds of the last complete sync. */
    val lastSyncAt: Long?,
    /** Increases with every change; a cheap cache key. */
    val version: Long,
) {
    private val projectsById = projects.associateBy { it.id }

    fun project(id: EntityID): Project? = projectsById[id]
    val inbox: Project get() = projectsById[INBOX_ID] ?: Database.defaultInbox()

    fun sections(projectId: EntityID): List<Section> = sectionsByProject[projectId].orEmpty()

    /** A task with its repaired structure, or null if there is no such (live) task. */
    fun task(id: EntityID): TodoTask? = tasksById[id]

    val allTasks: Collection<TodoTask> get() = tasksById.values

    /** Ids of the top-level tasks in a project area, sorted. */
    fun taskIds(projectId: EntityID, sectionId: EntityID?, includeCompleted: Boolean = false): List<EntityID> =
        filter(top[AreaKey(projectId, sectionId)], includeCompleted)

    fun tasks(projectId: EntityID, sectionId: EntityID?, includeCompleted: Boolean = false): List<TodoTask> =
        taskIds(projectId, sectionId, includeCompleted).mapNotNull(tasksById::get)

    /** Ids of the direct subtasks of a task, sorted. */
    fun subtaskIds(parentId: EntityID, includeCompleted: Boolean = false): List<EntityID> =
        filter(children[parentId], includeCompleted)

    fun subtasks(parentId: EntityID, includeCompleted: Boolean = false): List<TodoTask> =
        subtaskIds(parentId, includeCompleted).mapNotNull(tasksById::get)

    /** The siblings of a place (the subtasks of [parentId], or the top-level tasks of the area), sorted. */
    fun siblingIds(projectId: EntityID, sectionId: EntityID?, parentId: EntityID?, includeCompleted: Boolean = true): List<EntityID> =
        if (parentId != null) subtaskIds(parentId, includeCompleted) else taskIds(projectId, sectionId, includeCompleted)

    /** All subtasks below a task, depth first. */
    fun descendantIds(id: EntityID): List<EntityID> {
        val out = ArrayList<EntityID>()
        val stack = ArrayDeque(children[id].orEmpty().reversed())
        while (stack.isNotEmpty()) {
            val cur = stack.removeLast()
            out.add(cur)
            children[cur]?.let { for (c in it.asReversed()) stack.addLast(c) }
        }
        return out
    }

    /** Open tasks in a project, at any depth. */
    fun openCount(projectId: EntityID): Int = openByProject[projectId] ?: 0

    /** Open top-level tasks in a project area (section headers). */
    fun openCount(projectId: EntityID, sectionId: EntityID?): Int = openTopByArea[AreaKey(projectId, sectionId)] ?: 0

    /** Direct subtasks: (completed, total). */
    fun subtaskProgress(parentId: EntityID): Pair<Int, Int> {
        val ids = children[parentId].orEmpty()
        return ids.count { tasksById[it]?.isCompleted == true } to ids.size
    }

    /** Open tasks with the label (any project or depth), in project order. */
    fun tasksWithLabel(name: String): List<TodoTask> = ordered { !it.isCompleted && name in it.labels }

    fun openLabelCount(label: String): Int = tasksById.values.count { !it.isCompleted && label in it.labels }

    /** Open tasks whose title or description contains [query] (case-insensitive), in project order. */
    fun search(query: String): List<TodoTask> {
        val m = TextMatcher(query.trim())
        return ordered { !it.isCompleted && (m.matches(it.content) || m.matches(it.description)) }
    }

    /** Tasks matching [predicate], in display order (projects, sections, then depth-first). */
    private fun ordered(predicate: (TodoTask) -> Boolean): List<TodoTask> {
        val out = ArrayList<TodoTask>()
        for (p in projects) {
            for (sid in listOf<EntityID?>(null) + sections(p.id).map { it.id }) {
                for (id in top[AreaKey(p.id, sid)].orEmpty()) {
                    for (tid in listOf(id) + descendantIds(id)) tasksById[tid]?.takeIf(predicate)?.let(out::add)
                }
            }
        }
        return out
    }

    private fun filter(ids: List<EntityID>?, includeCompleted: Boolean): List<EntityID> {
        if (ids == null) return emptyList()
        return if (includeCompleted) ids else ids.filter { tasksById[it]?.isCompleted == false }
    }

    companion object {
        val EMPTY: Snapshot = build(Database(), 0)

        val taskOrder: Comparator<TodoTask> = compareBy<TodoTask> { it.order }.thenBy { it.createdAt }.thenBy { it.id }

        fun build(db: Database, version: Long): Snapshot {
            val projects = db.projects.values.toMutableList()
            if (projects.none { it.id == INBOX_ID }) projects.add(Database.defaultInbox())
            projects.sortWith(compareBy<Project> { if (it.isInbox || it.id == INBOX_ID) 0 else 1 }.thenBy { it.order }.thenBy { it.name }.thenBy { it.id })
            val projectIds = projects.map { it.id }.toSet()

            val sectionsByProject = db.sections.values.filter { it.projectId in projectIds }
                .groupBy { it.projectId }
                .mapValues { (_, list) -> list.sortedWith(compareBy<Section> { it.order }.thenBy { it.id }) }

            // Structure repair.
            val raw = db.tasks
            fun projectOf(t: TodoTask) = if (t.projectId in projectIds) t.projectId else INBOX_ID
            val parent = HashMap<EntityID, EntityID?>(raw.size * 2)
            for (t in raw.values) {
                val p = t.parentId?.takeIf { it != t.id }?.let(raw::get)
                parent[t.id] = p?.takeIf { projectOf(it) == projectOf(t) }?.id
            }
            // Break cycles: walk up from each task; a task met twice on one walk closes a cycle, which is cut at
            // its smallest id (deterministic, so every device shows the same).
            val state = HashMap<EntityID, Int>() // 1: on the current walk, 2: done
            for (start in raw.keys.sorted()) {
                if (state[start] == 2) continue
                val walk = ArrayList<EntityID>()
                var cur: EntityID? = start
                while (cur != null && state[cur] == null) {
                    state[cur] = 1
                    walk.add(cur)
                    cur = parent[cur]
                }
                if (cur != null && state[cur] == 1) {
                    val cycle = walk.subList(walk.indexOf(cur), walk.size)
                    parent[cycle.min()] = null
                }
                for (w in walk) state[w] = 2
            }
            // Depth: a task more than MAX_TASK_DEPTH levels deep becomes top-level.
            val depth = HashMap<EntityID, Int>(raw.size * 2)
            fun depthOf(id: EntityID): Int {
                depth[id]?.let { return it }
                val chain = ArrayList<EntityID>()
                var cur: EntityID? = id
                while (cur != null && depth[cur] == null) {
                    chain.add(cur)
                    cur = parent[cur]
                }
                var d = cur?.let { depth[it] } ?: 0
                for (c in chain.asReversed()) {
                    d = if (parent[c] == null) 1 else d + 1
                    if (d > SyncLimits.MAX_TASK_DEPTH) {
                        parent[c] = null
                        d = 1
                    }
                    depth[c] = d
                }
                return depth.getValue(id)
            }
            raw.keys.forEach(::depthOf)
            fun root(id: EntityID): EntityID {
                var cur = id
                while (true) cur = parent[cur] ?: return cur
            }

            val tasks = HashMap<EntityID, TodoTask>(raw.size * 2)
            for (t in raw.values) {
                val pid = projectOf(t)
                val r = raw.getValue(root(t.id))
                val sid = r.sectionId?.takeIf { s -> db.sections[s]?.projectId == pid }
                val fixed = if (pid == t.projectId && sid == t.sectionId && parent[t.id] == t.parentId) t
                else t.copy(projectId = pid, sectionId = sid, parentId = parent[t.id])
                tasks[t.id] = fixed
            }

            val top = HashMap<AreaKey, MutableList<TodoTask>>()
            val children = HashMap<EntityID, MutableList<TodoTask>>()
            val openByProject = HashMap<EntityID, Int>()
            val openTopByArea = HashMap<AreaKey, Int>()
            for (t in tasks.values) {
                val key = AreaKey(t.projectId, t.sectionId)
                val p = t.parentId
                if (p == null) top.getOrPut(key) { ArrayList() }.add(t) else children.getOrPut(p) { ArrayList() }.add(t)
                if (!t.isCompleted) {
                    openByProject.merge(t.projectId, 1, Int::plus)
                    if (p == null) openTopByArea.merge(key, 1, Int::plus)
                }
            }

            val labels = ArrayList<Label>()
            val names = HashSet<String>()
            for (l in db.labels.values.sortedWith(compareBy<Label> { it.order }.thenBy { it.id })) {
                if (names.add(l.name)) labels.add(l)
            }
            var nextOrder = (labels.maxOfOrNull { it.order } ?: 0.0) + 1
            for (name in tasks.values.flatMap { it.labels }.toSortedSet()) {
                if (names.add(name)) labels.add(Label(Ids.labelId(name), name, order = nextOrder++))
            }

            val unsynced = db.pendingDeletes.size + db.tasks.values.count { t ->
                val s = db.shadows[t.id]
                s == null || TaskFields.edited(t, s.task)
            }

            return Snapshot(
                projects = projects,
                sectionsByProject = sectionsByProject,
                labels = labels,
                tasksById = tasks,
                top = top.mapValues { (_, l) -> l.sortedWith(taskOrder).map { it.id } },
                children = children.mapValues { (_, l) -> l.sortedWith(taskOrder).map { it.id } },
                openByProject = openByProject,
                openTopByArea = openTopByArea,
                unsyncedCount = unsynced,
                lastSyncAt = db.lastSyncAt,
                version = version,
            )
        }
    }
}
