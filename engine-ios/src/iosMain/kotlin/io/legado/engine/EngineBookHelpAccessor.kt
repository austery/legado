package io.legado.engine

import io.legado.app.constant.EventBus
import io.legado.app.data.entities.Book
import io.legado.app.data.entities.BookChapter
import io.legado.app.data.entities.BookSource
import io.legado.app.help.book.BookHelpAccessor
import io.legado.app.help.book.BookStorageProviders
import io.legado.app.help.file.AppFilesDirs
import io.legado.app.utils.MD5Utils
import io.legado.app.utils.postEvent

/** Text-reader adapter: upstream's image-aware implementation now depends on Compose UI. */
internal object EngineBookHelpAccessor : BookHelpAccessor {
    override fun saveContent(bookSource: BookSource, book: Book, bookChapter: BookChapter, content: String) {
        val storage = BookStorageProviders.get()
        storage.saveText(book, bookChapter, content)
        if (storage.hasContent(book, bookChapter)) {
            postEvent(EventBus.SAVE_CONTENT, book to bookChapter)
        }
    }

    override fun getCoverPath(bookUrl: String): String =
        "${AppFilesDirs.get().filesDir.trimEnd('/')}/covers/${MD5Utils.md5Encode16(bookUrl)}.jpg"

    override suspend fun clearCacheExtra() = Unit
}
