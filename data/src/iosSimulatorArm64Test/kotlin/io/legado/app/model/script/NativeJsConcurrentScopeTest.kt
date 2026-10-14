package io.legado.app.model.script

import com.fleeksoft.ksoup.Ksoup
import io.legado.app.help.image.IosImageOps
import io.legado.app.help.source.SourceNetworkProvider
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.DelicateCoroutinesApi
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.newSingleThreadContext
import kotlinx.coroutines.runBlocking
import platform.Foundation.NSCondition
import platform.Foundation.NSDate
import platform.Foundation.dateWithTimeIntervalSinceNow
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** Exercises real JS/DOM behavior; the external Cookie host only schedules calls. */
@OptIn(DelicateCoroutinesApi::class, ExperimentalCoroutinesApi::class)
class NativeJsConcurrentScopeTest {
    @Test
    fun selectedNodeSurvivesAnotherIndependentScriptEnding() = runBlocking {
        registerNativeJsEngines(IosImageOps)
        val host = CookieBarrier()
        val engine: JsEngine = NativeJsEngine
        newSingleThreadContext("source-a").use { firstThread ->
            newSingleThreadContext("source-b").use { secondThread ->
                val first = async(firstThread) {
                    val scope = engine.getRuntimeScope(JsBindings().apply {
                        this["cookie"] = host
                        this["src"] = Ksoup.parse("<span>Retained source title</span>")
                    })
                    try {
                        assertEquals("Retained source title",
                            engine.eval("src.select('span')[0].text()", scope, null))
                        engine.eval(
                            """
                            cookie.getCookie('a-enter');
                            var node = src.select('span')[0];
                            cookie.getCookie('a-node');
                            node.text();
                            """.trimIndent(), scope, null
                        )
                    } finally {
                        scope.close()
                    }
                }
                val second = async(secondThread) {
                    host.awaitFirst()
                    val scope = engine.getRuntimeScope(JsBindings().apply {
                        this["cookie"] = host
                    })
                    try {
                        engine.eval("cookie.getCookie('b-enter'); 'peer-complete';", scope, null)
                    } finally {
                        scope.close()
                        host.closed()
                    }
                }
                val observed = first.await()
                assertEquals("peer-complete", second.await())
                assertEquals("a-enter -> b-enter -> a-node -> b-closed", host.schedule())
                println("SPEC004 concurrent DOM result=$observed schedule=${host.schedule()}")
                assertEquals("Retained source title", observed,
                    "A live script's DOM node must survive another independent script ending")
            }
        }
    }

    @Test
    fun nestedScriptRestoresOuterContext() = verifyNestedContext(false)

    @Test
    fun throwingNestedScriptRestoresOuterContext() = verifyNestedContext(true)

    @Test
    fun sharedScopeRestoresOuterCancellationAfterNestedScript() = verifySharedCancellation(false)

    @Test
    fun sharedScopeRestoresOuterCancellationAfterThrowingNestedScript() = verifySharedCancellation(true)

    private fun verifySharedCancellation(throwInner: Boolean) {
        registerNativeJsEngines(IosImageOps)
        val engine: JsEngine = NativeJsEngine
        val outerJob = Job()
        val innerJob = Job()
        val host = SharedScopeCookieHost(engine, outerJob, innerJob, throwInner)
        val scope = NativeQuickJsSharedJsScopeProvider.getScope(
            "var sharedFixture = 'ready';", false, null) ?: error("Missing fixture scope")
        host.scope = scope
        try {
            val compiled = engine.compileForSubScope("cookie.getCookie('nested');")
            val result = engine.evalInSubScope(compiled, scope,
                JsBindings().apply { this["cookie"] = host }, outerJob)
            assertEquals("cancelled", result,
                "A nested call must not remove the outer script's cancellation context")
            assertEquals(throwInner, host.innerThrew)
            assertTrue(innerJob.isActive, "The independent inner operation must remain active")
        } finally {
            outerJob.cancel()
            innerJob.cancel()
        }
    }

