package io.legado.app.utils

/** Legacy OHOS UUID formatter; iOS uses the platform UUID generator. */
actual fun randomUUIDString(): String {
    val r = kotlin.random.Random.Default
    // 16 字节随机数, 拼成 UUID 字符串
    val bytes = ByteArray(16)
    r.nextBytes(bytes)
    // version = 4 (random)
    bytes[6] = (bytes[6].toInt() and 0x0f or 0x40).toByte()
    // variant = IETF RFC 4122
    bytes[8] = (bytes[8].toInt() and 0x3f or 0x80).toByte()
    return formatUuid(bytes)
}

private fun formatUuid(b: ByteArray): String {
    val sb = StringBuilder(36)
    appendHex(sb, b, 0, 4)
    sb.append('-')
    appendHex(sb, b, 4, 2)
    sb.append('-')
    appendHex(sb, b, 6, 2)
    sb.append('-')
    appendHex(sb, b, 8, 2)
    sb.append('-')
    appendHex(sb, b, 10, 6)
    return sb.toString()
}

private fun appendHex(sb: StringBuilder, b: ByteArray, off: Int, len: Int) {
    val hex = "0123456789abcdef"
    for (i in 0 until len) {
        val v = b[off + i].toInt() and 0xff
        sb.append(hex[v ushr 4]).append(hex[v and 0xf])
    }
}
