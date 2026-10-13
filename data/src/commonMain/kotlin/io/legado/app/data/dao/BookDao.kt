package io.legado.app.data.dao

import androidx.room3.Dao
import androidx.room3.Delete
import androidx.room3.Insert
import androidx.room3.OnConflictStrategy
import androidx.room3.Query
import androidx.room3.Transaction
import androidx.room3.Update
import io.legado.app.constant.BookType
import io.legado.app.data.entities.Book
import io.legado.app.data.entities.BookGroup
import io.legado.app.data.entities.BookSource
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map

@Dao
abstract class BookDao {

    open fun flowByGroup(groupId: Long): Flow<List<Book>> {
        return when (groupId) {
            BookGroup.IdRoot -> flowRoot()
            BookGroup.IdAll -> flowAll()
            BookGroup.IdLocal -> flowLocal()
            BookGroup.IdUngrouped -> flowNoGroup()
            BookGroup.IdError -> flowUpdateError()
            else -> flowByUserGroup(groupId)
        }.map { list ->
            list.filterNot { (it.type and BookType.notShelf) > 0 }
        }
    }

    @Query(
        """
        select * from books where type & ${BookType.text} > 0
        and type & ${BookType.local} = 0
        and ((SELECT sum(groupId) FROM book_groups where groupId > 0) & `group`) = 0
        and (select show from book_groups where groupId = ${BookGroup.IdUngrouped}) != 1
        """
    )
    abstract fun flowRoot(): Flow<List<Book>>

    @Query("SELECT * FROM books")
    abstract fun flowAll(): Flow<List<Book>>

    @Query("SELECT * FROM books WHERE type & ${BookType.local} > 0")
    abstract fun flowLocal(): Flow<List<Book>>

    @Query(
        """
        select * from books
        where ((SELECT sum(groupId) FROM book_groups where groupId > 0) & `group`) = 0
        """
    )
    abstract fun flowNoGroup(): Flow<List<Book>>

    @Query("SELECT * FROM books WHERE (`group` & :group) > 0")
    abstract fun flowByUserGroup(group: Long): Flow<List<Book>>

    @Query("SELECT * FROM books WHERE type & ${BookType.updateError} > 0")
    abstract fun flowUpdateError(): Flow<List<Book>>

    @Query("SELECT * FROM books WHERE `name` in (:names)")
    abstract suspend fun findByName(vararg names: String): List<Book>

    @Query("select * from books where originName = :fileName")
    abstract suspend fun getBookByFileName(fileName: String): Book?

    @Query("SELECT * FROM books WHERE bookUrl = :bookUrl")
    abstract suspend fun getBook(bookUrl: String): Book?

    @Query("SELECT * FROM books WHERE name = :name and author = :author")
    protected abstract suspend fun matchingBooks(name: String, author: String): List<Book>

    open suspend fun getBook(name: String, author: String): Book? =
        if (name.isBlank() || author.isBlank()) null else matchingBooks(name, author).singleOrNull()

    @Query("""select distinct bs.* from books, book_sources bs 
        where origin == bookSourceUrl and origin not like '${BookType.localTag}%' 
        and origin not like '${BookType.webDavTag}%'""")
    abstract suspend fun getAllUseBookSource(): List<BookSource>

    @Query("SELECT * FROM books WHERE name = :name and origin = :origin")
    protected abstract suspend fun booksByOrigin(name: String, origin: String): List<Book>

    open suspend fun getBookByOrigin(name: String, origin: String): Book? =
        booksByOrigin(name, origin).singleOrNull()

    @Query("SELECT name, author, bookUrl FROM books")
    abstract fun flowShelfBookKeys(): Flow<List<ShelfBookKey>>

    @Query(
        """
        SELECT * FROM books 
        WHERE name LIKE '%' || :key || '%' COLLATE NOCASE
        OR author LIKE '%' || :key || '%' COLLATE NOCASE
        OR originName LIKE '%' || :key || '%' COLLATE NOCASE
        OR kind LIKE '%' || :key || '%' COLLATE NOCASE
        OR intro LIKE '%' || :key || '%' COLLATE NOCASE
        ORDER BY durChapterTime DESC
        """
    )
    abstract fun searchShelfBooks(key: String): Flow<List<Book>>

    @Query("SELECT * FROM books")
    abstract suspend fun all(): List<Book>

    @Query("SELECT * FROM books where type & ${BookType.text} > 0 ORDER BY durChapterTime DESC limit 1")
    abstract suspend fun lastReadBook(): Book?

    @Query("SELECT name, bookUrl FROM books")
    abstract suspend fun allBookUrlsWithName(): List<BookFolder>

    @Query("SELECT COUNT(*) FROM books")
    abstract suspend fun allBookCount(): Int

    @Query("select min(`order`) from books")
    abstract suspend fun minOrder(): Int

    @Query("select exists(select 1 from books where bookUrl = :bookUrl)")
    abstract suspend fun has(bookUrl: String): Boolean

    open suspend fun has(name: String, author: String): Boolean = getBook(name, author) != null

    @Query(
        """select exists(select 1 from books where type & ${BookType.local} > 0 
        and (originName = :fileName or (origin != '${BookType.localTag}' and origin like '%' || :fileName)))"""
    )
    abstract suspend fun hasFile(fileName: String): Boolean

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    protected abstract suspend fun insertRaw(book: Book)

    @Update
    protected abstract suspend fun updateRaw(book: Book)

