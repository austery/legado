package io.legado.app.data.dao

import io.legado.app.constant.BookType
import io.legado.app.data.entities.Book
import io.legado.app.help.file.AppFilesDirs
import io.legado.app.utils.File

/** Only our immutable, content-addressed TXT namespace is admitted to the native shelf. */
object NativeLocalTxt {
    fun root(): String = File(AppFilesDirs.get().filesDir, "books/native-txt").absolutePath
    private const val PREFIX = "native-txt://"
    fun identity(digest: String): String {
        require(Regex("[0-9a-f]{64}").matches(digest))
        return "$PREFIX$digest/book.txt"
    }
    fun path(book: Book): String {
        require(owns(book)) { "Unrecognized local TXT identity" }
        return File(root(), book.bookUrl.removePrefix(PREFIX)).absolutePath
    }
    fun owns(book: Book): Boolean = runCatching {
        if (book.type and BookType.local == 0 || book.type and BookType.text == 0 || book.origin != book.bookUrl) return false
        val prefix = PREFIX
        book.bookUrl.startsWith(prefix) &&
            Regex("[0-9a-f]{64}/book\\.txt").matches(book.bookUrl.removePrefix(prefix))
    }.getOrDefault(false)
}
