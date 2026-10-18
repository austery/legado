package io.legado.app.model.script

import io.legado.app.help.image.IosImageOps
import io.legado.app.model.analyzeRule.AnalyzeRuleCore
import kotlin.experimental.ExperimentalNativeApi
import kotlin.native.ref.WeakReference
import kotlin.native.runtime.GC
import kotlin.native.runtime.NativeRuntimeApi
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

@OptIn(ExperimentalNativeApi::class, NativeRuntimeApi::class)
class NativeJsAnalyzerLifetimeTest {
    @Test
    fun chainedAnalyzerIsReleasedAfterScriptCloses() {
        registerNativeJsEngines(IosImageOps)
        val reference = evaluateAndClose()
        GC.collect()
        assertNull(reference.get(), "Completed scripts must not retain their analyzer and content")
    }

    private fun evaluateAndClose(): WeakReference<AnalyzeRuleCore> {
        val analyzer = AnalyzeRuleCore()
        val reference = WeakReference(analyzer)
        try {
            repeat(3) {
                assertEquals("Retained title", analyzer.evalJS(
                    "java.setContent('<span>Retained title</span>').setBaseUrl('https://fixture.invalid/').getString('span@text');"))
            }
        } finally {
            analyzer.close()
        }
        return reference
    }
}
