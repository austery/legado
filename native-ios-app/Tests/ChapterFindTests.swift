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

    func testHighlightsSurviveReflowWithoutChangingBodySelectionOrSamplingTyping() async throws {
        let body = "Start\n" + String(repeating: "plain body text\n", count: 100) + "NEEDLE target\n" + String(repeating: "following body\n", count: 100)
        let context = ChapterFindContext(chapterKey: "source/book/chapter", readingIdentity: "reading", text: body)
        let find = ChapterFindSession()
        var style = ReadingStyle()
        let view = AnchoredTextView(); view.delegate = view; view.isEditable = false
        let host = UIViewController(); host.view = view
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 834, height: 1194))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        var samples: [Int] = []
        func configure() {
            view.configure(chapterKey: context.chapterKey, body: body, style: style,
                restoration: ReadingRestoration(identity: context.readingIdentity, utf16Offset: 0),
                onDisplayed: { _, _ in }, onParagraphScroll: { _, offset in samples.append(offset) })
            view.applyFind(find.presentation); view.layoutIfNeeded()
        }
        configure(); try await Task.sleep(nanoseconds: 150_000_000)
        view.selectedRange = NSRange(location: 0, length: 1)
        find.open(context); find.query = "NEEDLE"; configure()
        XCTAssertEqual(find.matches, [NSRange(location: 1606, length: 6)])
        XCTAssertNotNil(view.textStorage.attribute(.backgroundColor, at: 1606, effectiveRange: nil))
        XCTAssertEqual(view.selectedRange, NSRange(location: 0, length: 1), "Highlighting must preserve native selection")
        XCTAssertEqual(view.anchor, 0)
        XCTAssertTrue(samples.isEmpty, "Typing/highlighting is not a reading action")
        find.move(forward: true); configure()
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(samples, [1606])
        XCTAssertEqual(view.anchor, 1606)
        style.size = 30; configure()
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertNotNil(view.textStorage.attribute(.backgroundColor, at: 1606, effectiveRange: nil), "Typography must retain the selected highlight")
        XCTAssertEqual(view.text, body)
        XCTAssertEqual(samples, [1606], "Reflow is not another reading action")
        window.frame = CGRect(x: 0, y: 0, width: 1194, height: 834)
        configure(); try await Task.sleep(nanoseconds: 150_000_000); view.layoutIfNeeded()
        XCTAssertTrue(view.usesSpreads)
        let pages = try XCTUnwrap(view.spreadView)
        XCTAssertTrue(pages.visibleRanges.contains { NSLocationInRange(1606, $0) })
        let page = try XCTUnwrap(pages.subviews.compactMap { $0 as? ReadingPageTextView }.first { NSLocationInRange(1606, $0.originalRange) })
        XCTAssertNotNil(page.textStorage.attribute(.backgroundColor, at: 1606 - page.originalRange.location, effectiveRange: nil))
        XCTAssertEqual(samples, [1606])
        find.close(); configure()
        XCTAssertNil(page.textStorage.attribute(.backgroundColor, at: 1606 - page.originalRange.location, effectiveRange: nil))
        XCTAssertEqual(view.anchor, 1606)
        XCTAssertEqual(view.text, body)
    }

    func testRetiredReadingContextRejectsQueuedNavigationAndOldHighlights() async throws {
        let body = "Start\n" + String(repeating: "plain body text\n", count: 60) + "NEEDLE target"
        let old = ChapterFindContext(chapterKey: "source/book/chapter", readingIdentity: "old", text: body)
        let find = ChapterFindSession()
        let view = AnchoredTextView(); view.delegate = view; view.isEditable = false
        let host = UIViewController(); host.view = view
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1194, height: 834))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        var samples: [String] = []
        view.configure(chapterKey: old.chapterKey, body: body, style: ReadingStyle(),
            restoration: ReadingRestoration(identity: old.readingIdentity, utf16Offset: 0),
            onDisplayed: { _, _ in }, onParagraphScroll: { token, _ in samples.append(token) })
        view.layoutIfNeeded(); try await Task.sleep(nanoseconds: 150_000_000)
        find.open(old); find.query = "NEEDLE"; find.move(forward: true)
        let retired = find.presentation
        view.applyFind(retired)
        // Retire before the queued user-position publication can reach the coordinator.
        view.configure(chapterKey: "source/book/new-chapter", body: "New chapter", style: ReadingStyle(),
            restoration: ReadingRestoration(identity: "new", utf16Offset: 0),
            onDisplayed: { _, _ in }, onParagraphScroll: { token, _ in samples.append(token) })
        view.applyFind(retired); view.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(samples.isEmpty)
        XCTAssertEqual(view.anchor, 0)
        XCTAssertEqual(view.text, "New chapter")
        XCTAssertNil(view.textStorage.attribute(.backgroundColor, at: 0, effectiveRange: nil))
        for page in view.spreadView?.subviews.compactMap({ $0 as? ReadingPageTextView }) ?? [] where page.textStorage.length > 0 {
            XCTAssertNil(page.textStorage.attribute(.backgroundColor, at: 0, effectiveRange: nil))
        }
    }

    func testFindHighlightCrossesPageBoundaryWithoutChangingOriginalCharacters() throws {
        let body = (0..<350).map { "word-\($0) 😀 中文 continuous reading " }.joined()
        let source = NSAttributedString(string: body, attributes: [.font: UIFont.systemFont(ofSize: 22)])
        let pages = ReadingSpreadView(frame: CGRect(x: 0, y: 0, width: 1194, height: 760))
        pages.reflow(text: source, margin: 28, anchor: 0, paper: .white)
        let layout = try XCTUnwrap(pages.pagination)
        XCTAssertGreaterThan(layout.ranges.count, 2)
        let boundary = layout.ranges[1].location
        let match = (body as NSString).rangeOfComposedCharacterSequences(for: NSRange(location: boundary - 1, length: 2))
        pages.updateFindHighlights(matches: [match], selected: match)
        let left = try XCTUnwrap(pages.subviews.compactMap { $0 as? ReadingPageTextView }.first { $0.originalRange == layout.ranges[0] })
        let right = try XCTUnwrap(pages.subviews.compactMap { $0 as? ReadingPageTextView }.first { $0.originalRange == layout.ranges[1] })
        XCTAssertNotNil(left.textStorage.attribute(.backgroundColor, at: left.textStorage.length - 1, effectiveRange: nil))
        XCTAssertNotNil(right.textStorage.attribute(.backgroundColor, at: 0, effectiveRange: nil))
        XCTAssertEqual(left.text, (body as NSString).substring(with: left.originalRange))
        XCTAssertEqual(right.text, (body as NSString).substring(with: right.originalRange))
        pages.updateFindHighlights(matches: [], selected: nil)
        XCTAssertNil(left.textStorage.attribute(.backgroundColor, at: left.textStorage.length - 1, effectiveRange: nil))
        XCTAssertNil(right.textStorage.attribute(.backgroundColor, at: 0, effectiveRange: nil))
    }

    func testManualSpreadTurnRetiresFindRevealBeforeTypographyReflow() async throws {
        let body = (0..<240).map { "Paragraph \($0) continued reading text." }.joined(separator: "\n")
        let context = ChapterFindContext(chapterKey: "source/book/chapter", readingIdentity: "reading", text: body)
        let find = ChapterFindSession(); find.open(context); find.query = "Paragraph 10 "
        var style = ReadingStyle()
        let view = AnchoredTextView(); view.delegate = view; view.isEditable = false
        let host = UIViewController(); host.view = view
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1194, height: 834))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        var samples: [Int] = []
        func configure() {
            view.configure(chapterKey: context.chapterKey, body: body, style: style,
                restoration: ReadingRestoration(identity: context.readingIdentity, utf16Offset: 0),
                onDisplayed: { _, _ in }, onParagraphScroll: { _, offset in samples.append(offset) })
            view.applyFind(find.presentation); view.layoutIfNeeded()
        }
        configure(); try await Task.sleep(nanoseconds: 150_000_000)
        find.move(forward: true); configure(); try await Task.sleep(nanoseconds: 150_000_000)
        let matchAnchor = view.anchor
        let pages = try XCTUnwrap(view.spreadView)
        XCTAssertTrue(pages.accessibilityScroll(.left), "A real user paging action must advance")
        let accepted = view.anchor
        XCTAssertGreaterThan(accepted, matchAnchor)
        XCTAssertEqual(samples.last, accepted)
        let sampleCount = samples.count
        style.size = 30; configure(); try await Task.sleep(nanoseconds: 150_000_000); view.layoutIfNeeded()
        XCTAssertTrue(try XCTUnwrap(view.spreadView).visibleRanges.contains { NSLocationInRange(accepted, $0) },
                      "Reflow must follow the latest user page turn rather than the older Find hit")
        XCTAssertEqual(view.anchor, accepted)
        XCTAssertEqual(samples.count, sampleCount, "Reflow itself must not save another position")
    }

}
