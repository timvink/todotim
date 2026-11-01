package app.todotim.core

import java.nio.ByteBuffer
import java.security.MessageDigest
import java.util.UUID

/** Derived ids for remote names that are not valid entity ids (docs/caldav.md). Must match the Swift TodoCore. */
object Ids {
    /** Namespace for ids derived from UIDs, calendar URIs and label names. Never change it: derived ids are stored. */
    val NAMESPACE: UUID = UUID.fromString("0f6f0c1e-5a43-4bd4-9a0f-2f4c2b1e7a55")

    /** Name-based UUID (version 5, SHA-1), lowercase. */
    fun uuidV5(namespace: UUID, name: String): String {
        val ns = ByteBuffer.allocate(16).putLong(namespace.mostSignificantBits).putLong(namespace.leastSignificantBits).array()
        val bytes = MessageDigest.getInstance("SHA-1").run { update(ns); update(name.toByteArray(Charsets.UTF_8)); digest() }.copyOf(16)
        bytes[6] = ((bytes[6].toInt() and 0x0F) or 0x50).toByte()
        bytes[8] = ((bytes[8].toInt() and 0x3F) or 0x80).toByte()
        val buf = ByteBuffer.wrap(bytes)
        return UUID(buf.long, buf.long).toString().lowercase()
    }

    fun taskId(uid: String): EntityID = if (isValidEntityID(uid)) uid else uuidV5(NAMESPACE, "uid:$uid")
    fun projectId(calendarUri: String): EntityID = if (isValidEntityID(calendarUri)) calendarUri else uuidV5(NAMESPACE, "calendar:$calendarUri")
    fun labelId(name: String): EntityID = uuidV5(NAMESPACE, "label:$name")
}
