@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)

package io.legado.engine

import kotlinx.atomicfu.atomic
import io.legado.app.help.DefaultDataResourceProvider
import io.legado.app.help.DefaultDataResourceProviders
import io.legado.app.help.config.AppConfigAccessor
import io.legado.app.help.config.AppConfigProviders
import io.legado.app.data.AppDatabaseProviders
import io.legado.app.data.NativeAppDatabaseProvider
import io.legado.app.data.IosDatabaseDriver
import io.legado.app.data.AppDatabaseProvider
import platform.Foundation.NSUUID
import platform.Foundation.NSTemporaryDirectory
import platform.Foundation.NSProcessInfo
import platform.Foundation.NSURL
import platform.Foundation.NSURLSession
import platform.Foundation.dataTaskWithURL
import platform.Foundation.NSDate
import platform.Foundation.NSRunLoop
import platform.Foundation.timeIntervalSince1970
import platform.Foundation.runUntilDate
import platform.Foundation.dateWithTimeIntervalSinceNow
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertTrue
import kotlin.test.assertFalse

class IncrementalSearchNativeTest {
    @Test
    fun blankQueryIsRejectedBeforeStartingASearchSubscription() {
        val engine = ReaderEngine()
        try {
            var delivered: EngineReply? = null
            engine.startSearch("  ", emptyList()) { delivered = it }
            val deadline = NSDate().timeIntervalSince1970 + 10.0
            while (delivered == null && NSDate().timeIntervalSince1970 < deadline) {
                NSRunLoop.currentRunLoop.runUntilDate(NSDate.dateWithTimeIntervalSinceNow(0.01))
            }
            assertEquals(EngineErrorCode.INVALID_INPUT, assertNotNull(delivered as? EngineFailure).code)
        } finally {
            engine.close()
        }
    }

    @Test
    fun nonblankQueryBeforeInitializationIsReportedThroughTheCompletion() {
        val engine = ReaderEngine()
        try {
            val reply = awaitReply { engine.startSearch("Shared work", emptyList(), it) }
            assertEquals(EngineErrorCode.INVALID_INPUT, assertNotNull(reply as? EngineFailure).code)
        } finally { engine.close() }
    }

    @Test
    fun sameSourceWaiterDoesNotConsumeThePermitNeededByAnIndependentEngine() = withFixture("slow", "fast") { fixture ->
        val previousConfig = AppConfigProviders.get()
        AppConfigProviders.register(object : AppConfigAccessor by previousConfig {
            override val threadCount = 2
        })
        try {
            val first = fixture.start(listOf(fixture.base + "/slow"))
            first.awaitUpdate { it.sources.single().status == SearchSourceStatus.RUNNING }
            fixture.awaitEntered("slow")
            val peer = fixture.createInitializedPeer()
            val waiting = fixture.start(listOf(fixture.base + "/slow"), reader = peer)
            waiting.awaitUpdate { it.sources.single().status == SearchSourceStatus.RUNNING }
            pumpFor(0.1)
            val independent = fixture.createInitializedPeer()
            val fast = fixture.start(listOf(fixture.base + "/fast"), reader = independent)
            val available = fast.awaitUpdate(timeout = 2.0) { it.works.isNotEmpty() }
            assertEquals("fast", available.works.single().candidates.single().book.sourceId.substringAfterLast('/'))
            assertFalse(first.updates.any { it.works.isNotEmpty() }, "The held source must remain held until the fast source completes")
        } finally { AppConfigProviders.register(previousConfig) }
    }

    @Test
    fun fastSourceAppearsBeforeReleasedPeerAndExactSourcesExpandAsOneWork() = withFixture("fast", "slow") { fixture ->
        val probe = fixture.start()
        val partial = probe.awaitUpdate { it.works.singleOrNull()?.sourceCount == 1 }
        assertEquals(SearchPhase.SEARCHING, partial.phase)
        assertEquals("fast", partial.works.single().candidates.single().book.sourceId.substringAfterLast('/'))
        fixture.releaseSlow()
        val done = probe.awaitUpdate(partial.revision) { it.phase == SearchPhase.IDLE }
        assertEquals(2, done.works.single().sourceCount)
        assertEquals(setOf("fast", "slow"), done.works.single().candidates.map { it.book.sourceId.substringAfterLast('/') }.toSet())
        assertFalse(done.hasNextPage)
        assertTrue(probe.updates.zipWithNext().all { (a, b) -> a.revision < b.revision })
    }

