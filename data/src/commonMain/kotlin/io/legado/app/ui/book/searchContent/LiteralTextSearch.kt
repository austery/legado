package io.legado.app.ui.book.searchContent

import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive

/** Upstream literal, case-sensitive, non-overlapping UTF-16 matching. */
object LiteralTextSearch {
    suspend fun positions(content: String, pattern: String, limit: Int = Int.MAX_VALUE): List<Int> {
        require(pattern.isNotEmpty()) { "Search text must not be empty" }
        require(limit > 0) { "Search limit must be positive" }
        val positions = mutableListOf<Int>()
        var index = content.indexOf(pattern)
        while (index >= 0) {
            currentCoroutineContext().ensureActive()
            positions.add(index)
            if (positions.size == limit) break
            index = content.indexOf(pattern, index + pattern.length)
        }
        return positions
    }
}
