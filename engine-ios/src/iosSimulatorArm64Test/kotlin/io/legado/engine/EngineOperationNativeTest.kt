package io.legado.engine

import io.legado.app.data.entities.BookSource
import io.legado.app.help.image.IosImageOps
import io.legado.app.help.source.SourceNetworkProvider
import io.legado.app.model.analyzeRule.AnalyzeRuleCore
import io.legado.app.model.script.JsBindings
import io.legado.app.model.script.JsHostFailureObserver
import io.legado.app.model.script.NativeJsEngine
import io.legado.app.model.script.registerNativeJsEngines
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.job
import kotlinx.coroutines.supervisorScope
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.DelicateCoroutinesApi
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.newSingleThreadContext
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlin.test.assertFailsWith

/** Real native JS and engine providers, with no database initialization. */
@OptIn(DelicateCoroutinesApi::class, ExperimentalCoroutinesApi::class)
class EngineOperationNativeTest {
    @Test
    fun interactionInOneOperationDoesNotFailAnotherSuccessfulOperation() = runBlocking {
        withTimeout(15_000) {
            registerNativeJsEngines(IosImageOps)
            EngineHost.registerInteractionProviders()
            val peerStarted = CompletableDeferred<Unit>()
            val rejected = CompletableDeferred<Unit>()
            newSingleThreadContext("interaction-source").use { firstThread ->
                newSingleThreadContext("successful-source").use { secondThread ->
                    val first = async(firstThread) {
                        EngineHost.withOperation {
                            peerStarted.await()
                            assertEquals("after-interaction", evaluate(
                                "java.startBrowser('https://fixture.invalid/login', 'Verify'); 'after-interaction';"))
                            rejected.complete(Unit)
                            EngineHost.interactionFailure()
                        }
                    }
                    val second = async(secondThread) {
                        EngineHost.withOperation {
                            peerStarted.complete(Unit)
                            rejected.await()
                            assertEquals("usable candidate", evaluate("'usable candidate'"))
                            EngineHost.interactionFailure()
                        }
                    }
                    assertEquals(EngineErrorCode.INTERACTION_REQUIRED, first.await()?.code)
                    assertNull(second.await(), "A successful source must not inherit a peer's interaction failure")
                }
            }
        }
    }

    @Test
    fun cancelledScriptDoesNotPublishAResultOrCancelAnotherOperation() = runBlocking {
        withTimeout(15_000) {
            registerNativeJsEngines(IosImageOps)
            EngineHost.registerInteractionProviders()
            supervisorScope {
                val cancellationReached = CompletableDeferred<Unit>()
                val publishedResult = CompletableDeferred<String?>()
                newSingleThreadContext("cancelled-source").use { firstThread ->
                    newSingleThreadContext("surviving-source").use { secondThread ->
                        val first = async(firstThread) {
                            val result = EngineHost.withOperation {
                                val cookie = CancellingCookie(currentCoroutineContext().job, cancellationReached)
                                evaluate("cookie.getCookie('cancel'); 'must-not-complete';", cookie)
                            }
                            publishedResult.complete(result)
                        }
                        val second = async(secondThread) {
                            EngineHost.withOperation {
                                cancellationReached.await()
                                assertEquals("surviving candidate", evaluate("'surviving candidate'"))
                                EngineHost.interactionFailure()
                            }
                        }
                        assertFailsWith<CancellationException> { first.await() }
                        assertNull(second.await(), "Cancelling one source must not fail its peer")
                        assertFalse(publishedResult.isCompleted,
                            "A cancelled native script must not publish a successful operation result")
                    }
                }
            }
        }
    }

    @Test
    fun nestedOperationRestoresOuterFailureAfterSuccessAndScriptFailure() = runBlocking {
        withTimeout(15_000) {
            registerNativeJsEngines(IosImageOps)
            EngineHost.registerInteractionProviders()
            EngineHost.withOperation {
                assertEquals("outer value", evaluate(
                    "java.startBrowser('https://fixture.invalid/login', 'Verify'); 'outer value';"))
                assertEquals(EngineErrorCode.INTERACTION_REQUIRED, EngineHost.interactionFailure()?.code)
                EngineHost.withOperation {
                    assertNull(EngineHost.interactionFailure())
                    assertEquals("inner candidate", evaluate("'inner candidate'"))
                    assertNull(EngineHost.interactionFailure())
                }
                assertEquals(EngineErrorCode.INTERACTION_REQUIRED, EngineHost.interactionFailure()?.code,
                    "A successful nested operation must restore the outer failure")
                var innerScriptFailed = false
                try {
                    EngineHost.withOperation {
                        assertNull(EngineHost.interactionFailure())
                        evaluate("throw new Error('Controlled nested script failure');")
                        error("The fixture script must throw")
                    }
                } catch (error: Exception) {
                    assertTrue(NativeJsEngine.isJsException(error), "Expected the real native script failure")
                    innerScriptFailed = true
                }
                assertTrue(innerScriptFailed)
                assertEquals(EngineErrorCode.INTERACTION_REQUIRED, EngineHost.interactionFailure()?.code,
                    "A failing nested operation must restore the outer failure")
                assertEquals("outer continuation", evaluate("'outer continuation'"))
            }
            EngineHost.withOperation {
                assertEquals("new operation", evaluate("'new operation'"))
                assertNull(EngineHost.interactionFailure(), "Completed outer failure must not leak to a new operation")
            }
        }
    }

