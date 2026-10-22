package io.legado.app.ui.book.audio

import io.legado.app.model.LrcParser
import kotlin.test.Test
import kotlin.test.assertEquals

class LrcTimingTest {
    @Test
    fun qrcWordCompletedBeforeZeroDoesNotAnimateAgain() {
        val line = LrcParser.parse(listOf("[offset:400]\n[100,200]A(100,200)")).lines.single()
        for (next in listOf(null, 1000)) {
            val samples = line.fillSamples(next)
            assertEquals(0, samples.last().timeMs)
            assertEquals(1f, samples.charProgressAt(0))
        }
    }

    @Test
    fun qrcWordCrossingZeroFinishesAtShiftedEnd() {
        val line = LrcParser.parse(listOf("[offset:200]\n[100,200]A(100,200)")).lines.single()
        val samples = line.fillSamples(1000)
        assertEquals(0f, samples.charProgressAt(0))
        assertEquals(0.5f, samples.charProgressAt(50))
        assertEquals(1f, samples.charProgressAt(100))
    }

    @Test
    fun enhancedLrcWithoutEndStillUsesNextLine() {
        val line = LrcParser.parse(listOf("[00:00.000]<00:00.000>A")).lines.single()
        val samples = line.fillSamples(1000)
        assertEquals(0.5f, samples.charProgressAt(500))
        assertEquals(1f, samples.charProgressAt(1000))
    }
}
