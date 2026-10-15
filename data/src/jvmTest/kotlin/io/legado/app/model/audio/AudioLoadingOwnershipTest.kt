package io.legado.app.model.audio

import io.legado.app.data.entities.Book
import io.legado.app.data.entities.BookSource
import io.legado.app.model.AudioPlayShared
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import org.junit.Test
import kotlin.coroutines.CoroutineContext
import kotlin.test.assertEquals
import kotlin.test.assertNotEquals

class AudioLoadingOwnershipTest {
    private class QueuedDispatcher : CoroutineDispatcher() {
        val tasks = ArrayDeque<Runnable>()
        override fun dispatch(context: CoroutineContext, block: Runnable) { tasks.addLast(block) }
        fun drain() { while (tasks.isNotEmpty()) tasks.removeFirst().run() }
    }

    @Test fun pauseBeforeLaunchDoesNotPermanentlyLockTheChapter() {
        val dispatcher = QueuedDispatcher()
        val scope = CoroutineScope(SupervisorJob() + dispatcher)
        val messages = mutableListOf<String>()
        val controller = object : AudioPlayController {
            override val isPlaying = false
            override val duration = 0L
            override val currentPosition = 0L
            override val bufferedPosition = 0L
            override val playbackState = AudioPlayController.STATE_IDLE
            override var playWhenReady = false
            override var listener: AudioPlayControllerListener? = null
            override fun play() = Unit
            override fun pause() = Unit
            override fun stop() = Unit
            override fun seekTo(position: Long) = Unit
            override fun setPlaybackSpeed(speed: Float) = Unit
            override suspend fun prepare() = Unit
            override fun release() = Unit
        }
        val factory = AudioPlayAnalyzeRuleFactory { _, _, _, _ -> error("No rule execution expected") }
        val host = object : AudioPlaySessionHost {
            override val controller = controller
            override val scope = scope
            override val analyzeRuleFactory = factory
            override var pendingTimerMinute = 0
            override suspend fun startPlayback(url: String, positionMs: Int) = Unit
            override fun toast(message: String) { messages.add(message) }
        }
        val manager = AudioPlayManager(controller, scope, factory, AudioPlaySession(host))
        val oldBook = AudioPlayShared.book
        val oldSource = AudioPlayShared.bookSource
        try {
            AudioPlayShared.book = Book(bookUrl = "fixture", name = "Fixture")
            AudioPlayShared.bookSource = BookSource(bookSourceUrl = "fixture")
            manager.loadPlayUrl()
            manager.cancelContentLoad()
            dispatcher.drain()
            AudioPlayShared.book = null
            manager.loadPlayUrl()
            assertEquals(listOf("book or source is null"), messages)
            val old = manager.beginLoading()
            manager.clearLoading()
            val current = manager.beginLoading()
            assertNotEquals(old, current)
            manager.endLoading(old)
            manager.endLoading(current)
        } finally {
            scope.cancel()
            dispatcher.drain()
            AudioPlayShared.book = oldBook
            AudioPlayShared.bookSource = oldSource
        }
    }
}
