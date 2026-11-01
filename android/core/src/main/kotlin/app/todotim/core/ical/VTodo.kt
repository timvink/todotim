package app.todotim.core.ical

import app.todotim.core.EntityID
import app.todotim.core.Ids
import app.todotim.core.Priority
import app.todotim.core.Section
import app.todotim.core.SyncLimits
import app.todotim.core.TodoTask
import app.todotim.core.isValidEntityID
import java.text.Normalizer
import java.time.LocalDate
import java.time.ZoneId

/** A task as read from one CalDAV resource: the [TodoTask] plus what only the resource knows. */
data class VTodoTask(
    val task: TodoTask,
    val uid: String,
    /** Section name and order from the `X-TODOTIM-SECTION` parameters (see docs/caldav.md). */
    val sectionName: String? = null,
    val sectionOrder: Double? = null,
)

/**
 * Mapping between [TodoTask] and a VTODO (docs/caldav.md; mirrors `VTodo` in the Swift TodoCore). Reading never
 * fails on content TodoTim does not understand; writing patches only the properties TodoTim owns, so alarms,
 * recurrence details, start dates and other clients' X- properties survive.
 *
 * Times are epoch milliseconds; iCalendar holds whole seconds. [ZoneId] parameters play the role of Swift's
 * `Calendar`: the device timezone in which DATE-TIME due dates are read as dates.
 */
object VTodo {
    const val PROD_ID = "-//TodoTim//TodoTim//EN"

    /** Largest UID accepted (longer ones make the resource unreadable). */
    const val MAX_UID_LENGTH = 1_000
    const val MAX_RULE_LENGTH = 1_000

    /** Seconds between 1970-01-01 and 2001-01-01, the epoch of `X-APPLE-SORT-ORDER` defaults. */
    const val APPLE_EPOCH = 978_307_200L

    /** The entity id for a UID: the UID itself when valid, else a stable name-based UUID. */
    fun taskId(uid: String): EntityID = Ids.taskId(uid)

    // Read

    /**
     * The task in [ics], or null when it holds no usable VTODO (no VCALENDAR, no UID, malformed). The master
     * VTODO (without RECURRENCE-ID) is used. Remote text is clipped to [SyncLimits]. [zone] converts UTC and TZID
     * due times to a date and reads floating times.
     */
    fun read(ics: String, projectId: EntityID, zone: ZoneId = ZoneId.systemDefault()): VTodoTask? {
        val root = try { ICalendar.parse(ics) } catch (_: ICalException) { return null }
        if (root.name != "VCALENDAR") return null
        val todo = master(root) ?: return null
        val uid = todo.first("UID")?.value?.let(::trimWhitespace) ?: return null
        if (uid.isEmpty() || utf8Length(uid) > MAX_UID_LENGTH) return null
        fun text(name: String, limit: Int) = clip(todo.first(name)?.let { ICalendar.unescapeText(it.value) } ?: "", limit)
        fun instant(name: String) = todo.first(name)?.let { ICalendar.instant(it, zone) }
        val created = instant("CREATED") ?: instant("DTSTAMP") ?: instant("LAST-MODIFIED") ?: 0L
        val modified = instant("LAST-MODIFIED") ?: instant("DTSTAMP") ?: created

        val status = todo.first("STATUS")?.value?.uppercase()
        val completed = status == "COMPLETED" || status == "CANCELLED" || (status == null && todo.first("COMPLETED") != null)

        val labels = ArrayList<String>()
        val seen = HashSet<String>()
        for (p in todo.all("CATEGORIES")) {
            for (name in ICalendar.splitTextList(p.value)) {
                val n = clip(trimWhitespace(name), SyncLimits.MAX_NAME_LENGTH)
                // Swift compares strings by canonical equivalence.
                if (n.isNotEmpty() && labels.size < SyncLimits.MAX_LABELS_PER_TASK && seen.add(nfc(n))) labels.add(n)
            }
        }

        val parentUid = todo.all("RELATED-TO").firstOrNull(::isParent)
            ?.let { trimWhitespace(it.value) }?.takeIf { it.isNotEmpty() && utf8Length(it) <= MAX_UID_LENGTH }

        val sectionLine = todo.first("X-TODOTIM-SECTION")
        val sectionId = sectionLine?.let { trimWhitespace(it.value) }?.takeIf(::isValidEntityID)

        val id = taskId(uid)
        val task = TodoTask(
            id = id, projectId = projectId, sectionId = sectionId,
            parentId = parentUid?.let(::taskId)?.takeIf { it != id },
            content = text("SUMMARY", SyncLimits.MAX_CONTENT_LENGTH),
            description = text("DESCRIPTION", SyncLimits.MAX_DESCRIPTION_LENGTH),
            priority = priority(todo.first("PRIORITY")?.value),
            due = todo.first("DUE")?.let(DateValue::of)?.localDate(zone),
            labels = labels, isCompleted = completed,
            completedAt = if (completed) (instant("COMPLETED") ?: modified) else null,
            order = order(todo, created),
            collapsed = todo.first("X-OC-HIDESUBTASKS")?.let { trimWhitespace(it.value) } == "1",
            recurrence = todo.first("RRULE")?.let { clip(it.value, MAX_RULE_LENGTH) },
            createdAt = created, updatedAt = modified,
        )
        return VTodoTask(
            task, uid,
            sectionName = if (sectionId == null) null else sectionLine?.param("X-NAME")?.let { clip(normalizeNewlines(it), SyncLimits.MAX_NAME_LENGTH) },
            sectionOrder = if (sectionId == null) null else sectionLine?.param("X-ORDER")?.let(::finiteDouble),
        )
    }

