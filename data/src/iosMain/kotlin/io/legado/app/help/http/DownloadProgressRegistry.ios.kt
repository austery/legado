package io.legado.app.help.http

import io.legado.app.utils.canonicalizeUri
import kotlinx.atomicfu.locks.SynchronizedObject
import kotlinx.atomicfu.locks.synchronized

/**
 * 字节级下载进度注册表 (iOS, 对照 jvmAndAndroid 的 [io.legado.app.help.glide.progress.ProgressManager]):
 * Ktor [io.ktor.client.plugins.onDownload] 回调按 url 分发到监听者 (漫画页转圈环心等)。
 *
 * 与 ProgressManager 的差异: 不缓存"已读字节"状态 (每次下载由 Kotlin 请求侧直接上报;
 * 重试重发会重新从 0 上报, 与 desktop 端 okhttp 拦截器行为一致)。
 */
object DownloadProgressRegistry {

    private val lock = SynchronizedObject()
    private val listeners = mutableMapOf<String, MutableList<(Long, Long?) -> Unit>>()

    /** 注册按 url 的进度监听 (url 与 [KmpRequest.url] 一致), 返回注销函数。 */
    fun addListener(url: String, listener: (bytesRead: Long, total: Long?) -> Unit): () -> Unit {
        val key = url.canonicalizeUri()
        synchronized(lock) {
            listeners.getOrPut(key) { mutableListOf() }.add(listener)
        }
        return { removeListener(key, listener) }
    }

    fun removeListener(url: String, listener: (Long, Long?) -> Unit) {
        val key = url.canonicalizeUri()
        synchronized(lock) {
            listeners[key]?.remove(listener)
            if (listeners[key].isNullOrEmpty()) listeners.remove(key)
        }
    }

    /** Ktor onDownload 上报 (任意线程; 监听者自行切线程, 与 ProgressManager 同为 IO 线程回调)。 */
    fun notify(url: String, bytesRead: Long, total: Long?) {
        val key = url.canonicalizeUri()
        val snapshot = synchronized(lock) { listeners[key]?.toList() } ?: return
        snapshot.forEach { it(bytesRead, total) }
    }
}
