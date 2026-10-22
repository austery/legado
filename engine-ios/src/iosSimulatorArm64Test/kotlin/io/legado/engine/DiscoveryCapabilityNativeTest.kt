package io.legado.engine

import io.legado.app.data.entities.BookListPage
import io.legado.app.data.entities.BookSource
import io.legado.app.help.image.IosImageOps
import io.legado.app.help.source.exploreKinds
import io.legado.app.model.script.registerNativeJsEngines
import io.legado.app.model.webBook.BookListPager
import io.legado.app.model.webBook.parseExploreOptionsFromUrl
import kotlinx.coroutines.runBlocking
import platform.Foundation.NSUUID
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** Characterizes the pinned upstream implementation, without a second category parser. */
class DiscoveryCapabilityNativeTest {
    private fun source(rule: String) = BookSource(
        bookSourceUrl = "https://discovery-${NSUUID().UUIDString}.invalid", bookSourceName = "Discovery probe",
        exploreUrl = rule)

    @Test
    fun plainCategoriesPreserveHeadingAndActionKinds() = runBlocking {
        val kinds = source("TITLE:Rankings&&Popular::https://fixture.invalid/popular&&BUTTON:Refresh::'refresh'").exploreKinds()
        assertEquals(listOf("Rankings", "Popular", "Refresh"), kinds.map { it.title })
        assertEquals(listOf("title", "text", "button"), kinds.map { it.type })
        assertEquals(null, kinds[0].url)
        assertEquals("'refresh'", kinds[2].url)
    }

    @Test
    fun jsonAndNativeJsProducedCategoriesUseTheSameUpstreamModel() = runBlocking {
        registerNativeJsEngines(IosImageOps)
        val json = """[{"title":"Popular","url":"https://fixture.invalid/popular"}]"""
        val direct = source(json).exploreKinds()
        val scripted = source("@js:JSON.stringify([{title:'Popular',url:'https://fixture.invalid/popular'}])").exploreKinds()
        assertEquals(direct, scripted)
        assertEquals("Popular", scripted.single().title)
    }

    @Test
    fun malformedCategoriesAreErrorRowsRatherThanEmptySuccess() = runBlocking {
        assertTrue(source("").exploreKinds().isEmpty())
        val malformed = source("""["not an ExploreKind"]""").exploreKinds()
        assertTrue(malformed.single().title.startsWith("ERROR:"))
        assertFalse(malformed.single().url.isNullOrBlank(), "Upstream stores diagnostic text in the URL field; native must not navigate to it")
    }

    @Test
    fun upstreamOptionsAndPagerKeepTheirSelectionAndContinuationSemantics() {
        val options = parseExploreOptionsFromUrl("https://fixture.invalid/<Order(Hot:hot,New:new)>/<Tags(A:a,B:b)|,>")
        assertEquals(listOf("Order", "Tags"), options.map { it.name })
        assertEquals("hot", options[0].resolvedValue)
        assertTrue(options[1].multiSelect)
        options[1].selectedValues.addAll(listOf("b", "a"))
        assertEquals("a,b", options[1].resolvedValue)
        val pager = BookListPager()
        pager.advance(BookListPage(arrayListOf(), true, "https://fixture.invalid/cursor"), 0, 1)
        assertEquals(2, pager.page)
        assertEquals("https://fixture.invalid/cursor", pager.nextPageUrl)
        assertTrue(pager.hasNextPage)
        pager.advance(BookListPage(arrayListOf(), true), 1, 1)
        assertFalse(pager.hasNextPage, "Duplicate-only subsequent pages stop upstream paging")
    }
}
