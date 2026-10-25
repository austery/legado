package io.legado.app.data

import androidx.room3.Room
import androidx.sqlite.driver.bundled.BundledSQLiteDriver
import io.legado.app.data.entities.Book
import io.legado.app.data.entities.BookChapter
import kotlinx.coroutines.runBlocking
import org.junit.Test
import java.nio.file.Files
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue
import androidx.sqlite.execSQL
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withTimeout
import io.legado.app.constant.BookType
import io.legado.app.data.dao.NativeShelfException
import io.legado.app.data.dao.NativeShelfFailure
import io.legado.app.data.dao.NativeShelfTarget

/** Native shelf persistence only; all databases and book records are synthetic. */
class NativeShelfIntegrationTest {
    @Test
    fun groupNamesCapacityAndDeletedSlotReuseRespectExistingRepresentation() = runBlocking {
        withDatabase { database, _ ->
            val dao = database.nativeShelfDao
            dao.createGroup("  Growing  ", dao.organization().token)
            val before = dao.organization()
            for (name in listOf("", "  ", " Growing ")) {
                assertEquals(NativeShelfFailure.INVALID_INPUT, assertFailsWith<NativeShelfException> {
                    dao.createGroup(name, before.token)
                }.failure)
                assertEquals(before, dao.organization())
            }
            repeat(62) { index -> dao.createGroup("Group $index", dao.organization().token) }
            val full = dao.organization()
            assertEquals(63, full.groups.size)
            assertEquals(4611686018427387904L, full.groups.last().groupId)
            assertEquals(NativeShelfFailure.GROUP_CAPACITY, assertFailsWith<NativeShelfException> {
                dao.createGroup("Overflow", full.token)
            }.failure)
            assertEquals(full, dao.organization())
            dao.deleteGroup(2L, full.token)
            val reused = dao.createGroup("Replacement", dao.organization().token)
            assertEquals(2L, reused.groups.single { it.groupName == "Replacement" }.groupId)
        }
    }

    @Test
    fun failedBatchMembershipAndGroupDeletionRollBackEveryWrittenRelationship() = runBlocking {
        withDatabase { database, path ->
            val dao = database.nativeShelfDao
            for (id in listOf("a", "b")) dao.addToShelf(
                Book(bookUrl = id, origin = "source", name = id, durChapterPos = 41),
                listOf(BookChapter(bookUrl = id, url = "chapter-$id")))
            dao.createGroup("Growing", dao.organization().token)
            val before = dao.organization()
            val targets = listOf(NativeShelfTarget("source", "a"), NativeShelfTarget("source", "b"))
            BundledSQLiteDriver().open(path).use { connection ->
                connection.execSQL("CREATE TRIGGER fail_second_membership BEFORE UPDATE OF `group` ON books WHEN NEW.bookUrl = 'b' BEGIN SELECT RAISE(ABORT, 'Synthetic second membership failure'); END")
            }
            assertFailsWith<Exception> { dao.changeGroups(targets, listOf(1L), emptyList(), before.token) }
            assertEquals(before, dao.organization())
            BundledSQLiteDriver().open(path).use { connection -> connection.execSQL("DROP TRIGGER fail_second_membership") }
            val grouped = dao.changeGroups(targets, listOf(1L), emptyList(), before.token)
            BundledSQLiteDriver().open(path).use { connection ->
                connection.execSQL("CREATE TRIGGER fail_group_delete BEFORE DELETE ON book_groups BEGIN SELECT RAISE(ABORT, 'Synthetic group delete failure'); END")
            }
            assertFailsWith<Exception> { dao.deleteGroup(1L, grouped.token) }
            assertEquals(grouped, dao.organization())
            assertEquals(41, dao.openBook("source", "a").book.durChapterPos)
        }
    }

