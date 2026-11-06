package io.legado.app.ui.book.searchContent

import androidx.room3.Room
import androidx.sqlite.driver.bundled.BundledSQLiteDriver
import com.sun.net.httpserver.HttpServer
import io.legado.app.data.AppDatabase
import io.legado.app.data.AppDbProviders
import io.legado.app.data.DatabaseMigrations
import io.legado.app.data.dao.NativeBodyCoordinates
import io.legado.app.data.entities.Book
import io.legado.app.data.entities.BookChapter
import io.legado.app.data.entities.BookSource
import io.legado.app.data.entities.ReplaceRule
import io.legado.app.help.book.BookStorage
import io.legado.app.help.book.BookStorageProviders
import io.legado.app.help.book.ContentProcessorAccessor
import io.legado.app.help.book.ContentProcessorProviders
import io.legado.app.help.book.ContentProcessorShared
import io.legado.app.help.book.DefaultContentProcessorDeps
import io.legado.app.help.book.JvmBookStorage
import io.legado.app.help.book.chineseT2S
import io.legado.app.help.book.chineseS2T
import io.legado.app.help.config.AppConfigAccessor
import io.legado.app.help.config.AppConfigProviders
import io.legado.app.ui.book.info.edit.BookInfoEditIdentityIntegrationTest.TestDatabaseAccessor
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.cancel
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Test
import java.lang.reflect.Proxy
import java.net.InetSocketAddress
import java.nio.file.Files
import java.util.concurrent.atomic.AtomicInteger
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** Public upstream search, real Room/catalog, real cache files and real shared text processing. */
class UpstreamCachedSearchCharacterizationTest {
    @Test
    fun titleInsertionShiftsUtf16MatchesAndIdentityBodySeamPreservesThem() = runBlocking {
        fixture { f ->
            val chapter = f.chapter(0)
            val body = "😀开篇\nneedle needle"
            f.cache(chapter, body)
            val processed = f.model.searchChapter("needle", chapter)
            assertEquals(listOf(15, 22), processed.map { it.queryIndexInChapter })
            assertEquals(listOf(5, 12), listOf(body.indexOf("needle"), body.lastIndexOf("needle")))
            processed.forEach { assertEquals("needle", it.resultText.substring(it.queryIndexInResult, it.queryIndexInResult + 6)) }
            // Diagnostic injection only: proves the existing matcher accepts original text.
            // This is not a production bridge or a claim that its global provider may be replaced.
            f.processor.originalText = true
            val original = f.model.searchChapter("needle", chapter)
            assertEquals(listOf(5, 12), original.map { it.queryIndexInChapter })
            assertEquals(listOf(5, 5), original.map { NativeBodyCoordinates.paragraphStart(body, it.queryIndexInChapter) })
            original.forEach { assertEquals("needle", body.substring(it.queryIndexInChapter, it.queryIndexInChapter + 6)) }
            assertEquals(body, f.storage.getContent(f.book, chapter))
        }
    }

    @Test
    fun duplicateTitleRemovalMakesTheOffsetDeltaContentDependent() = runBlocking {
        fixture { f ->
            val chapter = f.chapter(0)
            val body = "   Chapter 1\nneedle"
            f.cache(chapter, body)
            assertEquals(13, body.indexOf("needle"))
            assertEquals(10, f.model.searchChapter("needle", chapter).single().queryIndexInChapter)
            assertEquals(body, f.storage.getContent(f.book, chapter))
        }
    }

    @Test
    fun replacementCanCreateHitsThatDoNotExistInOriginalText() = runBlocking {
        fixture { f ->
            val chapter = f.chapter(0)
            f.cache(chapter, "raw tail raw")
            f.database.replaceRuleDao.insert(ReplaceRule(id = 7, name = "Fixture expansion",
                pattern = "raw", replacement = "LONG needle", isRegex = false))
            f.processor.delegate.upReplaceRules()
            f.model.replaceEnabled = true
            val results = f.model.searchChapter("needle", chapter)
            assertEquals(listOf(15, 32), results.map { it.queryIndexInChapter })
            assertFalse(f.storage.getContent(f.book, chapter)!!.contains("needle"))
            f.model.replaceEnabled = false
            assertTrue(f.model.searchChapter("needle", chapter).isEmpty())
        }
    }

