package app.todotim.core.dav

import app.todotim.core.EntityID
import app.todotim.core.SyncLimits
import app.todotim.core.isValidEntityID
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.add
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.put

/**
 * The JSON of the `sections` and `labels` calendar properties (docs/caldav.md): `[{"id","name","order"}]`,
 * labels with `"color"` (`#RRGGBB`). Server data is untrusted: at most [SyncLimits.MAX_PROPERTY_BYTES] and
 * [SyncLimits.MAX_PROPERTY_ENTRIES] entries; entries with an invalid or repeated id are dropped; text is clipped.
 */
object PropertyList {
    data class Entry(
        val id: EntityID,
        val name: String,
        val order: Double,
        val color: String? = null,
    )

    /** The entries, or null when [json] is too large or not a JSON array. */
    fun decode(json: String): List<Entry>? {
        if (Multistatus.utf8Length(json) > SyncLimits.MAX_PROPERTY_BYTES) return null
        val raw = try {
            Json.parseToJsonElement(json) as? JsonArray
        } catch (e: Exception) {
            null
        } ?: return null
        val out = ArrayList<Entry>()
        val seen = HashSet<EntityID>()
        for (item in raw.take(SyncLimits.MAX_PROPERTY_ENTRIES)) {
            val o = item as? JsonObject ?: continue
            val id = o.string("id") ?: continue
            if (!isValidEntityID(id) || !seen.add(id)) continue
            val name = o.string("name")?.let { clip(normalizeNewlines(it), SyncLimits.MAX_NAME_LENGTH) } ?: ""
            val order = (o["order"] as? JsonPrimitive)?.takeIf { !it.isString }?.doubleOrNull ?: 0.0
            val color = o.string("color")?.let { clip(it, SyncLimits.MAX_COLOR_LENGTH) }
            out.add(Entry(id, name, if (order.isFinite()) order else 0.0, color))
        }
        return out
    }

    /** Compact JSON with sorted keys (as the Swift client writes it). */
    fun encode(entries: List<Entry>): String = buildJsonArray {
        for (e in entries) {
            add(
                buildJsonObject {
                    e.color?.let { put("color", it) }
                    put("id", e.id)
                    put("name", e.name)
                    // Whole numbers without ".0", as Swift's JSONEncoder writes them.
                    if (e.order == Math.floor(e.order) && Math.abs(e.order) < 1e15) put("order", e.order.toLong())
                    else put("order", e.order)
                },
            )
        }
    }.toString()

    private fun JsonObject.string(key: String): String? = (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.content

    private fun normalizeNewlines(s: String): String =
        if (!s.contains('\r')) s else s.replace("\r\n", "\n").replace('\r', '\n')

    /** The first [max] code points of [s]. */
    private fun clip(s: String, max: Int): String {
        if (s.length <= max) return s
        val end = s.offsetByCodePoints(0, minOf(max, s.codePointCount(0, s.length)))
        return s.substring(0, end)
    }
}
