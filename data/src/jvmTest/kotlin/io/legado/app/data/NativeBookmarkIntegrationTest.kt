package io.legado.app.data

import androidx.room3.Room
import androidx.sqlite.driver.bundled.BundledSQLiteDriver
import androidx.sqlite.execSQL
import io.legado.app.data.dao.NativeChapterProjection
import io.legado.app.data.dao.NativeResumeException
import io.legado.app.data.dao.NativeShelfException
import io.legado.app.data.entities.Book
import io.legado.app.data.entities.BookChapter
import io.legado.app.data.entities.BookSource
import kotlinx.coroutines.runBlocking
import org.junit.Test
import java.nio.file.Files
import kotlin.test.*

class NativeBookmarkIntegrationTest {
    private fun open(path: String) = Room.databaseBuilder<AppDatabase>(path)
        .setDriver(BundledSQLiteDriver()).addMigrations(*DatabaseMigrations.migrations).build()

    private suspend fun seed(db: AppDatabase, id: String = "book", author: String = "Author"): Book {
        db.nativeShelfDao.addToShelf(Book(bookUrl = id, origin = "source", name = "Title", author = author),
            listOf(BookChapter(bookUrl = id, url = "chapter-$id", title = "Chapter", index = 2)))
        return assertNotNull(db.bookDao.getBook(id))
    }

    private suspend fun save(db: AppDatabase, book: Book, id: String = "bookmark", offset: Int = 9) =
        db.nativeBookmarkDao.save(id, book.origin, book.bookUrl, "chapter-${book.bookUrl}", 2,
            "first\r\n第二段 🌿", offset, NativeChapterProjection.from(book))

    @Test
    fun paragraphDeduplicationAndRestartPreserveProgressAndRetention() = runBlocking {
        val directory = Files.createTempDirectory("native-bookmarks-").toFile()
        val path = directory.resolve("test.db").absolutePath
        var db = open(path)
        try {
            val book = seed(db)
            val saved = save(db, book)
            assertEquals(7, saved.paragraphUtf16Offset)
            assertEquals("第二段 🌿", saved.excerpt)
            assertEquals(saved, save(db, book, "duplicate", 10))
            assertEquals(book, db.bookDao.getBook(book.bookUrl))
            assertNull(db.nativeResumeDao.get(book.bookUrl))
            db.close(); db = open(path)
            assertEquals(listOf(saved), db.nativeBookmarkDao.list("source", "book"))
            db.nativeShelfDao.removeFromShelf("source", "book")
            assertFailsWith<NativeShelfException> { db.nativeBookmarkDao.list("source", "book") }
            seed(db)
            assertEquals(listOf(saved), db.nativeBookmarkDao.list("source", "book"))
            db.nativeBookmarkDao.remove("source", "book", saved.id)
            db.nativeBookmarkDao.remove("source", "book", saved.id)
            db.close(); db = open(path)
            assertTrue(db.nativeBookmarkDao.list("source", "book").isEmpty())
        } finally { db.close(); directory.deleteRecursively() }
    }

    @Test
    fun unknownAuthorsStayIsolatedAndInvalidWritesLeaveNoRows() = runBlocking {
        withDatabase { db ->
            val a = seed(db, "a", "")
            val b = seed(db, "b", "")
            val saved = save(db, a)
            assertTrue(db.nativeBookmarkDao.list("source", "b").isEmpty())
            db.nativeBookmarkDao.remove("source", "b", saved.id)
            assertEquals(listOf(saved), db.nativeBookmarkDao.list("source", "a"))
            assertFailsWith<NativeShelfException> { db.nativeBookmarkDao.list("wrong-source", "a") }
            assertFailsWith<NativeResumeException> { save(db, b, offset = 12) }
            assertFailsWith<NativeResumeException> { save(db, b.copy(durChapterPos = 42)) }
            assertFailsWith<NativeResumeException> {
                db.nativeBookmarkDao.save("bad", "source", "b", "chapter-a", 2, "body", 0,
                    NativeChapterProjection.from(b))
            }
            assertTrue(db.nativeBookmarkDao.list("source", "b").isEmpty())
        }
    }

