package io.legado.app.help.config

import io.legado.app.constant.PreferKey
import io.legado.app.utils.cnCompare
import io.legado.app.utils.randomUUIDString
import platform.Foundation.NSUserDefaults
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class UpstreamShelfSortNativeTest {
    @Test
    fun nativeComparatorOrdersChineseAndPreservesEqualStrings() {
        val input = listOf("上海", "北京", "广州")
        assertEquals(listOf("北京", "广州", "上海"), input.sortedWith { a, b -> a.cnCompare(b) })
        assertEquals(0, "同名".cnCompare("同名"))
        assertTrue("".cnCompare("北京") < 0)
        assertTrue("A".cnCompare("北京") < 0)
        // Upstream falls back to code points for digits and characters outside its table.
        assertTrue("10".cnCompare("2") < 0)
        assertEquals(-"𠀀".cnCompare("北京").sign(), "北京".cnCompare("𠀀").sign())
    }

    @Test
    fun existingPreferenceKeyRefreshesAndSurvivesProviderRecreation() {
        val suite = "upstream-shelf-sort-" + randomUUIDString()
        val defaults = NSUserDefaults(suiteName = suite)
        try {
            val preferences = IosPreferenceProvider(defaults)
            val config = NativeAppConfigAccessor(preferences)
            assertEquals(0, config.bookshelfSort)
            for (mode in 0..5) {
                preferences.putInt(PreferKey.bookshelfSort, mode)
                assertEquals(mode, config.bookshelfSort)
                val reopened = IosPreferenceProvider(NSUserDefaults(suiteName = suite))
                assertEquals(mode, reopened.getInt(PreferKey.bookshelfSort, -1))
            }
        } finally {
            defaults.removePersistentDomainForName(suite)
        }
    }

    private fun Int.sign(): Int = compareTo(0)
}
