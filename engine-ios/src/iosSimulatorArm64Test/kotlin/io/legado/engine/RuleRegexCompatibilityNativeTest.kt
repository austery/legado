package io.legado.engine

import io.legado.app.utils.IosRuleRegex
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

class RuleRegexCompatibilityNativeTest {
    @Test fun namedNumericAndEscapedReplacementReferences() {
        fun replace(text: String, pattern: String, replacement: String, first: Boolean = false) =
            IosRuleRegex.replace(text, pattern, false, replacement, first, 3000)
        assertEquals("abc", replace("abc", "(?<word>abc)", "${'$'}{word}"))
        assertEquals("abc-abc", replace("abc", "(?<word>abc)", "${'$'}{word}-${'$'}1"))
        assertEquals("abc2", replace("abc", "(abc)", "${'$'}12"))
        assertEquals("${'$'}{word}", replace("abc", "(?<word>abc)", "\\${'$'}{word}"))
        assertEquals("", replace("b", "(?<word>a)?b", "${'$'}{word}"))
        assertEquals("aX", replace("ab", "(?<=a)b", "X", true))
        assertEquals("Xb", replace("bb", "b", "X", true))
        assertEquals("b", replace("b", "(?<=a)b", "X", true))
        assertFailsWith<IllegalArgumentException> { replace("abc", "(?<word>abc)", "${'$'}{missing}") }
        assertFailsWith<IllegalArgumentException> { replace("abc", "(?x)abc # (?<missing>abc)", "${'$'}{missing}") }
        assertEquals("abc", replace("abc", "(?x)(?<word>abc) # ignored", "${'$'}{word}"))
    }
}
