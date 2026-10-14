package io.legado.engine

import io.legado.app.constant.PreferKey
import io.legado.app.data.entities.BookListPage
import io.legado.app.data.entities.BookSource
import io.legado.app.data.entities.SearchBook
import io.legado.app.help.config.AppConfigProviders
import io.legado.app.help.config.NativeAppConfigAccessor
import io.legado.app.help.config.PreferenceProvider
import io.legado.app.model.webBook.SourcePageOutcome
import io.legado.app.model.webBook.SourceSearchGroup
import io.legado.app.model.webBook.SearchModel
import io.legado.app.ui.book.search.SearchScope
import kotlinx.atomicfu.atomic
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withContext
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withTimeoutOrNull
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class SearchModelSessionTest {
    @Test
    fun failedPageIsRetriedWithoutSkippingItsPageNumber() = runBlocking {
        val priorConfig = runCatching { AppConfigProviders.get() }.getOrNull()
        AppConfigProviders.register(NativeAppConfigAccessor(FixturePreferences()))
        val owner = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val source = BookSource(bookSourceUrl = "https://paging.invalid", bookSourceName = "Paging")
        val callback = RecordingCallback()
        val requestedPages = arrayListOf<Int>()
        val model = SearchModel(owner, callback, sourceResolver = { listOf(source) },
            pageExecutor = { _, page, _ ->
                requestedPages.add(page)
                if (requestedPages.size == 1) error("Controlled first-page failure")
                BookListPage(arrayListOf(SearchBook(bookUrl = "https://paging.invalid/book", origin = source.bookSourceUrl,
                    name = "Fixture title", author = "Fixture author")), false)
            })
        try {
            model.search(1L, "Fixture")
            assertEquals("failed", withTimeout(5000) { callback.rounds.receive() })
            model.search(1L, "Fixture")
            assertEquals("finished:false", withTimeout(5000) { callback.rounds.receive() })
            assertEquals(listOf(1, 1), requestedPages)
        } finally {
            withContext(NonCancellable) {
                model.closeAndJoin()
                owner.cancel()
                if (priorConfig != null) AppConfigProviders.register(priorConfig)
            }
        }
    }

    @Test
    fun finalNonemptyPageClearsHasMore() = runBlocking {
        val priorConfig = runCatching { AppConfigProviders.get() }.getOrNull()
        AppConfigProviders.register(NativeAppConfigAccessor(FixturePreferences()))
        val owner = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val source = BookSource(bookSourceUrl = "https://last-page.invalid", bookSourceName = "Last page")
        val callback = RecordingCallback()
        val model = SearchModel(owner, callback, sourceResolver = { listOf(source) },
            pageExecutor = { _, page, _ ->
                BookListPage(arrayListOf(SearchBook(bookUrl = "${source.bookSourceUrl}/$page", origin = source.bookSourceUrl,
                    name = "Fixture page $page", author = "Fixture author")), page == 1)
            })
        try {
            model.search(1L, "Fixture")
            assertEquals("finished:true", withTimeout(5000) { callback.rounds.receive() })
            model.search(1L, "Fixture")
            assertEquals("finished:false", withTimeout(5000) { callback.rounds.receive() })
        } finally {
            withContext(NonCancellable) {
                model.closeAndJoin()
                owner.cancel()
                if (priorConfig != null) AppConfigProviders.register(priorConfig)
            }
        }
    }

    @Test
    fun fastResultsArriveWhileSlowSourceIsStillRunningWithinConcurrencyLimit() = runBlocking {
        val fast = source("fast"); val slow = source("slow"); val queued = source("queued")
        val entered = Channel<String>(Channel.UNLIMITED)
        val releaseFast = CompletableDeferred<Unit>(); val releaseSlow = CompletableDeferred<Unit>()
        val active = atomic(0); val peak = atomic(0)
        fixture(listOf(fast, slow, queued), fetch = { source, _ ->
            val count = active.incrementAndGet()
            while (true) {
                val before = peak.value
                if (before >= count || peak.compareAndSet(before, count)) break
            }
            entered.send(source.bookSourceName)
            try {
                when (source.bookSourceName) { "fast" -> releaseFast.await(); "slow" -> releaseSlow.await() }
                page(source, source.bookSourceName)
            } finally { active.decrementAndGet() }
        }) { model, callback ->
            try {
                model.search(1L, "Fixture")
                assertEquals(setOf("fast", "slow"), setOf(entered.receive(), entered.receive()))
                assertEquals(2, active.value)
                assertTrue(entered.tryReceive().isFailure, "Third source must wait for a concurrency slot")
                releaseFast.complete(Unit)
                callback.titlesUntil(listOf("fast"))
                assertFalse(releaseSlow.isCompleted, "Useful result must precede the delayed source")
                assertEquals("queued", entered.receive())
                releaseSlow.complete(Unit)
                assertEquals("finished:false", callback.rounds.receive())
                assertEquals(2, peak.value)
            } finally { releaseFast.complete(Unit); releaseSlow.complete(Unit) }
        }
    }

    @Test
    fun aFailedSourceIsReportedSeparatelyFromAnEmptySuccess() = runBlocking {
        val found = source("found"); val empty = source("empty"); val failed = source("failed")
        fixture(listOf(found, empty, failed), fetch = { source, _ ->
            when (source.bookSourceName) {
                "found" -> page(source, "Retained title")
                "empty" -> BookListPage(arrayListOf(), false)
                else -> error("Controlled source failure")
            }
        }) { model, callback ->
            model.search(1L, "Fixture")
            val events = List(3) { callback.pages.receive() }.associateBy { it.sourceId }
            assertEquals(SourcePageOutcome.Success(false, false), events.getValue(found.bookSourceUrl).outcome)
            assertEquals(SourcePageOutcome.Success(false, true), events.getValue(empty.bookSourceUrl).outcome)
            val failure = events.getValue(failed.bookSourceUrl).outcome as SourcePageOutcome.Failure
            assertEquals("Controlled source failure", failure.error.message)
            assertEquals("finished:false", callback.rounds.receive())
            callback.titlesUntil(listOf("Retained title"))
        }
    }

    @Test
    fun aPageTimeoutIsFailureRatherThanEmptyOrCancelled() = runBlocking {
        val timed = source("timeout"); val empty = source("empty")
        fixture(listOf(timed, empty), fetch = { source, _ ->
            if (source.bookSourceUrl == timed.bookSourceUrl) {
                withTimeout(20) { awaitCancellation() }
            } else BookListPage(arrayListOf(), false)
        }) { model, callback ->
            model.search(1L, "Fixture")
            val events = List(2) { callback.pages.receive() }.associateBy { it.sourceId }
            val outcome = events.getValue(timed.bookSourceUrl).outcome as SourcePageOutcome.Failure
            assertTrue(outcome.error is TimeoutCancellationException)
            assertEquals(SourcePageOutcome.Success(false, true), events.getValue(empty.bookSourceUrl).outcome)
            assertEquals("finished:false", callback.rounds.receive())
        }
    }

    @Test
    fun retryKeepsAcceptedPagesAndRetriesOnlyTheFailedPage() = runBlocking {
        val source = source("retry"); val requests = arrayListOf<Int>(); var secondPageAttempts = 0
        fixture(listOf(source), fetch = { current, number ->
            requests.add(number)
            if (number == 2 && secondPageAttempts++ == 0) error("Retry this page")
            page(current, "Page $number", more = number == 1)
        }) { model, callback ->
            model.search(1L, "Fixture"); assertEquals("finished:true", callback.rounds.receive())
            model.search(1L, "Fixture"); assertEquals("failed", callback.rounds.receive())
            model.retrySource(source.bookSourceUrl)
            assertEquals(SourcePageOutcome.Success(false, false), callback.pageUntil(source.bookSourceUrl, 1, 2).outcome)
            val snapshot = callback.titlesUntil(listOf("Page 1", "Page 2"))
            assertEquals(listOf(1, 2, 2), requests)
            assertEquals(1, snapshot.single().generation)
        }
    }

    @Test
    fun loadMoreDoesNotSilentlyRetryAFailedSource() = runBlocking {
        val failed = source("failed"); val empty = source("empty"); val attempts = atomic(0)
        fixture(listOf(failed, empty), fetch = { source, _ ->
            if (source.bookSourceUrl == failed.bookSourceUrl) {
                if (attempts.incrementAndGet() == 1) error("Explicit retry required")
                page(source, "Recovered title")
            } else BookListPage(arrayListOf(), false)
        }) { model, callback ->
            model.search(1L, "Fixture"); assertEquals("finished:false", callback.rounds.receive())
            model.loadMore(); assertEquals("finished:false", callback.rounds.receive())
            assertEquals(1, attempts.value)
            model.retrySource(failed.bookSourceUrl)
            assertEquals(SourcePageOutcome.Success(false, false), callback.pageUntil(failed.bookSourceUrl, 1, 1).outcome)
            callback.titlesUntil(listOf("Recovered title"))
            assertEquals(2, attempts.value)
        }
    }

    @Test
    fun restartDiscardsAnOldInflightPageAndReturnsToPageOne() = runBlocking {
        val source = source("restart"); val requests = arrayListOf<Int>()
        val oldPageEntered = CompletableDeferred<Unit>(); val releaseOld = CompletableDeferred<Unit>()
        var firstPageCalls = 0
        fixture(listOf(source), fetch = { current, number ->
            requests.add(number)
            if (number == 1) {
                firstPageCalls++
                page(current, if (firstPageCalls == 1) "Original title" else "Restarted title", more = firstPageCalls == 1)
            } else {
                oldPageEntered.complete(Unit)
                releaseOld.await()
                page(current, "Stale page two")
            }
        }) { model, callback ->
            try {
                model.search(1L, "Fixture"); assertEquals("finished:true", callback.rounds.receive())
                model.search(1L, "Fixture"); oldPageEntered.await()
                model.restartSource(source.bookSourceUrl)
                callback.titlesUntil(emptyList())
                assertEquals(listOf(1, 2), requests, "Restart must wait for the same-source in-flight page")
                releaseOld.complete(Unit)
                val snapshot = callback.titlesUntil(listOf("Restarted title"))
                assertEquals(listOf(1, 2, 1), requests)
                assertEquals(1, snapshot.single().generation)
                val events = arrayListOf<PageEvent>()
                while (true) {
                    val event = callback.pages.tryReceive().getOrNull() ?: break
                    events.add(event)
                }
                assertFalse(events.any { it.page == 2 && it.outcome is SourcePageOutcome.Success })
            } finally { releaseOld.complete(Unit) }
        }
    }

    @Test
    fun closeAndJoinWaitsForBothMainAndRestartCleanupAndRetiresTheirCallbacks() = runBlocking {
        for (restarting in listOf(false, true)) {
            val source = source(if (restarting) "closing-restart" else "closing-main")
            val entered = CompletableDeferred<Unit>(); val cleanupEntered = CompletableDeferred<Unit>()
            val releaseCleanup = CompletableDeferred<Unit>(); var attempts = 0
            fixture(listOf(source), fetch = { current, _ ->
                attempts++
                if (restarting && attempts == 1) page(current, "Accepted title")
                else {
                    entered.complete(Unit)
                    try { awaitCancellation() }
                    finally {
                        withContext(NonCancellable) {
                            cleanupEntered.complete(Unit)
                            releaseCleanup.await()
                        }
                    }
                }
            }) { model, callback ->
                try {
                    model.search(1L, "Fixture")
                    if (restarting) {
                        assertEquals("finished:false", callback.rounds.receive())
                        model.restartSource(source.bookSourceUrl)
                    }
                    entered.await()
                    while (callback.groups.tryReceive().isSuccess) {}
                    while (callback.pages.tryReceive().isSuccess) {}
                    coroutineScope {
                        val closing = async { model.closeAndJoin() }
                        cleanupEntered.await()
                        assertFalse(closing.isCompleted, "Close must await source cleanup")
                        releaseCleanup.complete(Unit)
                        closing.await()
                    }
                    assertTrue(callback.groups.tryReceive().isFailure, "Retired work must not publish results")
                    assertTrue(callback.pages.tryReceive().isFailure, "Retired work must not publish page outcomes")
                } finally { releaseCleanup.complete(Unit) }
            }
        }
    }

    @Test
    fun closeAndJoinAlsoWaitsForAReplacedRestartStillCleaningUp() = runBlocking {
        val source = source("replaced-restart")
        val entered = CompletableDeferred<Unit>()
        val cleanupEntered = CompletableDeferred<Unit>()
        val releaseCleanup = CompletableDeferred<Unit>()
        val attempts = atomic(0)
        fixture(listOf(source), fetch = { current, _ ->
            if (attempts.incrementAndGet() == 1) page(current, "Accepted title")
            else {
                entered.complete(Unit)
                try { awaitCancellation() }
                finally {
                    withContext(NonCancellable) {
                        cleanupEntered.complete(Unit)
                        releaseCleanup.await()
                    }
                }
            }
        }) { model, callback ->
            try {
                model.search(1L, "Fixture")
                assertEquals("finished:false", callback.rounds.receive())
                model.restartSource(source.bookSourceUrl)
                entered.await()
                model.restartSource(source.bookSourceUrl)
                cleanupEntered.await()
                coroutineScope {
                    val closeStarted = CompletableDeferred<Unit>()
                    val closing = async {
                        closeStarted.complete(Unit)
                        model.closeAndJoin()
                    }
                    closeStarted.await()
                    assertFalse(closing.isCompleted, "Replaced restart cleanup remains owned until it returns")
                    releaseCleanup.complete(Unit)
                    closing.await()
                }
                assertEquals(2, attempts.value, "Cancelled replacement must not fetch after close")
            } finally { releaseCleanup.complete(Unit) }
        }
    }

    @Test
    fun queuedMainPagesKeepTheirOriginalGenerationAndShareRestartConcurrencyLimit() = runBlocking {
        val first = source("first")
        val second = source("second")
        val queued = source("queued")
        val restarted = source("restarted")
        val entered = Channel<String>(Channel.UNLIMITED)
        val releaseFirst = CompletableDeferred<Unit>()
        val releaseSecond = CompletableDeferred<Unit>()
        val releaseRestart = CompletableDeferred<Unit>()
        val active = atomic(0)
        val peak = atomic(0)
        val restartedRequests = atomic(0)
        fixture(listOf(first, second, queued, restarted), fetch = { current, _ ->
            val count = active.incrementAndGet()
            while (true) {
                val before = peak.value
                if (before >= count || peak.compareAndSet(before, count)) break
            }
            entered.send(current.bookSourceName)
            try {
                when (current.bookSourceName) {
                    "first" -> releaseFirst.await()
                    "second" -> releaseSecond.await()
                    "restarted" -> {
                        restartedRequests.incrementAndGet()
                        releaseRestart.await()
                    }
                }
                page(current, current.bookSourceName)
            } finally { active.decrementAndGet() }
        }) { model, callback ->
            try {
                model.search(1L, "Fixture")
                assertEquals(setOf("first", "second"), setOf(entered.receive(), entered.receive()))
                model.restartSource(restarted.bookSourceUrl)
                callback.titlesUntil(emptyList())
                assertTrue(entered.tryReceive().isFailure, "A restart shares the existing page concurrency budget")
                releaseFirst.complete(Unit)
                assertEquals("restarted", entered.receive())
                releaseSecond.complete(Unit)
                assertEquals("queued", entered.receive())
                callback.pageUntil(queued.bookSourceUrl, 0, 1)
                releaseRestart.complete(Unit)
                callback.pageUntil(restarted.bookSourceUrl, 1, 1)
                model.loadMore()
                model.closeAndJoin()
                assertEquals(1, restartedRequests.value, "Queued pre-restart work must not fetch a second page")
                assertEquals(2, peak.value)
            } finally {
                releaseFirst.complete(Unit)
                releaseSecond.complete(Unit)
                releaseRestart.complete(Unit)
            }
        }
    }

    @Test
    fun stoppedSearchCanRestartOneSourceWithUpdatedOptionsAndRetainPeers() = runBlocking {
        val changed = source("changed"); val peer = source("peer")
        val option = atomic(0)
        val requests = Channel<Pair<String, Int>>(Channel.UNLIMITED)
        fixture(listOf(changed, peer), fetch = { current, number ->
            requests.send(current.bookSourceUrl to number)
            page(current, if (current == changed) "Option ${option.value}" else "Peer")
        }) { model, callback ->
            model.search(1L, "Fixture")
            assertEquals("finished:false", callback.rounds.receive())
            repeat(2) { requests.receive() }
            model.cancelSearch()
            assertEquals("failed", callback.rounds.receive())
            option.value = 1
            model.restartSource(changed.bookSourceUrl)
            assertEquals(changed.bookSourceUrl to 1, requests.receive())
            callback.pageUntil(changed.bookSourceUrl, 1, 1)
            val groups = callback.groups
            var titles: Set<String>
            do { titles = groups.receive().flatMap { it.books }.map { it.name }.toSet() }
            while (titles != setOf("Option 1", "Peer"))
            assertNull(withTimeoutOrNull(200) { callback.rounds.receive() },
                "Stopped main search must not finish again")
            model.closeAndJoin()
            assertTrue(requests.tryReceive().isFailure, "Only the changed source is requested again")
        }
    }

    @Test
    fun permanentCloseRejectsSourceCommandsEvenAfterAStop() = runBlocking {
        val source = source("retired")
        val requests = Channel<Unit>(Channel.UNLIMITED)
        fixture(listOf(source), fetch = { current, _ ->
            requests.send(Unit)
            page(current, "Accepted")
        }) { model, callback ->
            model.search(1L, "Fixture")
            assertEquals("finished:false", callback.rounds.receive())
            requests.receive()
            model.cancelSearch()
            model.closeAndJoin()
            model.restartSource(source.bookSourceUrl)
            model.retrySource(source.bookSourceUrl)
            assertNull(withTimeoutOrNull(200) { requests.receive() },
                "Permanent retirement cannot resume a retained query")
        }
    }

    @Test
    fun closingWhileSourcesResolveCannotResurrectTheSession() = runBlocking {
        val prior = runCatching { AppConfigProviders.get() }.getOrNull()
        AppConfigProviders.register(NativeAppConfigAccessor(FixturePreferences()))
        val owner = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val resolving = CompletableDeferred<Unit>()
        val releaseResolver = CompletableDeferred<Unit>()
        val callback = RecordingCallback()
        val source = source("resolving")
        val model = SearchModel(owner, callback, sourceResolver = {
            resolving.complete(Unit)
            releaseResolver.await()
            listOf(source)
        }, pageExecutor = { _, _, _ -> page(source, "Resurrected title") })
        try {
            withTimeout(10_000) {
                coroutineScope {
                    val launch = async { model.search(1L, "Fixture") }
                    resolving.await()
                    model.closeAndJoin()
                    releaseResolver.complete(Unit)
                    launch.await()
                    assertTrue(callback.resolved.tryReceive().isFailure,
                        "A retired source-resolution continuation must not publish or start a new search")
                }
            }
        } finally {
            releaseResolver.complete(Unit)
            withContext(NonCancellable) {
                model.closeAndJoin()
                owner.cancel()
                if (prior != null) AppConfigProviders.register(prior)
            }
        }
    }

    private fun source(id: String) = BookSource(bookSourceUrl = "https://$id.invalid", bookSourceName = id)

    private fun page(source: BookSource, title: String, more: Boolean = false) = BookListPage(
        arrayListOf(SearchBook(bookUrl = "${source.bookSourceUrl}/$title", origin = source.bookSourceUrl,
            originName = source.bookSourceName, name = title, author = "Fixture author")), more)

    private suspend fun fixture(
        sources: List<BookSource>,
        fetch: suspend (BookSource, Int) -> BookListPage,
        check: suspend (SearchModel, RecordingCallback) -> Unit,
    ) {
        val prior = runCatching { AppConfigProviders.get() }.getOrNull()
        AppConfigProviders.register(NativeAppConfigAccessor(FixturePreferences()))
        val owner = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val callback = RecordingCallback()
        val model = SearchModel(owner, callback, sourceResolver = { sources },
            pageExecutor = { source, number, _ -> fetch(source, number) })
        try {
            withTimeout(10_000) { check(model, callback) }
        } finally {
            withContext(NonCancellable) {
                model.closeAndJoin()
                owner.cancel()
                if (prior != null) AppConfigProviders.register(prior)
            }
        }
    }

    private data class PageEvent(val sourceId: String, val generation: Int, val page: Int, val outcome: SourcePageOutcome)

    private class RecordingCallback : SearchModel.CallBack {
        val resolved = Channel<List<BookSource>>(Channel.UNLIMITED)
        val rounds = Channel<String>(Channel.UNLIMITED)
        val groups = Channel<List<SourceSearchGroup>>(Channel.UNLIMITED)
        val pages = Channel<PageEvent>(Channel.UNLIMITED)
        override fun getSearchScope() = SearchScope("")
        override fun onSearchSourcesResolved(sources: List<BookSource>) { resolved.trySend(sources) }
        override fun onSearchStart() {}
        override fun onSearchSuccess(searchBooks: List<SearchBook>) {}
        override fun onSearchGroupsChanged(groups: List<SourceSearchGroup>) {
            this.groups.trySend(groups.map { it.copy(books = it.books.map { book -> book.copy() }) })
        }
        override fun onSourcePageFinished(sourceId: String, generation: Int, page: Int, outcome: SourcePageOutcome) {
            pages.trySend(PageEvent(sourceId, generation, page, outcome))
        }
        override fun onSearchFinish(isEmpty: Boolean, hasMore: Boolean) { rounds.trySend("finished:$hasMore") }
        override fun onSearchCancel(exception: Throwable?) { rounds.trySend("failed") }
        suspend fun pageUntil(sourceId: String, generation: Int, page: Int): PageEvent {
            while (true) {
                val event = pages.receive()
                if (event.sourceId == sourceId && event.generation == generation && event.page == page) return event
            }
        }
        suspend fun titlesUntil(expected: List<String>): List<SourceSearchGroup> {
            while (true) {
                val snapshot = groups.receive()
                if (snapshot.flatMap { it.books }.map { it.name } == expected) return snapshot
            }
        }
    }

    private class FixturePreferences : PreferenceProvider {
        override fun getString(key: String, default: String) = default
        override fun getStringOrNull(key: String): String? = null
        override fun getInt(key: String, default: Int) = if (key == PreferKey.threadCount) 2 else default
        override fun getBoolean(key: String, default: Boolean) = default
        override fun getLong(key: String, default: Long) = default
        override fun getFloat(key: String, default: Float) = default
        override fun putString(key: String, value: String?): Unit = error("No fixture preference writes")
        override fun putInt(key: String, value: Int): Unit = error("No fixture preference writes")
        override fun putBoolean(key: String, value: Boolean): Unit = error("No fixture preference writes")
        override fun putLong(key: String, value: Long): Unit = error("No fixture preference writes")
        override fun putFloat(key: String, value: Float): Unit = error("No fixture preference writes")
        override fun remove(key: String): Unit = error("No fixture preference writes")
        override fun contains(key: String) = false
        override fun getAll(): Map<String, *> = emptyMap<String, String>()
        override fun addPreferenceChangeListener(listener: (String) -> Unit): () -> Unit = {}
    }
}
