package io.legado.app.utils

import io.legado.app.model.analyzeRule.AnalyzeRuleCore
import org.junit.Test
import kotlin.test.assertEquals

class RuleRegexCompatibilityTest {
    @Test fun firstReplacementRetainsContextAndUnmatchedText() {
        for (provider in listOf(DefaultRuleRegex, JvmRuleRegex)) {
            assertEquals("aX", provider.replace("ab", "(?<=a)b", false, "X", true, 0))
            assertEquals("b", provider.replace("b", "(?<=a)b", false, "X", true, 0))
            assertEquals("Xb", provider.replace("bb", "b", false, "X", true, 0))
        }
    }

    @Test fun sourceRuleExtractsOnlyOnceBeforeReplacement() {
        val old = RuleRegexes.get()
        try {
            for (provider in listOf(DefaultRuleRegex, JvmRuleRegex)) {
                RuleRegexes.register(provider)
                assertEquals("b", AnalyzeRuleCore().setContent("ab").getString("##(?<=a)b##X##"))
                assertEquals("a", AnalyzeRuleCore().setContent("ab").getString("##a(?=b)##X##"))
                assertEquals("X", AnalyzeRuleCore().setContent("ab").getString("##b##X##"))
            }
        } finally { RuleRegexes.register(old) }
    }
}
