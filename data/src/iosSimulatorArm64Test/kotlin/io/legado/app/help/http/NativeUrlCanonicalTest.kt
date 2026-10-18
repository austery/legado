package io.legado.app.help.http

import io.ktor.http.Url
import platform.Foundation.NSURLComponents
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull

class NativeUrlCanonicalTest {
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
