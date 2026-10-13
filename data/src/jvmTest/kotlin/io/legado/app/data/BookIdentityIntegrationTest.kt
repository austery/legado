package io.legado.app.data

import androidx.room3.Room
import androidx.sqlite.driver.bundled.BundledSQLiteDriver
import io.legado.app.data.entities.Book
import io.legado.app.data.entities.BookChapter
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import androidx.room3.useWriterConnection
import androidx.room3.immediateTransaction
import androidx.sqlite.execSQL
import io.legado.app.help.book.isSameNameAuthor
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.cancel
import io.legado.app.model.ReadBookShared
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withTimeout

import org.junit.Test
import java.nio.file.Files
import kotlin.test.assertEquals

/** Synthetic databases only; exercises the actual generated application DAO. */
class BookIdentityIntegrationTest {
    @Test
    fun missingAuthorsCoexistWithoutSelectingAnotherBook() = runBlocking {
        val directory = Files.createTempDirectory("PROTOTYPE-spec003-actual-").toFile()
        val database = Room.databaseBuilder<AppDatabase>(directory.resolve("test.db").absolutePath)
            .setDriver(BundledSQLiteDriver())
            .addMigrations(*DatabaseMigrations.migrations)
            .build()
        try {
            database.bookDao.insert(Book(bookUrl = "https://one/book", origin = "one", name = "Title", author = ""))
            database.bookDao.insert(Book(bookUrl = "https://two/book", origin = "two", name = "Title", author = ""))
            assertEquals(2, database.bookDao.allBookCount())
            assertEquals(null, database.bookDao.getBook("Title", ""))
        } finally {
            database.close()
            directory.deleteRecursively()
        }
    }
    @Test
    fun knownAuthorReplacementPreservesLegacyCascadesAndUpdateConflicts() = runBlocking {
        val directory = Files.createTempDirectory("PROTOTYPE-spec003-actual-").toFile()
        val database = Room.databaseBuilder<AppDatabase>(directory.resolve("test.db").absolutePath)
            .setDriver(BundledSQLiteDriver()).addMigrations(*DatabaseMigrations.migrations).build()
        try {
            val first = Book(bookUrl = "one", name = "Title", author = "Author")
            val second = Book(bookUrl = "two", name = "Other", author = "Else")
            database.bookDao.insert(first, second)
            database.bookChapterDao.insert(BookChapter(bookUrl = "one", url = "chapter-one"), BookChapter(bookUrl = "two", url = "chapter-two"))
            // Both primary-key and known-author conflicts must cascade, as old REPLACE did.
            database.bookDao.insert(first.copy(bookUrl = "two"))
            assertEquals(listOf("two"), database.bookDao.all().map { it.bookUrl })
            assertEquals(0, database.bookChapterDao.getChapterCount("one"))
            assertEquals(0, database.bookChapterDao.getChapterCount("two"))
            database.bookDao.insert(second.copy(bookUrl = "three"))
            // Updating a nonexistent primary key remains a no-op even with a colliding identity.
            database.bookDao.update(first.copy(bookUrl = "missing"))
            assertEquals(2, database.bookDao.allBookCount())
            assertFailsWith<Exception> { database.bookDao.update(first.copy(bookUrl = "three")) }
            assertEquals("Other", database.bookDao.getBook("three")?.name)
        } finally { database.close(); directory.deleteRecursively() }
    }

    @Test
    fun missingAuthorReadersNeverBorrowAnotherRecordsIdentity() = runBlocking {
        withDatabase { database ->
            val first = Book(bookUrl = "one", origin = "source", name = "Title", author = "")
            val second = first.copy(bookUrl = "two")
            database.bookDao.insert(first, second)
            assertFalse(database.bookDao.has("Title", ""))
            assertEquals(null, database.bookDao.getBookByOrigin("Title", "source"))
            assertFalse(first.isSameNameAuthor(second))
            assertTrue(first.isSameNameAuthor(first.copy()))
            for (blank in listOf("", " ", "\t", "\u3000", "\u00a0")) {
                database.bookDao.insert(first.copy(bookUrl = "blank-$blank", author = blank))
                assertEquals(null, database.bookDao.getBook("Title", blank))
            }
        }
    }

