package io.legado.app.help.http

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.DelicateCoroutinesApi
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.newSingleThreadContext
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import platform.Foundation.NSUUID
import kotlin.test.Test
import kotlin.test.assertEquals

/** Real shared Cookie provider operations on synthetic session-only domains. */
@OptIn(DelicateCoroutinesApi::class, ExperimentalCoroutinesApi::class)
class SharedCookieStoreConcurrencyTest {
    @Test
    fun concurrentResponsesRetainEverySessionCookieForOneDomain() = runBlocking {
        val store: CookieStoreProvider = SharedCookieStore
        val workers = List(8) { newSingleThreadContext("cookie-response-$it") }
        try {
            withTimeout(30_000) {
                repeat(32) { round ->
                    val domain = "session-${NSUUID().UUIDString.lowercase()}.invalid"
                    store.updateSessionCookie(domain, "original=retained")
                    val ready = Channel<Unit>(workers.size)
                    val start = CompletableDeferred<Unit>()
                    val updates = workers.mapIndexed { worker, dispatcher ->
                        async(dispatcher) {
                            ready.send(Unit)
                            start.await()
                            repeat(8) { response ->
                                store.updateSessionCookie(domain, "worker${worker}response$response=retained")
                            }
                        }
                    }
                    repeat(workers.size) { ready.receive() }
                    start.complete(Unit)
                    updates.awaitAll()
                    val observed = SharedCookieStore.cookieToMap(
                        SharedCookieStore.getSessionCookie(domain).orEmpty()
                    )
                    println("SPEC004 Cookie round=$round retained=${observed.size}/65")
                    assertEquals("retained", observed["original"])
                    repeat(8) { worker -> repeat(8) { response ->
                        assertEquals("retained", observed["worker${worker}response$response"],
                            "Completed response Cookie missing: round=$round worker=$worker response=$response")
                    } }
                }
            }
        } finally { workers.forEach { it.close() } }
    }
}
