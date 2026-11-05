package io.legado.app.data.entities

import androidx.room3.Entity
import androidx.room3.ForeignKey
import androidx.room3.Index

/** An owner follows explicit source switches; the captured text identity stays fixed. */
@Entity(tableName = "native_bookmarks", primaryKeys = ["id"], foreignKeys = [ForeignKey(
    entity = Book::class, parentColumns = ["bookUrl"], childColumns = ["ownerBookUrl"],
    onDelete = ForeignKey.CASCADE
)], indices = [Index(value = ["ownerBookUrl"]), Index(
    value = ["ownerBookUrl", "sourceId", "sourceBookUrl", "chapterUrl", "textVersion", "textSha256", "paragraphUtf16Offset"],
    unique = true
)])
data class NativeBookmark(
    val id: String,
    val ownerBookUrl: String,
    val sourceId: String,
    val sourceBookUrl: String,
    val chapterUrl: String,
    val chapterIndex: Int,
    val chapterTitle: String,
    val textVersion: String,
    val textSha256: String,
    val textUtf16Length: Int,
    val paragraphUtf16Offset: Int,
    val excerpt: String,
    val createdAt: Long
)
