package io.legado.app.model.fileBook

import io.legado.app.data.entities.Book
import io.legado.app.exception.RegexTimeoutException
import io.legado.app.utils.DefaultRuleRegex
import io.legado.app.utils.RuleMatchSpans
import io.legado.app.utils.RuleRegex
import io.legado.app.utils.RuleRegexes
import org.junit.Test
import java.lang.reflect.Proxy
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

class TextFileTimeoutTest {
    @Test fun aTimedOutFirstBlockCannotPublishALaterPartialCatalog() {
        val bytes = ("Preface text\n".repeat(45000) + "Chapter 1\nBody\n").toByteArray()
        val previousFiles = runCatching { FileBookProviders.get() }.getOrNull()
        val previousRegex = RuleRegexes.get()
        var scans = 0
        FileBookProviders.register(Proxy.newProxyInstance(
            FileBookAccessor::class.java.classLoader, arrayOf(FileBookAccessor::class.java)
        ) { _, method, _ ->
            check(method.name == "getBookInputStream") { "Unexpected operation: ${method.name}" }
            bytes.inputStream()
        } as FileBookAccessor)
        RuleRegexes.register(object : RuleRegex by DefaultRuleRegex {
            override fun findAll(source: CharSequence, pattern: String, multiline: Boolean, timeout: Long): List<RuleMatchSpans> {
                scans++
                if (scans == 1) throw RegexTimeoutException("Injected first-block timeout")
                return DefaultRuleRegex.findAll(source, pattern, multiline, timeout)
            }
        })
        try {
            val book = Book(bookUrl = "fixture", origin = "fixture-source", charset = "UTF-8", tocUrl = "^Chapter.*$")
            assertFailsWith<RegexTimeoutException> { TextFileCore(book).getChapterList() }
            assertEquals(1, scans)
        } finally {
            RuleRegexes.register(previousRegex)
            if (previousFiles != null) FileBookProviders.register(previousFiles)
        }
    }
}
