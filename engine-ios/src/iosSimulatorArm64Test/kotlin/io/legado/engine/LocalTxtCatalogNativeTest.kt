package io.legado.engine

import androidx.room3.Room
import androidx.sqlite.driver.NativeSQLiteDriver
import io.legado.app.data.*
import io.legado.app.data.dao.NativeShelfEntry
import io.legado.app.data.entities.Book
import io.legado.app.data.entities.TxtTocRule
import io.legado.app.help.book.LocalBookLocator
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

class LocalTxtCatalogNativeTest {
    private val paragraph = "这是一段普通正文，用来把章节撑到超过上游的拆分上限。\n"
    private val long = paragraph.repeat(120 * 1024 / paragraph.encodeToByteArray().size + 1)

    /** Every listed chapter must open: the reader moves through the catalog without skipping entries. */
    private fun assertEveryChapterOpens(entry: NativeShelfEntry) {
        assertEquals(entry.chapters.indices.toList(), entry.chapters.map { it.index })
        assertEquals(entry.chapters.size, entry.chapters.map { it.url }.toSet().size)
        assertEquals(entry.chapters.size, entry.book.totalChapterNum)
        assertEquals(entry.chapters.last().title, entry.book.latestChapterTitle)
        for (chapter in entry.chapters) {
            TextFile.clear()
            assertTrue(TextFile.getContent(entry.book, chapter).isNotEmpty(), "Empty chapter ${chapter.index} '${chapter.title}'")
        }
    }

    private fun body(entry: NativeShelfEntry) = entry.chapters.joinToString("") {
        TextFile.clear()
        TextFile.getContent(entry.book, it)
    }

    private fun withImporter(check: suspend (suspend (String, String) -> NativeShelfEntry) -> Unit) = runBlocking {
        val fs = FileSystem.SYSTEM
        val root = (NSTemporaryDirectory() + "native-txt-catalog-" + NSUUID().UUIDString).toPath()
        fs.createDirectories(root)
        val db = Room.databaseBuilder<AppDatabase>((root / "test.db").toString()).setDriver(NativeSQLiteDriver())
            .addMigrations(*DatabaseMigrations.migrations).build()
        val previousDb = runCatching { AppDatabaseProviders.get() }.getOrNull()
        val previousAccessor = runCatching { AppDbProviders.get() }.getOrNull()
        val previousDirs = runCatching { AppFilesDirs.get() }.getOrNull()
        val previousFiles = runCatching { FileBookProviders.get() }.getOrNull()
        val previousLocator = runCatching { LocalBookLocators.get() }.getOrNull()
        try {
            AppDatabaseProviders.register(object : AppDatabaseProvider { override val appDb = db })
            AppDbProviders.register(NativeAppDbAccessor())
            AppFilesDirs.register(object : AppFilesDir {
                override val filesDir get() = root.toString()
                override val cacheDir get() = (root / "cache").toString()
                override val externalFilesDir: String? = null
                override val externalCacheDir: String? = null
            })
            FileBookProviders.register(NativeFileBookAccessor())
            LocalBookLocators.register(LocalTxtLocator(NativeLocalBookLocator()))
            RuleRegexes.register(IosRuleRegex)
            db.txtTocRuleDao.insert(TxtTocRule(id = 1, name = "test", rule = "^第.{1,9}[章卷].{0,30}$", serialNumber = 0))
            check { name, text ->
                val input = root / "input.txt"
                fs.write(input) { writeUtf8(text) }
                LocalTxtImport.import(input.toString(), name)
            }
        } finally {
            db.close(); TextFile.clear()
            if (previousDb != null) AppDatabaseProviders.register(previousDb) else AppDatabaseProviders.reset()
            if (previousAccessor != null) AppDbProviders.register(previousAccessor) else AppDbProviders.unregister()
            if (previousDirs != null) AppFilesDirs.register(previousDirs) else AppFilesDirs.reset()
            LocalBookLocators.register(previousLocator ?: object : LocalBookLocator {
                override fun getLocalPath(book: Book): String? = error("LocalBookLocators not registered")
                override fun getReadableFileRef(book: Book): String? = error("LocalBookLocators not registered")
                override fun removeLocalPathCache(book: Book): Unit = error("LocalBookLocators not registered")
            })
            previousFiles?.let { FileBookProviders.register(it) }
            fs.deleteRecursively(root)
        }
    }

    @Test
    fun firstLongChapterOpensAndKeepsItsText() = withImporter { import ->
        val entry = import("first.txt", "第一章 开始\n$long\n第二章 中间\n中间正文。\n第三章 结束\n结束正文。\n")
        assertEveryChapterOpens(entry)
        assertTrue(entry.chapters.first().title.startsWith("第一章 开始("), entry.chapters.first().title)
        val text = body(entry)
        assertEquals(long.count { it == '段' }, text.count { it == '段' })
        assertTrue("中间正文" in text && "结束正文" in text)
    }

    @Test
    fun middleAndLastLongChaptersOpen() = withImporter { import ->
        assertEveryChapterOpens(import("middle.txt", "第一章 开始\n短正文。\n第二章 很长\n$long\n第三章 结束\n短正文。\n"))
        assertEveryChapterOpens(import("last.txt", "第一章 开始\n短正文。\n第二章 很长\n$long"))
    }

    @Test
    fun titleOnlyVolumeDoesNotBlockReading() = withImporter { import ->
        assertEveryChapterOpens(import("volume.txt", "第一卷 启程\n第一章 开始\n第一章正文。\n第二章 继续\n第二章正文。\n"))
    }
}