    @Test
    fun batchRemovalAndInvalidTargetsCannotPartiallyRemoveShelfBooks() = runBlocking {
        withDatabase { database, path ->
            val dao = database.nativeShelfDao
            for (id in listOf("a", "b")) dao.addToShelf(
                Book(bookUrl = id, origin = "source", name = id),
                listOf(BookChapter(bookUrl = id, url = "chapter-$id")))
            dao.createGroup("Growing", dao.organization().token)
            val targets = listOf(NativeShelfTarget("source", "a"), NativeShelfTarget("source", "b"))
            val before = dao.changeGroups(targets, listOf(1L), emptyList(), dao.organization().token)
            val wrong = listOf(targets.first(), NativeShelfTarget("wrong-source", "b"))
            assertEquals(NativeShelfFailure.IDENTITY_CONFLICT, assertFailsWith<NativeShelfException> {
                dao.removeBooks(wrong, before.token)
            }.failure)
            assertEquals(before, dao.organization())
            BundledSQLiteDriver().open(path).use { connection ->
                connection.execSQL("CREATE TRIGGER fail_second_remove BEFORE UPDATE OF type ON books WHEN NEW.bookUrl = 'b' BEGIN SELECT RAISE(ABORT, 'Synthetic second removal failure'); END")
            }
            assertFailsWith<Exception> { dao.removeBooks(targets, before.token) }
            assertEquals(before, dao.organization())
        }
    }

    @Test
    fun staleOrganizationFailsWhileReadingProgressDoesNotInvalidateMembershipEditing() = runBlocking {
        withDatabase { database, _ ->
            val dao = database.nativeShelfDao
            val book = Book(bookUrl = "book", origin = "source", name = "Book")
            dao.addToShelf(book, listOf(BookChapter(bookUrl = "book", url = "chapter", title = "Chapter")))
            val emptyGroups = dao.organization()
            val created = dao.createGroup("Growing", emptyGroups.token)
            assertEquals(NativeShelfFailure.STALE_ORGANIZATION, assertFailsWith<NativeShelfException> {
                dao.renameGroup(1L, "Stale", emptyGroups.token)
            }.failure)
            val saved = database.nativeResumeDao.save("source", "book", "chapter", 0, "first\nsecond", 6, 0,
                io.legado.app.data.dao.NativeChapterProjection.from(book))
            assertEquals(created.token, dao.organization().token)
            val changed = dao.changeGroups(listOf(NativeShelfTarget("source", "book")), listOf(1L), emptyList(), created.token)
            assertEquals(1L, changed.books.single().group)
            assertEquals(saved, dao.resume("book"))
            assertEquals(NativeShelfFailure.STALE_ORGANIZATION, assertFailsWith<NativeShelfException> {
                dao.deleteGroup(1L, created.token)
            }.failure)
        }
    }

    @Test
    fun shelfRemovalClearsEveryMembershipButReAdmissionKeepsReadingRecord() = runBlocking {
        withDatabase { database, _ ->
            val dao = database.nativeShelfDao
            val book = Book(bookUrl = "book", origin = "source", name = "Book", durChapterPos = 53)
            dao.addToShelf(book, listOf(BookChapter(bookUrl = "book", url = "chapter")))
            dao.createGroup("Growing", dao.organization().token)
            dao.createGroup("Reading", dao.organization().token)
            val target = NativeShelfTarget("source", "book")
            dao.changeGroups(listOf(target), listOf(1L, 2L), emptyList(), dao.organization().token)
            assertEquals(3L, dao.addToShelf(book, emptyList()).book.group)
            val removed = dao.removeBooks(listOf(target), dao.organization().token)
            assertEquals(emptyList(), removed.books)
            val restored = dao.addToShelf(book, emptyList())
            assertEquals(0L, restored.book.group)
            assertEquals(53, restored.book.durChapterPos)
            assertEquals(listOf("chapter"), restored.chapters.map { it.url })
            dao.changeGroups(listOf(target), listOf(1L), emptyList(), dao.organization().token)
            dao.removeFromShelf("source", "book")
            assertEquals(0L, dao.addToShelf(book, emptyList()).book.group)
        }
    }

