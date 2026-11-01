package app.todotim.core

import app.todotim.core.FixtureJson.array
import app.todotim.core.FixtureJson.string
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ProjectColorTest {
    // Port of VTodoTests.testColorMapping.
    @Test fun colorMapping() {
        assertEquals("#DB4035", ProjectColor.hex("red"))
        assertEquals("red", ProjectColor.key("#DB4035"))
        assertEquals("red", ProjectColor.key("#db4035ff"))
        assertEquals("blue", ProjectColor.key("#4174FE"))
        assertNull(ProjectColor.key("red"))
        assertNull(ProjectColor.key("#12345"))
    }

    @Test fun fixtures() {
        val json = FixtureJson.load("palette.json")
        val entries = json.array("entries").map { Triple(it.string("key"), it.string("name"), it.string("hex")) }
        assertEquals(entries, ProjectColor.entries.map { Triple(it.key, it.name, "#%06X".format(it.hex)) })
        for (case in json.array("lookup")) {
            val input = case.string("input")!!
            assertEquals(input, case.string("key"), ProjectColor.entry(input).key)
            assertEquals(input, case.string("hex"), ProjectColor.hex(input))
        }
        for (case in json.array("nearest")) {
            val hex = case.string("hex")!!
            assertEquals(hex, case.string("key"), ProjectColor.key(hex))
        }
    }
}
