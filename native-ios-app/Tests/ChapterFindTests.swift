import UIKit
import XCTest
@testable import NativeReader

@MainActor
final class ChapterFindTests: XCTestCase {
    func testLiteralQueriesUseOriginalUnicodeRangesAndNonOverlappingResults() {
        let find = ChapterFindSession()
        find.open(ChapterFindContext(chapterKey: "source/book/chapter", readingIdentity: "reading", text: "猫😀猫\nCat cat\né e\u{301}\n😀"))
        find.query = "猫"
        XCTAssertEqual(find.matches, [NSRange(location: 0, length: 1), NSRange(location: 3, length: 1)])
        find.query = "😀"
        XCTAssertEqual(find.matches, [NSRange(location: 1, length: 2), NSRange(location: 18, length: 2)])
        find.query = "cat"
        XCTAssertEqual(find.matches, [NSRange(location: 9, length: 3)], "Queries are case sensitive")
        find.query = "é"
        XCTAssertEqual(find.matches, [NSRange(location: 13, length: 1)], "No canonical body normalization")
        find.query = "e\u{301}"
        XCTAssertEqual(find.matches, [NSRange(location: 15, length: 2)])
        find.query = "missing"
        XCTAssertTrue(find.matches.isEmpty)
        find.query = ""
        XCTAssertTrue(find.matches.isEmpty)
        find.open(ChapterFindContext(chapterKey: "source/book/chapter", readingIdentity: "reading", text: "aaaaa"))
        find.query = "aa"
        XCTAssertEqual(find.matches, [NSRange(location: 0, length: 2), NSRange(location: 2, length: 2)])
    }
    func testOnlyExplicitNavigationSelectsAndContextChangesRetireFind() {
        let find = ChapterFindSession()
        let context = ChapterFindContext(chapterKey: "source/book/chapter", readingIdentity: "reading", text: "cat cat")
        find.open(context)
        find.query = "cat"
        XCTAssertNil(find.selectedIndex, "Typing must not select or navigate")
        find.move(forward: true)
        XCTAssertEqual(find.selectedIndex, 0)
        find.move(forward: true)
        XCTAssertEqual(find.selectedIndex, 1)
        find.move(forward: true)
        XCTAssertEqual(find.selectedIndex, 0, "Next wraps")
        find.move(forward: false)
        XCTAssertEqual(find.selectedIndex, 1, "Previous wraps")
        find.updateContext(context)
        XCTAssertEqual(find.selectedIndex, 1)
        find.query = "missing"
        XCTAssertNil(find.selectedIndex)
        find.move(forward: true)
        XCTAssertNil(find.selectedIndex)
        for replacement in [
            ChapterFindContext(chapterKey: "source/book/other", readingIdentity: "reading", text: context.text),
            ChapterFindContext(chapterKey: context.chapterKey, readingIdentity: "new-session", text: context.text),
            ChapterFindContext(chapterKey: context.chapterKey, readingIdentity: context.readingIdentity, text: "new body")
        ] {
            find.open(context); find.query = "cat"; find.move(forward: true)
            find.updateContext(replacement)
            XCTAssertFalse(find.isPresented)
            XCTAssertTrue(find.query.isEmpty)
            XCTAssertTrue(find.matches.isEmpty)
            XCTAssertNil(find.selectedIndex)
        }
        find.open(context); find.query = "cat"; find.move(forward: false)
        XCTAssertEqual(find.selectedIndex, 1)
        find.close()
        XCTAssertFalse(find.isPresented)
        find.move(forward: true)
        XCTAssertNil(find.selectedIndex)
    }

}