    /**
     * The VTODO without RECURRENCE-ID. An object that holds only overrides of another object's occurrences has
     * none and is not a task of its own.
     */
    private fun masterIndex(root: ICalComponent): Int =
        root.components.indexOfFirst { it.name == "VTODO" && it.first("RECURRENCE-ID") == null }

    private fun master(root: ICalComponent): ICalComponent? = root.components.getOrNull(masterIndex(root))

    private fun isParent(p: ICalProperty): Boolean {
        val type = p.param("RELTYPE")?.uppercase()
        return type == null || type == "PARENT"
    }

    /** RFC 5545 priority: 1–4 high, 5 medium, 6–9 low, 0 or absent none. */
    fun priority(value: String?): Priority =
        when (value?.let { parseLong(trimWhitespace(it)) } ?: 0L) {
            in 1L..4L -> Priority.P1
            5L -> Priority.P2
            in 6L..9L -> Priority.P3
            else -> Priority.P4
        }

    fun icalPriority(p: Priority): String = when (p) {
        Priority.P1 -> "1"
        Priority.P2 -> "5"
        Priority.P3 -> "9"
        Priority.P4 -> "0"
    }

    /**
     * `X-TODOTIM-ORDER` when it agrees with `X-APPLE-SORT-ORDER` (equal to its floor) or that is absent; else
     * `X-APPLE-SORT-ORDER` (another client reordered); else CREATED in seconds since 2001, so tasks without an
     * order sort after ordered ones by age.
     */
    fun order(todo: ICalComponent, created: Long): Double {
        val precise = todo.first("X-TODOTIM-ORDER")?.let { finiteDouble(it.value) }
        val apple = todo.first("X-APPLE-SORT-ORDER")?.let { parseLong(trimWhitespace(it.value)) }
        if (precise != null && (apple == null || apple == appleOrder(precise))) return precise
        if (apple != null) return apple.toDouble()
        return (Math.floorDiv(created, 1000L) - APPLE_EPOCH).toDouble()
    }

    /** The integer `X-APPLE-SORT-ORDER` written for an order: its floor (clamped). */
    fun appleOrder(order: Double): Long {
        val f = Math.floor(order)
        if (f >= 9.2e18) return Long.MAX_VALUE
        if (f <= -9.2e18) return Long.MIN_VALUE
        return f.toLong()
    }

    fun finiteDouble(s: String): Double? = parseDouble(trimWhitespace(s))?.takeIf { it.isFinite() }

    /** Shortest representation that reads back as the same Double, as Swift writes it (`2`, `0.25`, `1e-05`). */
    fun format(d: Double): String =
        if (d == Math.floor(d) && Math.abs(d) < 1e15) d.toLong().toString() else swiftDescription(d)

    /** CR LF and CR become LF (a parameter cannot hold a CR, so names are compared without it). */
    fun normalizeNewlines(s: String): String =
        if (!s.contains('\r')) s else s.replace("\r\n", "\n").replace("\r", "\n")

    /** [s] cut to at most [max] characters (grapheme clusters), as remote text is on read. */
    internal fun clip(s: String, max: Int): String {
        if (s.length <= max && utf8Length(s) <= max) return s
        val g = graphemes(s)
        return if (g.size > max) g.subList(0, max).joinToString("") else s
    }

    // Write

