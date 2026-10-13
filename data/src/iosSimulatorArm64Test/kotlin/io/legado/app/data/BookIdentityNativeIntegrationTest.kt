package io.legado.app.data

import androidx.room3.Room
import androidx.sqlite.driver.NativeSQLiteDriver
import io.legado.app.data.entities.Book
import io.legado.app.data.entities.BookChapter
import androidx.sqlite.execSQL
import androidx.room3.useWriterConnection
import androidx.room3.immediateTransaction
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue
import kotlin.test.assertFalse
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withTimeout

import platform.Foundation.NSTemporaryDirectory
import platform.Foundation.NSUUID
import kotlin.test.Test
import kotlin.test.assertEquals

/** Actual generated application DAO; synthetic simulator temporary database only. */
class BookIdentityNativeIntegrationTest {
    @Test
    fun missingAuthorsCoexistWithoutSelectingAnotherBook() = runBlocking {
        val path = NSTemporaryDirectory() + "PROTOTYPE-spec003-" + NSUUID().UUIDString + ".db"
        val database = Room.databaseBuilder<AppDatabase>(path)
            .setDriver(NativeSQLiteDriver())
            .addMigrations(*DatabaseMigrations.migrations)
            .build()
        try {
            database.bookDao.insert(Book(bookUrl = "https://one/book", origin = "one", name = "Title", author = ""))
            database.bookDao.insert(Book(bookUrl = "https://two/book", origin = "two", name = "Title", author = ""))
            assertEquals(2, database.bookDao.allBookCount())
            assertEquals(null, database.bookDao.getBook("Title", ""))
        } finally {
            database.close()
        }
    }
    @Test
    fun nativeAccessorActuallyRollsBackNestedReplacement() = runBlocking {
        val path = NSTemporaryDirectory() + "PROTOTYPE-spec003-" + NSUUID().UUIDString + ".db"
        val database = Room.databaseBuilder<AppDatabase>(path).setDriver(NativeSQLiteDriver())
            .addMigrations(*DatabaseMigrations.migrations).build()
        AppDatabaseProviders.register(object : AppDatabaseProvider { override val appDb = database })
        try {
            val original = Book(bookUrl = "one", name = "Title", author = "Author", durChapterPos = 37)
            database.bookDao.insert(original)
            val chapter = BookChapter(bookUrl = "one", url = "chapter", title = "Original")
            database.bookChapterDao.insert(chapter)
            assertFailsWith<IllegalStateException> {
                NativeAppDbAccessor().runInTransactionSuspending {
                    database.bookDao.insert(original.copy(bookUrl = "replacement"))
                    error("Injected after nested generated DAO replacement")
                }
            }
            assertEquals(original, database.bookDao.getBook("one"))
            assertEquals(listOf(chapter), database.bookChapterDao.getChapterList("one"))
            assertEquals(null, database.bookDao.getBook("replacement"))
        } finally { AppDatabaseProviders.reset(); database.close() }
    }

    @Test
    fun nativeSchema88UpgradePreservesChapterAndCookie() = runBlocking {
        val path = NSTemporaryDirectory() + "PROTOTYPE-spec003-migration-" + NSUUID().UUIDString + ".db"
        val driver = NativeSQLiteDriver()
        driver.open(path).use { connection ->
            SCHEMA_88_FIXTURE.split(";\n").filter { it.isNotBlank() }.forEach { connection.execSQL(it) }
            connection.execSQL("INSERT INTO books(bookUrl,origin,name,author,durChapterPos) VALUES('old','source','Original','Author',37)")
            connection.execSQL("INSERT INTO chapters(url,title,isVolume,bookUrl,`index`,isVip,isPay) VALUES('chapter','Saved',0,'old',4,0,0)")
            connection.execSQL("INSERT INTO cookies(url,cookie) VALUES('source','test=value')")
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
            driver.open(path).use { connection ->
                connection.prepare("SELECT cookie FROM cookies WHERE url='source'").use { q -> assertTrue(q.step()); assertEquals("test=value", q.getText(0)) }
                connection.prepare("PRAGMA integrity_check").use { q -> assertTrue(q.step()); assertEquals("ok", q.getText(0)) }
                connection.prepare("PRAGMA foreign_key_check").use { q -> assertFalse(q.step()) }
                connection.prepare("PRAGMA index_list(books)").use { q ->
                    var found = false
                    while (q.step()) if (q.getText(1) == "index_books_name_author") { found = true; assertEquals(0L, q.getLong(2)) }
                    assertTrue(found)
                }
            }
        } finally { database.close() }
    }

    @Test
    fun independentRoomConnectionsSerializeKnownReplacementAndPreserveUnknownBooks() = runBlocking {
        val path = NSTemporaryDirectory() + "PROTOTYPE-spec003-concurrency-" + NSUUID().UUIDString + ".db"
        val databases = List(4) {
            Room.databaseBuilder<AppDatabase>(path).setDriver(NativeSQLiteDriver())
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
            // Keep uniquely named simulator evidence files; never touch an application database.
        }
    }

}
