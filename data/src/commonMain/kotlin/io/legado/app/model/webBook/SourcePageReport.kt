package io.legado.app.model.webBook

/**
 * The accepted outcome of one source page, reported to the native engine
 * through [SearchModel.CallBack.onSourcePageFinished].
 */
sealed interface SourcePageReport {
    data class Success(val hasNextPage: Boolean, val isEmpty: Boolean) : SourcePageReport
    data class Failure(val error: Throwable) : SourcePageReport
    data object Cancelled : SourcePageReport
}
