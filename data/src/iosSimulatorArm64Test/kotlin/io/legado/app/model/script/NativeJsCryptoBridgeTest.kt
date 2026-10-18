package io.legado.app.model.script

import io.legado.app.help.image.IosImageOps
import io.legado.app.model.analyzeRule.AnalyzeRuleCore
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

class NativeJsCryptoBridgeTest {
    @Test
    fun decryptAcceptsSignedUnsignedAndNativeReturnedCipherBytes() = withAnalyzer {
        // AES-128 ECB known-answer vector: key 000102...0f, plaintext 001122...ff.
        val expected = "0,17,34,51,68,85,102,119,136,153,170,187,204,221,238,255"
        for (input in listOf(
            "[105,196,224,216,106,123,4,48,216,205,183,128,112,180,197,90]",
            "[105,-60,-32,-40,106,123,4,48,-40,-51,-73,-128,112,-76,-59,90]",
            "java.base64DecodeToByteArray('acTg2Gp7BDDYzbeAcLTFWg==')",
            "'69c4e0d86a7b0430d8cdb78070b4c55a'",
            "'acTg2Gp7BDDYzbeAcLTFWg=='"
        )) {
            assertEquals(expected, evalJS("""
                var crypto = java.createSymmetricCrypto('AES/ECB/NoPadding',
                    [0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15]);
                crypto.decrypt($input).map(function(b) { return b & 255; }).join(',');
            """.trimIndent()), input)
        }
    }

    @Test
    fun decryptStrAcceptsCipherArraysHexAndBase64WithoutChangingUnicode() = withAnalyzer {
        for (input in listOf(
            "crypto.encrypt(text)", "crypto.encryptHex(text)", "crypto.encryptBase64(text)",
            "java.base64DecodeToByteArray(crypto.encryptBase64(text))"
        )) {
            assertEquals("Native bridge: 你好 🌍", evalJS("""
                var crypto = java.createSymmetricCrypto('AES/CBC/PKCS5Padding',
                    '0123456789abcdef', 'fedcba9876543210');
                var text = 'Native bridge: 你好 🌍';
                crypto.decryptStr($input);
            """.trimIndent()), input)
        }
    }

    @Test
    fun invalidCiphertextThrowsThroughBridgeAndAnalyzerRemainsUsable() = withAnalyzer {
        evalJS("var crypto = java.createSymmetricCrypto('AES/ECB/NoPadding', '0123456789abcdef');")
        for (method in listOf("decrypt", "decryptStr")) {
            for (input in listOf("[1,2,3]", "'01'")) {
                assertFailsWith<RuntimeException> { evalJS("crypto.$method($input)") }
                assertEquals("alive", evalJS("java.evalJS(\"'alive'\")"))
            }
        }
    }

    private fun withAnalyzer(block: AnalyzeRuleCore.() -> Unit) {
        registerNativeJsEngines(IosImageOps)
        val analyzer = AnalyzeRuleCore()
        try { analyzer.block() } finally { analyzer.close() }
    }
}