    /**
     * What TodoTim writes, compared between the resource and the local task to decide whether (and which
     * properties) to write. Times are compared in whole seconds, like iCalendar; text by canonical equivalence,
     * like Swift strings.
     */
    private data class Fields(
        val content: String,
        val description: String,
        val priority: Priority,
        val due: LocalDate?,
        val isCompleted: Boolean,
        val completedAt: Long?,
        val parentId: EntityID?,
        val order: Double,
        val collapsed: Boolean,
        val labels: List<String>,
        val sectionId: EntityID?,
        val sectionName: String?,
        val sectionOrder: Double?,
        val recurrence: String?,
        val createdAt: Long,
    ) {
        companion object {
            fun of(t: TodoTask, sectionId: EntityID?, sectionName: String?, sectionOrder: Double?) = Fields(
                content = nfc(t.content), description = nfc(t.description), priority = t.priority, due = t.due,
                isCompleted = t.isCompleted,
                completedAt = if (t.isCompleted) t.completedAt?.let(::seconds) else null,
                parentId = t.parentId, order = t.order + 0.0, // + 0.0: -0.0 equals 0.0, as in Swift
                 collapsed = t.collapsed, labels = t.labels.map(::nfc),
                sectionId = sectionId, sectionName = sectionName?.let(::nfc), sectionOrder = sectionOrder?.plus(0.0),
                recurrence = t.recurrence?.let(::nfc), createdAt = seconds(t.createdAt),
            )

            fun of(t: TodoTask, section: Section?) = of(t, section?.id, section?.name, section?.order)
            fun of(v: VTodoTask) = of(v.task, v.task.sectionId, v.sectionName, v.sectionOrder)
        }
    }

    /** Whole seconds (rounded down) of epoch milliseconds. */
    fun seconds(epochMillis: Long): Long = Math.floorDiv(epochMillis, 1000L)

    /**
     * A new calendar object for [task]. [parentUid] is the parent's UID; [section] the task's (live) section,
     * whose name and order are copied into `X-TODOTIM-SECTION`.
     */
    fun make(task: TodoTask, uid: String, parentUid: String?, section: Section?): String {
        val todo = ICalComponent("VTODO", mutableListOf(ICalProperty("UID", uid)))
        apply(task, parentUid, section, changed = null, old = null, todo = todo, zone = ZoneId.systemDefault())
        val root = ICalComponent(
            "VCALENDAR",
            mutableListOf(ICalProperty("VERSION", "2.0"), ICalProperty("PRODID", PROD_ID)),
            mutableListOf(todo),
        )
        return ICalendar.serialize(root)
    }

    /**
     * [ics] with the master VTODO's owned properties rewritten where [task] differs from [old] (the resource as
     * read). Returns null when nothing differs or [ics] cannot be parsed. [zone] is the one [old] was read in: a
     * DATE-TIME due date moves by the days between its local date and the new one.
     */
    fun patch(
        ics: String, old: VTodoTask, task: TodoTask, parentUid: String?, section: Section?,
        zone: ZoneId = ZoneId.systemDefault(),
    ): String? {
        val before = Fields.of(old)
        val after = Fields.of(task, section)
        if (before == after) return null
        val root = try { ICalendar.parse(ics) } catch (_: ICalException) { return null }
        val index = masterIndex(root)
        if (index < 0) return null
        val todo = root.components[index]
        apply(task, parentUid, section, changed = before to after, old = todo.deepCopy(), todo = todo, zone = zone)
        return ICalendar.serialize(root)
    }