    @Test
    fun chineseConversionCanCreateAnUnmappableOriginalQuery() = runBlocking {
        fixture { f ->
            val chapter = f.chapter(0)
            val body = "這是繁體中文"
            f.cache(chapter, body)
            f.conversion.set(1)
            val result = f.model.searchChapter("繁体", chapter).single()
            assertEquals(12, result.queryIndexInChapter)
            assertFalse(body.contains("繁体"))
            assertEquals(body, f.storage.getContent(f.book, chapter))
            f.conversion.set(0)
            assertTrue(f.model.searchChapter("繁体", chapter).isEmpty())
        }
    }

    @Test
    fun cachedCoverageSkipsMissingBodiesAndKeepsCatalogOrderWithoutNetworkOrProgressWrites() = runBlocking {
        fixture { f ->
            val first = f.chapter(0)
            val missing = f.chapter(1)
            val last = f.chapter(2)
            f.cache(last, "needle last")
            f.cache(first, "needle first")
            f.database.bookChapterDao.insert(missing)
            val batches = mutableListOf<Pair<List<Int>, Int>>()
            val names = setOf(first.getFileName(), missing.getFileName(), last.getFileName())
            val results = f.model.searchAllChapters("needle", names) { batch, total ->
                batches += batch.map { it.chapterIndex } to total
            }
            assertEquals(listOf(0, 2), results.map { it.chapterIndex })
            assertEquals(listOf(listOf(0) to 1, listOf(2) to 2), batches)
            val subset = f.model.searchAllChapters("needle", setOf(last.getFileName()))
            assertEquals(listOf(2), subset.map { it.chapterIndex })
            assertEquals(0, f.requests.get())
        }
    }

    @Test
    fun cancellationStopsBeforeNextCachedChapter() = runBlocking {
        fixture { f ->
            val first = f.chapter(0)
            val second = f.chapter(1)
            f.cache(first, "needle first"); f.cache(second, "needle second")
            var batches = 0
            val searching = f.scope.async {
                f.model.searchAllChapters("needle", setOf(first.getFileName(), second.getFileName())) { _, _ ->
                    batches++
                    currentCoroutineContext().cancel()
                }
            }
            searching.join()
            assertTrue(searching.isCancelled)
            assertEquals(1, batches)
            assertEquals(listOf(first.url), f.reads)
        }
    }

    @Test
    fun upstreamSnippetCanSplitASurrogatePairAtItsWindowBoundary() = runBlocking {
        fixture { f ->
            val chapter = f.chapter(0)
            f.processor.originalText = true
            f.cache(chapter, "😀" + "a".repeat(19) + "needle")
            val result = f.model.searchChapter("needle", chapter).single()
            assertEquals(21, result.queryIndexInChapter)
            assertEquals(20, result.queryIndexInResult)
            assertTrue(result.resultText.first().isLowSurrogate())
            assertEquals("needle", result.resultText.substring(result.queryIndexInResult))
        }
    }

    @Test
    fun literalNonOverlappingQueriesAndChangedCacheDoNotReuseOldResults() = runBlocking {
        fixture { f ->
            val chapter = f.chapter(0)
            f.processor.originalText = true
            f.cache(chapter, "aaaa a.* 中文😀中文")
            assertEquals(listOf(0, 2), f.model.searchChapter("aa", chapter).map { it.queryIndexInChapter })
            assertEquals(listOf(5), f.model.searchChapter("a.*", chapter).map { it.queryIndexInChapter })
            assertEquals(listOf(9, 13), f.model.searchChapter("中文", chapter).map { it.queryIndexInChapter })
            assertTrue(f.model.searchChapter("absent", chapter).isEmpty())
            val old = f.model.searchChapter("中文", chapter)
            f.cache(chapter, "中文 moved")
            val fresh = f.model.searchChapter("中文", chapter)
            assertEquals(listOf(0), fresh.map { it.queryIndexInChapter })
            assertEquals(listOf(9, 13), old.map { it.queryIndexInChapter })
            // Upstream results contain coordinates, not a body fingerprint or stale-result guard.
        }
    }

    private class Processor(val delegate: ContentProcessorShared) : ContentProcessorAccessor {
        var originalText = false
        override fun getTitleReplaceRules(book: Book) = delegate.getTitleReplaceRules()
        override fun getContent(book: Book, chapter: BookChapter, content: String, useReplace: Boolean): CharSequence =
            if (originalText) content else delegate.getContent(book, chapter, content, useReplace = useReplace).toString()
        override fun upReplaceRules() = error("Fixture explicitly awaits the real processor refresh")
    }