    @Test
    fun renamedAndDeletedGroupsPreserveBooksAndOtherGroups() = runBlocking {
        withDatabase { database, _ ->
            val dao = database.nativeShelfDao
            dao.addToShelf(Book(bookUrl = "book", origin = "source", name = "Book", durChapterPos = 29),
                listOf(BookChapter(bookUrl = "book", url = "chapter")))
            dao.createGroup("Growing", dao.organization().token)
            dao.createGroup("Reading", dao.organization().token)
            dao.changeGroups(listOf(NativeShelfTarget("source", "book")), listOf(1L, 2L), emptyList(), dao.organization().token)
            val renamed = dao.renameGroup(1L, "  Later  ", dao.organization().token)
            assertEquals(listOf("Later", "Reading"), renamed.groups.map { it.groupName })
            val deleted = dao.deleteGroup(1L, renamed.token)
            assertEquals(listOf("Reading"), deleted.groups.map { it.groupName })
            assertEquals(2L, deleted.books.single().group)
            assertEquals(29, dao.openBook("source", "book").book.durChapterPos)
            val ungrouped = dao.deleteGroup(2L, deleted.token)
            assertEquals(0L, ungrouped.books.single().group)
            assertEquals(1, dao.listBooks().size)
        }
    }

    @Test
    fun groupMembershipEditingPreservesBooksAndUntouchedMemberships() = runBlocking {
        withDatabase { database, _ ->
            val dao = database.nativeShelfDao
            for (id in listOf("a", "b")) dao.addToShelf(
                Book(bookUrl = id, origin = "source", name = id, durChapterPos = 37),
                listOf(BookChapter(bookUrl = id, url = "chapter-$id")))
            dao.createGroup("Growing", dao.organization().token)
            dao.createGroup("Reading", dao.organization().token)
            val a = NativeShelfTarget("source", "a")
            val b = NativeShelfTarget("source", "b")
            dao.changeGroups(listOf(a), listOf(1L), emptyList(), dao.organization().token)
            val together = dao.changeGroups(listOf(a, b), listOf(2L), emptyList(), dao.organization().token)
            assertEquals(3L, together.books.single { it.bookUrl == "a" }.group)
            assertEquals(2L, together.books.single { it.bookUrl == "b" }.group)
            val removed = dao.changeGroups(listOf(a), emptyList(), listOf(1L), together.token)
            assertEquals(2L, removed.books.single { it.bookUrl == "a" }.group)
            assertEquals(37, dao.openBook("source", "a").book.durChapterPos)
            assertEquals(listOf("chapter-a"), dao.openBook("source", "a").chapters.map { it.url })
        }
    }

    @Test
    fun creatingGroupsReturnsAStableCoherentOrganization() = runBlocking {
        withDatabase { database, _ ->
            val dao = database.nativeShelfDao
            val empty = dao.organization()
            assertEquals(emptyList(), empty.groups)
            val first = dao.createGroup("  Growing  ", empty.token)
            assertEquals(listOf("Growing"), first.groups.map { it.groupName })
            assertEquals(listOf(1L), first.groups.map { it.groupId })
            val second = dao.createGroup("Reading", first.token)
            assertEquals(listOf("Growing", "Reading"), second.groups.map { it.groupName })
            assertEquals(listOf(1L, 2L), second.groups.map { it.groupId })
            assertEquals(second, dao.organization())
        }
    }

    @Test
    fun freshAdmissionDoesNotInheritSourceGroupMembership() = runBlocking {
        withDatabase { database, _ ->
            val candidate = Book(bookUrl = "incoming-groups", origin = "source", name = "Incoming", group = 7)
            val added = database.nativeShelfDao.addToShelf(candidate,
                listOf(BookChapter(bookUrl = candidate.bookUrl, url = "chapter")))
            assertEquals(0L, added.book.group)
            assertEquals(0L, database.nativeShelfDao.openBook("source", candidate.bookUrl).book.group)
        }
    }

