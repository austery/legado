@file:Suppress("INVISIBLE_REFERENCE", "INVISIBLE_MEMBER")
@file:OptIn(org.jetbrains.compose.resources.InternalResourceApi::class)

package io.legado.app.ui.route

import io.legado.app.constant.AppLog
import io.legado.app.constant.BookType
import io.legado.app.data.AppDbAccessor
import io.legado.app.data.AppDbProviders
import io.legado.app.data.dao.BookmarkDao
import io.legado.app.data.entities.Book
import io.legado.app.data.entities.BookChapter
import io.legado.app.data.entities.BookSource
import io.legado.app.data.entities.Bookmark
import io.legado.app.data.entities.ReplaceRule
import io.legado.app.help.IntentData
import io.legado.app.help.book.BookChapterLoader
import io.legado.app.help.book.ContentProcessorAccessor
import io.legado.app.help.book.ContentProcessorProviders
import io.legado.app.help.config.AppConfigAccessor
import io.legado.app.help.config.AppConfigProviders
import io.legado.app.model.AudioPlayCommander
import io.legado.app.model.AudioPlayCommanders
import io.legado.app.model.AudioPlayShared
import io.legado.app.ui.book.info.BookInfoScreenModel
import io.legado.app.ui.book.info.BookInfoUiEvent
import io.legado.app.ui.book.toc.TocScreenModel
import io.legado.app.ui.book.toc.TocUiEvent
import io.legado.app.ui.book.toc.TocUiState
import io.legado.app.ui.root.AppNavigator
import io.legado.app.ui.root.AppRoute
import io.legado.app.ui.root.RouteResultPayload
import io.legado.app.ui.root.RouteResults
import io.legado.app.ui.root.toRouteRef
import java.lang.reflect.InvocationHandler
import java.lang.reflect.Proxy
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.jetbrains.compose.resources.ResourceEnvironment
import org.jetbrains.compose.resources.LanguageQualifier
import org.jetbrains.compose.resources.RegionQualifier
import org.jetbrains.compose.resources.ThemeQualifier
import org.jetbrains.compose.resources.DensityQualifier
import org.jetbrains.compose.resources.getResourceEnvironment
import org.junit.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** Runs in its own required JVM; no app database, network provider or playback service is used. */
class CatalogReturnRegressionTest {
    @Test
    fun unchangedDetailsHandoffPreservesCompleteCatalog() = runBlocking {
        withFixture { fixture ->
            handoffDetailsCatalog(fixture.details)
            val loaded = BookChapterLoader.loadChapterList(fixture.book, fixture.source)
            assertEquals(fixture.original, loaded)
            fixture.assertNoFixtureErrors()
        }
    }

    @Test
    fun reversingThenReadingFromDetailsPreservesCompleteReversedCatalog() = verifyReentry(selectChapter = false)

    @Test
    fun selectingReversedChapterHandsOffTheSelectedChapterIdentity() = verifyReentry(selectChapter = true)

    private fun verifyReentry(selectChapter: Boolean) = runBlocking {
        withFixture { fixture ->
            reverseTocCatalog(fixture.toc, fixture.navigator, fixture.tocEntry, fixture.scope)
            val expected = fixture.original.reversed().mapIndexed { index, chapter -> chapter.copy(index = index) }
            assertEquals(expected, fixture.toc.state.value.chapters)
            val selected = fixture.toc.state.value.chapters.first()
            if (selectChapter) {
                fixture.book.durChapterIndex = selected.index
                fixture.navigator.pop(RouteResultPayload.Toc(selected.index, 0, true))
            } else {
                fixture.navigator.pop()
            }
            withTimeout(5_000) { fixture.navigator.resultsFor(fixture.detailsEntry).first() }
            // Both production entry paths call this same extracted operation.
            handoffDetailsCatalog(fixture.details)
            val loaded = BookChapterLoader.loadChapterList(fixture.book, fixture.source)
            fixture.navigator.push(AppRoute.AudioPlay(fixture.book.toRouteRef()), RouteResults.READER)
            AudioPlayShared.restoreSource(fixture.book, fixture.source, loaded)
            fixture.navigator.pop()
            withTimeout(5_000) { fixture.navigator.resultsFor(fixture.detailsEntry).first() }
            fixture.navigator.pop()
            val pending = withTimeout(5_000) { fixture.navigator.resultsFor(fixture.outer).first() }.payload as RouteResultPayload.ChangeSource
            assertEquals(expected, pending.toc)
            assertFalse(AudioPlayShared.restoreSource(pending.book, pending.source, pending.toc, pending.audioSourceRevision))
            fixture.assertNoFixtureErrors()
            assertEquals(snapshot(expected, selected.url), snapshot(AudioPlayShared.chapterList.orEmpty(), AudioPlayShared.durChapter?.url, AudioPlayShared.chapterSize, AudioPlayShared.simulatedChapterSize))
        }
    }

