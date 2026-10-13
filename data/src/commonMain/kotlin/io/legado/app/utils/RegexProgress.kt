package io.legado.app.utils

/** Reject invalid native match iteration before a replacement can monopolize its caller. */
internal expect fun checkRegexReplacementProgress(
    regex: Regex,
    input: CharSequence,
    checkCancellation: () -> Unit = {}
)
