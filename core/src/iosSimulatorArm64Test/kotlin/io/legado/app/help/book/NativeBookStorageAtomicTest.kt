package io.legado.app.help.book

import io.legado.app.data.entities.Book
import io.legado.app.data.entities.BookChapter
import io.legado.app.utils.randomUUIDString
import okio.FileSystem
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import okio.IOException

class NativeBookStorageAtomicTest {
    @Test
    fun existingPathAndRawTextRemainCompatibleAndAbandonedStagingIsIgnored() {
        val root = FileSystem.SYSTEM_TEMPORARY_DIRECTORY / ("PROTOTYPE-native-storage-" + randomUUIDString())
        val storage = NativeBookStorage(root.toString())
        val book = Book(bookUrl="book",origin="source",name="Title",author="Author")
        val chapter = BookChapter(bookUrl="book",url="chapter",title="Chapter",index=3)
        storage.saveText(book,chapter,"first")
        val path = root / book.getFolderName() / chapter.getFileName()
        FileSystem.SYSTEM.write(path.parent!! / "abandoned.staging") { writeUtf8("not a chapter") }
        assertEquals("first",storage.getContent(book,chapter))
        val text = "中文\r\n🌿 e\u0301 👩‍💻"
        storage.saveText(book,chapter,text)
        assertEquals(text,storage.getContent(book,chapter))
        assertEquals(text,FileSystem.SYSTEM.read(path) { readUtf8() })
        storage.saveText(book,chapter,"")
        assertEquals(text,storage.getContent(book,chapter))
    }

    @Test
    fun invalidParentPropagatesRatherThanReportingCacheSuccess() {
        val root = FileSystem.SYSTEM_TEMPORARY_DIRECTORY / ("PROTOTYPE-native-storage-" + randomUUIDString())
        FileSystem.SYSTEM.write(root) { writeUtf8("blocking parent") }
        val storage = NativeBookStorage(root.toString())
        assertFailsWith<IOException> {
            storage.saveText(Book(bookUrl="book",origin="source",name="Title"),BookChapter(bookUrl="book",url="chapter"),"body")
        }
        assertEquals("blocking parent",FileSystem.SYSTEM.read(root) { readUtf8() })
    }
}
