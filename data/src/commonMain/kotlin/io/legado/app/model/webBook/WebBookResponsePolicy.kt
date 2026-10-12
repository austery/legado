package io.legado.app.model.webBook

import io.legado.app.help.http.StrResponse
import kotlin.coroutines.AbstractCoroutineContextElement
import kotlin.coroutines.CoroutineContext

/** Optional host validation after source login recovery and before content parsing.
 * Without this context element, existing clients retain their response behavior.
 * Raw JavaScript HTTP helpers intentionally remain outside this policy.
 */
class WebBookResponsePolicy(val validate: (StrResponse) -> Unit) :
    AbstractCoroutineContextElement(Key) {
    companion object Key : CoroutineContext.Key<WebBookResponsePolicy>
}