    @Query("DELETE FROM books WHERE bookUrl = :bookUrl")
    protected abstract suspend fun deleteRaw(bookUrl: String)

    /** Preserve legacy known-author REPLACE behavior inside one writer transaction. */
    @Transaction
    open suspend fun insert(vararg book: Book) {
        for (candidate in book) {
            if (candidate.name.isNotBlank() && candidate.author.isNotBlank()) {
                val matches = matchingBooks(candidate.name, candidate.author)
                if (matches.size > 1) throw BookIdentityConflictException("Ambiguous known-author book identity")
                matches.filter { it.bookUrl != candidate.bookUrl }.forEach { deleteRaw(it.bookUrl) }
            }
            insertRaw(candidate)
        }
    }

    /** Missing primary keys remain no-ops; colliding known-author edits fail atomically. */
    @Transaction
    open suspend fun update(vararg book: Book) {
        for (candidate in book) {
            if (getBook(candidate.bookUrl) == null) continue
            if (candidate.name.isNotBlank() && candidate.author.isNotBlank()) {
                if (matchingBooks(candidate.name, candidate.author).any { it.bookUrl != candidate.bookUrl }) {
                    throw BookIdentityConflictException("Known-author book identity conflict")
                }
            }
            updateRaw(candidate)
        }
    }

    @Delete
    abstract suspend fun delete(vararg book: Book)

    @Transaction
    open suspend fun replace(oldBook: Book, newBook: Book) {
        delete(oldBook)
        insert(newBook)
    }

    /**
     * 仅 PATCH 当前章节定位 (目录选章节跳阅读). 整行 update 会冲掉并发写入的其他列,
     * 也会与阅读退出时的 [updateProgress] 互相覆盖.
     */
    @Query("update books set durChapterIndex = :index, durChapterPos = :pos where bookUrl = :bookUrl")
    abstract suspend fun upDurChapter(bookUrl: String, index: Int, pos: Int)

    /**
     * 仅 PATCH 进度字段, 避免阅读/播放界面退出时的整行 update 冲掉后台
     * updateToc/refreshBookInfo 写入的最新元数据.
     */
    @Query(
        """update books set
            durChapterIndex = :durChapterIndex,
            durChapterPos = :durChapterPos,
            durChapterTime = :durChapterTime,
            durChapterTitle = :durChapterTitle,
            lastCheckCount = 0
            where bookUrl = :bookUrl"""
    )
    abstract suspend fun updateProgress(
        bookUrl: String,
        durChapterIndex: Int,
        durChapterPos: Int,
        durChapterTime: Long,
        durChapterTitle: String?
    )

    /**
     * WebDAV 上传进度成功后只落 syncTime
     */
    @Query("update books set syncTime = :syncTime where bookUrl = :bookUrl")
    abstract suspend fun upSyncTime(bookUrl: String, syncTime: Long)

    /**
     * 仅 PATCH 阅读配置列 (readConfig); 阅读界面菜单改的是整场持有的内存副本 book.config,
     * 整行 update 会冲掉并发 updateToc/refreshBookInfo 写入的其他字段.
     */
    @Query("update books set readConfig = :readConfig where bookUrl = :bookUrl")
    abstract suspend fun updateReadConfig(bookUrl: String, readConfig: Book.ReadConfig?)

    /**
     * 仅 PATCH 检查记录 (lastCheckTime + totalChapterNum); 缓存/更新流程持有长生命周期
     * 快照且期间跑网络请求, 整行 update 会冲掉期间别处写入的字段.
     */
    @Query("update books set lastCheckTime = :lastCheckTime, totalChapterNum = :totalChapterNum where bookUrl = :bookUrl")
    abstract suspend fun updateLastCheckTime(bookUrl: String, lastCheckTime: Long, totalChapterNum: Int)

    /**
     * 仅 PATCH 目录相关列; 目录刷新 (getChapterListAwait) 改的是内存快照 book,
     * 整行 update 会冲掉阅读/播放界面并发 PATCH 写入的进度字段.
     */
    @Query(
        """update books set
            totalChapterNum = :totalChapterNum,
            lastCheckTime = :lastCheckTime,
            lastCheckCount = :lastCheckCount,
            latestChapterTitle = :latestChapterTitle,
            latestChapterTime = :latestChapterTime,
            durChapterTitle = :durChapterTitle
            where bookUrl = :bookUrl"""
    )
    abstract suspend fun updateTocInfo(
        bookUrl: String,
        totalChapterNum: Int,
        lastCheckTime: Long,
        lastCheckCount: Int,
        latestChapterTitle: String?,
        latestChapterTime: Long,
        durChapterTitle: String?
    )

    /**
     * 仅 PATCH 排序列; 书架管理拖拽排序持有的是长生命周期内存副本,
     * 整行 update 会把副本里的旧元数据写回去.
     */
    @Query("update books set `order` = :order where bookUrl = :bookUrl")
    abstract suspend fun upOrder(bookUrl: String, order: Int)

    @Query("update books set `group` = `group` - :group where `group` & :group > 0")
    abstract suspend fun removeGroup(group: Long)

    @Query("delete from books where type & ${BookType.notShelf} > 0")
    abstract suspend fun deleteNotShelfBook()
}

data class BookFolder(
    val name: String,
    val bookUrl: String
)

data class ShelfBookKey(
    val name: String,
    val author: String,
    val bookUrl: String
)

/** A shared identity conflict, distinct from storage or parsing failures. */
class BookIdentityConflictException(message: String) : IllegalStateException(message)