    @Test
    fun absentAuthorsStaySeparateAndUnknownSelectionNeverWidensScope() = withFixture("fast", "missing-a", "missing-b") { fixture ->
        val probe = fixture.start(emptyList())
        val done = probe.awaitUpdate { it.phase == SearchPhase.IDLE }
        assertEquals(3, done.works.size)
        assertEquals(2, done.works.count { it.author.isBlank() })
        assertTrue(done.works.all { it.sourceCount == 1 && it.candidates.size == 1 })
        fixture.stop(probe)
        var rejected: EngineReply? = null
        fixture.engine.startSearch("work", listOf(fixture.base + "/unknown-selection")) { rejected = it }
        pumpUntil { rejected != null }
        assertEquals(EngineErrorCode.NOT_FOUND, assertNotNull(rejected as? EngineFailure).code)
    }

    @Test
    fun failedEmptyAndInteractiveSourcesDifferFromSuccessfulCandidates() = withFixture("fast", "empty", "failure", "interaction") { fixture ->
        val done = fixture.start().awaitUpdate { it.phase == SearchPhase.IDLE }
        val sources = done.sources.associateBy { it.sourceId.substringAfterLast('/') }
        assertEquals(SearchSourceStatus.SUCCESS, sources.getValue("fast").status)
        assertEquals(SearchSourceStatus.EMPTY, sources.getValue("empty").status)
        assertEquals(SearchSourceStatus.FAILED, sources.getValue("failure").status)
        assertEquals(EngineErrorCode.NETWORK, sources.getValue("failure").failure?.code)
        assertEquals(SearchSourceStatus.FAILED, sources.getValue("interaction").status)
        assertEquals(EngineErrorCode.INTERACTION_REQUIRED, sources.getValue("interaction").failure?.code)
        assertEquals(1, done.works.single().sourceCount)
    }

    @Test
    fun failedSecondPageRetriesThatPageAndFinalNonemptyPageEndsPaging() = withFixture("paged") { fixture ->
        val probe = fixture.start()
        val first = probe.awaitUpdate { it.phase == SearchPhase.IDLE }
        assertTrue(first.hasNextPage)
        assertEquals(listOf("Shared work"), first.works.map { it.title })
        assertTrue(awaitReply { fixture.engine.loadMoreSearch(first.sessionId, it) } is SearchCommandAccepted)
        val failed = probe.awaitUpdate(first.revision) {
            it.phase == SearchPhase.IDLE && it.sources.single().status == SearchSourceStatus.FAILED
        }
        assertEquals(2, failed.sources.single().page)
        assertEquals(listOf("Shared work"), failed.works.map { it.title })
        assertFalse(failed.sources.single().hasNextPage)
        assertTrue(awaitReply { fixture.engine.retrySearchSource(first.sessionId, fixture.base + "/paged", it) } is SearchCommandAccepted)
        val retried = probe.awaitUpdate(failed.revision) {
            it.phase == SearchPhase.IDLE && it.sources.single().status == SearchSourceStatus.SUCCESS
        }
        assertEquals(2, retried.sources.single().page)
        assertEquals(listOf("Shared work", "Second page work"), retried.works.map { it.title })
        assertFalse(retried.hasNextPage)
    }

    @Test
    fun stoppingKeepsFinishedCandidatesAndRetiresLateCallbacks() = withFixture("fast", "slow") { fixture ->
        val probe = fixture.start()
        val first = probe.awaitUpdate { it.works.isNotEmpty() }
        assertTrue(awaitReply { fixture.engine.cancelSearch(first.sessionId, it) } is SearchCommandAccepted)
        val stopped = probe.awaitUpdate(first.revision) { it.phase == SearchPhase.CANCELLED }
        assertEquals(1, stopped.works.single().candidates.size)
        assertEquals(SearchSourceStatus.CANCELLED, stopped.sources.single { it.sourceId.endsWith("/slow") }.status)
        assertFalse(stopped.hasNextPage)
        val restart = awaitReply { fixture.engine.restartSearchSource(first.sessionId, fixture.base + "/fast", it) }
        assertTrue(restart is EngineFailure)
        assertEquals(EngineErrorCode.CANCELLED, restart.code)
        val count = probe.updates.size
        fixture.releaseSlow()
        pumpFor(0.2)
        assertEquals(count, probe.updates.size)
    }

