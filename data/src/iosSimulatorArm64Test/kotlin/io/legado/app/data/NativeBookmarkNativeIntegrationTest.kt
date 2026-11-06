package io.legado.app.data

import androidx.room3.Room
import androidx.sqlite.execSQL
import androidx.sqlite.driver.NativeSQLiteDriver
import io.legado.app.data.dao.NativeChapterProjection
import io.legado.app.data.dao.NativeResumeException
import io.legado.app.data.dao.NativeShelfException
import io.legado.app.data.dao.NativeShelfTarget
import io.legado.app.data.entities.Book
import io.legado.app.data.entities.BookChapter
import io.legado.app.data.entities.BookSource
import kotlinx.coroutines.runBlocking
import kotlin.test.Test
import platform.Foundation.NSTemporaryDirectory
import platform.Foundation.NSUUID
import platform.Foundation.NSFileManager
import kotlin.test.*

class NativeBookmarkNativeIntegrationTest {
    private fun open(path: String) = Room.databaseBuilder<AppDatabase>(path)
        .setDriver(NativeSQLiteDriver()).addMigrations(*DatabaseMigrations.migrations).build()

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
        val path = NSTemporaryDirectory() + "native-bookmarks-" + NSUUID().UUIDString + ".db"
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
        } finally { db.close(); removeFixture(path) }
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
    fun groupChangesPreserveBookmarksAndTrueBookDeletionCascades() = runBlocking {
        withDatabase { db ->
            val book = seed(db)
            val saved = save(db, book)
            val groups = db.nativeShelfDao.createGroup("Keep", db.nativeShelfDao.organization().token)
            val group = groups.groups.single()
            val assigned = db.nativeShelfDao.changeGroups(
                listOf(NativeShelfTarget(book.origin, book.bookUrl)), listOf(group.groupId), emptyList(), groups.token)
            assertEquals(listOf(saved), db.nativeBookmarkDao.list(book.origin, book.bookUrl))
            db.nativeShelfDao.deleteGroup(group.groupId, assigned.token)
            assertEquals(listOf(saved), db.nativeBookmarkDao.list(book.origin, book.bookUrl))
            assertNull(db.nativeResumeDao.get(book.bookUrl))
            db.bookDao.delete(assertNotNull(db.bookDao.getBook(book.bookUrl)))
            assertNull(db.bookDao.getBook(book.bookUrl))
            seed(db)
            assertTrue(db.nativeBookmarkDao.list(book.origin, book.bookUrl).isEmpty())
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
    fun appendCatalogPreservesNativeRecordsAndRejectsChangedPrefix() = runBlocking {
        withDatabase { db ->
            val source = BookSource(bookSourceUrl = "source", bookSourceName = "Source")
            db.bookSourceDao.insert(source)
            val chapters = listOf(BookChapter(bookUrl = "book", url = "chapter-book", title = "Chapter", index = 0))
            db.nativeShelfDao.addToShelf(Book(bookUrl = "book", origin = "source", name = "Title", author = "Author"), chapters)
            val initial = assertNotNull(db.bookDao.getBook("book"))
            val resume = db.nativeResumeDao.save("source", "book", "chapter-book", 0,
                "first\nsecond", 7, 0, NativeChapterProjection.from(initial))
            val readingBook = assertNotNull(db.bookDao.getBook("book"))
            val bookmark = db.nativeBookmarkDao.save("mark", "source", "book", "chapter-book", 0,
                "first\nsecond", 7, NativeChapterProjection.from(readingBook))
            val next = chapters + BookChapter(bookUrl = "book", url = "new", title = "New", index = 1)
            val invalid = listOf(
                listOf(chapters.single().copy(title = "Renamed")),
                listOf(chapters.single().copy(index = 1)),
                emptyList(),
                listOf(chapters.single().copy(url = "changed")),
                next + next.last().copy(index = 2)
            )
            for (catalog in invalid) {
                assertFailsWith<NativeShelfException> {
                    db.nativeShelfDao.appendCatalog("source", "book", source, chapters, readingBook, catalog)
                }
                assertEquals(readingBook, db.bookDao.getBook("book"))
                assertEquals(chapters, db.bookChapterDao.getChapterList("book"))
                assertEquals(resume, db.nativeResumeDao.get("book"))
                assertEquals(listOf(bookmark), db.nativeBookmarkDao.list("source", "book"))
            }
            assertFailsWith<NativeShelfException> {
                db.nativeShelfDao.appendCatalog("source", "book", source, chapters,
                    readingBook.copy(bookUrl = "redirected"), next)
            }
            assertEquals(1, db.nativeShelfDao.appendCatalog("source", "book", source, chapters, readingBook, next))
            val after = assertNotNull(db.bookDao.getBook("book"))
            assertEquals(NativeChapterProjection.from(readingBook), NativeChapterProjection.from(after))
            assertEquals(resume, db.nativeResumeDao.get("book"))
            assertEquals(listOf(bookmark), db.nativeBookmarkDao.list("source", "book"))
            assertEquals(next, db.bookChapterDao.getChapterList("book"))
            assertEquals(0, db.nativeShelfDao.appendCatalog("source", "book", source, next, after, next))
            assertEquals(after, db.bookDao.getBook("book"))
            db.bookSourceDao.insert(source.copy(enabled = false))
            assertFailsWith<NativeShelfException> {
                db.nativeShelfDao.appendCatalog("source", "book", source, next, after,
                    next + BookChapter(bookUrl = "book", url = "third", title = "Third", index = 2))
            }
            assertEquals(next, db.bookChapterDao.getChapterList("book"))
            assertEquals(resume, db.nativeResumeDao.get("book"))
            assertEquals(listOf(bookmark), db.nativeBookmarkDao.list("source", "book"))
            db.bookSourceDao.insert(source)
            assertFailsWith<NativeShelfException> {
                db.nativeShelfDao.appendCatalog("source", "book", source, chapters, readingBook, next)
            }
        }
    }

    @Test
    fun appendDoesNotOverwriteProgressWrittenAfterCapture() = runBlocking {
        withDatabase { db ->
            val source = BookSource(bookSourceUrl = "source", bookSourceName = "Source")
            db.bookSourceDao.insert(source)
            val old = listOf(BookChapter(bookUrl = "book", url = "first", title = "First", index = 0))
            db.nativeShelfDao.addToShelf(Book(bookUrl = "book", origin = "source", name = "Title", author = "Author"), old)
            val captured = assertNotNull(db.bookDao.getBook("book"))
            val saved = db.nativeResumeDao.save("source", "book", "first", 0, "first\nsecond", 7, 0,
                NativeChapterProjection.from(captured))
            val current = assertNotNull(db.bookDao.getBook("book"))
            assertEquals(1, db.nativeShelfDao.appendCatalog("source", "book", source, old, captured,
                old + BookChapter(bookUrl = "book", url = "second", title = "Second", index = 1)))
            assertEquals(NativeChapterProjection.from(current),
                NativeChapterProjection.from(assertNotNull(db.bookDao.getBook("book"))))
            assertEquals(saved, db.nativeResumeDao.get("book"))
        }
    }

    @Test
    fun catalogSummaryFailureRollsBackInsertedSuffix() = runBlocking {
        val path = NSTemporaryDirectory() + "native-append-rollback-" + NSUUID().UUIDString + ".db"
        var db = open(path)
        try {
            val source = BookSource(bookSourceUrl = "source", bookSourceName = "Source")
            db.bookSourceDao.insert(source)
            val old = listOf(BookChapter(bookUrl = "book", url = "first", title = "First", index = 0))
            db.nativeShelfDao.addToShelf(Book(bookUrl = "book", origin = "source", name = "Title", author = "Author"), old)
            val before = assertNotNull(db.bookDao.getBook("book"))
            db.close()
            NativeSQLiteDriver().open(path).use {
                it.execSQL("CREATE TRIGGER fail_catalog_summary BEFORE UPDATE OF totalChapterNum ON books BEGIN SELECT RAISE(ABORT, 'synthetic catalog failure'); END")
            }
            db = open(path)
            assertFailsWith<Exception> {
                db.nativeShelfDao.appendCatalog("source", "book", source, old, before,
                    old + BookChapter(bookUrl = "book", url = "second", title = "Second", index = 1))
            }
            assertEquals(old, db.bookChapterDao.getChapterList("book"))
            assertEquals(before, db.bookDao.getBook("book"))
            db.close(); db = open(path)
            assertEquals(old, db.bookChapterDao.getChapterList("book"))
            assertEquals(before, db.bookDao.getBook("book"))
        } finally { db.close(); removeFixture(path) }
    }

    private suspend fun withDatabase(block: suspend (AppDatabase) -> Unit) {
        val path = NSTemporaryDirectory() + "native-bookmarks-" + NSUUID().UUIDString + ".db"
        val db = open(path)
        try { block(db) } finally { db.close(); removeFixture(path) }
    }
    @OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)
    private fun removeFixture(path: String) {
        for (suffix in listOf("", "-wal", "-shm")) {
            NSFileManager.defaultManager.removeItemAtPath(path + suffix, error = null)
        }
    }

}
