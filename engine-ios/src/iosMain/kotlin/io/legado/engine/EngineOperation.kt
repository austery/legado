package io.legado.engine

import io.legado.app.model.script.NativeJsEngine
import kotlinx.atomicfu.atomic
import kotlin.coroutines.AbstractCoroutineContextElement
import kotlin.coroutines.CoroutineContext

/** A source operation owns its failure latch in the explicitly propagated context. */
internal class EngineOperation : AbstractCoroutineContextElement(Key) {
    companion object Key : CoroutineContext.Key<EngineOperation> {
        fun currentScript(): EngineOperation? = try {
            NativeJsEngine.currentContextNonNull().coroutineContext?.get(Key)
        } catch (_: IllegalStateException) {
            null
        }
    }

    private val interaction = atomic<EngineFailure?>(null)
    fun interactionFailure(): EngineFailure? = interaction.value
    fun reject(code: EngineErrorCode, message: String) {
        interaction.compareAndSet(null, EngineFailure(code, message))
    }
}

/** Ordinary Kotlin provider calls retain typed failures without a JS bridge latch. */
internal class EngineHostRejection(val failure: EngineFailure) : Exception(failure.message)
