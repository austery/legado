package io.legado.app.data.entities

import androidx.room3.Entity
import androidx.room3.ForeignKey

/** Native coordinates are separate from the legacy chapter-level projection. */
@Entity(tableName = "native_reading_resume", primaryKeys = ["bookUrl"], foreignKeys = [ForeignKey(
    entity = Book::class, parentColumns = ["bookUrl"], childColumns = ["bookUrl"], onDelete = ForeignKey.CASCADE
)])
data class NativeReadingResume(
    val bookUrl: String,
    val sourceId: String,
    val chapterUrl: String,
    val chapterIndex: Int,
    val textVersion: String,
    val textSha256: String,
    val textUtf16Length: Int,
    val paragraphUtf16Offset: Int,
    val revision: Long,
    val savedAt: Long
)
