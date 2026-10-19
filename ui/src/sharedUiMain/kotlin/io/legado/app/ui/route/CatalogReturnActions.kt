package io.legado.app.ui.route

import io.legado.app.data.AppDbProviders
import io.legado.app.help.book.isNotShelf
import io.legado.app.ui.book.info.BookInfoScreenModel
import io.legado.app.ui.book.toc.TocScreenModel
import io.legado.app.ui.book.toc.TocUiEvent
import io.legado.app.ui.root.AppNavigator
import io.legado.app.ui.root.RouteEntryId
import io.legado.app.help.IntentData
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch

/** Reverse only a complete catalog and publish its new order to returning owners. */
internal fun reverseTocCatalog(
    screenModel: TocScreenModel,
    navigator: AppNavigator,
    ownerEntryId: RouteEntryId?,
    scope: CoroutineScope,
) {
    val state = screenModel.state.value
    if (!state.canReverseCatalog) return
    val current = state.chapters
    if (current.isEmpty()) return
    val reversed = current.reversed().mapIndexed { i, c -> c.copy(index = i) }
    screenModel.dispatch(TocUiEvent.ReverseChapterList(reversed))
    val curBook = screenModel.state.value.book ?: return
    curBook.config.reverseToc = !curBook.config.reverseToc
    ownerEntryId?.let { navigator.updateSourceCatalog(it, curBook, reversed) }
    scope.launch {
        val db = AppDbProviders.get()
        if (curBook.isNotShelf) return@launch
        db.bookChapterDao.insert(*reversed.toTypedArray())
    }
}

/** Preserve the existing unshelved-book handoff used by both details entry paths. */
internal fun handoffDetailsCatalog(screenModel: BookInfoScreenModel) {
    if (!screenModel.state.value.inBookshelf) {
        IntentData.chapterList = screenModel.loadedChapterList
    }
}