    @Test
    fun reversingSearchResultsMustNotTruncateReturnedPlaybackCatalog() = runBlocking {
        withFixture { fixture ->
            fixture.toc.dispatch(TocUiEvent.SetSearchMode(true))
            fixture.toc.dispatch(TocUiEvent.SetQuery("Match"))
            withTimeout(5_000) { fixture.toc.state.first { it.chapters.size == 1 } }
            assertEquals("b-1", fixture.toc.state.value.chapters.single().url)
            reverseTocCatalog(fixture.toc, fixture.navigator, fixture.tocEntry, fixture.scope)
            fixture.toc.dispatch(TocUiEvent.SetSearchMode(false))
            fixture.navigator.pop()
            withTimeout(5_000) { fixture.navigator.resultsFor(fixture.detailsEntry).first() }
            fixture.navigator.pop()
            val pending = withTimeout(5_000) { fixture.navigator.resultsFor(fixture.outer).first() }.payload as RouteResultPayload.ChangeSource
            assertTrue(AudioPlayShared.restoreSource(pending.book, pending.source, pending.toc, pending.audioSourceRevision))
            fixture.assertNoFixtureErrors()
            // Either ignoring reversal while searching or reversing the full catalog is safe.
            // A display projection must never replace the complete playback catalog.
            val actual = AudioPlayShared.chapterList.orEmpty()
            val completeForward = snapshot(fixture.original, "b-0")
            val reversed = fixture.original.reversed().mapIndexed { index, chapter -> chapter.copy(index = index) }
            val completeReverse = snapshot(reversed, "b-2")
            val observed = snapshot(actual, AudioPlayShared.durChapter?.url, AudioPlayShared.chapterSize, AudioPlayShared.simulatedChapterSize)
            assertTrue(observed == completeForward || observed == completeReverse,
                "Expected complete forward $completeForward or complete reverse $completeReverse; actual $observed")
        }
    }

    @Test
    fun clearingSearchDoesNotAuthorizeReversingThePreviousProjection() {
        val filtered = TocUiState.Empty.copy(
            searching = true, searchKey = "Match", catalogSearchKey = "Match",
            chapters = listOf(BookChapter(bookUrl = "b", url = "b-1", index = 1)),
        )
        val clearing = filtered.copy(searching = false, searchKey = "")
        assertFalse(clearing.canReverseCatalog)
        val complete = clearing.copy(
            catalogSearchKey = "",
            chapters = (0..2).map { BookChapter(bookUrl = "b", url = "b-$it", index = it) },
        )
        assertTrue(complete.canReverseCatalog)
    }

    private data class CatalogSnapshot(val count: Int, val identities: List<String>, val indices: List<Int>, val target: String?, val playbackCount: Int, val simulatedCount: Int)
    private fun snapshot(chapters: List<BookChapter>, target: String?, playbackCount: Int = chapters.size, simulatedCount: Int = chapters.size) = CatalogSnapshot(
        chapters.size, chapters.map { "${it.bookUrl}/${it.url}" }, chapters.map { it.index }, target, playbackCount, simulatedCount,
    )

    private suspend fun withFixture(block: suspend (Fixture) -> Unit) {
        val fixture = Fixture()
        try {
            fixture.initialize()
            block(fixture)
        } finally {
            fixture.close()
        }
    }

