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
}