    @Test
    fun replacingAQueryRetiresItsCallbacksAndUsesOnlyTheNewScope() = withFixture("fast", "slow") { fixture ->
        val old = fixture.start()
        val partial = old.awaitUpdate { it.works.isNotEmpty() }
        val fresh = fixture.start(listOf(fixture.base + "/fast"), "replacement")
        val done = fresh.awaitUpdate { it.phase == SearchPhase.IDLE }
        assertTrue(done.sessionId != partial.sessionId)
        assertEquals(listOf("Replacement work"), done.works.map { it.title })
        assertEquals(listOf(fixture.base + "/fast"), done.sources.map { it.sourceId })
        fixture.stop(old)
        val count = old.updates.size
        fixture.releaseSlow()
        pumpFor(0.2)
        assertEquals(count, old.updates.size)
    }

    @Test
    fun restartingOneSourceRejectsItsOldPageWithoutLosingItsPeer() = withFixture("fast", "restart") { fixture ->
        val probe = fixture.start()
        val partial = probe.awaitUpdate { update -> update.works.isNotEmpty() &&
            update.sources.single { it.sourceId.endsWith("/restart") }.status == SearchSourceStatus.RUNNING }
        fixture.awaitEntered("restart")
        assertTrue(awaitReply { fixture.engine.restartSearchSource(partial.sessionId, fixture.base + "/restart", it) } is SearchCommandAccepted)
        fixture.releaseSlow()
        val done = probe.awaitUpdate(partial.revision) { it.phase == SearchPhase.IDLE }
        assertEquals(setOf("Shared work", "New edition"), done.works.map { it.title }.toSet())
        assertEquals(1, done.sources.single { it.sourceId.endsWith("/restart") }.generation)
        fixture.releaseSlow()
        pumpFor(0.2)
        assertFalse(probe.updates.last().works.any { it.title == "Old edition" })
    }

    @Test
    fun eachExpandedCandidateLoadsItsOwnDetailsCatalogAndBodyWithoutShelfAdmission() = withFixture("fast", "slow", "duplicate") { fixture ->
        val before = assertNotNull(awaitReply { fixture.engine.listShelf(it) } as? ShelfReply)
        fixture.releaseSlow()
        val done = fixture.start().awaitUpdate { it.phase == SearchPhase.IDLE }
        val work = done.works.single()
        assertEquals(3, work.sourceCount)
        assertEquals(4, work.candidates.size)
        for (candidate in work.candidates) {
            val book = candidate.book
            val kind = book.sourceId.substringAfterLast('/')
            val detail = assertNotNull(awaitReply { fixture.engine.loadBook(book.sourceId, book.id, it) } as? BookReply)
            assertEquals("$kind detail", detail.book.intro)
            val toc = assertNotNull(awaitReply { fixture.engine.loadToc(book.sourceId, book.id, it) } as? TocReply)
            assertTrue(toc.chapters.single().id.contains("/content/$kind/"))
            val body = assertNotNull(awaitReply {
                fixture.engine.loadChapter(book.sourceId, book.id, toc.chapters.single().id, false, it)
            } as? ContentReply)
            assertTrue(body.text.contains("$kind paragraph one."))
            assertEquals("Shared work", candidate.book.title, "Loading details must not mutate an emitted search snapshot")
        }
        val after = assertNotNull(awaitReply { fixture.engine.listShelf(it) } as? ShelfReply)
        assertEquals(before.books.map { it.book.sourceId to it.book.id }, after.books.map { it.book.sourceId to it.book.id })
    }

