package app.todotim.android.ui

import androidx.compose.ui.graphics.Color

/**
 * Todoist's project/label palette keyed like `Project.color` (from Sources/TodoCore/ProjectColor.swift).
 *
 * TODO: replace with `app.todotim.core.ProjectColor` once that port lands in core.
 */
object Palette {
    private val hex: Map<String, Long> = mapOf(
        "berry_red" to 0xB8255F, "red" to 0xDB4035, "orange" to 0xFF9933, "yellow" to 0xFAD000,
        "olive_green" to 0xAFB83B, "lime_green" to 0x7ECC49, "green" to 0x299438, "mint_green" to 0x6ACCBC,
        "teal" to 0x158FAD, "sky_blue" to 0x14AAF5, "light_blue" to 0x96C3EB, "blue" to 0x4073FF,
        "grape" to 0x884DFF, "violet" to 0xAF38EB, "lavender" to 0xEB96EB, "magenta" to 0xE05194,
        "salmon" to 0xFF8D85, "charcoal" to 0x808080, "grey" to 0xB8B8B8, "taupe" to 0xCCAC93,
    )

    /** Palette colour for [key]; unknown keys are charcoal. */
    fun color(key: String): Color {
        val k = key.lowercase().replace(' ', '_')
        val value = hex[k] ?: if (k == "mint") hex.getValue("mint_green") else hex.getValue("charcoal")
        return Color(0xFF000000 or value)
    }
}