    /**
     * Sets the owned properties of [todo]; with [changed], only those whose field differs. [old] is the VTODO
     * before the change (for DATE-TIME due dates and DTSTART).
     */
    private fun apply(
        t: TodoTask, parentUid: String?, section: Section?, changed: Pair<Fields, Fields>?,
        old: ICalComponent?, todo: ICalComponent, zone: ZoneId,
    ) {
        fun differs(key: (Fields) -> Any?): Boolean = changed == null || key(changed.first) != key(changed.second)
        val stamp = ICalendar.utcString(t.updatedAt)
        if (differs { it.createdAt } || todo.first("CREATED") == null) {
            todo.set(ICalProperty("CREATED", ICalendar.utcString(t.createdAt)))
        }
        todo.set(ICalProperty("DTSTAMP", stamp))
        todo.set(ICalProperty("LAST-MODIFIED", stamp))
        if (differs { it.content }) todo.set(ICalProperty("SUMMARY", ICalendar.escapeText(t.content)))
        if (differs { it.description }) {
            if (t.description.isEmpty()) todo.remove("DESCRIPTION")
            else todo.set(ICalProperty("DESCRIPTION", ICalendar.escapeText(t.description)))
        }
        if (differs { it.priority }) todo.set(ICalProperty("PRIORITY", icalPriority(t.priority)))
        if (differs { it.due }) setDue(t.due, old, todo, zone)
        if (differs { it.isCompleted } || differs { it.completedAt }) {
            if (t.isCompleted) {
                todo.set(ICalProperty("STATUS", "COMPLETED"))
                todo.set(ICalProperty("COMPLETED", ICalendar.utcString(t.completedAt ?: t.updatedAt)))
                todo.set(ICalProperty("PERCENT-COMPLETE", "100"))
            } else {
                todo.set(ICalProperty("STATUS", "NEEDS-ACTION"))
                todo.remove("COMPLETED")
                todo.remove("PERCENT-COMPLETE")
            }
        }
        if (differs { it.parentId }) {
            todo.properties.removeAll { it.name == "RELATED-TO" && isParent(it) }
            if (parentUid != null) todo.properties.add(ICalProperty("RELATED-TO", listOf(ICalParam("RELTYPE", "PARENT")), parentUid))
        }
        if (differs { it.order }) {
            todo.set(ICalProperty("X-APPLE-SORT-ORDER", appleOrder(t.order).toString()))
            todo.set(ICalProperty("X-TODOTIM-ORDER", format(t.order)))
        }
        if (differs { it.collapsed }) {
            if (t.collapsed) todo.set(ICalProperty("X-OC-HIDESUBTASKS", "1")) else todo.remove("X-OC-HIDESUBTASKS")
        }
        if (differs { it.labels }) {
            todo.remove("CATEGORIES")
            if (t.labels.isNotEmpty()) {
                todo.properties.add(ICalProperty("CATEGORIES", t.labels.joinToString(",") { ICalendar.escapeText(it) }))
            }
        }
        if (differs { it.sectionId } || differs { it.sectionName } || differs { it.sectionOrder }) {
            if (section != null) {
                todo.set(ICalProperty(
                    "X-TODOTIM-SECTION",
                    listOf(ICalParam("X-NAME", section.name), ICalParam("X-ORDER", format(section.order))),
                    section.id,
                ))
            } else {
                todo.remove("X-TODOTIM-SECTION")
            }
        }
        if (differs { it.recurrence }) {
            val rule = t.recurrence
            if (rule != null) todo.set(ICalProperty("RRULE", rule)) else todo.remove("RRULE")
        }
    }

    /**
     * TodoTim writes `DUE;VALUE=DATE`. A DATE-TIME due date from another client keeps its time of day and is
     * moved by the same number of days; DTSTART (if any) moves along, so the span between start and due stays
     * the same.
     *
     * RFC 5545 §3.6.2: DUE must have DTSTART's value type and be later than it, and excludes DURATION. So a new
     * due date on a task with a DATE-TIME start is written as the end of that day (floating, so it reads back as
     * the same date), the start moves back to that day if it was later, and DURATION is removed.
     */
    private fun setDue(due: LocalDate?, old: ICalComponent?, todo: ICalComponent, zone: ZoneId) {
        if (due == null) {
            todo.remove("DUE")
            return
        }
        todo.remove("DURATION")
        val oldDueProp = old?.first("DUE")
        val oldValue = oldDueProp?.let(DateValue::of)
        val delta: Long? = oldValue?.localDate(zone)?.let { daysBetween(it, due) }
        if (oldDueProp != null && oldValue != null && !oldValue.isDate && delta != null) {
            todo.set(oldValue.shifted(delta).property("DUE", oldDueProp))
        } else {
            val start = todo.first("DTSTART")
            val startValue = start?.let(DateValue::of)
            if (delta == null && start != null && startValue != null && !startValue.isDate) {
                todo.set(ICalProperty("DUE", ICalendar.basicDate(due.year, due.monthValue, due.dayOfMonth) + "T235959"))
                val startDay = startValue.localDate(zone)
                if (startDay != null) {
                    val back = daysBetween(startDay, due)
                    if (back < 0) todo.set(startValue.shifted(back).property("DTSTART", start))
                }
                return
            }
            todo.set(ICalendar.dateProperty("DUE", due))
        }
        if (delta != null && delta != 0L) {
            val start = todo.first("DTSTART") ?: return
            val value = DateValue.of(start) ?: return
            todo.set(value.shifted(delta).property("DTSTART", start))
        }
    }
}

private fun nfc(s: String): String =
    if (Normalizer.isNormalized(s, Normalizer.Form.NFC)) s else Normalizer.normalize(s, Normalizer.Form.NFC)

internal fun utf8Length(s: String): Int {
    var n = 0
    var i = 0
    while (i < s.length) {
        val c = s[i]
        n += when {
            c.code < 0x80 -> 1
            c.code < 0x800 -> 2
            Character.isHighSurrogate(c) && i + 1 < s.length && Character.isLowSurrogate(s[i + 1]) -> { i++; 4 }
            else -> 3
        }
        i++
    }
    return n
}
