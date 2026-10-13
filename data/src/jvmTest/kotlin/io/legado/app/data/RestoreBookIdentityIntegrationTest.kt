package io.legado.app.data

import androidx.room3.Room
import androidx.room3.immediateTransaction
import androidx.room3.useWriterConnection
import androidx.sqlite.driver.bundled.BundledSQLiteDriver
import io.legado.app.data.dao.BookIdentityConflictException
import io.legado.app.data.entities.Book
import io.legado.app.data.entities.BookChapter
import io.legado.app.help.config.PreferenceProvider
import io.legado.app.help.config.PreferenceProviders
import io.legado.app.help.config.ReadBookConfigProviders
import io.legado.app.help.config.ReadBookConfigShared
import io.legado.app.help.file.AppFilesDir
import io.legado.app.help.file.AppFilesDirs
import io.legado.app.help.storage.BackupRestoreHook
import io.legado.app.help.storage.BackupRestoreHooks
import io.legado.app.help.storage.RestoreShared
import kotlinx.coroutines.runBlocking
import org.junit.Test
import java.nio.file.Files
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

/** Real restore entrypoint and Room DAOs; no platform settings or user database is registered. */
class RestoreBookIdentityIntegrationTest {
    @Test
    fun serializedRestoreRetainsLegacyWritesAndRollsBackConflictingBatch() = runBlocking {
        val root = Files.createTempDirectory("PROTOTYPE-spec003-restore-").toFile()
        val appFiles = root.resolve("files").apply { mkdirs() }
        val cache = root.resolve("cache").apply { mkdirs() }
        val backup = root.resolve("input").apply { mkdirs() }
        // Set directories before BackupConfigShared/BackupShared can capture their paths.
        AppFilesDirs.register(object : AppFilesDir {
            override val filesDir = appFiles.absolutePath
            override val cacheDir = cache.absolutePath
            override val externalFilesDir: String? = null
            override val externalCacheDir: String? = null
        })
        val preferences = TemporaryRestorePreferences()
        PreferenceProviders.register(preferences)
        ReadBookConfigProviders.register(ReadBookConfigShared(preferences))
        var completions = 0
        BackupRestoreHooks.register(object : BackupRestoreHook {
            override suspend fun onRestoreFinished() { completions++ }
        })
        val database = Room.databaseBuilder<AppDatabase>(root.resolve("synthetic.db").absolutePath)
            .setDriver(BundledSQLiteDriver()).addMigrations(*DatabaseMigrations.migrations).build()
        AppDbProviders.register(object : AppDbAccessor {
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
        })
        try {
            val old = Book(bookUrl = "old", origin = "source", name = "Known", author = "Author", durChapterPos = 37)
            database.bookDao.insert(old)
            database.bookChapterDao.insert(BookChapter(bookUrl = "old", url = "old-chapter"))
            backup.resolve("bookshelf.json").writeText("""[
                {"bookUrl":"replacement","origin":"source2","name":"Known","author":"Author","durChapterPos":17,"type":8},
                {"bookUrl":"unknown-one","origin":"source","name":"Unknown","author":"","durChapterPos":31,"type":8},
                {"bookUrl":"unknown-two","origin":"source2","name":"Unknown","author":"","durChapterPos":47,"type":8}
            ]""")
            RestoreShared.restoreLocked(backup.absolutePath)
            assertEquals(1, completions)
            assertEquals(null, database.bookDao.getBook("old"))
            assertEquals(0, database.bookChapterDao.getChapterCount("old"))
            assertEquals(17, database.bookDao.getBook("replacement")?.durChapterPos)
            assertEquals(31, database.bookDao.getBook("unknown-one")?.durChapterPos)
            assertEquals(47, database.bookDao.getBook("unknown-two")?.durChapterPos)
            assertEquals(3, database.bookDao.allBookCount())
            assertTrue(appFiles.resolve("restoreIgnore.json").exists())

            // Restore intentionally updates an exact existing URL; it is not native shelf re-add.
            backup.resolve("bookshelf.json").writeText("""[
                {"bookUrl":"unknown-one","origin":"source","name":"Unknown","author":"","durChapterPos":99,"intro":"restored","type":8}
            ]""")
            RestoreShared.restoreLocked(backup.absolutePath)
            assertEquals(2, completions)
            assertEquals(99, database.bookDao.getBook("unknown-one")?.durChapterPos)
            assertEquals("restored", database.bookDao.getBook("unknown-one")?.intro)
            assertEquals(47, database.bookDao.getBook("unknown-two")?.durChapterPos)

            database.bookDao.insert(Book(bookUrl = "other", origin = "source", name = "Other", author = "Else"))
            val before = database.bookDao.all().sortedBy { it.bookUrl }
            backup.resolve("bookshelf.json").writeText("""[
                {"bookUrl":"replacement","origin":"source2","name":"Known","author":"Author","intro":"must rollback","type":8},
                {"bookUrl":"other","origin":"source","name":"Known","author":"Author","type":8},
                {"bookUrl":"never-inserted","origin":"source","name":"New","author":"","type":8}
            ]""")
            assertFailsWith<BookIdentityConflictException> { RestoreShared.restoreLocked(backup.absolutePath) }
            assertEquals(before, database.bookDao.all().sortedBy { it.bookUrl })
            assertEquals(null, database.bookDao.getBook("never-inserted"))
            assertEquals(2, completions)
        } finally {
            database.close()
            AppFilesDirs.reset()
            root.deleteRecursively()
        }
    }
}

/** String-backed isolated preferences; never delegates to Java or platform user settings. */
private class TemporaryRestorePreferences : PreferenceProvider {
    private val values = mutableMapOf<String, String>()
    override fun getString(key: String, default: String) = values[key] ?: default
    override fun getStringOrNull(key: String) = values[key]
    override fun getInt(key: String, default: Int) = values[key]?.toIntOrNull() ?: default
    override fun getBoolean(key: String, default: Boolean) = values[key]?.toBooleanStrictOrNull() ?: default
    override fun getLong(key: String, default: Long) = values[key]?.toLongOrNull() ?: default
    override fun getFloat(key: String, default: Float) = values[key]?.toFloatOrNull() ?: default
    override fun putString(key: String, value: String?) { if (value == null) values.remove(key) else values[key] = value }
    override fun putInt(key: String, value: Int) { values[key] = value.toString() }
    override fun putBoolean(key: String, value: Boolean) { values[key] = value.toString() }
    override fun putLong(key: String, value: Long) { values[key] = value.toString() }
    override fun putFloat(key: String, value: Float) { values[key] = value.toString() }
    override fun remove(key: String) { values.remove(key) }
    override fun contains(key: String) = values.containsKey(key)
    override fun getAll(): Map<String, *> = values.toMap()
    override fun addPreferenceChangeListener(listener: (String) -> Unit): () -> Unit = {}
}
