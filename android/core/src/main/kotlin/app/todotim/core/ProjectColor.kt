package app.todotim.core

/**
 * Todoist's project/label color palette, keyed by lowercase name (stored in [Project.color] and
 * [Label.color]). CalDAV stores colors as hex (`#RRGGBB`); [key] maps any other color to the
 * nearest palette entry. Port of `ProjectColor.swift`; both are checked against
 * `fixtures/palette.json`.
 */
object ProjectColor {
    /** [hex] is `0xRRGGBB`. */
    data class Entry(val key: String, val name: String, val hex: Int) {
        val id: String get() = key
    }

    val entries: List<Entry> = listOf(
        Entry("berry_red", "Berry Red", 0xB8255F),
        Entry("red", "Red", 0xDB4035),
        Entry("orange", "Orange", 0xFF9933),
        Entry("yellow", "Yellow", 0xFAD000),
        Entry("olive_green", "Olive Green", 0xAFB83B),
        Entry("lime_green", "Lime Green", 0x7ECC49),
        Entry("green", "Green", 0x299438),
        Entry("mint_green", "Mint Green", 0x6ACCBC),
        Entry("teal", "Teal", 0x158FAD),
        Entry("sky_blue", "Sky Blue", 0x14AAF5),
        Entry("light_blue", "Light Blue", 0x96C3EB),
        Entry("blue", "Blue", 0x4073FF),
        Entry("grape", "Grape", 0x884DFF),
        Entry("violet", "Violet", 0xAF38EB),
        Entry("lavender", "Lavender", 0xEB96EB),
        Entry("magenta", "Magenta", 0xE05194),
        Entry("salmon", "Salmon", 0xFF8D85),
        Entry("charcoal", "Charcoal", 0x808080),
        Entry("grey", "Grey", 0xB8B8B8),
        Entry("taupe", "Taupe", 0xCCAC93),
    )

    private val byKey: Map<String, Entry> = entries.associateBy { it.key }

    /**
     * Accepts "olive_green", "olive green", "olivegreen" and "mint" (Todoist's short names);
     * anything else is charcoal.
     */
    fun entry(key: String): Entry {
        byKey[key]?.let { return it }
        val k = key.lowercase().replace(" ", "_")
        byKey[k]?.let { return it }
        val squashed = k.replace("_", "")
        entries.firstOrNull { it.key.replace("_", "") == squashed }?.let { return it }
        if (k == "mint") return byKey.getValue("mint_green")
        return byKey.getValue("charcoal")
    }

    /** "#DB4035". */
    fun hex(key: String): String = "#%06X".format(entry(key).hex)

    /** Palette key nearest to `#RRGGBB` or `#RRGGBBAA` (alpha ignored); null when not a hex color. */
    fun key(hex: String): String? {
        val s = hex.trim { it == '\t' || Character.getType(it) == Character.SPACE_SEPARATOR.toInt() }
        if (!s.startsWith("#")) return null
        val body = s.substring(1)
        val length = body.codePointCount(0, body.length)
        if (length != 6 && length != 8) return null
        val v = parseHex(body.substring(0, body.offsetByCodePoints(0, 6))) ?: return null
        return entries.minByOrNull { distance(it.hex, v) }?.key
    }

    /** Weighted RGB distance: 2·Δr² + 4·Δg² + 3·Δb². */
    private fun distance(a: Int, b: Int): Int {
        val dr = (a shr 16 and 0xFF) - (b shr 16 and 0xFF)
        val dg = (a shr 8 and 0xFF) - (b shr 8 and 0xFF)
        val db = (a and 0xFF) - (b and 0xFF)
        return 2 * dr * dr + 4 * dg * dg + 3 * db * db
    }

    /** Swift's `UInt32(_:radix: 16)`: an optional "+" and ASCII hex digits. */
    private fun parseHex(s: String): Int? {
        val digits = s.removePrefix("+")
        if (digits.isEmpty() || !digits.all { it in '0'..'9' || it in 'a'..'f' || it in 'A'..'F' }) return null
        return digits.toInt(16)
    }
}
