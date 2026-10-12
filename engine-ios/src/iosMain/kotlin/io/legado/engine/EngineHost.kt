@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)

package io.legado.engine

import io.legado.app.constant.registerNativeAndroidId
import io.legado.app.data.registerIosAppDbAccessor
import io.legado.app.data.registerIosDatabaseDriver
import io.legado.app.data.entities.BaseSource
import io.legado.app.help.registerNativeFileCacheProvider
import io.legado.app.help.registerNativeSourceCacheProvider
import io.legado.app.help.book.registerNativeBookHelpAccessor
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
import io.legado.app.model.webBook.registerNativeWebBookProviders
import kotlinx.atomicfu.atomic
import kotlinx.coroutines.sync.Mutex
import platform.Foundation.NSLog
import platform.UIKit.UIDevice

/** Owns the process-wide upstream providers; all engine operations hold gate. */
internal object EngineHost {
    val gate = Mutex()
    private var ready = false
    private var failed = false
    private val interaction = atomic<EngineFailure?>(null)

    fun beginOperation() { interaction.value = null }
    fun interactionFailure(): EngineFailure? = interaction.value

    private fun reject(code: EngineErrorCode, message: String): Nothing {
        // The upstream C bridge catches Throwable and returns JS undefined. Preserve
        // the failure separately so a later successful JS value cannot hide it.
        interaction.compareAndSet(null, EngineFailure(code, message))
        throw IllegalStateException(message)
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
        registerNativeBookHelpAccessor()
        registerNativeContentProcessorAccessor()
        registerNativeSourceHelpAccessor()
        registerNativeSourceCacheProvider()
        registerNativeFileCacheProvider()
        registerNativeSourceProviders()
        registerNativeJsEngines(IosImageOps)
        registerNativeWebBookProviders()
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
        ready = true
        failed = false
    }
}