    @Test
    fun nestedReplacementAndBatchEditFailuresRestoreBooksAndChapters() = runBlocking {
        withDatabase { database ->
            val original = Book(bookUrl = "one", name = "Title", author = "Author", durChapterPos = 37)
            val other = Book(bookUrl = "other", name = "Other", author = "Else")
            database.bookDao.insert(original, other)
            val chapter = BookChapter(bookUrl = "one", url = "chapter", title = "Original")
            database.bookChapterDao.insert(chapter)
            assertFailsWith<IllegalStateException> {
                database.useWriterConnection { writer -> writer.immediateTransaction {
                    database.bookDao.insert(original.copy(bookUrl = "replacement"))
                    error("Injected after legacy replacement and its cascade")
                } }
            }
            assertEquals(original, database.bookDao.getBook("one"))
            assertEquals(listOf(chapter), database.bookChapterDao.getChapterList("one"))
            assertEquals(null, database.bookDao.getBook("replacement"))
            assertFailsWith<IllegalStateException> {
                database.bookDao.update(original.copy(intro = "must rollback"), original.copy(bookUrl = "other"))
            }
            assertEquals(original, database.bookDao.getBook("one"))
            assertEquals(other, database.bookDao.getBook("other"))
            assertFailsWith<IllegalStateException> {
                database.useWriterConnection { writer -> writer.immediateTransaction {
                    database.bookDao.insert(original.copy(bookUrl = "new", name = "New"))
                    error("Injected before chapter insert")
                } }
            }
            assertEquals(null, database.bookDao.getBook("new"))
        }
    }

    @Test
    fun schema88MigrationPreservesBookChapterSourceCookieAndReopens() = runBlocking {
        val directory = Files.createTempDirectory("PROTOTYPE-spec003-actual-migration-").toFile()
        val path = directory.resolve("test.db").absolutePath
        val driver = BundledSQLiteDriver()
        driver.open(path).use { connection ->
            val sql = requireNotNull(javaClass.getResource("/schema88-fixture.sql")).readText()
            sql.split(";\n").filter { it.isNotBlank() }.forEach { connection.execSQL(it) }
            connection.execSQL("INSERT INTO books(bookUrl,origin,name,author,durChapterPos) VALUES('old','source','Original','Author',37)")
            connection.execSQL("INSERT INTO chapters(url,title,isVolume,bookUrl,`index`,isVip,isPay) VALUES('chapter','Saved',0,'old',4,0,0)")
            connection.execSQL("INSERT INTO cookies(url,cookie) VALUES('source','test=value')")
            connection.execSQL("INSERT INTO book_sources(`bookSourceUrl`,`bookSourceName`,`bookSourceType`,`lastUpdateTime`,`respondTime`,`weight`) VALUES('source','Saved source',0,0,0,0)")
            connection.execSQL("PRAGMA user_version=88")
        }
        fun open() = Room.databaseBuilder<AppDatabase>(path).setDriver(driver)
            .addMigrations(*DatabaseMigrations.migrations).build()
        var database = open()
        try {
            assertEquals(37, database.bookDao.getBook("old")?.durChapterPos)
            assertEquals("Saved", database.bookChapterDao.getChapter("old", 4)?.title)
            database.bookDao.insert(Book(bookUrl = "unknown-one", name = "Unknown"), Book(bookUrl = "unknown-two", name = "Unknown"))
            database.close()
            database = open()
            assertEquals(3, database.bookDao.allBookCount())
            assertEquals("Saved", database.bookChapterDao.getChapter("old", 4)?.title)
            driver.open(path).use { connection ->
                connection.prepare("SELECT cookie FROM cookies WHERE url='source'").use { q -> assertTrue(q.step()); assertEquals("test=value", q.getText(0)) }
                connection.prepare("SELECT bookSourceName FROM book_sources WHERE bookSourceUrl='source'").use { q -> assertTrue(q.step()); assertEquals("Saved source", q.getText(0)) }
                connection.prepare("PRAGMA integrity_check").use { q -> assertTrue(q.step()); assertEquals("ok", q.getText(0)) }
                connection.prepare("PRAGMA foreign_key_check").use { q -> assertFalse(q.step()) }
                connection.prepare("PRAGMA index_list(books)").use { q ->
                    var found = false
                    while (q.step()) if (q.getText(1) == "index_books_name_author") { found = true; assertEquals(0L, q.getLong(2)) }
                    assertTrue(found)
                }
            }
        } finally { database.close(); directory.deleteRecursively() }
    }

    private suspend fun withDatabase(block: suspend (AppDatabase) -> Unit) {
        val directory = Files.createTempDirectory("PROTOTYPE-spec003-actual-").toFile()
        val database = Room.databaseBuilder<AppDatabase>(directory.resolve("test.db").absolutePath)
            .setDriver(BundledSQLiteDriver()).addMigrations(*DatabaseMigrations.migrations).build()
        try { block(database) } finally { database.close(); directory.deleteRecursively() }
    }