    @Test
    fun sameKnownIdentityReusesOriginalBookAndCatalogWithoutReplacing() = runBlocking {
        val directory = Files.createTempDirectory("PROTOTYPE-spec003-shelf-").toFile()
        val database = Room.databaseBuilder<AppDatabase>(directory.resolve("test.db").absolutePath)
            .setDriver(BundledSQLiteDriver()).addMigrations(*DatabaseMigrations.migrations).build()
        try {
            val original = Book(bookUrl = "original", origin = "original-source", name = "Title", author = "Author", durChapterPos = 37, intro = "Original metadata")
            val chapter = BookChapter(bookUrl = original.bookUrl, url = "saved-chapter", title = "Saved")
            database.nativeShelfDao.addToShelf(original, listOf(chapter))
            val candidate = original.copy(bookUrl = "candidate", origin = "other-source", durChapterPos = 0, intro = "New metadata")
            val result = database.nativeShelfDao.addToShelf(candidate, listOf(chapter.copy(bookUrl = candidate.bookUrl, url = "other-chapter")))
            assertEquals(original, result.book)
            assertEquals(listOf(chapter), result.chapters)
            assertEquals(1, database.bookDao.allBookCount())
            assertEquals(null, database.bookDao.getBook(candidate.bookUrl))
        } finally { database.close(); directory.deleteRecursively() }
    }
    @Test
    fun softRemovalReaddAndExactReopenPreserveExistingRecord() = runBlocking {
        val directory = Files.createTempDirectory("PROTOTYPE-spec003-shelf-").toFile()
        val path = directory.resolve("test.db").absolutePath
        fun open() = Room.databaseBuilder<AppDatabase>(path).setDriver(BundledSQLiteDriver())
            .addMigrations(*DatabaseMigrations.migrations).build()
        var database = open()
        try {
            val original = Book(bookUrl = "original", origin = "source", name = "Title", author = "", type = BookType.text or BookType.updateError, durChapterPos = 37)
            val chapter = BookChapter(bookUrl = original.bookUrl, url = "saved", title = "Saved")
            database.nativeShelfDao.addToShelf(original, listOf(chapter))
            database.nativeShelfDao.removeFromShelf("source", "original")
            assertEquals(emptyList(), database.nativeShelfDao.listBooks())
            assertEquals(original.copy(type = original.type or BookType.notShelf), database.bookDao.getBook("original"))
            assertEquals(listOf(chapter), database.bookChapterDao.getChapterList("original"))
            assertEquals(NativeShelfFailure.NOT_ON_SHELF, assertFailsWith<NativeShelfException> {
                database.nativeShelfDao.openBook("source", "original")
            }.failure)
            // Reuse precedes incoming metadata/catalog validation.
            val restored = database.nativeShelfDao.addToShelf(original.copy(author = "new author", intro = "discard"), emptyList())
            assertEquals(original, restored.book)
            assertEquals(listOf(chapter), restored.chapters)
            database.close()
            database = open()
            assertEquals(restored, database.nativeShelfDao.openBook("source", "original"))
            assertEquals(NativeShelfFailure.IDENTITY_CONFLICT, assertFailsWith<NativeShelfException> {
                database.nativeShelfDao.openBook("wrong-source", "original")
            }.failure)
        } finally { database.close(); directory.deleteRecursively() }
    }

