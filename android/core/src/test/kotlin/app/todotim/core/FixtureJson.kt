package app.todotim.core

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonPrimitive
import java.io.File
import java.time.LocalDate
import java.util.Locale

/** Reads the shared golden files in `fixtures/` (path from the `todotim.fixtures` system property). */
internal object FixtureJson {
    fun load(name: String): JsonObject {
        val dir = System.getProperty("todotim.fixtures") ?: error("system property todotim.fixtures is not set")
        return Json.parseToJsonElement(File(dir, name).readText()) as JsonObject
    }

    fun JsonObject.array(key: String): List<JsonObject> = getValue(key).jsonArray.map { it as JsonObject }

    /** The string value, or null when missing or JSON null. */
    fun JsonObject.string(key: String): String? = (this[key] as? JsonPrimitive)?.takeIf { it !is JsonNull }?.content

    fun JsonObject.strings(key: String): List<String> = (this[key] as? JsonArray)?.map { it.jsonPrimitive.content } ?: emptyList()

    fun JsonObject.date(key: String): LocalDate? = string(key)?.let(LocalDate::parse)

    fun JsonElement?.isNullOrJsonNull() = this == null || this is JsonNull

    /** `en_US` → Locale. */
    fun locale(id: String): Locale = Locale.forLanguageTag(id.replace('_', '-'))
}
