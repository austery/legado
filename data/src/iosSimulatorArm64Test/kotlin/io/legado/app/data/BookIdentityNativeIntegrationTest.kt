package io.legado.app.data

import androidx.room3.Room
import androidx.sqlite.driver.NativeSQLiteDriver
import io.legado.app.data.entities.Book
import io.legado.app.data.entities.BookChapter
import androidx.sqlite.execSQL
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue
import kotlin.test.assertFalse
import kotlinx.coroutines.runBlocking
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

}