    @Test
    fun unknownRecordsStaySeparateAndUrlOwnershipConflictsNeverOverwrite() = runBlocking {
        withDatabase { database, _ ->
            val first = Book(bookUrl = "one", origin = "source-one", name = "Title", author = "", durChapterPos = 31)
            val second = first.copy(bookUrl = "two", origin = "source-two", author = " ", durChapterPos = 47)
            val known = first.copy(bookUrl = "known", origin = "known-source", author = "Author", durChapterPos = 59)
            for (book in listOf(first, second, known)) {
                database.nativeShelfDao.addToShelf(book, listOf(BookChapter(bookUrl = book.bookUrl, url = "chapter-${book.bookUrl}")))
            }
            assertEquals(3, database.nativeShelfDao.listBooks().size)
            assertEquals(NativeShelfFailure.IDENTITY_CONFLICT, assertFailsWith<NativeShelfException> {
                database.nativeShelfDao.addToShelf(first.copy(origin = "wrong-source"), emptyList())
            }.failure)
            assertEquals(first, database.bookDao.getBook("one"))
            // A unique known identity may win despite a candidate URL owned by another source.
            val reused = database.nativeShelfDao.addToShelf(known.copy(bookUrl = "one", origin = "new-source"), emptyList())
            assertEquals(known, reused.book)
            assertEquals(first, database.bookDao.getBook("one"))
            database.nativeShelfDao.removeFromShelf(known.origin, known.bookUrl)
            assertEquals(known, database.nativeShelfDao.addToShelf(known.copy(bookUrl = "different"), emptyList()).book)
            assertEquals(second, database.nativeShelfDao.openBook(second.origin, second.bookUrl).book)
        }
    }

    @Test
    fun ambiguousKnownIdentityAndCatalogFailurePreserveAllStoredData() = runBlocking {
        withDatabase { database, path ->
            val original = Book(bookUrl = "original", origin = "source", name = "Title", author = "Author")
            database.nativeShelfDao.addToShelf(original, listOf(BookChapter(bookUrl = "original", url = "saved")))
            // Deliberately model preexisting ambiguous data outside the protected application writer.
            BundledSQLiteDriver().open(path).use { connection ->
                connection.execSQL("INSERT INTO books(bookUrl,origin,name,author,type) VALUES('ambiguous','source2','Title','Author',8)")
                connection.execSQL("CREATE TRIGGER fail_catalog BEFORE INSERT ON chapters WHEN NEW.bookUrl = 'failure' BEGIN SELECT RAISE(ABORT, 'Synthetic catalog write failure'); END")
            }
            val before = database.bookDao.all().sortedBy { it.bookUrl }
            assertEquals(NativeShelfFailure.AMBIGUOUS_IDENTITY, assertFailsWith<NativeShelfException> {
                database.nativeShelfDao.addToShelf(original.copy(bookUrl = "candidate"), emptyList())
            }.failure)
            assertEquals(before, database.bookDao.all().sortedBy { it.bookUrl })
            // Exact source/URL still has priority over ambiguous metadata.
            assertEquals(original, database.nativeShelfDao.addToShelf(original, emptyList()).book)
            assertFailsWith<Exception> {
                database.nativeShelfDao.addToShelf(original.copy(bookUrl = "failure", name = "New"), listOf(BookChapter(bookUrl = "failure", url = "new-chapter")))
            }
            assertEquals(null, database.bookDao.getBook("failure"))
            assertEquals(before, database.bookDao.all().sortedBy { it.bookUrl })
            assertEquals(listOf("saved"), database.bookChapterDao.getChapterList("original").map { it.url })
            assertEquals(NativeShelfFailure.INVALID_INPUT, assertFailsWith<NativeShelfException> {
                database.nativeShelfDao.addToShelf(original.copy(bookUrl = "empty", name = "Empty"), emptyList())
            }.failure)
            assertEquals(null, database.bookDao.getBook("empty"))
        }
    }

