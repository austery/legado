package io.legado.engine

import io.legado.app.data.entities.BookSource
import io.legado.app.help.image.IosImageOps
import io.legado.app.help.source.exploreKinds
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
import kotlin.test.assertSame
import kotlin.test.assertNull
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlin.test.assertFailsWith

/** Real native JS and engine providers, with no database initialization. */
@OptIn(DelicateCoroutinesApi::class, ExperimentalCoroutinesApi::class)
class EngineOperationNativeTest {
    @Test
    fun uncaughtBridgeErrorRetainsItsTypedOperationFailure() = runBlocking {
        registerNativeJsEngines(IosImageOps)
        EngineHost.registerInteractionProviders()
        val failure = assertFailsWith<EngineHostRejection> {
            EngineHost.withOperation {
                evaluate("java.startBrowser('https://fixture.invalid/login', 'Verify');")
            }
        }
        assertEquals(EngineErrorCode.INTERACTION_REQUIRED, failure.failure.code)
        EngineHost.withOperation {
            assertNull(EngineHost.interactionFailure())
            assertEquals("next operation", evaluate("'next operation'"))
        }
    }

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
                                "try { java.startBrowser('https://fixture.invalid/login', 'Verify'); } catch (error) {} 'after-interaction';"))
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
                    "try { java.startBrowser('https://fixture.invalid/login', 'Verify'); } catch (error) {} 'outer value';"))
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
                        "try { java.webView(null,'https://fixture.invalid',null); } catch (error) {} 'after-webview';"))
                    assertEquals(EngineErrorCode.UNSUPPORTED, EngineHost.interactionFailure()?.code,
                        "A rejected cross-thread WebView helper must not become success")
                }
            }
        }
    }

    @Test
    fun topLevelCategoryScriptsKeepCaughtAndUncaughtInteractionFailures() = runBlocking {
        registerNativeJsEngines(IosImageOps)
        EngineHost.registerInteractionProviders()
        for (script in listOf(
            "java.startBrowser('https://fixture.invalid','Verify'); '[]';",
            "try { java.startBrowser('https://fixture.invalid','Verify'); } catch (error) {} '[]';",
        )) {
            val source = BookSource(bookSourceUrl = "https://category-${platform.Foundation.NSUUID().UUIDString}.invalid",
                bookSourceName = "Top-level category context", exploreUrl = "@js:" + script)
            EngineHost.withOperation {
                source.exploreKinds()
                assertEquals(EngineErrorCode.INTERACTION_REQUIRED, EngineHost.interactionFailure()?.code)
            }
            assertNull(NativeJsEngine.currentContext())
            EngineHost.withOperation { assertNull(EngineHost.interactionFailure()) }
        }
    }

    @Test
    fun topLevelContextEntryRestoresBorrowedScopeAfterNestedFailure() = runBlocking {
        registerNativeJsEngines(IosImageOps)
        assertNull(NativeJsEngine.currentContext())
        EngineHost.withOperation {
            val operation = currentCoroutineContext()[EngineOperation]
            NativeJsEngine.runScriptWithContext {
                val outer = NativeJsEngine.currentContextNonNull()
                assertSame(operation, outer.coroutineContext?.get(EngineOperation))
                val inner = EngineOperation()
                val innerContext = outer.coroutineContext!! + inner
                assertFailsWith<IllegalArgumentException> {
                    NativeJsEngine.runScriptWithContext(innerContext) {
                        assertSame(outer, NativeJsEngine.currentContextNonNull())
                        assertSame(inner, outer.coroutineContext?.get(EngineOperation))
                        throw IllegalArgumentException("Controlled nested failure")
                    }
                }
                assertSame(operation, outer.coroutineContext?.get(EngineOperation))
            }
        }
        assertNull(NativeJsEngine.currentContext(), "Temporary entry scope must be released")
        assertFailsWith<IllegalArgumentException> {
            NativeJsEngine.runScriptWithContext(currentCoroutineContext()) {
                NativeJsEngine.currentContextNonNull()
                throw IllegalArgumentException("Controlled outer failure")
            }
        }
        assertNull(NativeJsEngine.currentContext(), "Failure must also release the entry scope")
    }

    @Test
    fun concurrentTopLevelSourceOperationsKeepTheirFailuresSeparate() = runBlocking {
        withTimeout(15_000) {
            registerNativeJsEngines(IosImageOps)
            EngineHost.registerInteractionProviders()
            val ready = CompletableDeferred<Unit>()
            val rejected = CompletableDeferred<Unit>()
            newSingleThreadContext("top-level-rejection").use { firstThread ->
                newSingleThreadContext("top-level-success").use { secondThread ->
                    val first = async(firstThread) {
                        EngineHost.withOperation {
                            ready.await()
                            evaluateTopLevel("try { java.startBrowser('https://fixture.invalid','Verify'); } catch (error) {} 'after';")
                            rejected.complete(Unit)
                            EngineHost.interactionFailure()
                        }
                    }
                    val second = async(secondThread) {
                        EngineHost.withOperation {
                            ready.complete(Unit); rejected.await()
                            assertEquals("survives", evaluateTopLevel("'survives';"))
                            EngineHost.interactionFailure()
                        }
                    }
                    assertEquals(EngineErrorCode.INTERACTION_REQUIRED, first.await()?.code)
                    assertNull(second.await())
                }
            }
        }
    }

    @Test
    fun topLevelCancellationReachesCooperativeHostAndKeepsPeerAlive() = runBlocking {
        withTimeout(15_000) {
            registerNativeJsEngines(IosImageOps)
            EngineHost.registerInteractionProviders()
            supervisorScope {
                val cancelled = CompletableDeferred<Unit>()
                val afterCancellation = CompletableDeferred<Unit>()
                newSingleThreadContext("top-level-cancelled").use { firstThread ->
                    newSingleThreadContext("top-level-peer").use { secondThread ->
                        val first = async(firstThread) {
                            EngineHost.withOperation {
                                val cookie = CancellingCookie(currentCoroutineContext().job, cancelled, afterCancellation)
                                evaluateTopLevel("try { cookie.getCookie('cancel'); } catch (error) {} cookie.getCookie('after');", cookie)
                            }
                        }
                        val second = async(secondThread) {
                            cancelled.await()
                            EngineHost.withOperation { evaluateTopLevel("'peer survives';") }
                        }
                        assertFailsWith<CancellationException> { first.await() }
                        assertFalse(afterCancellation.isCompleted, "Cancelled context must prevent the host helper from performing its protected work")
                        assertEquals("peer survives", second.await())
                    }
                }
            }
        }
    }

    private suspend fun evaluateTopLevel(script: String, cookie: SourceNetworkProvider? = null): String? =
        NativeJsEngine.runScriptWithContext {
            val source = BookSource(bookSourceUrl = "https://fixture.invalid", bookSourceName = "Top-level fixture")
            source.evalJS(script) { if (cookie != null) this["cookie"] = cookie } as? String
        }

    private class NestedSourceCookie(library: String?) : SourceNetworkProvider {
        private val source = BookSource(bookSourceUrl = "https://fixture.invalid",
            bookSourceName = "Nested source fixture", jsLib = library)
        var result: String? = null
        override fun getCookie(tag: String): String {
            result = source.evalJS(
                "try { java.startBrowser('https://fixture.invalid/login','Verify'); } catch (error) {} 'nested-value';") as? String
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
            val failure = assertFailsWith<Exception> { evaluate("cookie.getCookie('fail');", cookie) }
            assertTrue(NativeJsEngine.isJsException(failure))
            assertTrue(failure.message.orEmpty().contains("Controlled host failure"))
            assertFalse(failure.message.orEmpty().contains("Controlled observer failure"))
            assertEquals("still usable", evaluate("'still usable';"))
        }
        assertEquals(1, observations)
    }

    private class CancellingCookie(
        private val operationJob: Job,
        private val cancellationReached: CompletableDeferred<Unit>,
        private val afterCancellation: CompletableDeferred<Unit>? = null,
    ) : SourceNetworkProvider {
        override fun getCookie(tag: String): String {
            if (tag == "after") {
                // Host helpers cooperate with cancellation through the supplied script context.
                NativeJsEngine.currentContextNonNull().ensureActive()
                afterCancellation?.complete(Unit)
                return "after"
            }
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
