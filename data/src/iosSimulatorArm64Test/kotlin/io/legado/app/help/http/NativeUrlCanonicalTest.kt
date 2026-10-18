package io.legado.app.help.http

import io.ktor.http.Url
import platform.Foundation.NSURLComponents
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull

class NativeUrlCanonicalTest {
    @Test
    fun downloadProgressUsesTheRequestUrlForRegistrationAndRemoval() {
        val raw = "https://example.com/中文 image%20one.jpg?q=%2F"
        val encoded = "https://example.com/%E4%B8%AD%E6%96%87%20image%20one.jpg?q=%2F"
        val updates = mutableListOf<Pair<Long, Long?>>()
        val listener: (Long, Long?) -> Unit = { read, total -> updates.add(read to total) }
        val dispose = DownloadProgressRegistry.addListener(raw, listener)
        try {
            DownloadProgressRegistry.notify(KmpRequestBuilder().url(raw).build().url.toString(), 7, 10)
            assertEquals(listOf<Pair<Long, Long?>>(7L to 10L), updates)
            DownloadProgressRegistry.removeListener(encoded, listener)
            DownloadProgressRegistry.notify(raw, 8, 10)
            assertEquals(1, updates.size)
        } finally {
            dispose()
        }
        val disposeEncoded = DownloadProgressRegistry.addListener(encoded, listener)
        try {
            DownloadProgressRegistry.notify(raw, 9, null)
            assertEquals(9L to null, updates.last())
            disposeEncoded()
            DownloadProgressRegistry.notify(encoded, 10, 10)
            assertEquals(2, updates.size)
        } finally {
            disposeEncoded()
        }
    }

    @Test
    fun requestBuildersCanonicalizeMalformedEscapesAndUnicodeExactlyOnce() {
        val cases = listOf(
            "https://example.com/a b?q=中%zz#f g" to
                "https://example.com/a%20b?q=%E4%B8%AD%25zz#f%20g",
            "https://example.com/%e4%bd%a0?q=%2F%3F&n=100%" to
                "https://example.com/%e4%bd%a0?q=%2F%3F&n=100%25",
            "  https://example.com/p\n" to "https://example.com/p",
            "http://[::1]:8080/p a" to "http://[::1]:8080/p%20a",
            "https://example.com/a{b}|c[d]^e`f\\g" to
                "https://example.com/a%7Bb%7D%7Cc%5Bd%5D%5Ee%60f%5Cg"
        )
        for ((input, expected) in cases) {
            val requests = listOf(
                KmpRequestBuilder().url(input).build(),
                KmpRequestBuilder().url(input.toKmpHttpUrl()).build()
            )
            for (request in requests) {
                assertEquals(expected, request.url.toString())
                assertEquals(expected, request.newBuilder().build().url.toString())
                assertEquals(expected, expected.toKmpHttpUrl().toString())
                // Exercise the Ktor and Foundation parsing boundary used by Darwin.
                val url = Url(request.url.toString())
                val components = assertNotNull(NSURLComponents(string = url.toString()))
                assertNotNull(components.URL)
                assertEquals(url.encodedPath, components.percentEncodedPath)
                assertEquals(url.encodedQuery, components.percentEncodedQuery ?: "")
            }
        }
    }
}
