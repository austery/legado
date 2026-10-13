package io.legado.app.utils

internal actual fun checkRegexReplacementProgress(
    regex: Regex,
    input: CharSequence,
    checkCancellation: () -> Unit
) {
    var minimumStart = 0
    var match = regex.find(input)
    while (match != null) {
        checkCancellation()
        val start = match.range.first
        val end = match.range.last + 1
        if (start < minimumStart || end < start || end > input.length) {
            throw UnsupportedOperationException("Native regex matching did not advance safely")
        }
        // Empty matches are valid, but their next search must advance one character.
        minimumStart = if (end == start) start + 1 else end
        if (minimumStart > input.length) return
        match = match.next()
    }
}
