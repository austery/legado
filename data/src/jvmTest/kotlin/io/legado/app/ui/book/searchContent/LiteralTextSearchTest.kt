package io.legado.app.ui.book.searchContent

import kotlinx.coroutines.runBlocking
import org.junit.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

class LiteralTextSearchTest {
    @Test fun originalUtf16LiteralAndNonOverlappingCoordinates() = runBlocking {
        val body = "aaaa a.* 中文😀中文"
        assertEquals(listOf(0, 2), LiteralTextSearch.positions(body, "aa"))
        assertEquals(listOf(5), LiteralTextSearch.positions(body, "a.*"))
        assertEquals(listOf(9, 13), LiteralTextSearch.positions(body, "中文"))
        assertEquals(emptyList(), LiteralTextSearch.positions(body, "A"))
    }

    @Test fun boundedAndUnlimitedCallsShareTheSamePrefix() = runBlocking {
        val body = "needle ".repeat(250)
        val all = LiteralTextSearch.positions(body, "needle")
        assertEquals(250, all.size)
        assertEquals(all.take(201), LiteralTextSearch.positions(body, "needle", 201))
        assertFailsWith<IllegalArgumentException> { LiteralTextSearch.positions(body, "") }
        assertFailsWith<IllegalArgumentException> { LiteralTextSearch.positions(body, "needle", 0) }
    }
}
