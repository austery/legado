package io.legado.engine

import io.legado.app.data.dao.NativeLocalTxt
import io.legado.app.data.entities.Book
import io.legado.app.help.book.LocalBookLocator

/** Resolve stable native identities at the file boundary without changing upstream parsing. */
internal class LocalTxtLocator(private val fallback: LocalBookLocator) : LocalBookLocator by fallback {
    override fun getLocalPath(book: Book): String? =
        if (NativeLocalTxt.owns(book)) NativeLocalTxt.path(book) else fallback.getLocalPath(book)

    override fun getReadableFileRef(book: Book): String? =
        if (NativeLocalTxt.owns(book)) NativeLocalTxt.path(book) else fallback.getReadableFileRef(book)
}