    private class SharedScopeCookieHost(
        private val engine: JsEngine,
        private val outerJob: Job,
        private val innerJob: Job,
        private val throwInner: Boolean,
    ) : SourceNetworkProvider {
        lateinit var scope: JsScope
        var innerThrew = false

        override fun getCookie(tag: String): String {
            val inner = engine.compileForSubScope(
                if (throwInner) "throw new Error('Nested shared fixture')" else "'inner-complete'")
            try {
                engine.evalInSubScope(inner, scope, JsBindings(), innerJob)
            } catch (error: Exception) {
                innerThrew = true
            }
            outerJob.cancel()
            return try {
                engine.currentContextNonNull().ensureActive()
                "incorrectly-active"
            } catch (error: CancellationException) {
                "cancelled"
            }
        }
        override fun replaceCookie(tag: String, cookie: String): Unit =
            error("Cookie writes are outside this fixture")
        override fun removeCookie(tag: String): Unit =
            error("Cookie writes are outside this fixture")
    }

    private fun verifyNestedContext(throwInner: Boolean) {
        registerNativeJsEngines(IosImageOps)
        val engine: JsEngine = NativeJsEngine
        val host = NestedCookieHost(engine, throwInner)
        val scope = engine.getRuntimeScope(JsBindings().apply {
            this["cookie"] = host
            this["src"] = Ksoup.parse("<span>Outer title</span>")
        })
        host.expectedOuterScope = scope
        try {
            val observed = engine.eval(
                "cookie.getCookie('nested'); src.select('span')[0].text();", scope, null)
            assertEquals("Outer title", observed)
            assertTrue(host.outerContextRestored, "Nested execution must restore the live outer context")
            assertEquals(throwInner, host.innerThrew)
            if (!throwInner) assertEquals("Inner title", host.innerResult)
        } finally {
            scope.close()
        }
    }

    private class NestedCookieHost(
        private val engine: JsEngine,
        private val throwInner: Boolean,
    ) : SourceNetworkProvider {
        lateinit var expectedOuterScope: JsScope
        var outerContextRestored = false
        var innerThrew = false
        var innerResult: String? = null

        override fun getCookie(tag: String): String {
            val inner = engine.getRuntimeScope(JsBindings())
            try {
                innerResult = engine.eval(
                    if (throwInner) "throw new Error('Nested fixture error')" else "'Inner title'",
                    inner, null) as? String
            } catch (error: Exception) {
                innerThrew = true
            } finally {
                inner.close()
            }
            outerContextRestored = engine.currentContextNonNull() === expectedOuterScope
            return "fixture-cookie"
        }
        override fun replaceCookie(tag: String, cookie: String): Unit =
            error("Cookie writes are outside this fixture")
        override fun removeCookie(tag: String): Unit =
            error("Cookie writes are outside this fixture")
    }

    private class CookieBarrier : SourceNetworkProvider {
        private val condition = NSCondition()
        private var first = false
        private var second = false
        private var node = false
        private var peerClosed = false
        private val events = mutableListOf<String>()

        override fun getCookie(tag: String): String = locked {
            events.add(tag)
            when (tag) {
                "a-enter" -> {
                    first = true
                    condition.broadcast()
                    await { second }
                }
                "b-enter" -> {
                    second = true
                    condition.broadcast()
                    await { node }
                }
                "a-node" -> {
                    node = true
                    condition.broadcast()
                    await { peerClosed }
                }
                else -> error("Unexpected fixture tag: $tag")
            }
            "fixture-cookie"
        }

        override fun replaceCookie(tag: String, cookie: String): Unit =
            error("Cookie writes are outside this fixture")
        override fun removeCookie(tag: String): Unit =
            error("Cookie writes are outside this fixture")

        fun awaitFirst() = locked { await { first } }
        fun closed() = locked {
            events.add("b-closed")
            peerClosed = true
            condition.broadcast()
        }
        fun schedule(): String = locked { events.joinToString(" -> ") }

        private fun await(predicate: () -> Boolean) {
            val deadline = NSDate.dateWithTimeIntervalSinceNow(10.0)
            while (!predicate()) {
                check(condition.waitUntilDate(deadline)) { "Fixture timed out: $events" }
            }
        }
        private fun <T> locked(action: () -> T): T {
            condition.lock()
            return try { action() } finally { condition.unlock() }
        }
    }
}
