package io.legado.app.data

import androidx.room3.Room
import androidx.sqlite.driver.bundled.BundledSQLiteDriver
import io.legado.app.data.dao.NativeChapterProjection
import io.legado.app.data.entities.Book
import io.legado.app.data.entities.BookChapter
import io.legado.app.data.entities.Bookmark
import io.legado.app.data.entities.BookSource
import kotlinx.coroutines.runBlocking
import org.junit.Test
import java.nio.file.Files
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull

/** Observed upstream behavior, including gaps that a native adapter must address. */
class UpstreamBookmarkCharacterizationTest {
    @Test
    fun originalCoordinatesAndExcerptSurviveRestartAndDeletion() = runBlocking {
        val directory = Files.createTempDirectory("native-bookmark-characterization-").toFile()
        val path = directory.resolve("test.db").absolutePath
        fun open() = Room.databaseBuilder<AppDatabase>(path).setDriver(BundledSQLiteDriver())
            .addMigrations(*DatabaseMigrations.migrations).build()
        var database = open()
        try {
            val bookmark = Bookmark(time = 101, bookName = "Book", bookAuthor = "Author",
                chapterIndex = 2, chapterPos = 7, chapterName = "Chapter", bookText = "第二段 🌿")
            database.bookmarkDao.insert(bookmark)
            database.close()
            database = open()
            assertEquals(listOf(bookmark), database.bookmarkDao.getByBook("Book", "Author"))
            database.bookmarkDao.delete(bookmark)
            database.bookmarkDao.delete(bookmark)
            database.close()
            database = open()
            assertEquals(emptyList(), database.bookmarkDao.getByBook("Book", "Author"))
        } finally {
            database.close()
            directory.deleteRecursively()
        }
    }

    @Test
    fun titleAuthorLookupCombinesDistinctUnknownAuthorShelfEntries() = runBlocking {
        withDatabase { database ->
            for (id in listOf("a", "b")) {
                database.nativeShelfDao.addToShelf(
                    Book(bookUrl = id, origin = "source-$id", name = "Same title", author = ""),
                    listOf(BookChapter(bookUrl = id, url = "chapter-$id")))
            }
            assertEquals(2, database.nativeShelfDao.listBooks().size)
            val first = Bookmark(time = 1, bookName = "Same title", bookAuthor = "", bookText = "A text")
            val second = Bookmark(time = 2, bookName = "Same title", bookAuthor = "", bookText = "B text")
            database.bookmarkDao.insert(first, second)
            for (book in database.nativeShelfDao.listBooks()) {
                assertEquals(setOf(1L, 2L), database.bookmarkDao.getByBook(book.name, book.author).map { it.time }.toSet())
            }
        }
    }

    @Test
    fun nativeSourceSwitchRetainsLegacyBookmarkButChangesResolvedBook() = runBlocking {
        withDatabase { database ->
            val old = Book(bookUrl = "old", origin = "old-source", name = "Book", author = "Author")
            database.nativeShelfDao.addToShelf(old,
                listOf(BookChapter(bookUrl = "old", url = "old-chapter", title = "Old chapter")))
            val bookmark = Bookmark(time = 3, bookName = old.name, bookAuthor = old.author,
                chapterIndex = 0, chapterPos = 12, chapterName = "Old chapter", bookText = "Old passage")
            database.bookmarkDao.insert(bookmark)
            val source = BookSource(bookSourceUrl = "new-source", bookSourceName = "New")
            database.bookSourceDao.insert(source)
            val replacement = old.copy(bookUrl = "new", origin = source.bookSourceUrl)
            val chapter = BookChapter(bookUrl = "new", url = "different-chapter", title = "Different chapter")
            database.nativeShelfDao.switchSource(old.origin, old.bookUrl, 0,
                NativeChapterProjection.from(assertNotNull(database.bookDao.getBook("old"))),
                replacement, listOf(chapter), chapter.url, "Entirely different body", source)
            assertNull(database.bookDao.getBook("old"))
            assertEquals("new", database.bookDao.getBook(bookmark.bookName, bookmark.bookAuthor)?.bookUrl)
            assertEquals(listOf(bookmark), database.bookmarkDao.getByBook(bookmark.bookName, bookmark.bookAuthor))
            assertEquals("different-chapter", database.bookChapterDao.getChapterList("new").single().url)
        }
    }

    @Test
    fun timestampCollisionReplacesExistingBookmark() = runBlocking {
        withDatabase { database ->
            val first = Bookmark(time = 4, bookName = "First", bookAuthor = "A", bookText = "First text")
            val second = Bookmark(time = 4, bookName = "Second", bookAuthor = "B", bookText = "Second text")
            database.bookmarkDao.insert(first)
            database.bookmarkDao.insert(second)
            assertEquals(emptyList(), database.bookmarkDao.getByBook("First", "A"))
            assertEquals(listOf(second), database.bookmarkDao.getByBook("Second", "B"))
        }
    }

    private suspend fun withDatabase(block: suspend (AppDatabase) -> Unit) {
        val directory = Files.createTempDirectory("native-bookmark-characterization-").toFile()
        val database = Room.databaseBuilder<AppDatabase>(directory.resolve("test.db").absolutePath)
            .setDriver(BundledSQLiteDriver()).addMigrations(*DatabaseMigrations.migrations).build()
        try {
            block(database)
        } finally {
            database.close()
            directory.deleteRecursively()
        }
    }
}
