package io.legado.engine

import androidx.room3.Room
import androidx.sqlite.driver.NativeSQLiteDriver
import androidx.sqlite.execSQL
import io.legado.app.data.*
import io.legado.app.data.dao.*
import io.legado.app.help.DefaultDataResourceProvider
import io.legado.app.help.DefaultDataResourceProviders
import io.legado.app.help.book.LocalBookLocators
import io.legado.app.help.book.NativeLocalBookLocator
import io.legado.app.help.file.AppFilesDir
import io.legado.app.help.file.AppFilesDirs
import io.legado.app.model.fileBook.*
import io.legado.app.utils.IosRuleRegex
import io.legado.app.utils.RuleRegexes
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
        val root = (NSTemporaryDirectory() + "native-txt-" + NSUUID().UUIDString).toPath()
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
                override val filesDir = root.toString()
                override val cacheDir = (root / "cache").toString()
                override val externalFilesDir: String? = null
                override val externalCacheDir: String? = null
            })
            DefaultDataResourceProviders.register(object : DefaultDataResourceProvider { override fun readResource(name: String) = "[]" })
            FileBookProviders.register(NativeFileBookAccessor())
            LocalBookLocators.register(NativeLocalBookLocator())
            RuleRegexes.register(IosRuleRegex)
            val input = root / "input.txt"
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
            db.close(); TextFile.clear(); db = open(); bind()
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
                val beforeFiles = fs.listRecursively(owned).filter { fs.metadata(it).isRegularFile }.toList().toSet()
                fs.write(input) { writeUtf8("transaction must fail before admission") }
                assertFails { LocalTxtImport.import(input.toString(), "Rollback.txt") }
                assertEquals(2, db.nativeShelfDao.listBooks().size)
                assertEquals(beforeFiles, fs.listRecursively(owned).filter { fs.metadata(it).isRegularFile }.toList().toSet())
                assertEquals(resume, db.nativeResumeDao.get(savedBook.bookUrl))
                assertEquals(listOf(bookmark), db.nativeBookmarkDao.list(savedBook.origin, savedBook.bookUrl))
            } finally {
                NativeSQLiteDriver().open((root / "test.db").toString()).use { it.execSQL("DROP TRIGGER fail_txt_chapter") }
            }
            fs.write(savedBook.bookUrl.removePrefix("file://").toPath()) { writeUtf8("tampered") }
            assertFails { LocalTxtImport.verify(savedBook) }
            assertEquals(resume, db.nativeResumeDao.get(savedBook.bookUrl))
            assertEquals(listOf(bookmark), db.nativeBookmarkDao.list(savedBook.origin, savedBook.bookUrl))
            Unit
        } finally {
            db.close(); TextFile.clear()
            if (previousDb != null) AppDatabaseProviders.register(previousDb) else AppDatabaseProviders.reset()
            if (previousAccessor != null) AppDbProviders.register(previousAccessor) else AppDbProviders.unregister()
            previousDirs?.let { AppFilesDirs.register(it) }
            previousResources?.let { DefaultDataResourceProviders.register(it) }
            previousFiles?.let { FileBookProviders.register(it) }
            previousLocator?.let { LocalBookLocators.register(it) }
            fs.deleteRecursively(root)
        }
    }
}