    @Test
    fun incrementalRegistrationPreservesLoadedCatalogCachedBodyAndExistingShelfProgress() = withFixture("fast", "slow") { fixture ->
        val source = fixture.base + "/fast"
        val seed = assertNotNull(awaitReply { fixture.engine.search(source, "work", 1, it) } as? SearchReply).books.single()
        val detail = assertNotNull(awaitReply { fixture.engine.loadBook(source, seed.id, it) } as? BookReply)
        assertEquals("Exact fast", detail.book.title)
        val chapter = assertNotNull(awaitReply { fixture.engine.loadToc(source, seed.id, it) } as? TocReply).chapters.single()
        assertTrue(awaitReply { fixture.engine.addToShelf(source, seed.id, it) } is ShelfEntryReply)
        val original = assertNotNull(awaitReply { fixture.engine.loadChapter(source, seed.id, chapter.id, false, it) } as? ContentReply)
        val token = assertNotNull(original.reading).token
        val secondParagraph = original.text.indexOf("fast paragraph two.")
        assertTrue(secondParagraph > 0, "The fixture must provide a distinct second paragraph")
        val saved = assertNotNull(awaitReply { fixture.engine.saveReadingPosition(token, 1L, secondParagraph, it) } as? ReadingSaved)
        assertEquals(1L, saved.revision)
        assertTrue(saved.paragraphUtf16Offset > 0, "Saving the initial zero offset would not prove position preservation")
        fixture.releaseSlow()
        val done = fixture.start().awaitUpdate { it.phase == SearchPhase.IDLE }
        assertEquals(2, done.works.single().sourceCount)
        // Read through the current registry and TOC before shelf reopen can repair either.
        val cached = assertNotNull(awaitReply { fixture.engine.loadChapter(source, seed.id, chapter.id, true, it) } as? ContentReply)
        assertTrue(cached.fromCache)
        assertEquals(original.text, cached.text)
        assertEquals(saved.revision, assertNotNull(cached.reading).revision)
        val shelf = assertNotNull(awaitReply { fixture.engine.listShelf(it) } as? ShelfReply)
        assertEquals(listOf(source to seed.id), shelf.books.map { it.book.sourceId to it.book.id })
        val resumed = assertNotNull(awaitReply { fixture.engine.openReading(source, seed.id, true, it) } as? ContentReply)
        assertEquals(saved.revision, assertNotNull(resumed.reading).revision)
        assertEquals(saved.paragraphUtf16Offset, assertNotNull(resumed.reading).paragraphUtf16Offset)
    }

    @Test
    fun controlledTitleAuthorAndCombinedQueriesReachTheSourceWithoutRewritingInput() = withFixture("fast") { fixture ->
        for (query in listOf("Shared work", "Fixture author", "Shared work Fixture author")) {
            val done = fixture.start(query = query).awaitUpdate { it.phase == SearchPhase.IDLE }
            assertEquals(listOf("Shared work"), done.works.map { it.title }, query)
        }
        val unmatched = fixture.start(query = "unmatched fixture query").awaitUpdate { it.phase == SearchPhase.IDLE }
        assertTrue(unmatched.works.isEmpty())
        assertEquals(SearchSourceStatus.EMPTY, unmatched.sources.single().status)
    }

    @Test
    fun timedOutSourceDoesNotEraseSuccessfulPeer() = withFixture("fast", "timeout") { fixture ->
        val probe = fixture.start()
        probe.awaitUpdate { it.works.isNotEmpty() }
        val done = probe.awaitUpdate(timeout = 35.0) { it.phase == SearchPhase.IDLE }
        assertEquals(1, done.works.single().sourceCount)
        val timeout = done.sources.single { it.sourceId.endsWith("/timeout") }
        assertEquals(SearchSourceStatus.FAILED, timeout.status)
        assertEquals(EngineErrorCode.TIMEOUT, timeout.failure?.code)
    }

    private class Probe(val engine: ReaderEngine, query: String, sources: List<String>) {
        val updates = arrayListOf<SearchUpdate>()
        val failures = arrayListOf<EngineFailure>()
        val request = engine.startSearch(query, sources) { reply -> when (reply) {
            is SearchUpdate -> updates.add(reply)
            is EngineFailure -> failures.add(reply)
        } }
        fun awaitUpdate(after: Long = 0L, timeout: Double = 15.0, predicate: (SearchUpdate) -> Boolean): SearchUpdate {
            pumpUntil(timeout) { failures.isNotEmpty() || updates.any { it.revision > after && predicate(it) } }
            assertTrue(failures.isEmpty(), failures.joinToString { "${it.code}: ${it.message}" })
            return updates.first { it.revision > after && predicate(it) }
        }
    }

