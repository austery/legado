package io.legado.app.model.script

import io.legado.app.data.entities.BookSource
import io.legado.app.help.image.IosImageOps
import io.legado.app.model.analyzeRule.AnalyzeRuleCore
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

class NativeJsRuleBridgeTest {
    @Test
    fun scriptCannotCloseItsExecutingAnalyzer() {
        registerNativeJsEngines(IosImageOps)
        for (source in listOf(null, BookSource(), BookSource().apply { jsLib = "var sharedMarker = 1;" })) {
            val analyzer = AnalyzeRuleCore(source = source)
            try {
                assertEquals("undefined", analyzer.evalJS("typeof java.close"))
                assertFailsWith<RuntimeException> { analyzer.evalJS("java.close(); 'unsafe'") }
                assertEquals("alive", analyzer.evalJS("java.evalJS(\"'alive'\")"))
            } finally {
                analyzer.close()
            }
        }
    }

    @Test
    fun cssAndXPathReturnNodeCollectionsThroughBothMethods() = withAnalyzer {
        setContent("<html><body><span>one</span><span>two</span></body></html>")
        for (rule in listOf("span", "@XPath://span")) {
            for (method in listOf("getElement", "getElements")) {
                assertEquals("one,two", evalJS("java.$method('$rule').map(function(node) { return node.text(); }).join(',')"))
            }
        }
        assertEquals(0, evalJS("java.getElements('missing').length"))
    }

    @Test
    fun jsonResultsPreserveObjectsScalarsAndNulls() = withAnalyzer {
        setContent("""{"items":[{"name":"one"},7,"two",true,null],"count":3}""")
        assertEquals("one:7:two:true:true", evalJS("""
            var values = java.getElements('$.items[*]');
            [values[0].name, values[1], values[2], values[3], values[4] === null].join(':');
        """.trimIndent()))
        assertEquals(true, evalJS("java.getElement('$.count') === 3"))
        assertEquals("one", evalJS("java.getElement('$.items[0]').name"))
    }

    @Test
    fun regexResultsPreserveNestedCaptureGroups() = withAnalyzer {
        setContent("a1 b2")
        assertEquals("a1:a:1", evalJS("java.getElement(':([a-z])([0-9])').join(':')"))
        assertEquals("a1:a:1|b2:b:2", evalJS("""
            java.getElements(':([a-z])([0-9])').map(function(groups) { return groups.join(':'); }).join('|');
        """.trimIndent()))
    }

    @Test
    fun decompressionAcceptsIntegerArraysFromJavaScriptAndNativeByteReturns() = withAnalyzer {
        assertEquals("Native bridge", evalJS("java.decompressString([31,139,8,0,0,0,0,0,2,255,243,75,44,201,44,75,85,72,42,202,76,73,79,5,0,21,118,84,148,13,0,0,0], 'gzip', 'UTF-8')"))
        assertEquals("Native bridge", evalJS("java.decompressString(java.base64DecodeToByteArray('H4sIAAAAAAAC//NLLMksS1VIKspMSU8FABV2VJQNAAAA'), 'gzip', 'UTF-8')"))
        assertEquals("78,97,116,105,118,101,32,98,114,105,100,103,101", evalJS("java.decompressBytes([31,139,8,0,0,0,0,0,2,255,243,75,44,201,44,75,85,72,42,202,76,73,79,5,0,21,118,84,148,13,0,0,0], 'gzip').join(',')"))
        assertEquals("Native bridge", evalJS("java.decompressString([120,156,243,75,44,201,44,75,85,72,42,202,76,73,79,5,0,34,92,4,245], 'zlib', 'UTF-8')"))
        assertEquals("Native bridge", evalJS("java.decompressString(java.base64DecodeToByteArray('eJzzSyzJLEtVSCrKTElPBQAiXAT1'), 'zlib', 'UTF-8')"))
        assertEquals("78,97,116,105,118,101,32,98,114,105,100,103,101", evalJS("java.decompressBytes([120,156,243,75,44,201,44,75,85,72,42,202,76,73,79,5,0,34,92,4,245], 'zlib').join(',')"))
        assertEquals("Native bridge", evalJS("java.decompressString([243,75,44,201,44,75,85,72,42,202,76,73,79,5,0], 'deflate', 'UTF-8')"))
        assertEquals("Native bridge", evalJS("java.decompressString(java.base64DecodeToByteArray('80ssySxLVUgqykxJTwUA'), 'deflate', 'UTF-8')"))
        assertEquals("78,97,116,105,118,101,32,98,114,105,100,103,101", evalJS("java.decompressBytes([243,75,44,201,44,75,85,72,42,202,76,73,79,5,0], 'deflate').join(',')"))
        assertEquals("", evalJS("java.decompressString([1,2,3], 'gzip', 'UTF-8')"))
        assertEquals(true, evalJS("java.decompressBytes([1,2,3], 'gzip') === null"))
    }

    private fun withAnalyzer(block: AnalyzeRuleCore.() -> Unit) {
        registerNativeJsEngines(IosImageOps)
        val analyzer = AnalyzeRuleCore()
        try { analyzer.block() } finally { analyzer.close() }
    }
}
