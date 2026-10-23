package io.legado.app.model.audio

import kotlin.math.PI
import kotlin.math.sin
import kotlin.test.Test
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class AudioSpectrumLocalRegressionTest {
    @Test
    fun returnedBandsDistinguishLowAndHighFrequencySignals() {
        fun bands(frequency: Double): DoubleArray {
            val spectrum = AudioSpectrum(48000)
            repeat(1024) { spectrum.pushSample(sin(2 * PI * frequency * it / 48000)) }
            return assertNotNull(spectrum.analyze()).bands.copyOf()
        }
        val low = bands(187.5)
        val high = bands(6000.0)
        assertTrue(low.max() > 1.0, "Low tone must reach the returned bands")
        assertTrue(high.max() > 1.0, "High tone must reach the returned bands")
        assertTrue(low.indices.maxBy { low[it] } < high.indices.maxBy { high[it] })
    }

    @Test
    fun resetRequiresANewWindowAndSilenceClearsReturnedEnergy() {
        val spectrum = AudioSpectrum(48000)
        repeat(1024) { spectrum.pushSample(sin(2 * PI * 187.5 * it / 48000)) }
        assertTrue(assertNotNull(spectrum.analyze()).lowBand > 1.0)
        spectrum.reset()
        assertNull(spectrum.analyze())
        repeat(1024) { spectrum.pushSample(0.0) }
        val silent = assertNotNull(spectrum.analyze())
        assertTrue(silent.bands.all { it == 0.0 })
        assertTrue(silent.lowBand == 0.0)
    }
}
