import Foundation
import ReaderEngine

struct DiscoverySourceFixture: Encodable {
    var bookSourceUrl: String
    var bookSourceName = "Discovery test source"
    var bookSourceType = 0
    var enabled = true
    var enabledExplore = true
    var bookSourceGroup = "Discovery"
    var lastUpdateTime = 1
    var exploreUrl: String
    var jsLib: String?
    var searchUrl: String
    var ruleSearch = ["bookList": "id.search-only", "name": "text", "bookUrl": "text"]
    var ruleExplore = ["bookList": "class.discovery-book", "name": "class.name@text", "author": "class.author@text",
        "intro": "class.intro@text", "bookUrl": "class.name@href", "nextPageUrl": "class.next@href",
        "hasMoreRule": "result.indexOf('data-more=' + String.fromCharCode(34) + 'true') >= 0"]
    var ruleBookInfo = ["name": "tag.h1@text", "author": "class.author@text", "intro": "class.intro@text", "tocUrl": "class.toc@href"]
    var ruleToc = ["chapterList": "class.chapter", "chapterName": "text", "chapterUrl": "href"]
    var ruleContent = ["content": "id.content@text", "nextContentUrl": "class.next@href"]
    init(base: String, id: String? = nil, categories: String? = nil) {
        bookSourceUrl = id ?? base
        searchUrl = base + "/search?key={{key}}&page={{page}}"
        exploreUrl = categories ?? "Popular::" + base + "/discover/normal?page={{page}}"
    }
    func json() throws -> String { String(decoding: try JSONEncoder().encode(self), as: UTF8.self) }
}
