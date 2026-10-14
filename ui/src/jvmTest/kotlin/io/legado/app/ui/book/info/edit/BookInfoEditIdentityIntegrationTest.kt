package io.legado.app.ui.book.info.edit

import androidx.room3.Room
import androidx.room3.immediateTransaction
import androidx.room3.useWriterConnection
import androidx.sqlite.driver.bundled.BundledSQLiteDriver
import io.legado.app.constant.AppLog
import io.legado.app.data.AppDatabase
import io.legado.app.data.AppDbAccessor
import io.legado.app.data.AppDbProviders
import io.legado.app.data.DatabaseMigrations
import io.legado.app.data.dao.BookIdentityConflictException
import io.legado.app.data.entities.Book
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.joinAll
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Test
import java.nio.file.Files
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertTrue

class BookInfoEditIdentityIntegrationTest {
    @Test
    fun conflictingMetadataEditPreservesRecordsAndReportsIdentityConflict() = runBlocking {
        val directory = Files.createTempDirectory("PROTOTYPE-spec003-editor-").toFile()
        val database = Room.databaseBuilder<AppDatabase>(directory.resolve("test.db").absolutePath)
            .setDriver(BundledSQLiteDriver()).addMigrations(*DatabaseMigrations.migrations).build()
        val previous = runCatching { AppDbProviders.get() }.getOrNull()
        val job = SupervisorJob()
        AppDbProviders.register(TestDatabaseAccessor(database))
        AppLog.clear()
        try {
            val first = Book(bookUrl = "first", name = "Title", author = "Author", durChapterPos = 17)
            val second = Book(bookUrl = "second", name = "Other", author = "Other author", durChapterPos = 29)
            database.bookDao.insert(first, second)
            var succeeded = false
            val editor = BookInfoEditViewModelShared(CoroutineScope(job)) { }
            editor.loadBook(second)
            editor.saveBook(second.copy(name = first.name, author = first.author), null) { succeeded = true }
            withTimeout(10_000) { job.children.toList().joinAll() }
            assertFalse(succeeded)
            assertEquals(first, database.bookDao.getBook(first.bookUrl))
            assertEquals(second, database.bookDao.getBook(second.bookUrl))
            val entry = AppLog.logs.single()
            assertIs<BookIdentityConflictException>(entry.third)
            assertTrue(entry.second.startsWith("书籍信息保存失败，存在相同书名作者书籍"), entry.second)

            // The same public entrypoint still saves a nonconflicting edit and calls success.
            AppLog.clear()
            val edited = second.copy(intro = "Updated description")
            editor.saveBook(edited, null) { succeeded = true }
            withTimeout(10_000) { job.children.toList().joinAll() }
            assertTrue(succeeded)
            assertEquals(edited, database.bookDao.getBook(second.bookUrl))
            assertTrue(AppLog.logs.isEmpty())
        } finally {
            job.cancelAndJoin()
            previous?.let(AppDbProviders::register)
            database.close()
            directory.deleteRecursively()
            AppLog.clear()
        }
    }

    internal class TestDatabaseAccessor(private val database: AppDatabase) : AppDbAccessor {
        override val bookDao get() = database.bookDao
        override val bookSourceDao get() = database.bookSourceDao
        override val bookChapterDao get() = database.bookChapterDao
        override val bookGroupDao get() = database.bookGroupDao
        override val keywordHighlightDao get() = database.keywordHighlightDao
        override val replaceRuleDao get() = database.replaceRuleDao
        override val readRecordDao get() = database.readRecordDao
        override val serverDao get() = database.serverDao
        override val txtTocRuleDao get() = database.txtTocRuleDao
        override val dictRuleDao get() = database.dictRuleDao
        override val sourceFilterRuleDao get() = database.sourceFilterRuleDao
        override val httpTTSDao get() = database.httpTTSDao
        override val cacheDao get() = database.cacheDao
        override val cookieDao get() = database.cookieDao
        override val ruleSubDao get() = database.ruleSubDao
        override val bookmarkDao get() = database.bookmarkDao
        override val searchKeywordDao get() = database.searchKeywordDao
        override val keyboardAssistsDao get() = database.keyboardAssistsDao

        override suspend fun <R> runInTransactionSuspending(block: suspend () -> R): R =
            database.useWriterConnection { writer -> writer.immediateTransaction { block() } }
    }
}