    @Test
    fun sourceSwitchRollsBackFailureThenTransfersOnlyOwnership() = runBlocking {
        withDatabase { db ->
            val original = seed(db)
            val saved = save(db, original)
            val source = BookSource(bookSourceUrl = "replacement-source", bookSourceName = "Replacement")
            db.bookSourceDao.insert(source)
            val replacement = original.copy(bookUrl = "replacement", origin = source.bookSourceUrl)
            val chapters = listOf(BookChapter(bookUrl = replacement.bookUrl, url = "replacement-chapter"))
            assertFailsWith<IllegalStateException> {
                db.nativeShelfDao.switchSource("source", "book", 0, NativeChapterProjection.from(original),
                    replacement, chapters, "replacement-chapter", "New text", source) { error("Publish failed") }
            }
            assertEquals(original, db.bookDao.getBook("book"))
            assertNull(db.bookDao.getBook("replacement"))
            assertEquals(listOf(saved), db.nativeBookmarkDao.list("source", "book"))
            db.nativeShelfDao.switchSource("source", "book", 0, NativeChapterProjection.from(original),
                replacement, chapters, "replacement-chapter", "New text", source)
            assertNull(db.bookDao.getBook("book"))
            assertEquals(listOf(saved.copy(ownerBookUrl = "replacement")),
                db.nativeBookmarkDao.list(source.bookSourceUrl, "replacement"))
        }
    }

    @Test
    fun schema91UpgradePreservesLegacyDataAndBackupCanBeRestored() = runBlocking {
        val directory = Files.createTempDirectory("native-bookmarks-migration-").toFile()
        val path = directory.resolve("test.db").absolutePath
        val backup = directory.resolve("schema91-backup.db")
        val driver = BundledSQLiteDriver()
        try {
            val fixture = requireNotNull(javaClass.getResource("/schema91-fixture.sql")).readText()
            driver.open(path).use { connection ->
                fixture.split(";\n").filter { it.isNotBlank() }.forEach { connection.execSQL(it) }
                connection.execSQL("INSERT INTO books(bookUrl,origin,name,author,type,durChapterPos) VALUES('book','source','Title','Author',8,37)")
                connection.execSQL("INSERT INTO native_reading_resume VALUES('book','source','chapter',2,'native-body-v1','hash',50,7,3,1234)")
                connection.execSQL("INSERT INTO bookmarks(time,bookName,bookAuthor,chapterIndex,chapterPos,chapterName,bookText,content,type,endPos) VALUES(1,'Title','Author',2,7,'Chapter','Excerpt','Note',0,7)")
                connection.execSQL("INSERT INTO book_groups(groupId,groupName,`order`) VALUES(1,'Retained group',0)")
                connection.execSQL("UPDATE books SET `group`=1 WHERE bookUrl='book'")
                connection.execSQL("INSERT INTO cookies(url,cookie) VALUES('source','retained-cookie')")
                connection.execSQL("PRAGMA user_version=91")
            }
            java.io.File(path).copyTo(backup)
            val bytes = backup.readBytes()
            val db = open(path)
            try {
                assertEquals(37, db.bookDao.getBook("book")?.durChapterPos)
                assertEquals(1L, db.bookDao.getBook("book")?.group)
                assertEquals(3L, db.nativeResumeDao.get("book")?.revision)
                assertEquals("Note", db.bookmarkDao.getByBook("Title", "Author").single().content)
                assertTrue(db.nativeBookmarkDao.list("source", "book").isEmpty())
            } finally { db.close() }
            driver.open(path).use { connection ->
                connection.prepare("PRAGMA user_version").use { assertTrue(it.step()); assertEquals(92, it.getInt(0)) }
                connection.prepare("SELECT groupName FROM book_groups WHERE groupId=1").use { assertTrue(it.step()); assertEquals("Retained group", it.getText(0)) }
                connection.prepare("SELECT cookie FROM cookies WHERE url='source'").use { assertTrue(it.step()); assertEquals("retained-cookie", it.getText(0)) }
                connection.prepare("PRAGMA integrity_check").use { assertTrue(it.step()); assertEquals("ok", it.getText(0)) }
                connection.prepare("PRAGMA foreign_key_check").use { assertFalse(it.step()) }
            }
            val restored = directory.resolve("restored.db")
            backup.copyTo(restored)
            assertContentEquals(bytes, restored.readBytes())
            driver.open(restored.absolutePath).use { connection ->
                connection.prepare("PRAGMA user_version").use { assertTrue(it.step()); assertEquals(91, it.getInt(0)) }
                connection.prepare("SELECT content FROM bookmarks").use { assertTrue(it.step()); assertEquals("Note", it.getText(0)) }
            }
        } finally { directory.deleteRecursively() }
    }

    private suspend fun withDatabase(block: suspend (AppDatabase) -> Unit) {
        val directory = Files.createTempDirectory("native-bookmarks-").toFile()
        val db = open(directory.resolve("test.db").absolutePath)
        try { block(db) } finally { db.close(); directory.deleteRecursively() }
    }
}
