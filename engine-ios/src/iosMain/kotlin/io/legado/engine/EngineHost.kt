@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)

package io.legado.engine

import io.legado.app.constant.AppConst
import io.legado.app.help.config.AppConfigProviders
import io.legado.app.utils.IosRuleRegex
import io.legado.app.utils.RuleRegexes
import io.legado.app.utils.registerRuleRegexForJsonPath
import io.legado.app.constant.registerNativeAndroidId
import io.legado.app.data.registerIosAppDbAccessor
import io.legado.app.data.registerIosDatabaseDriver
import io.legado.app.data.entities.BaseSource
import io.legado.app.help.registerNativeFileCacheProvider
import io.legado.app.help.registerNativeSourceCacheProvider
import io.legado.app.help.book.BookHelpProviders
import io.legado.app.help.book.registerNativeBookStorage
import io.legado.app.help.book.registerNativeContentProcessorAccessor
import io.legado.app.help.config.registerIosPreferenceProvider
import io.legado.app.help.config.registerNativeAppConfigAccessor
import io.legado.app.help.file.registerIosAppFilesDir
import io.legado.app.help.http.*
import io.legado.app.help.image.IosImageOps
import io.legado.app.help.log.registerNativeAppLogHost
import io.legado.app.help.source.*
import io.legado.app.help.storage.registerNativeDataStorage
import io.legado.app.help.toast.Toaster
import io.legado.app.help.toast.Toasters
import io.legado.app.model.script.registerNativeJsEngines
import io.legado.app.model.script.JsHostFailureObserver
import io.legado.app.model.webBook.registerNativeWebBookProviders
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.sync.withPermit
import platform.Foundation.NSLog
import platform.UIKit.UIDevice

/** Owns upstream providers; gate protects serialized product and registry operations. */
internal object EngineHost {
    val gate = Mutex()
    private var ready = false
    private var failed = false
    private val networkRegistryMutex = Mutex()
    private val sourceLeases = mutableMapOf<String, Mutex>()
    private var networkPermits: Semaphore? = null

    /** Process-wide leases include legacy requests and independent engine sessions. */
    suspend fun <T> withSourceRequest(sourceId: String, background: Boolean = false,
        reserveForeground: Boolean = true, action: suspend () -> T): T {
        if (!background) OfflineWork.cancel()
        val (permits, lease) = networkRegistryMutex.withLock {
            val permits = networkPermits ?: Semaphore(
                AppConfigProviders.get().threadCount.coerceIn(1, AppConst.MAX_THREAD)
            ).also { networkPermits = it }
            permits to sourceLeases.getOrPut(sourceId) { Mutex() }
        }
        if (!background || !reserveForeground) return lease.withLock { permits.withPermit { action() } }
        // The single cache lane may borrow spare capacity, never the foreground's last permit.
        return lease.withLock {
            val acquired = networkRegistryMutex.withLock {
                if (permits.availablePermits <= 1 || !permits.tryAcquire()) false
                else if (permits.availablePermits == 0) {
                    permits.release()
                    false
                } else true
            }
            check(acquired) { "No spare network capacity for caching; retry after foreground requests finish" }
            try { action() } finally { permits.release() }
        }
    }

    suspend fun <T> withOperation(action: suspend () -> T): T {
        val operation = EngineOperation()
        val observer = JsHostFailureObserver { error ->
            generateSequence(error) { it.cause }.take(16)
                .filterIsInstance<EngineHostRejection>().firstOrNull()?.failure?.let {
                    operation.reject(it.code, it.message)
                }
        }
        return withContext(operation + observer) {
            try {
                action()
            } catch (error: Throwable) {
                // The JS exception no longer carries the original Kotlin rejection.
                // Translate it before leaving its operation-local failure context.
                currentCoroutineContext().ensureActive()
                operation.interactionFailure()?.let { throw EngineHostRejection(it) }
                throw error
            } finally {
                currentCoroutineContext().ensureActive()
            }
        }
    }

    suspend fun interactionFailure(): EngineFailure? =
        currentCoroutineContext()[EngineOperation]?.interactionFailure()

    private fun reject(code: EngineErrorCode, message: String): Nothing {
        // Preserve typed rejection even if JavaScript catches the bridge error
        // and returns an otherwise successful value.
        EngineOperation.currentScript()?.reject(code, message)
        throw EngineHostRejection(EngineFailure(code, message))
    }

    fun initialize() {
        if (ready) return
        check(!failed) { "Initialization previously failed; restart the host process" }
        failed = true
        registerIosAppFilesDir()
        Toasters.register(object : Toaster {
            override fun toast(message: String) { NSLog("%@", message) }
            override fun toastLong(message: String) { toast(message) }
        })
        registerIosPreferenceProvider()
        registerNativeAppLogHost()
        registerNativeAppConfigAccessor()
        registerNativeAndroidId(UIDevice.currentDevice.identifierForVendor?.UUIDString)
        registerNativeHttpProvider()
        registerDefaultIosCookieStoreProvider()
        registerSharedCookieJarBridge()
        registerIosDatabaseDriver()
        registerNativeDataStorage()
        registerNativeBookStorage()
        registerIosAppDbAccessor()
        BookHelpProviders.register(EngineBookHelpAccessor)
        registerNativeContentProcessorAccessor()
        registerNativeSourceHelpAccessor()
        registerNativeSourceCacheProvider()
        registerNativeFileCacheProvider()
        registerNativeSourceProviders()
        registerNativeJsEngines(IosImageOps)
        registerNativeWebBookProviders()
        RuleRegexes.register(IosRuleRegex)
        registerRuleRegexForJsonPath()
        registerInteractionProviders()
        ready = true
        failed = false
    }

    internal fun registerInteractionProviders() {
        VerificationUiProviders.register(object : VerificationUiProvider {
            override fun showVerificationCodeDialog(url: String, source: BaseSource) {
                reject(EngineErrorCode.INTERACTION_REQUIRED, "Source requires verification")
            }
            override fun startBrowser(source: BaseSource, url: String, title: String,
                saveResult: Boolean?, refetchAfterSuccess: Boolean?, asBottomSheet: Boolean) {
                reject(EngineErrorCode.INTERACTION_REQUIRED, "Source requires a browser interaction")
            }
        })
        BackstageWebViewProviders.register(object : BackstageWebViewFactory {
            override fun create(url: String?, html: String?, encode: String?, tag: String?,
                headerMap: Map<String, String>?, sourceRegex: String?, overrideUrlRegex: String?,
                javaScript: String?, delayTime: Long): BackstageWebViewHandle =
                reject(EngineErrorCode.UNSUPPORTED, "Background WebView is outside this engine slice")
        })
    }

}
