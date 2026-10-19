package io.legado.app.model.audio

import io.legado.app.data.entities.Book
import io.legado.app.data.entities.BookChapter
import io.legado.app.data.entities.BookSource
import io.legado.app.model.AudioPlayCommander
import io.legado.app.model.AudioPlayCommanders
import io.legado.app.model.AudioPlayShared
import io.legado.app.model.chapter.resolveChapter
import io.legado.app.ui.root.AppNavigator
import io.legado.app.ui.root.AppRoute
import io.legado.app.ui.root.RouteResults
import io.legado.app.ui.root.RouteResultPayload
import io.legado.app.ui.root.toRouteRef
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertSame

/** Runs in its own JVM via audioSourceReturnTest; never shares playback providers with other tests. */
class AudioSourceReturnTest {
    @Test
    fun returningFromDetailsReplacesIdentityCatalogAndPlaybackPosition() = runBlocking {
        val commander = RecordingCommander()
        AudioPlayCommanders.register(commander)
        val old = Book(bookUrl = "book-a", origin = "source-a")
        AudioPlayShared.book = old
        AudioPlayShared.chapterList = listOf(BookChapter(bookUrl = "book-a", url = "old"))
        AudioPlayShared.durPlayUrl = "old-media"
        val replacement = Book(bookUrl = "book-b", origin = "source-b", durChapterIndex = 1, durChapterPos = 345)
        val source = BookSource(bookSourceUrl = "source-b")
        val chapters = (0..2).map { BookChapter(bookUrl = "book-b", url = "b-$it", index = it, title = "Chapter $it") }
        AudioPlayShared.restoreSource(replacement, source, chapters)
        assertEquals(1, commander.stopped)
        assertSame(replacement, AudioPlayShared.book)
        assertSame(source, AudioPlayShared.bookSource)
        assertEquals(3, AudioPlayShared.simulatedChapterSize)
        assertEquals("b-1", AudioPlayShared.durChapter?.url)
        assertEquals(345, AudioPlayShared.durChapterPos)
        assertEquals("", AudioPlayShared.durPlayUrl)
        assertEquals("b-2", resolveChapter(replacement, 2, AudioPlayShared.chapterList)?.url)
        assertFailsWith<IllegalArgumentException> {
            AudioPlayShared.restoreSource(old, source, chapters)
        }
        assertSame(replacement, AudioPlayShared.book)
        assertEquals(1, commander.stopped)
    }
    @Test
    fun nestedSourceChangeMustNotBeOverwrittenByOuterPendingResult() = runBlocking {
        val commander = RecordingCommander()
        AudioPlayCommanders.register(commander)
        fun book(id: String) = Book(bookUrl = id, origin = "source-$id", durChapterPos = 123)
        fun source(id: String) = BookSource(bookSourceUrl = "source-$id")
        fun toc(id: String) = listOf(BookChapter(bookUrl = id, url = "$id-0", title = id))
        val a = book("a")
        val b = book("b")
        val c = book("c")
        AudioPlayShared.restoreSource(a, source("a"), toc("a"))
        val navigator = AppNavigator(AppRoute.AudioPlay(a.toRouteRef()))
        val outer = navigator.currentEntry.id
        val details = navigator.push(AppRoute.BookInfo(a.toRouteRef()), RouteResults.BOOK_INFO)
        navigator.setPendingResult(details, RouteResultPayload.ChangeSource(source("b"), b, toc("b"), AudioPlayShared.sourceRevision))
        navigator.push(AppRoute.AudioPlay(b.toRouteRef()), RouteResults.READER)
        AudioPlayShared.restoreSource(b, source("b"), toc("b"))
        AudioPlayShared.restoreSource(c, source("c"), toc("c"))
        AudioPlayShared.durChapterPos = 456
        AudioPlayShared.durPlayUrl = "current-c-media"
        val stoppedBeforeReturn = commander.stopped
        navigator.pop()
        withTimeout(1000) { navigator.resultsFor(details).first() }
        navigator.pop()
        val pending = withTimeout(1000) { navigator.resultsFor(outer).first() }.payload as RouteResultPayload.ChangeSource
        assertEquals(false, AudioPlayShared.restoreSource(pending.book, pending.source, pending.toc, pending.audioSourceRevision))
        assertSame(c, AudioPlayShared.book)
        assertEquals("source-c", AudioPlayShared.bookSource?.bookSourceUrl)
        assertEquals("c-0", AudioPlayShared.durChapter?.url)
        assertEquals(456, AudioPlayShared.durChapterPos)
        assertEquals("current-c-media", AudioPlayShared.durPlayUrl)
        assertEquals(stoppedBeforeReturn, commander.stopped)
    }

    @Test
    fun latestDirectDetailChangeStillAppliesToTheObservedPlayback() = runBlocking {
        AudioPlayCommanders.register(RecordingCommander())
        val a = Book(bookUrl = "direct-a", origin = "a")
        AudioPlayShared.book = a
        val revision = AudioPlayShared.sourceRevision
        val navigator = AppNavigator(AppRoute.AudioPlay(a.toRouteRef()))
        val outer = navigator.currentEntry.id
        val details = navigator.push(AppRoute.BookInfo(a.toRouteRef()), RouteResults.BOOK_INFO)
        for (id in listOf("b", "d")) {
            val book = Book(bookUrl = id, origin = id)
            navigator.setPendingResult(details, RouteResultPayload.ChangeSource(
                BookSource(bookSourceUrl = id), book,
                listOf(BookChapter(bookUrl = id, url = "$id-0", title = id)), revision,
            ))
        }
        // A metadata refresh of the same identity does not invalidate the source change.
        AudioPlayShared.book = a.copy(name = "Updated title")
        navigator.pop()
        val result = withTimeout(1000) { navigator.resultsFor(outer).first() }.payload as RouteResultPayload.ChangeSource
        assertEquals(true, AudioPlayShared.restoreSource(result.book, result.source, result.toc, result.audioSourceRevision))
        assertEquals("d", AudioPlayShared.book?.bookUrl)
        assertEquals("d-0", AudioPlayShared.durChapter?.url)
    }