    private class Fixture {
        // Only desktop resource environment discovery is replaced; resource strings remain real.
        private val previousResourceEnvironment = getResourceEnvironment
        private val previousDb = runCatching { AppDbProviders.get() }.getOrNull()
        private val previousConfig = runCatching { AppConfigProviders.get() }.getOrNull()
        private val previousProcessor = runCatching { ContentProcessorProviders.get() }.getOrNull()
        private val job = SupervisorJob()
        val scope = CoroutineScope(job)
        val book = Book(bookUrl = "fixture-b", origin = "fixture-source", name = "Fixture B", type = BookType.audio or BookType.notShelf, totalChapterNum = 3)
        val source = BookSource(bookSourceUrl = book.origin)
        val original = (0..2).map { BookChapter(bookUrl = book.bookUrl, url = "b-$it", title = if (it == 1) "Match" else "Chapter $it", index = it) }
        private val a = Book(bookUrl = "fixture-a", origin = "source-a", type = BookType.audio or BookType.notShelf)
        val navigator = AppNavigator(AppRoute.AudioPlay(a.toRouteRef()))
        val outer = navigator.currentEntry.id
        val detailsEntry = navigator.push(AppRoute.BookInfo(a.toRouteRef()), RouteResults.BOOK_INFO)
        val details = BookInfoScreenModel(a)
        val tocEntry = navigator.push(AppRoute.Toc(book.toRouteRef()), RouteResults.TOC)
        val toc = TocScreenModel(getChapterFiles = { emptySet() })

        suspend fun initialize() {
            getResourceEnvironment = ::fixtureResourceEnvironment
            AppLog.clear()
            val bookmarks = proxy<BookmarkDao> { _, method, _ ->
                when (method.name) {
                    "flowByBook", "flowSearch" -> flowOf(emptyList<Bookmark>())
                    else -> error("Unexpected bookmark access: ${method.name}")
                }
            }
            AppDbProviders.register(proxy<AppDbAccessor> { _, method, _ ->
                if (method.name == "getBookmarkDao") bookmarks else error("Unexpected database access: ${method.name}")
            })
            AppConfigProviders.register(proxy<AppConfigAccessor> { _, method, _ ->
                when (method.name) {
                    "getTocUiUseReplace", "getTocCountWords" -> false
                    "getChineseConverterType" -> 0
                    else -> error("Unexpected configuration: ${method.name}")
                }
            })
            ContentProcessorProviders.register(proxy<ContentProcessorAccessor> { _, method, _ ->
                if (method.name == "getTitleReplaceRules") emptyList<ReplaceRule>() else error("Unexpected content access: ${method.name}")
            })
            AudioPlayCommanders.register(RecordingCommander())
            AudioPlayShared.book = a
            navigator.registerCatalogHandler(detailsEntry, details::updateLoadedCatalog)
            details.acceptSourceReturn(book, original)
            details.dispatch(BookInfoUiEvent.UpdateBookshelf(false))
            navigator.publishSourceChange(detailsEntry, a, RouteResultPayload.ChangeSource(source, book, original, AudioPlayShared.sourceRevision))
            handoffDetailsCatalog(details)
            toc.dispatch(TocUiEvent.SetBook(book))
            withTimeout(5_000) { toc.state.first { it.chapters.size == 3 } }
        }

        fun assertNoFixtureErrors() = assertTrue(AppLog.logs.isEmpty(), "Fixture failures: ${AppLog.logs}")

        suspend fun close() {
            toc.onCleared()
            details.onCleared()
            job.cancelAndJoin()
            IntentData.chapterList = null
            getResourceEnvironment = previousResourceEnvironment
            if (previousDb != null) AppDbProviders.register(previousDb) else AppDbProviders.unregister()
            previousConfig?.let(AppConfigProviders::register)
            previousProcessor?.let(ContentProcessorProviders::register)
        }
    }

    private class RecordingCommander : AudioPlayCommander {
        override val isServiceRunning = false
        override var pendingTimerMinute = 0
        override val positionMs = 0
        override fun play() = Unit
        override fun stop() = Unit
        override fun stopPlay() = Unit
        override fun pause() = Unit
        override fun resume() = Unit
        override fun adjustSpeed(adjust: Float) = Unit
        override fun adjustProgress(position: Int) = Unit
        override fun setTimer(minute: Int) = Unit
        override fun addTimer() = Unit
        override fun loadPlayUrl() = Unit
    }

    companion object {
        private fun fixtureResourceEnvironment() = ResourceEnvironment(
            LanguageQualifier("en"), RegionQualifier("US"), ThemeQualifier.LIGHT, DensityQualifier.MDPI,
        )

        private inline fun <reified T> proxy(handler: InvocationHandler): T =
            Proxy.newProxyInstance(T::class.java.classLoader, arrayOf(T::class.java), handler) as T
    }
}