    private class Fixture(val database: AppDatabase, val book: Book, val storage: JvmBookStorage,
        val processor: Processor, val scope: CoroutineScope, val model: SearchContentViewModelShared,
        val requests: AtomicInteger, val reads: MutableList<String>, val conversion: AtomicInteger) {
        fun chapter(index: Int) = BookChapter(url = "${book.origin}/chapter/$index", bookUrl = book.bookUrl,
            index = index, title = "Chapter ${index + 1}")
        suspend fun cache(chapter: BookChapter, body: String) {
            database.bookChapterDao.insert(chapter)
            storage.saveText(book, chapter, body)
        }
    }

    private suspend fun fixture(block: suspend (Fixture) -> Unit) {
        val directory = Files.createTempDirectory("legado-cached-search-").toFile()
        val server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        val requests = AtomicInteger()
        server.createContext("/") { exchange -> requests.incrementAndGet(); exchange.sendResponseHeaders(500, -1); exchange.close() }
        server.start()
        val previousDatabase = runCatching { AppDbProviders.get() }.getOrNull()
        val previousConfig = runCatching { AppConfigProviders.get() }.getOrNull()
        val previousStorage = runCatching { BookStorageProviders.get() }.getOrNull()
        val previousProcessor = runCatching { ContentProcessorProviders.get() }.getOrNull()
        val job = SupervisorJob()
        val scope = CoroutineScope(job + Dispatchers.Default)
        val database = Room.databaseBuilder<AppDatabase>(directory.resolve("fixture.db").absolutePath)
            .setDriver(BundledSQLiteDriver()).addMigrations(*DatabaseMigrations.migrations).build()
        try {
            val base = "http://127.0.0.1:${server.address.port}"
            val book = Book(bookUrl = "$base/book", origin = base, name = "Search fixture", author = "Fixture",
                durChapterIndex = 4, durChapterPos = 27, durChapterTime = 123)
            val storage = JvmBookStorage(directory.resolve("cache").absolutePath)
            val reads = mutableListOf<String>()
            val conversion = AtomicInteger(0)
            AppDbProviders.register(TestDatabaseAccessor(database))
            AppConfigProviders.register(Proxy.newProxyInstance(AppConfigAccessor::class.java.classLoader,
                arrayOf(AppConfigAccessor::class.java)) { _, method, _ ->
                when (method.name) {
                    "getChineseConverterType" -> conversion.get()
                    "getReplaceEnableDefault" -> true
                    else -> error("Unexpected config read: ${method.name}")
                }
            } as AppConfigAccessor)
            BookStorageProviders.register(object : BookStorage by storage {
                override fun getContent(book: Book, chapter: BookChapter): String? {
                    reads += chapter.url
                    return storage.getContent(book, chapter)
                }
            })
            val processor = Processor(ContentProcessorShared(book.name, book.origin, DefaultContentProcessorDeps()))
            ContentProcessorProviders.register(processor)
            database.bookDao.insert(book)
            database.bookSourceDao.insert(BookSource(bookSourceUrl = base, bookSourceName = "Search fixture"))
            val control = java.net.URI.create("$base/control").toURL().openConnection() as java.net.HttpURLConnection
            try { assertEquals(500, control.responseCode) } finally { control.disconnect() }
            assertEquals(1, requests.getAndSet(0), "The fixture listener must observe a request")
            val storedBeforeSearch = database.bookDao.getBook(book.bookUrl)
            val model = SearchContentViewModelShared(scope) { type, title ->
                when (type) {
                    1 -> chineseT2S(title)
                    2 -> chineseS2T(title)
                    else -> title
                }
            }
            val ready = CompletableDeferred<Unit>()
            model.initBook(success = { ready.complete(Unit) }, book = book)
            withTimeout(5_000) { ready.await() }
            withTimeout(10_000) { block(Fixture(database, book, storage, processor, scope, model, requests, reads, conversion)) }
            assertEquals(storedBeforeSearch, database.bookDao.getBook(book.bookUrl), "Search must not write the stored book record")
            assertEquals(0, requests.get(), "Cached search must not fetch source content")
        } finally {
            job.cancelAndJoin()
            previousDatabase?.let(AppDbProviders::register) ?: AppDbProviders.unregister()
            // These providers lack unregister. Restore exact nullable state without changing production APIs.
            AppConfigProviders::class.java.getDeclaredField("impl").apply { isAccessible = true }.set(AppConfigProviders, previousConfig)
            BookStorageProviders::class.java.getDeclaredField("impl").apply { isAccessible = true }.set(BookStorageProviders, previousStorage)
            ContentProcessorProviders::class.java.getDeclaredField("impl").apply { isAccessible = true }.set(ContentProcessorProviders, previousProcessor)
            database.close()
            server.stop(0)
            check(directory.deleteRecursively())
        }
    }
}