    @Test
    fun independentRoomConnectionsSerializeKnownReplacementAndPreserveUnknownBooks() = runBlocking {
        val path = Files.createTempDirectory("PROTOTYPE-spec003-concurrency-").resolve("test.db").toFile().absolutePath
        val databases = List(4) {
            Room.databaseBuilder<AppDatabase>(path).setDriver(BundledSQLiteDriver())
                .addMigrations(*DatabaseMigrations.migrations).build()
        }
        try {
            // Open distinct Room pools before contention, so this tests writes rather than schema creation.
            databases.forEach { assertEquals(0, it.bookDao.allBookCount()) }
            val start = CompletableDeferred<Unit>()
            val ready = Channel<Unit>(databases.size)
            val completedWrites = withTimeout(30_000) {
                coroutineScope {
                    val workers = databases.mapIndexed { worker, database ->
                        async(Dispatchers.Default) {
                            ready.send(Unit)
                            start.await()
                            repeat(8) { sequence ->
                                val identity = worker * 8 + sequence
                                // Legacy known-author replacement must also atomically replace child chapters.
                                database.useWriterConnection { writer -> writer.immediateTransaction {
                                    database.bookDao.insert(Book(bookUrl = "known-$identity", name = "Known", author = "Author", durChapterPos = identity))
                                    database.bookChapterDao.insert(BookChapter(bookUrl = "known-$identity", url = "chapter-$identity", title = "Known $identity"))
                                } }
                                // Unknown authors have separate source records and independent progress/catalogs.
                                database.useWriterConnection { writer -> writer.immediateTransaction {
                                    database.bookDao.insert(Book(bookUrl = "unknown-$identity", origin = "source-$worker", name = "Unknown", author = "", durChapterPos = identity))
                                    database.bookChapterDao.insert(BookChapter(bookUrl = "unknown-$identity", url = "chapter-$identity", title = "Unknown $identity"))
                                } }
                            }
                            16
                        }
                    }
                    repeat(databases.size) { ready.receive() }
                    start.complete(Unit)
                    workers.awaitAll().sum()
                }
            }
            assertEquals(64, completedWrites)
            for (database in databases) {
                val books = database.bookDao.all()
                assertEquals(33, books.size)
                val known = books.single { it.name == "Known" }
                val winningIdentity = known.bookUrl.removePrefix("known-").toInt()
                assertEquals(winningIdentity, known.durChapterPos)
                assertEquals(listOf("Known $winningIdentity"), database.bookChapterDao.getChapterList(known.bookUrl).map { it.title })
                for (identity in 0 until 32) {
                    val unknown = database.bookDao.getBook("unknown-$identity")
                    assertEquals(identity, unknown?.durChapterPos)
                    assertEquals(listOf("Unknown $identity"), database.bookChapterDao.getChapterList("unknown-$identity").map { it.title })
                    if (identity != winningIdentity) assertEquals(0, database.bookChapterDao.getChapterCount("known-$identity"))
                }
                assertEquals(null, database.bookDao.getBook("Unknown", ""))
            }
        } finally {
            databases.forEach { it.close() }
            java.io.File(path).parentFile.deleteRecursively()
        }
    }

    @Test
    fun chapterRefreshCallbackDoesNotReplaceCurrentUnknownAuthorBook() {
        val reader = ReadBookShared()
        try {
            val original = Book(bookUrl = "current", origin = "source", name = "Title", author = "", totalChapterNum = 10)
            reader.bookValue = original
            reader.durChapterIndexValue = 8
            reader.onChapterListUpdated(original.copy(bookUrl = "foreign", totalChapterNum = 2))
            assertEquals(original, reader.book.value)
            assertEquals(8, reader.durChapterIndexValue)
            reader.onChapterListUpdated(original.copy(origin = "foreign-source", totalChapterNum = 2))
            assertEquals(original, reader.book.value)
            assertEquals(8, reader.durChapterIndexValue)
            val exactRecordUpdate = original.copy(totalChapterNum = 4)
            reader.onChapterListUpdated(exactRecordUpdate)
            assertEquals(exactRecordUpdate, reader.book.value)
            assertEquals(3, reader.durChapterIndexValue)
            val known = original.copy(author = "Author", totalChapterNum = 10)
            reader.bookValue = known
            val legacyKnownUpdate = known.copy(bookUrl = "other-record", origin = "other-source", totalChapterNum = 7)
            reader.onChapterListUpdated(legacyKnownUpdate)
            assertEquals(legacyKnownUpdate, reader.book.value)
        } finally { reader.cancel() }
    }

}