    private class Fixture(val kinds: List<String>) {
        val engine = ReaderEngine()
        private val fixtureHost = assertNotNull(NSProcessInfo.processInfo.environment["SPEC004_FIXTURE_BASE"] as? String,
            "Start the task fixture and pass SPEC004_FIXTURE_BASE")
        val base = fixtureHost.trimEnd('/') + "/" + NSUUID().UUIDString
        private val driver: IosDatabaseDriver
        private val previous: AppDatabaseProvider
        private val probes = arrayListOf<Probe>()
        private val peers = arrayListOf<ReaderEngine>()
        private val previousResources = runCatching { DefaultDataResourceProviders.get() }.getOrNull()
        init {
            // The standalone fixture has no bundled UI default resources.
            DefaultDataResourceProviders.register(object : DefaultDataResourceProvider {
                override fun readResource(name: String) = "[]"
            })
            assertTrue(awaitReply { engine.initialize(it) } is EngineReady)
            previous = AppDatabaseProviders.get()
            val path = NSTemporaryDirectory() + "spec004-search-" + NSUUID().UUIDString + "/test.db"
            println("SPEC004 isolated Room database=$path")
            driver = IosDatabaseDriver(path)
            AppDatabaseProviders.register(NativeAppDatabaseProvider(driver))
            assertTrue(awaitReply { engine.importSources(sourceJson(base, kinds), it) } is SourcesReply)
        }
        fun start(sources: List<String> = kinds.map { "$base/$it" }, query: String = "work", reader: ReaderEngine = engine): Probe =
            Probe(reader, query, sources).also { probes.add(it) }
        fun createInitializedPeer(): ReaderEngine = ReaderEngine().also {
            peers.add(it)
            assertTrue(awaitReply { completion -> it.initialize(completion) } is EngineReady)
        }
        fun awaitEntered(source: String) {
            val completed = atomic(false)
            NSURLSession.sharedSession.dataTaskWithURL(assertNotNull(NSURL.URLWithString("$base/entered/$source"))) { _, _, _ ->
                completed.value = true
            }.resume()
            pumpUntil { completed.value }
        }
        fun releaseSlow() {
            NSURLSession.sharedSession.dataTaskWithURL(assertNotNull(NSURL.URLWithString("$base/release"))) { _, _, _ -> }.resume()
        }
        fun stop(probe: Probe) {
            pumpUntil { probe.updates.isNotEmpty() || probe.failures.isNotEmpty() }
            val last = probe.updates.lastOrNull() ?: return
            // An already retired session returns CANCELLED only after its owned work has joined.
            awaitReply { probe.engine.cancelSearch(last.sessionId, it) }
        }
        fun close() {
            try { probes.forEach { stop(it) }; releaseSlow(); peers.forEach { it.close() }; engine.close() }
            finally {
                driver.close()
                AppDatabaseProviders.register(previous)
                previousResources?.let { DefaultDataResourceProviders.register(it) }
            }
        }
    }

    companion object {
        private fun withFixture(vararg kinds: String, action: (Fixture) -> Unit) {
            val fixture = Fixture(kinds.toList())
            try { action(fixture) } finally { fixture.close() }
        }
        private fun awaitReply(start: ((EngineReply) -> Unit) -> Unit): EngineReply {
            var reply: EngineReply? = null
            start { reply = it }
            pumpUntil { reply != null }
            return assertNotNull(reply)
        }
        private fun pumpUntil(timeout: Double = 15.0, condition: () -> Boolean) {
            val end = NSDate().timeIntervalSince1970 + timeout
            while (!condition() && NSDate().timeIntervalSince1970 < end)
                NSRunLoop.currentRunLoop.runUntilDate(NSDate.dateWithTimeIntervalSinceNow(0.01))
            assertTrue(condition(), "Timed out waiting for public Engine callback")
        }
        private fun pumpFor(seconds: Double) {
            val end = NSDate().timeIntervalSince1970 + seconds
            while (NSDate().timeIntervalSince1970 < end)
                NSRunLoop.currentRunLoop.runUntilDate(NSDate.dateWithTimeIntervalSinceNow(0.01))
        }
        private fun sourceJson(base: String, kinds: List<String>): String = kinds.joinToString(prefix = "[", postfix = "]") { kind ->
            val nameRule = if (kind == "interaction")
                "@js:java.startBrowser('https://fixture.invalid','Verify'); 'Shared work';" else "class.book@text"
            """{"bookSourceUrl":"$base/$kind","bookSourceName":"Search fixture $kind","bookSourceType":0,"enabled":true,"searchUrl":"$base/search/$kind?key={{key}}&page={{page}}","ruleSearch":{"bookList":"tag.article","name":"$nameRule","author":"class.author@text","bookUrl":"class.book@href","hasMoreRule":"result.indexOf('data-more=' + String.fromCharCode(34) + 'true') >= 0"},"ruleBookInfo":{"canReName":"true","name":"tag.h1@text","author":"class.author@text","intro":"class.intro@text","tocUrl":"class.toc@href"},"ruleToc":{"chapterList":"class.chapter","chapterName":"text","chapterUrl":"href"},"ruleContent":{"content":"class.content@html"}}"""
        }
    }
}
