package io.legado.app.utils

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

class RegexProgressTest {
    @Test
    fun rejectsRegressingNativeMatchRanges() {
        val regex = Regex(".*\\]|小说全文阅读|小说全集")
        assertFailsWith<UnsupportedOperationException> {
            checkRegexReplacementProgress(regex, "[剑来]小说全文阅读")
        }
    }

    @Test
    fun acceptsEmptyMatchesAndPreservesGroupReplacement() {
        val empty = Regex("")
        checkRegexReplacementProgress(empty, "ab")
        assertEquals("_a_b_", empty.replace("ab", "_"))
        val groups = Regex("(a)(b)")
        checkRegexReplacementProgress(groups, "ab ab")
        assertEquals("ba ba", groups.replace("ab ab", "\$2\$1"))
    }

    @Test
    fun observesCancellationBetweenMatches() {
        assertFailsWith<InterruptedProbe> {
            checkRegexReplacementProgress(Regex("a"), "aaa") { throw InterruptedProbe() }
        }
    }

    private class InterruptedProbe : RuntimeException()
}
