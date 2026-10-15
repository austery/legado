package io.legado.app.ui.association

import androidx.room3.Room
import androidx.sqlite.driver.bundled.BundledSQLiteDriver
import io.legado.app.data.AppDatabase
import io.legado.app.data.AppDbAccessor
import io.legado.app.data.AppDbProviders
import io.legado.app.data.DatabaseMigrations
import io.legado.app.data.dao.HttpTTSDao
import io.legado.app.data.entities.HttpTTS
import io.legado.app.ui.book.info.edit.BookInfoEditIdentityIntegrationTest
import kotlinx.coroutines.runBlocking
import org.junit.Test
import java.nio.file.Files
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

class AutomaticImportFailureTest {
    @Test fun defaultUpgradePreservesRowsAndVersionUntilACompleteRetry() = runBlocking {
        val directory = Files.createTempDirectory("legado-default-failure-").toFile()
        val database = Room.databaseBuilder<AppDatabase>(directory.resolve("test.db").absolutePath)
            .setDriver(BundledSQLiteDriver()).addMigrations(*DatabaseMigrations.migrations).build()
        val previous = runCatching { AppDbProviders.get() }.getOrNull()
        val oldResources = runCatching { io.legado.app.help.DefaultDataResourceProviders.get() }.getOrNull()
        val oldVersion = runCatching { io.legado.app.help.AppVersionProviders.get() }.getOrNull()
        val real = BookInfoEditIdentityIntegrationTest.TestDatabaseAccessor(database)
        var fail = true
        var malformed = true
        val dao = object : HttpTTSDao by database.httpTTSDao {
            override suspend fun insert(vararg httpTTS: HttpTTS) {
                if (fail) throw IllegalStateException("Injected write failure")
                database.httpTTSDao.insert(*httpTTS)
            }
        }
        AppDbProviders.register(object : AppDbAccessor by real { override val httpTTSDao = dao })
        io.legado.app.help.AppVersionProviders.register(object : io.legado.app.help.AppVersionProvider {
            override val versionCode = 100L
        })
        io.legado.app.help.DefaultDataResourceProviders.register(object : io.legado.app.help.DefaultDataResourceProvider {
            override fun readResource(name: String): String {
                check(name == "httpTTS.json")
                return if (malformed) "invalid json" else """[{"id":-2,"name":"Replacement"}]"""
            }
        })
        val versions = mutableMapOf(
            io.legado.app.help.config.LocalConfigKeys.txtTocRuleVersion to io.legado.app.help.config.HelpVersion.txtTocRule,
            io.legado.app.help.config.LocalConfigKeys.needUpDictRule to io.legado.app.help.config.HelpVersion.dictRule,
        )
        suspend fun startup() = io.legado.app.help.StartupMaintenanceShared.initDefaultData(
            getInt = { key, default -> versions[key] ?: default },
            putInt = { key, value -> versions[key] = value },
            getBoolean = { _, default -> default },
            getLong = { _, _ -> 100L },
        )
        try {
            database.httpTTSDao.insert(HttpTTS(id = -1, name = "Existing"))
            startup()
            assertEquals(listOf("Existing"), database.httpTTSDao.all().map { it.name })
            malformed = false
            startup()
            assertEquals(listOf("Existing"), database.httpTTSDao.all().map { it.name })
            assertEquals(null, versions[io.legado.app.help.config.LocalConfigKeys.httpTtsVersion])
            fail = false
            startup()
            assertEquals(listOf("Replacement"), database.httpTTSDao.all().map { it.name })
            assertEquals(io.legado.app.help.config.HelpVersion.httpTts, versions[io.legado.app.help.config.LocalConfigKeys.httpTtsVersion])
        } finally {
            if (previous != null) AppDbProviders.register(previous)
            if (oldResources != null) io.legado.app.help.DefaultDataResourceProviders.register(oldResources)
            if (oldVersion != null) io.legado.app.help.AppVersionProviders.register(oldVersion)
            database.close()
            directory.deleteRecursively()
        }
    }

    @Test fun databaseFailureIsNotAReportedImportAndCanBeRetried() = runBlocking {
        val directory = Files.createTempDirectory("legado-import-failure-").toFile()
        val database = Room.databaseBuilder<AppDatabase>(directory.resolve("test.db").absolutePath)
            .setDriver(BundledSQLiteDriver()).addMigrations(*DatabaseMigrations.migrations).build()
        val previous = runCatching { AppDbProviders.get() }.getOrNull()
        val real = BookInfoEditIdentityIntegrationTest.TestDatabaseAccessor(database)
        var fail = true
        val dao = object : HttpTTSDao by database.httpTTSDao {
            override suspend fun insert(vararg httpTTS: HttpTTS) {
                if (fail) throw IllegalStateException("Injected write failure")
                database.httpTTSDao.insert(*httpTTS)
            }
        }
        AppDbProviders.register(object : AppDbAccessor by real {
            override val httpTTSDao = dao
        })
        try {
            val hook = UiRuleSubAutoUpdateHook(this)
            val json = """[{"id":123,"name":"Fixture","url":"https://fixture.invalid/tts"}]"""
            val error = assertFailsWith<IllegalStateException> { hook.importByType(5, json) }
            assertEquals("Injected write failure", error.message)
            assertEquals(0, database.httpTTSDao.count())
            fail = false
            assertEquals(1, hook.importByType(5, json))
            assertEquals(1, database.httpTTSDao.count())
        } finally {
            if (previous != null) AppDbProviders.register(previous)
            database.close()
            directory.deleteRecursively()
        }
    }
}
