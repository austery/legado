package io.legado.app.model.script

import kotlin.coroutines.AbstractCoroutineContextElement
import kotlin.coroutines.CoroutineContext

/**
 * Lets a host retain typed failures caught by the synchronous native JS bridge.
 * The observer runs synchronously; its exceptions are suppressed at the C boundary.
 */
class JsHostFailureObserver(val onFailure: (Throwable) -> Unit) : AbstractCoroutineContextElement(Key) {
    companion object Key : CoroutineContext.Key<JsHostFailureObserver>
}
