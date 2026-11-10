package io.legado.desktop.config

import org.junit.Assert.*
import org.junit.Test

class DesktopPreferenceMigrationTest {
    @Test fun migrationPreservesValuesAndDoesNotResurrectRemovedKeys() {
        val legacy = mapOf("id" to "00123", "count" to "42", "enabled" to "TRUE", "ratio" to "1.25", "large" to "9223372036854775806")
        var stored: String? = null
        var reads = 0
        fun open() = DesktopPreferenceProvider({ stored }, { stored = it }, { reads++; legacy })
        val first = open()
        assertEquals("00123", first.getString("id", ""))
        assertEquals(42, first.getInt("count", 0))
        assertTrue(first.getBoolean("enabled", false))
        assertEquals(1.25f, first.getFloat("ratio", 0f), 0f)
        assertEquals(9223372036854775806L, first.getLong("large", 0))
        first.remove("count")
        first.putBoolean("enabled", false)
        val restarted = open()
        assertFalse(restarted.contains("count"))
        assertFalse(restarted.getBoolean("enabled", true))
        assertEquals(1, reads)
        assertEquals("42", legacy["count"])
    }

    @Test fun existingEmptyJsonWinsOverLegacy() {
        val provider = DesktopPreferenceProvider({ "{}" }, { fail("Unexpected write") }, { error("Unexpected migration") })
        assertTrue(provider.getAll().isEmpty())
    }

    @Test fun failedMigrationCanRetryWithoutDiscardingLegacy() {
        var failWrite = true
        var stored: String? = null
        val provider = DesktopPreferenceProvider({ stored }, {
            if (failWrite) error("Disk full")
            stored = it
        }, { mapOf("id" to "original") })
        assertThrows(IllegalStateException::class.java) { provider.getAll() }
        assertNull(stored)
        failWrite = false
        assertEquals("original", provider.getString("id", ""))
        assertNotNull(stored)
    }

    @Test fun unreadableOrInvalidJsonCannotOverwriteStoredData() {
        for (read in listOf<() -> String?>({ error("Unreadable") }, { "{invalid" })) {
            var writes = 0
            val provider = DesktopPreferenceProvider(read, { writes++ }, { error("Unexpected migration") })
            assertThrows(Exception::class.java) { provider.putString("new", "value") }
            assertEquals(0, writes)
        }
    }
}
