package io.legado.app.data.dao

import io.legado.app.constant.BookType
import io.legado.app.data.entities.Book
import io.legado.app.help.file.AppFilesDirs
import io.legado.app.utils.File

/** Only our immutable, content-addressed TXT namespace is admitted to the native shelf. */
object NativeLocalTxt {
    fun root(): String = File(AppFilesDirs.get().filesDir, "books/native-txt").absolutePath
    fun owns(book: Book): Boolean = runCatching {
        if (book.type and BookType.local == 0 || book.type and BookType.text == 0 || book.origin != book.bookUrl) return false
        val prefix = "file://${root()}/"
        book.bookUrl.startsWith(prefix) &&
            Regex("[0-9a-f]{64}/book\\.txt").matches(book.bookUrl.removePrefix(prefix))
    }.getOrDefault(false)
}
