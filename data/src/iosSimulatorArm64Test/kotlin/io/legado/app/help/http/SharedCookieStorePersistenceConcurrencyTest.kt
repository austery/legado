package io.legado.app.help.http

import androidx.room3.Room
import androidx.sqlite.driver.NativeSQLiteDriver
import io.legado.app.data.AppDatabase
import io.legado.app.data.AppDatabaseProvider
import io.legado.app.data.AppDatabaseProviders
import io.legado.app.data.AppDbProviders
import io.legado.app.data.DatabaseMigrations
import io.legado.app.data.NativeAppDbAccessor
import io.legado.app.help.CacheManager
import io.legado.app.utils.NetworkUtils
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.DelicateCoroutinesApi
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.newSingleThreadContext
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import platform.Foundation.NSTemporaryDirectory
import platform.Foundation.NSUUID
import kotlin.test.Test
import kotlin.test.assertEquals

/** Public provider behavior backed by a real disposable Room database. */
@OptIn(DelicateCoroutinesApi::class, ExperimentalCoroutinesApi::class)
class SharedCookieStorePersistenceConcurrencyTest {
    @Test
    fun concurrentResponsesRetainEveryPersistentCookieForOneDomain() = runBlocking {
        withStore { store ->
            val workers = List(8) { newSingleThreadContext("persistent-cookie-$it") }
            try {
                withTimeout(60_000) {
                    repeat(8) { round ->
                        val url = "https://persistent-${NSUUID().UUIDString.lowercase()}.invalid"
                        store.setCookie(url, "original=retained")
                        val ready = Channel<Unit>(workers.size)
                        val start = CompletableDeferred<Unit>()
                        val updates = workers.mapIndexed { worker, dispatcher ->
                            async(dispatcher) {
                                ready.send(Unit)
                                start.await()
                                repeat(4) { response ->
                                    store.replaceCookie(url, "worker${worker}response$response=retained")
                                }
                            }
                        }
                        repeat(workers.size) { ready.receive() }
                        start.complete(Unit)
                        updates.awaitAll()
                        val expected = buildMap {
                            put("original", "retained")
                            repeat(8) { worker -> repeat(4) { response ->
                                put("worker${worker}response$response", "retained")
                            } }
                        }
                        val observed = cookieToMap(store.getCookieNoSession(url))
                        println("SPEC004 persistent Cookie round=$round retained=${observed.size}/33")
                        assertEquals(expected, observed, "Every completed response must survive")
                        // Evict only this synthetic hot key; assert through the public cold read.
                        CacheManager.deleteMemory("${NetworkUtils.getSubDomain(url)}_cookie")
                        assertEquals(expected, cookieToMap(store.getCookieNoSession(url)),
                            "Persisted Cookie must agree with the completed response set")
                    }
                }
            } finally { workers.forEach { it.close() } }
        }
    }

    @Test
    fun mergingReplacingAndRemovingPreserveExistingProviderSemantics() = runBlocking {
        withStore { store ->
            val domain = "semantics-${NSUUID().UUIDString.lowercase()}.invalid"
            val url = "https://$domain/book"
            store.setCookie(url, "persistent=first; shared=persistent")
            store.updateSessionCookie(domain, "session=first; shared=session")
            store.replaceCookie(url, "persistent=updated; added=new")
            assertEquals(mapOf("persistent" to "updated", "shared" to "persistent", "added" to "new"),
                cookieToMap(store.getCookieNoSession(url)))
            assertEquals(mapOf("persistent" to "updated", "shared" to "session", "added" to "new", "session" to "first"),
                cookieToMap(store.getCookie(url)))
            store.updateSessionCookie(domain, "session=updated; extra=kept")
            assertEquals(mapOf("session" to "updated", "shared" to "session", "extra" to "kept"),
                cookieToMap(store.getSessionCookie(domain).orEmpty()))
            store.removeCookie(url, "shared")
            assertEquals(mapOf("persistent" to "updated", "added" to "new", "session" to "updated", "extra" to "kept"),
                cookieToMap(store.getCookie(url)))
            store.removeCookie(url)
            assertEquals("", store.getCookie(url))
            assertEquals("", store.getCookieNoSession(url))
            assertEquals(null, store.getSessionCookie(domain))
        }
    }

    @Test
    fun responseCookiesAreSentOnLaterRequestsAndPersistBeyondTheHotCache() = runBlocking {
        withStore { store ->
            val previousStore = CookieStoreProviders.get()
            CookieStoreProviders.register(store)
            try {
                val domain = "bridge-${NSUUID().UUIDString.lowercase()}.invalid"
                val request = KmpRequestBuilder().url("https://$domain/search?q=fixture").build()
                val response = KmpResponse(
                    code = 200,
                    message = "OK",
                    headers = mapOf("Set-Cookie" to listOf(
                        "persistent=retained; Max-Age=3600; Path=/",
                        "session=retained; Path=/"
                    )),
                    body = ByteArray(0),
                    contentType = "text/plain",
                    request = request
                )
                val bridge: CookieJarBridge = SharedCookieJarBridge()
                try { bridge.saveResponse(response) } finally { response.close() }
                val loaded = bridge.loadRequest(KmpRequestBuilder()
                    .url("https://$domain/book/1")
                    .header("Cookie", "request=retained")
                    .build())
                assertEquals(mapOf("request" to "retained", "persistent" to "retained", "session" to "retained"),
                    cookieToMap(loaded.header("Cookie").orEmpty()))
                assertEquals(mapOf("persistent" to "retained"), cookieToMap(store.getCookieNoSession(request.url.toString())))
                CacheManager.deleteMemory("${domain}_cookie")
                assertEquals(mapOf("persistent" to "retained"), cookieToMap(store.getCookieNoSession(request.url.toString())))
            } finally {
                if (previousStore != null) CookieStoreProviders.register(previousStore)
            }
        }
    }

    private suspend fun withStore(block: suspend (CookieStoreProvider) -> Unit) {
        val previousDatabase = runCatching { AppDatabaseProviders.get() }.getOrNull()
        val previousAccessor = runCatching { AppDbProviders.get() }.getOrNull()
        val path = NSTemporaryDirectory() + "SPEC004-cookie-fixture-" + NSUUID().UUIDString + ".db"
        val database = Room.databaseBuilder<AppDatabase>(path)
            .setDriver(NativeSQLiteDriver())
            .addMigrations(*DatabaseMigrations.migrations)
            .build()
        AppDatabaseProviders.register(object : AppDatabaseProvider {
            override val appDb: AppDatabase = database
        })
        AppDbProviders.register(NativeAppDbAccessor())
        try {
            withContext(Dispatchers.Default) { block(SharedCookieStore) }
        } finally {
            if (previousAccessor != null) AppDbProviders.register(previousAccessor)
            if (previousDatabase != null) AppDatabaseProviders.register(previousDatabase)
            else AppDatabaseProviders.reset()
            database.close()
        }
    }
}