    @Test
    fun nestedTextMigrationReturnsLatestIdentityWithoutChangingAudioRevision() = runBlocking {
        AudioPlayCommanders.register(RecordingCommander())
        val a = Book(bookUrl = "audio-a", origin = "a")
        AudioPlayShared.book = a
        val revision = AudioPlayShared.sourceRevision
        val navigator = AppNavigator(AppRoute.AudioPlay(a.toRouteRef()))
        val outer = navigator.currentEntry.id
        val details = navigator.push(AppRoute.BookInfo(a.toRouteRef()), RouteResults.BOOK_INFO)
        val b = Book(bookUrl = "text-b", origin = "b")
        val c = Book(bookUrl = "text-c", origin = "c")
        fun result(book: Book) = RouteResultPayload.ChangeSource(
            BookSource(bookSourceUrl = book.origin), book,
            listOf(BookChapter(bookUrl = book.bookUrl, url = "${book.bookUrl}-0")), revision,
        )
        navigator.publishSourceChange(details, a, result(b))
        val reader = navigator.push(AppRoute.Reader(b.toRouteRef()), RouteResults.READER)
        navigator.publishSourceChange(reader, b, result(c).copy(audioSourceRevision = null))
        navigator.pop()
        assertSame(c, (withTimeout(1000) { navigator.resultsFor(details).first() }.payload as RouteResultPayload.ChangeSource).book)
        navigator.pop()
        val returned = withTimeout(1000) { navigator.resultsFor(outer).first() }.payload as RouteResultPayload.ChangeSource
        assertSame(c, returned.book)
        assertEquals("c", returned.source.bookSourceUrl)
        assertEquals(revision, returned.audioSourceRevision)
        assertEquals(true, AudioPlayShared.isCurrentSourceReturn(returned.audioSourceRevision))
        assertSame(a, AudioPlayShared.book)
    }

    @Test
    fun refreshedCatalogReplacesPendingSnapshot() = verifyCatalogReturn(reverse = false)

    @Test
    fun reversedCatalogReplacesPendingSnapshot() = verifyCatalogReturn(reverse = true)

    private fun verifyCatalogReturn(reverse: Boolean) = runBlocking {
        AudioPlayCommanders.register(RecordingCommander())
        val a = Book(bookUrl = "catalog-a", origin = "a")
        val b = Book(bookUrl = "catalog-b", origin = "b")
        AudioPlayShared.book = a
        val navigator = AppNavigator(AppRoute.AudioPlay(a.toRouteRef()))
        val outer = navigator.currentEntry.id
        val details = navigator.push(AppRoute.BookInfo(a.toRouteRef()), RouteResults.BOOK_INFO)
        val old = listOf(BookChapter(bookUrl = b.bookUrl, url = "old"))
        navigator.publishSourceChange(details, a, RouteResultPayload.ChangeSource(
            BookSource(bookSourceUrl = b.origin), b, old, AudioPlayShared.sourceRevision,
        ))
        val refreshed = (0..2).map { BookChapter(bookUrl = b.bookUrl, url = "fresh-$it", index = it) }
        navigator.updateSourceCatalog(details, b, refreshed)
        val toc = navigator.push(AppRoute.Toc(b.toRouteRef()), RouteResults.TOC)
        val reversed = refreshed.reversed().mapIndexed { index, chapter -> chapter.copy(index = index) }
        if (reverse) navigator.updateSourceCatalog(toc, b, reversed)
        // An obsolete loader for A cannot replace B's pending catalog.
        navigator.updateSourceCatalog(details, a, listOf(BookChapter(bookUrl = a.bookUrl, url = "obsolete")))
        navigator.pop()
        withTimeout(1000) { navigator.resultsFor(details).first() }
        navigator.pop()
        val returned = withTimeout(1000) { navigator.resultsFor(outer).first() }.payload as RouteResultPayload.ChangeSource
        val expected = if (reverse) listOf("fresh-2", "fresh-1", "fresh-0") else listOf("fresh-0", "fresh-1", "fresh-2")
        assertEquals(expected, returned.toc.map { it.url })
        assertEquals(true, AudioPlayShared.restoreSource(returned.book, returned.source, returned.toc, returned.audioSourceRevision))
        assertEquals(expected.first(), AudioPlayShared.durChapter?.url)
    }

    private class RecordingCommander : AudioPlayCommander {
        var stopped = 0
        override val isServiceRunning = false
        override var pendingTimerMinute = 0
        override val positionMs = 0
        override fun play() = Unit
        override fun stop() = Unit
        override fun stopPlay() { stopped++ }
        override fun pause() = Unit
        override fun resume() = Unit
        override fun adjustSpeed(adjust: Float) = Unit
        override fun adjustProgress(position: Int) = Unit
        override fun setTimer(minute: Int) = Unit
        override fun addTimer() = Unit
        override fun loadPlayUrl() = Unit
    }

}
