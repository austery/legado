package io.legado.app.data.entities

import io.legado.app.utils.cnCompare

/** Existing upstream modes. Equal keys retain the caller's input order. */
fun sortShelfBooks(books: List<Book>, mode: Int): List<Book> = when (mode) {
    1 -> books.sortedByDescending { it.latestChapterTime }
    2 -> books.sortedWith { a, b -> a.name.cnCompare(b.name) }
    3 -> books.sortedBy { it.order }
    4 -> books.sortedByDescending { maxOf(it.latestChapterTime, it.durChapterTime) }
    5 -> books.sortedWith { a, b -> a.author.cnCompare(b.author) }
    else -> books.sortedByDescending { it.durChapterTime }
}
