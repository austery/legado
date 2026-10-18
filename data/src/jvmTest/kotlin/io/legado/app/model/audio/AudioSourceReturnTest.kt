package io.legado.app.model.audio

import io.legado.app.data.entities.Book
import io.legado.app.data.entities.BookChapter
import io.legado.app.data.entities.BookSource
import io.legado.app.model.AudioPlayCommander
import io.legado.app.model.AudioPlayCommanders
import io.legado.app.model.AudioPlayShared
import io.legado.app.model.chapter.resolveChapter
import kotlinx.coroutines.runBlocking
import org.junit.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertSame

/** Runs in its own JVM via audioSourceReturnTest; never shares playback providers with other tests. */
class AudioSourceReturnTest {
    @Test
    fun returningFromDetailsReplacesIdentityCatalogAndPlaybackPosition() = runBlocking {
        var stopped = 0
        val commander = object : AudioPlayCommander {
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
        AudioPlayCommanders.register(commander)
        val old = Book(bookUrl = "book-a", origin = "source-a")
        AudioPlayShared.book = old
        AudioPlayShared.chapterList = listOf(BookChapter(bookUrl = "book-a", url = "old"))
        AudioPlayShared.durPlayUrl = "old-media"
        val replacement = Book(bookUrl = "book-b", origin = "source-b", durChapterIndex = 1, durChapterPos = 345)
        val source = BookSource(bookSourceUrl = "source-b")
        val chapters = (0..2).map { BookChapter(bookUrl = "book-b", url = "b-$it", index = it, title = "Chapter $it") }
        AudioPlayShared.restoreSource(replacement, source, chapters)
        assertEquals(1, stopped)
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
        assertEquals(1, stopped)
    }
}
