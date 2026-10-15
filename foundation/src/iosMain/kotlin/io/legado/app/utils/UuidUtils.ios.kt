package io.legado.app.utils

import platform.Foundation.NSUUID

/** Concurrent temporary-file writers must not share Kotlin/Native's global PRNG state. */
actual fun randomUUIDString(): String = NSUUID().UUIDString.lowercase()
