package app.todotim.core

import kotlinx.serialization.Serializable
import java.time.LocalDate
import java.util.UUID

/** Entity ids: 1–64 characters from `[A-Za-z0-9_-]` (see docs/caldav.md). App-created ids are lowercase UUIDs. */
typealias EntityID = String

fun newID(): EntityID = UUID.randomUUID().toString().lowercase()

/** Whether [id] is acceptable as an entity id or reference. Ids become remote path segments, so anything else is rejected. */
fun isValidEntityID(id: String): Boolean {
    if (id.isEmpty() || id.length > 64) return false
    return id.all { it in 'a'..'z' || it in 'A'..'Z' || it in '0'..'9' || it == '-' || it == '_' }
}

/** Id of the inbox project. Its calendar URI on the server is [INBOX_CALENDAR]. */
const val INBOX_ID: EntityID = "inbox"
const val INBOX_CALENDAR = "todotim-inbox"

/** Todoist-style priority. p1 is the most urgent, p4 the default ("no priority"). */
@Serializable
enum class Priority(val level: Int) { P1(1), P2(2), P3(3), P4(4) }

/** Bounds on untrusted server data (mirrors `SyncLimits` in the Swift TodoCore). */
object SyncLimits {
    const val MAX_RESPONSE_BYTES = 32L * 1024 * 1024
    const val MAX_DISCOVERY_RESPONSE_BYTES = 1L * 1024 * 1024
    const val MAX_LISTING_ENTRIES = 10_000
    const val MAX_TASKS = 50_000
    const val MAX_CALENDARS = 1_000
    const val MAX_PROPERTY_ENTRIES = 5_000
    const val MAX_PROPERTY_BYTES = 1 shl 20
    const val MAX_CONTENT_LENGTH = 10_000
    const val MAX_DESCRIPTION_LENGTH = 100_000
    const val MAX_NAME_LENGTH = 1_000
    const val MAX_COLOR_LENGTH = 64
    const val MAX_LABELS_PER_TASK = 100
    const val MAX_TASK_DEPTH = 32
}

@Serializable
data class Project(
    val id: EntityID,
    val name: String,
    /** Key into [ProjectColor] (e.g. "red"). */
    val color: String = "charcoal",
    val order: Double,
    val isInbox: Boolean = false,
)

@Serializable
data class Section(
    val id: EntityID,
    val projectId: EntityID,
    val name: String,
    val order: Double,
)

@Serializable
data class Label(
    val id: EntityID,
    val name: String,
    val color: String = "charcoal",
    val order: Double,
)

/**
 * A task. Times are epoch milliseconds (UTC). [due] is a local calendar date without time.
 * A subtask ([parentId] set) always has its parent's [projectId] and [sectionId].
 */
@Serializable
data class TodoTask(
    val id: EntityID,
    val projectId: EntityID,
    val sectionId: EntityID? = null,
    val parentId: EntityID? = null,
    val content: String,
    val description: String = "",
    val priority: Priority = Priority.P4,
    /** Local calendar date, ISO `yyyy-MM-dd`. */
    @Serializable(with = LocalDateSerializer::class)
    val due: LocalDate? = null,
    /** Label names (not ids), like Todoist. */
    val labels: List<String> = emptyList(),
    val isCompleted: Boolean = false,
    val completedAt: Long? = null,
    /** Sort key among siblings (same project, section and parent). Ascending. */
    val order: Double,
    val collapsed: Boolean = false,
    /** iCalendar RRULE value of a repeating task, e.g. "FREQ=WEEKLY;INTERVAL=2". */
    val recurrence: String? = null,
    val createdAt: Long,
    val updatedAt: Long,
)

object LocalDateSerializer : kotlinx.serialization.KSerializer<LocalDate> {
    override val descriptor = kotlinx.serialization.descriptors.PrimitiveSerialDescriptor(
        "LocalDate", kotlinx.serialization.descriptors.PrimitiveKind.STRING,
    )
    override fun serialize(encoder: kotlinx.serialization.encoding.Encoder, value: LocalDate) =
        encoder.encodeString(value.toString())
    override fun deserialize(decoder: kotlinx.serialization.encoding.Decoder): LocalDate =
        LocalDate.parse(decoder.decodeString())
}