    @Test
    fun nestedSourceScriptsRetainTheCallingOperation() = runBlocking {
        withTimeout(15_000) {
            registerNativeJsEngines(IosImageOps)
            EngineHost.registerInteractionProviders()
            for (library in listOf(null, "function fixtureHelper(){ return 'library'; }")) {
                EngineHost.withOperation {
                    val cookie = NestedSourceCookie(library)
                    assertEquals("after-nested", evaluate(
                        "cookie.getCookie('nested'); 'after-nested';", cookie))
                    assertEquals("nested-value", cookie.result)
                    assertEquals(EngineErrorCode.INTERACTION_REQUIRED, EngineHost.interactionFailure()?.code,
                        "Nested source JS must retain its caller's operation context")
                }
            }
        }
    }

    @Test
    fun webViewRejectionSurvivesTheSynchronousCoroutineBridge() = runBlocking {
        withTimeout(15_000) {
            registerNativeJsEngines(IosImageOps)
            EngineHost.registerInteractionProviders()
            withContext(Dispatchers.Default) {
                EngineHost.withOperation {
                    assertEquals("after-webview", evaluate(
                        "java.webView(null,'https://fixture.invalid',null); 'after-webview';"))
                    assertEquals(EngineErrorCode.UNSUPPORTED, EngineHost.interactionFailure()?.code,
                        "A rejected cross-thread WebView helper must not become success")
                }
            }
        }
    }

    private class NestedSourceCookie(library: String?) : SourceNetworkProvider {
        private val source = BookSource(bookSourceUrl = "https://fixture.invalid",
            bookSourceName = "Nested source fixture", jsLib = library)
        var result: String? = null
        override fun getCookie(tag: String): String {
            result = source.evalJS(
                "java.startBrowser('https://fixture.invalid/login','Verify'); 'nested-value';") as? String
            return "nested-cookie"
        }
        override fun replaceCookie(tag: String, cookie: String): Unit =
            error("Fixture does not mutate cookies")
        override fun removeCookie(tag: String): Unit =
            error("Fixture does not mutate cookies")
    }

    @Test
    fun failingObserverCannotEscapeTheNativeHostCallback() = runBlocking {
        registerNativeJsEngines(IosImageOps)
        var observations = 0
        val cookie = object : SourceNetworkProvider {
            override fun getCookie(tag: String): String = error("Controlled host failure")
            override fun replaceCookie(tag: String, cookie: String): Unit = error("Fixture does not write")
            override fun removeCookie(tag: String): Unit = error("Fixture does not write")
        }
        withContext(JsHostFailureObserver {
            observations++
            error("Controlled observer failure")
        }) {
            assertEquals("still usable", evaluate("cookie.getCookie('fail'); 'still usable';", cookie))
        }
        assertEquals(1, observations)
    }

    private class CancellingCookie(
        private val operationJob: Job,
        private val cancellationReached: CompletableDeferred<Unit>,
    ) : SourceNetworkProvider {
        override fun getCookie(tag: String): String {
            operationJob.cancel(CancellationException("Controlled source cancellation"))
            cancellationReached.complete(Unit)
            return ""
        }
        override fun replaceCookie(tag: String, cookie: String): Unit =
            error("Fixture does not mutate cookies")
        override fun removeCookie(tag: String): Unit =
            error("Fixture does not mutate cookies")
    }

    private suspend fun evaluate(script: String, cookie: SourceNetworkProvider? = null): String? {
        val source = BookSource(bookSourceUrl = "https://fixture.invalid", bookSourceName = "Controlled fixture")
        val scope = NativeJsEngine.getRuntimeScope(JsBindings().apply {
            this["java"] = AnalyzeRuleCore(source = source)
            if (cookie != null) this["cookie"] = cookie
        })
        return try {
            NativeJsEngine.eval(script, scope, currentCoroutineContext()) as? String
        } finally {
            scope.close()
        }
    }
}
