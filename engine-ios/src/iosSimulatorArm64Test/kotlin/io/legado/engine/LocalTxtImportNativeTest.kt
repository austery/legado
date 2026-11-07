package io.legado.engine

import androidx.room3.Room
import androidx.sqlite.driver.NativeSQLiteDriver
import androidx.sqlite.execSQL
import io.legado.app.data.*
import io.legado.app.data.dao.*
import io.legado.app.help.DefaultDataResourceProvider
import io.legado.app.help.DefaultDataResourceProviders
import io.legado.app.data.entities.Book
import io.legado.app.help.book.LocalBookLocator
import io.legado.app.help.book.LocalBookLocators
import io.legado.app.help.book.NativeLocalBookLocator
import io.legado.app.help.file.AppFilesDir
import io.legado.app.help.file.AppFilesDirs
import io.legado.app.model.fileBook.*
import io.legado.app.utils.IosRuleRegex
import io.legado.app.utils.RuleRegexes
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import okio.FileSystem
import okio.Path.Companion.toPath
import platform.Foundation.NSTemporaryDirectory
import platform.Foundation.NSUUID
import kotlin.test.*

class LocalTxtImportNativeTest {
    @Test
    fun duplicatesReopenAndFailuresPreserveNativeAnchors() = runBlocking {
        val fs = FileSystem.SYSTEM
        var root = (NSTemporaryDirectory() + "native-txt-" + NSUUID().UUIDString).toPath()
        fs.createDirectories(root)
        fun open() = Room.databaseBuilder<AppDatabase>((root / "test.db").toString()).setDriver(NativeSQLiteDriver())
            .addMigrations(*DatabaseMigrations.migrations).build()
        var db = open()
        val previousDb = runCatching { AppDatabaseProviders.get() }.getOrNull()
        val previousAccessor = runCatching { AppDbProviders.get() }.getOrNull()
        val previousDirs = runCatching { AppFilesDirs.get() }.getOrNull()
        val previousResources = runCatching { DefaultDataResourceProviders.get() }.getOrNull()
        val previousFiles = runCatching { FileBookProviders.get() }.getOrNull()
        val previousLocator = runCatching { LocalBookLocators.get() }.getOrNull()
        fun bind() {
            AppDatabaseProviders.register(object : AppDatabaseProvider { override val appDb = db })
            AppDbProviders.register(NativeAppDbAccessor())
        }
        try {
            bind()
            AppFilesDirs.register(object : AppFilesDir {
                override val filesDir get() = root.toString()
                override val cacheDir get() = (root / "cache").toString()
                override val externalFilesDir: String? = null
                override val externalCacheDir: String? = null
            })
            DefaultDataResourceProviders.register(object : DefaultDataResourceProvider { override fun readResource(name: String) = "[]" })
            FileBookProviders.register(NativeFileBookAccessor())
            LocalBookLocators.register(LocalTxtLocator(NativeLocalBookLocator()))
            RuleRegexes.register(IosRuleRegex)
            var input = root / "input.txt"
            fs.write(input) { writeUtf8("\uFEFFfirst paragraph\nsecond paragraph 🌿\nlast paragraph\n") }
            val admitted = LocalTxtImport.import(input.toString(), "Original.txt")
            assertTrue(NativeLocalTxt.owns(admitted.book))
            assertEquals(1, db.nativeShelfDao.listBooks().size)
            val chapter = admitted.chapters.first()
            val body = TextFile.getContent(admitted.book, chapter)
            val offset = body.indexOf("second paragraph")
            assertTrue(offset > 0)
            val resume = db.nativeResumeDao.save(admitted.book.origin, admitted.book.bookUrl, chapter.url, chapter.index,
                body, offset, 0, NativeChapterProjection.from(admitted.book))
            val savedBook = assertNotNull(db.bookDao.getBook(admitted.book.bookUrl))
            val bookmark = db.nativeBookmarkDao.save("mark", savedBook.origin, savedBook.bookUrl, chapter.url,
                chapter.index, body, offset, NativeChapterProjection.from(savedBook))
            val duplicate = LocalTxtImport.import(input.toString(), "Renamed.txt")
            assertEquals(savedBook, duplicate.book)
            assertEquals(admitted.chapters, duplicate.chapters)
            assertEquals(resume, db.nativeResumeDao.get(savedBook.bookUrl))
            assertEquals(listOf(bookmark), db.nativeBookmarkDao.list(savedBook.origin, savedBook.bookUrl))
            // An unavailable database must not mask the failure or leave staging files.
            val ownedBefore = fs.listRecursively(NativeLocalTxt.root().toPath()).toList().toSet()
            AppDatabaseProviders.register(object : AppDatabaseProvider {
                override val appDb: AppDatabase get() = error("synthetic database unavailable")
            })
            try {
                val failure = assertFailsWith<ShelfStorageFailure> { LocalTxtImport.import(input.toString(), "Unavailable.txt") }
                assertEquals("synthetic database unavailable", failure.message)
                assertEquals(ownedBefore, fs.listRecursively(NativeLocalTxt.root().toPath()).toList().toSet())
                val originalBytes = fs.read(input) { readByteArray() }
                try {
                    fs.write(input) { writeUtf8("unseen copy with uncertain database admission") }
                    val digest = fs.read(input) { readByteString().sha256().hex() }
                    val retained = NativeLocalTxt.root().toPath() / digest / "book.txt"
                    val uncertain = assertFailsWith<ShelfStorageFailure> { LocalTxtImport.import(input.toString(), "Uncertain.txt") }
                    assertEquals("synthetic database unavailable", uncertain.message)
                    assertTrue(fs.exists(retained))
                    assertEquals(digest, fs.read(retained) { readByteString().sha256().hex() })
                    assertFalse(fs.listRecursively(NativeLocalTxt.root().toPath()).any { it.name.endsWith(".staging") })
                } finally { fs.write(input) { write(originalBytes) } }
            } finally { bind() }
            assertEquals(listOf(savedBook), db.nativeShelfDao.listBooks())
            db.close(); TextFile.clear()
            val movedRoot = (root.toString() + "-relocated").toPath()
            fs.atomicMove(root, movedRoot)
            root = movedRoot
            input = root / "input.txt"
            db = open(); bind()
            assertEquals(savedBook.bookUrl, db.nativeShelfDao.listBooks().single().bookUrl)
            val relocatedDuplicate = LocalTxtImport.import(input.toString(), "Relocated.txt")
            assertEquals(savedBook, relocatedDuplicate.book)
            assertEquals(admitted.chapters, relocatedDuplicate.chapters)
            fs.delete(input)
            val reopened = db.nativeShelfDao.openBook(savedBook.origin, savedBook.bookUrl)
            LocalTxtImport.verify(reopened.book)
            assertEquals(body, TextFile.getContent(reopened.book, reopened.chapters.first()))
            assertEquals(resume, db.nativeResumeDao.get(savedBook.bookUrl))
            assertEquals(listOf(bookmark), db.nativeBookmarkDao.list(savedBook.origin, savedBook.bookUrl))
            fs.write(input) { writeUtf8("different body") }
            val distinct = LocalTxtImport.import(input.toString(), "Original.txt")
            assertNotEquals(savedBook.bookUrl, distinct.book.bookUrl)
            assertEquals(2, db.nativeShelfDao.listBooks().size)
            for (bytes in listOf(byteArrayOf(), byteArrayOf(0xff.toByte()), ByteArray((LocalTxtImport.MAX_BYTES + 1).toInt()) { 65 })) {
                fs.write(input) { write(bytes) }
                assertFails { LocalTxtImport.import(input.toString(), "Bad.txt") }
                assertEquals(2, db.nativeShelfDao.listBooks().size)
            }
            // A real SQLite failure after Book insertion must roll back both records and the new file.
            NativeSQLiteDriver().open((root / "test.db").toString()).use {
                it.execSQL("CREATE TRIGGER fail_txt_chapter BEFORE INSERT ON chapters BEGIN SELECT RAISE(ABORT, 'synthetic TXT failure'); END")
            }
            try {
                val owned = NativeLocalTxt.root().toPath()
                val beforeFiles = fs.listRecursively(owned).toList().toSet()
                fs.write(input) { writeUtf8("transaction must fail before admission") }
                val failure = assertFails { LocalTxtImport.import(input.toString(), "Rollback.txt") }
                assertTrue(generateSequence(failure) { it.cause }.any { it.message?.contains("synthetic TXT failure") == true })
                assertEquals(2, db.nativeShelfDao.listBooks().size)
                assertEquals(beforeFiles, fs.listRecursively(owned).toList().toSet())
                assertEquals(resume, db.nativeResumeDao.get(savedBook.bookUrl))
                assertEquals(listOf(bookmark), db.nativeBookmarkDao.list(savedBook.origin, savedBook.bookUrl))
            } finally {
                NativeSQLiteDriver().open((root / "test.db").toString()).use { it.execSQL("DROP TRIGGER fail_txt_chapter") }
            }
            // Cancellation inside the copy loop leaves no staging file, copy or shelf row.
            val owned = NativeLocalTxt.root().toPath()
            val beforeCancel = fs.listRecursively(owned).toList().toSet()
            fs.write(input) { writeUtf8("cancelled before admission") }
            val cancelled = launch(start = CoroutineStart.ATOMIC) { LocalTxtImport.import(input.toString(), "Cancelled.txt") }
            cancelled.cancel(); cancelled.join()
            assertTrue(cancelled.isCancelled)
            assertEquals(beforeCancel, fs.listRecursively(owned).toList().toSet())
            assertEquals(2, db.nativeShelfDao.listBooks().size)
            // An unreadable picked file is invalid input, not a network failure.
            assertFailsWith<IllegalArgumentException> { LocalTxtImport.import((root / "absent.txt").toString(), "Absent.txt") }
            assertEquals(beforeCancel, fs.listRecursively(owned).toList().toSet())
            fs.write(NativeLocalTxt.path(savedBook).toPath()) { writeUtf8("tampered") }
            assertFailsWith<CacheUnavailable> { LocalTxtImport.verify(savedBook) }
            fs.delete(NativeLocalTxt.path(savedBook).toPath())
            assertFailsWith<CacheUnavailable> { LocalTxtImport.verify(savedBook) }
            assertEquals(resume, db.nativeResumeDao.get(savedBook.bookUrl))
            assertEquals(listOf(bookmark), db.nativeBookmarkDao.list(savedBook.origin, savedBook.bookUrl))
            Unit
        } finally {
            db.close(); TextFile.clear()
            if (previousDb != null) AppDatabaseProviders.register(previousDb) else AppDatabaseProviders.reset()
            if (previousAccessor != null) AppDbProviders.register(previousAccessor) else AppDbProviders.unregister()
            if (previousDirs != null) AppFilesDirs.register(previousDirs) else AppFilesDirs.reset()
            // Upstream registries have no reset; restore the unregistered failure instead of leaking test doubles.
            DefaultDataResourceProviders.register(previousResources ?: object : DefaultDataResourceProvider {
                override fun readResource(name: String): String = error("DefaultDataResourceProviders not registered")
            })
            LocalBookLocators.register(previousLocator ?: object : LocalBookLocator {
                override fun getLocalPath(book: Book): String? = error("LocalBookLocators not registered")
                override fun getReadableFileRef(book: Book): String? = error("LocalBookLocators not registered")
                override fun removeLocalPathCache(book: Book): Unit = error("LocalBookLocators not registered")
            })
            // NativeFileBookAccessor is stateless and identical to what EngineHost registers.
            previousFiles?.let { FileBookProviders.register(it) }
            fs.deleteRecursively(root)
        }
    }
}
