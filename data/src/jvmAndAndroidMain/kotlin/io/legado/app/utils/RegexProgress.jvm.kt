package io.legado.app.utils

internal actual fun checkRegexReplacementProgress(
    regex: Regex,
    input: CharSequence,
    checkCancellation: () -> Unit
) {
    // This guard targets a reproduced Kotlin/Native matcher defect.
}
