package app.todotim.android

import app.todotim.android.data.ServerSettings
import app.todotim.android.data.SettingsChange
import app.todotim.android.data.planSettingsChange
import app.todotim.android.ui.EditorText
import app.todotim.android.ui.parseQuickAdd
import app.todotim.android.ui.resolvePlace
import app.todotim.core.INBOX_ID
import app.todotim.core.Project
import app.todotim.core.Section
import app.todotim.core.store.Database
import app.todotim.core.store.TodoStore
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test
import java.time.LocalDate

class EditingTest {
    private val stored = ServerSettings("https://dav.example.com/dav/", "tim", hasPassword = true)

    @Test
    fun settingsStoreTheUrlAsTheSyncUsesIt() {
        assertEquals(
            SettingsChange("https://dav.example.com/dav/", "tim", null),
            planSettingsChange(stored, " https://DAV.example.com:443/dav ", "tim ", null),
        )
    }

    @Test
    fun anotherServerOrUserNeedsANewPassword() {
        for ((url, user) in listOf("https://other.example.com/dav/" to "tim", "https://dav.example.com/dav/" to "anna")) {
            val e = assertThrows(IllegalArgumentException::class.java) { planSettingsChange(stored, url, user, null) }
            assertEquals("Enter the password for this server and username.", e.message)
            assertEquals(SettingsChange(url, user, "pw"), planSettingsChange(stored, url, user, "pw"))
        }
        // Setting up for the first time without a password is allowed (the sync then asks for one).
        assertEquals(
            SettingsChange("https://dav.example.com/dav/", "tim", ""),
            planSettingsChange(ServerSettings(), "https://dav.example.com/dav", "tim", null),
        )
    }

    @Test
    fun editorTakesTextASyncDownloaded() {
        val title = EditorText("Milk")
        title.text = "Milk "
        title.stored = "Milk"
        title.follow("Milk", String::trim)
        assertEquals("Milk ", title.text)
        // A sync changed the stored title: the field shows it.
        title.follow("Oat milk", String::trim)
        assertEquals("Oat milk", title.text)
        // The field's own write coming back does not reset what is being typed.
        title.text = "Oat milk  "
        title.stored = "Oat milk"
        title.follow("Oat milk", String::trim)
        assertEquals("Oat milk  ", title.text)
    }

    @Test
    fun quickAddMatchesSectionsOfTheTargetProjectOnly() {
        val store = TodoStore(
            Database(
                projects = listOf(
                    Database.defaultInbox(),
                    Project("work", "Work", "blue", 1.0),
                    Project("home", "Home", "red", 2.0),
                ).associateBy { it.id },
                sections = listOf(
                    Section("plan", "work", "Planning", 1.0),
                    Section("review", "home", "Planning review", 1.0),
                ).associateBy { it.id },
            ),
        )
        val snapshot = store.snapshot.value
        val today = LocalDate.of(2026, 11, 1)

        val (inWork, _) = parseQuickAdd("Call /Planning review", today, snapshot, "work")
        assertEquals("Planning", inWork.sectionName)
        assertEquals("Call review", inWork.content)
        assertEquals("work" to "plan", resolvePlace(inWork, snapshot, "work" to null))

        // A #project token switches to that project's sections.
        val (toHome, _) = parseQuickAdd("Call /Planning review #Home", today, snapshot, "work")
        assertEquals("Planning review", toHome.sectionName)
        assertEquals("Call", toHome.content)
        assertEquals("home" to "review", resolvePlace(toHome, snapshot, "work" to null))

        val (fromInbox, _) = parseQuickAdd("Call /Planning review #Work", today, snapshot, INBOX_ID)
        assertEquals("work" to "plan", resolvePlace(fromInbox, snapshot, INBOX_ID to null))
    }
}
