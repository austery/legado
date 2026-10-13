package io.legado.app.ui.book.info.edit

import androidx.room3.Room
import androidx.sqlite.driver.bundled.BundledSQLiteDriver
import io.legado.app.constant.AppLog
import io.legado.app.data.AppDatabase
import io.legado.app.data.AppDbProviders
import io.legado.app.data.DatabaseMigrations
import io.legado.app.data.entities.Book
import io.legado.app.data.entities.BookChapter
import io.legado.app.data.entities.BookListPage
import io.legado.app.data.entities.BookSource
import io.legado.app.help.config.AppConfigAccessor
import io.legado.app.help.config.AppConfigProviders
import io.legado.app.help.toast.Toaster
import io.legado.app.help.toast.Toasters
import io.legado.app.model.webBook.PluginFilterSession
import io.legado.app.model.webBook.PluginSourceDelegate
import io.legado.app.model.webBook.PluginSourceDelegates
import io.legado.app.ui.bookshelf.BookshelfAddViewModelShared
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.joinAll
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Test
import java.lang.reflect.Proxy
import java.nio.file.Files
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

class BookshelfImportIdentityIntegrationTest {
    @Test
    fun repeatedUnknownRecordKeepsProgressWhileNewUnknownRecordImports() = runBlocking {
        val directory = Files.createTempDirectory("PROTOTYPE-spec003-import-").toFile()
        val database = Room.databaseBuilder<AppDatabase>(directory.resolve("test.db").absolutePath)
            .setDriver(BundledSQLiteDriver()).addMigrations(*DatabaseMigrations.migrations).build()
        val oldDb = runCatching { AppDbProviders.get() }.getOrNull()
        val oldConfig = runCatching { AppConfigProviders.get() }.getOrNull()
        val oldToaster = runCatching { Toasters.get() }.getOrNull()
        val job = SupervisorJob()
        val source = BookSource(bookSourceUrl = "prototype-${UUID.randomUUID()}", bookSourceName = "Fixture")
        val requests = CopyOnWriteArrayList<String>()
        val notifications = CopyOnWriteArrayList<String>()
        AppDbProviders.register(BookInfoEditIdentityIntegrationTest.TestDatabaseAccessor(database))
        // Only the public configuration used by this importer is provided.
        AppConfigProviders.register(Proxy.newProxyInstance(
            AppConfigAccessor::class.java.classLoader, arrayOf(AppConfigAccessor::class.java)
        ) { _, method, _ ->
            if (method.name == "getThreadCount") 1 else error("Unexpected configuration: ${method.name}")
        } as AppConfigAccessor)
        Toasters.register(object : Toaster {
            override fun toast(message: String) { notifications.add(message) }
            override fun toastLong(message: String) { notifications.add(message) }
        })
        // Only source transport is a fixture; importer, WebBook routing and Room DAO are real.
        PluginSourceDelegates.register(object : PluginSourceDelegate {
            override fun handles(bookSource: BookSource) = bookSource.bookSourceUrl in listOf(source.bookSourceUrl, source.bookSourceUrl + "-other")
            override suspend fun getBookInfoAwait(bookSource: BookSource, book: Book, canReName: Boolean): Book {
                requests.add(book.bookUrl)
                book.author = "Discovered author"
                return book
            }
            override suspend fun getBookListAwait(bookSource: BookSource, key: String, page: Int, filters: PluginFilterSession?): BookListPage = error("Unexpected search")
            override suspend fun getExploreAwait(bookSource: BookSource, url: String, page: Int, filters: PluginFilterSession?): BookListPage = error("Unexpected explore")
            override suspend fun getChapterListAwait(bookSource: BookSource, book: Book): Result<List<BookChapter>> = error("Unexpected catalog")
            override suspend fun getContentAwait(bookSource: BookSource, book: Book, bookChapter: BookChapter): String = error("Unexpected content")
        })
        AppLog.clear()
        try {
            val original = Book(bookUrl = "saved", origin = source.bookSourceUrl, name = "Unknown title", author = "", durChapterIndex = 4, durChapterPos = 37)
            val known = Book(bookUrl = "known", origin = source.bookSourceUrl, name = "Known title", author = "Known author", durChapterPos = 52)
            val chapter = BookChapter(bookUrl = "saved", url = "chapter", title = "Saved chapter")
            database.bookSourceDao.insert(source)
            database.bookDao.insert(original, known)
            database.bookChapterDao.insert(chapter)
            val importer = BookshelfAddViewModelShared(CoroutineScope(job))
            importer.importBookshelf("""[
                {"name":"Unknown title","author":"","origin":"${source.bookSourceUrl}","bookUrl":"saved"},
                {"name":"Known title","author":"Known author","origin":"${source.bookSourceUrl}","bookUrl":"known-other"},
                {"name":"New title","author":"","origin":"${source.bookSourceUrl}","bookUrl":"new"}
            ]""", 0)
            withTimeout(10_000) { job.children.toList().joinAll() }
            assertEquals(original, database.bookDao.getBook("saved"))
            assertEquals(listOf(chapter), database.bookChapterDao.getChapterList("saved"))
            assertEquals(known, database.bookDao.getBook("known"))
            assertNotNull(database.bookDao.getBook("new"))
            assertEquals(listOf("new"), requests.toList())
            assertEquals(3, database.bookDao.allBookCount())
            assertTrue(AppLog.logs.isEmpty(), AppLog.logs.toString())
            assertEquals(listOf("成功"), notifications.toList())

            // A reused URL from another source is an explicit conflict, never a source switch.
            val otherSource = source.copy(bookSourceUrl = source.bookSourceUrl + "-other")
            database.bookSourceDao.insert(otherSource)
            notifications.clear()
            importer.importBookshelf("""[{"name":"Unknown title","author":"","origin":"${otherSource.bookSourceUrl}","bookUrl":"saved"}]""", 0)
            withTimeout(10_000) { job.children.toList().joinAll() }
            assertEquals(original, database.bookDao.getBook("saved"))
            assertEquals(listOf(chapter), database.bookChapterDao.getChapterList("saved"))
            assertEquals(listOf("new"), requests.toList())
            assertEquals(listOf("Book URL belongs to a different source: saved"), notifications.toList())
        } finally {
            job.cancelAndJoin()
            oldDb?.let(AppDbProviders::register)
            oldConfig?.let(AppConfigProviders::register)
            if (oldToaster == null) Toasters.reset() else Toasters.register(oldToaster)
            database.close()
            directory.deleteRecursively()
            AppLog.clear()
        }
    }
}
