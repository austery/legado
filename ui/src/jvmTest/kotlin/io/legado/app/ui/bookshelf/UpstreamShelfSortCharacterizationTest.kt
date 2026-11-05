package io.legado.app.ui.bookshelf

import androidx.room3.Room
import androidx.sqlite.driver.bundled.BundledSQLiteDriver
import io.legado.app.data.AppDatabase
import io.legado.app.data.AppDbProviders
import io.legado.app.data.DatabaseMigrations
import io.legado.app.data.entities.Book
import io.legado.app.data.entities.BookGroup
import io.legado.app.help.config.AppConfigAccessor
import io.legado.app.help.config.AppConfigProviders
import io.legado.app.ui.book.info.edit.BookInfoEditIdentityIntegrationTest.TestDatabaseAccessor
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Test
import java.lang.reflect.Proxy
import java.nio.file.Files
import java.util.concurrent.atomic.AtomicInteger
import kotlin.test.assertEquals

/** Exercises the existing public ViewModel with real Room flows and SQLite storage. */
class UpstreamShelfSortCharacterizationTest {
    private val books = listOf(
        Book(bookUrl = "a", name = "北京", author = "张", durChapterTime = 30,
            latestChapterTime = 10, order = 1, group = 1, durChapterPos = 17),
        Book(bookUrl = "b", name = "广州", author = "王", durChapterTime = 10,
            latestChapterTime = 40, order = 2, group = 1, durChapterPos = 31),
        Book(bookUrl = "c", name = "上海", author = "李", durChapterTime = 20,
            latestChapterTime = 20, order = 0, group = 1, durChapterPos = 52)
    )

    @Test
    fun allSixModesAndInvalidModeUseExistingPublicRefresh() = runBlocking {
        withDatabase { database, mode ->
            database.bookDao.insert(*books.toTypedArray())
            val model = BookshelfViewModel()
            try {
                model.setBookshelfActive(true)
                val expected = listOf(
                    listOf("a", "c", "b"), listOf("b", "c", "a"),
                    listOf("a", "b", "c"), listOf("c", "a", "b"),
                    listOf("b", "a", "c"), listOf("c", "b", "a")
                )
                expected.forEachIndexed { index, order ->
                    mode.set(index)
                    model.upSort()
                    awaitOrder(model, order)
                    assertEquals(books.associate { it.bookUrl to it.durChapterPos },
                        model.books.value.associate { it.bookUrl to it.durChapterPos })
                }
                mode.set(99)
                model.upSort()
                awaitOrder(model, expected.first())
                assertEquals(books, books.map { database.bookDao.getBook(it.bookUrl) })
            } finally {
                model.onCleared()
            }
        }
    }

    @Test
    fun groupOverrideThenInheritancePersistsAfterDatabaseReopen() = runBlocking {
        withDatabase { database, mode ->
            database.bookDao.insert(*books.toTypedArray())
            database.bookGroupDao.insert(BookGroup(groupId = 1, groupName = "Fixture", bookSort = 3))
            mode.set(0)
            val model = BookshelfViewModel()
            try {
                model.setBookshelfActive(true)
                withTimeout(5_000) { model.bookGroups.first { it.any { group -> group.groupId == 1L } } }
                model.selectGroup(1)
                model.upSort()
                awaitOrder(model, listOf("c", "a", "b"))
                database.bookGroupDao.update(BookGroup(groupId = 1, groupName = "Fixture", bookSort = -1))
                withTimeout(5_000) { model.bookGroups.first { it.any { group -> group.bookSort == -1 } } }
                model.upSort()
                awaitOrder(model, listOf("a", "c", "b"))
            } finally {
                model.onCleared()
            }
        }
    }

    @Test
    fun equalTitlesKeepDistinctBooksAndProgress() = runBlocking {
        withDatabase { database, mode ->
            val sameTitleBooks = books.map { it.copy(name = "同名", durChapterPos = 17) }
            database.bookDao.insert(*sameTitleBooks.toTypedArray())
            mode.set(2)
            val model = BookshelfViewModel()
            try {
                model.setBookshelfActive(true)
                val result = withTimeout(5_000) { model.books.first { it.size == 3 } }
                assertEquals(setOf("a", "b", "c"), result.map { it.bookUrl }.toSet())
                assertEquals(sameTitleBooks, sameTitleBooks.map { database.bookDao.getBook(it.bookUrl) })
            } finally {
                model.onCleared()
            }
        }
    }

    private suspend fun awaitOrder(model: BookshelfViewModel, expected: List<String>) {
        val result = withTimeout(5_000) {
            model.books.first { list -> list.map { it.bookUrl } == expected }
        }
        assertEquals(expected, result.map { it.bookUrl })
    }

    private suspend fun withDatabase(block: suspend (AppDatabase, AtomicInteger) -> Unit) {
        val directory = Files.createTempDirectory("upstream-shelf-sort-").toFile()
        val path = directory.resolve("fixture.db").absolutePath
        val oldDatabase = runCatching { AppDbProviders.get() }.getOrNull()
        val oldConfig = runCatching { AppConfigProviders.get() }.getOrNull()
        val mode = AtomicInteger(0)
        val database = Room.databaseBuilder<AppDatabase>(path)
            .setDriver(BundledSQLiteDriver()).addMigrations(*DatabaseMigrations.migrations).build()
        AppDbProviders.register(TestDatabaseAccessor(database))
        AppConfigProviders.register(Proxy.newProxyInstance(
            AppConfigAccessor::class.java.classLoader, arrayOf(AppConfigAccessor::class.java)
        ) { _, method, _ ->
            when (method.name) {
                "getBookshelfSort" -> mode.get()
                "getAutoRefreshBook" -> false
                else -> error("Unexpected configuration read: ${method.name}")
            }
        } as AppConfigAccessor)
        try {
            block(database, mode)
            val storedGroups = database.bookGroupDao.all()
            val storedBooks = books.map { database.bookDao.getBook(it.bookUrl) }
            database.close()
            val reopened = Room.databaseBuilder<AppDatabase>(path)
                .setDriver(BundledSQLiteDriver()).addMigrations(*DatabaseMigrations.migrations).build()
            try {
                assertEquals(storedGroups, reopened.bookGroupDao.all())
                assertEquals(storedBooks, books.map { reopened.bookDao.getBook(it.bookUrl) })
            } finally {
                reopened.close()
            }
        } finally {
            database.close()
            oldDatabase?.let(AppDbProviders::register) ?: AppDbProviders.unregister()
            oldConfig?.let(AppConfigProviders::register)
            directory.deleteRecursively()
        }
    }
}