    @Test
    fun shelfListsOnlySourceTextBooksWithDeterministicRecentOrdering() = runBlocking {
        withDatabase { database, _ ->
            for ((url, time) in listOf("old" to 10L, "b" to 20L, "a" to 20L)) {
                val book = Book(bookUrl = url, origin = "source", name = url, author = "", durChapterTime = time)
                database.nativeShelfDao.addToShelf(book, listOf(BookChapter(bookUrl = url, url = "chapter")))
            }
            database.bookDao.insert(
                Book(bookUrl = "video", origin = "source", name = "Video", type = BookType.video),
                Book(bookUrl = "local", origin = "source", name = "Local", type = BookType.text or BookType.local),
                Book(bookUrl = "old-local", origin = BookType.localTag, name = "Old local", type = BookType.text),
                Book(bookUrl = "removed", origin = "source", name = "Removed", type = BookType.text or BookType.notShelf)
            )
            assertEquals(listOf("a", "b", "old"), database.nativeShelfDao.listBooks().map { it.bookUrl })
            assertEquals(NativeShelfFailure.IDENTITY_CONFLICT, assertFailsWith<NativeShelfException> {
                database.nativeShelfDao.removeFromShelf("wrong", "a")
            }.failure)
            assertEquals(listOf("a", "b", "old"), database.nativeShelfDao.listBooks().map { it.bookUrl })
        }
    }

    @Test
    fun independentRoomInstancesConvergeWithoutReplacingTheFirstNativeBook() = runBlocking {
        val directory = Files.createTempDirectory("PROTOTYPE-spec003-native-add-concurrency-").toFile()
        val path = directory.resolve("test.db").absolutePath
        val databases = List(4) { Room.databaseBuilder<AppDatabase>(path).setDriver(BundledSQLiteDriver()).addMigrations(*DatabaseMigrations.migrations).build() }
        try {
            databases.forEach { assertEquals(0, it.bookDao.allBookCount()) }
            val start = CompletableDeferred<Unit>()
            val ready = Channel<Unit>(4)
            val returned = withTimeout(30_000) {
                coroutineScope {
                    val workers = databases.mapIndexed { worker, database -> async(Dispatchers.Default) {
                        ready.send(Unit)
                        start.await()
                        (0 until 8).map { sequence ->
                            val identity = worker * 8 + sequence
                            val known = Book(bookUrl = "known-$identity", origin = "source-$worker", name = "Known", author = "Author", durChapterPos = identity)
                            val result = database.nativeShelfDao.addToShelf(known, listOf(BookChapter(bookUrl = known.bookUrl, url = "chapter-$identity", title = "Known $identity")))
                            val unknown = known.copy(bookUrl = "unknown-$identity", name = "Unknown", author = "")
                            database.nativeShelfDao.addToShelf(unknown, listOf(BookChapter(bookUrl = unknown.bookUrl, url = "chapter-$identity", title = "Unknown $identity")))
                            result
                        }
                    } }
                    repeat(4) { ready.receive() }
                    start.complete(Unit)
                    workers.awaitAll().flatten()
                }
            }
            assertEquals(32, returned.size)
            assertTrue(returned.all { it == returned.first() })
            val winner = returned.first()
            val identity = winner.book.bookUrl.removePrefix("known-").toInt()
            assertEquals(identity, winner.book.durChapterPos)
            assertEquals(listOf("Known $identity"), winner.chapters.map { it.title })
            for (database in databases) {
                assertEquals(33, database.nativeShelfDao.listBooks().size)
                assertEquals(winner, database.nativeShelfDao.openBook(winner.book.origin, winner.book.bookUrl))
                for (number in 0 until 32) {
                    val entry = database.nativeShelfDao.openBook("source-${number / 8}", "unknown-$number")
                    assertEquals(number, entry.book.durChapterPos)
                    assertEquals(listOf("Unknown $number"), entry.chapters.map { it.title })
                    if (number != identity) assertEquals(null, database.bookDao.getBook("known-$number"))
                }
            }
        } finally { databases.forEach { it.close() }; directory.deleteRecursively() }
    }

    private suspend fun withDatabase(block: suspend (AppDatabase, String) -> Unit) {
        val directory = Files.createTempDirectory("PROTOTYPE-spec003-shelf-").toFile()
        val path = directory.resolve("test.db").absolutePath
        val database = Room.databaseBuilder<AppDatabase>(path).setDriver(BundledSQLiteDriver()).addMigrations(*DatabaseMigrations.migrations).build()
        try { block(database, path) } finally { database.close(); directory.deleteRecursively() }
    }

}
