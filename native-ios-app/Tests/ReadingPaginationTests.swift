import UIKit
import XCTest
@testable import NativeReader

@MainActor
final class ReadingPaginationTests: XCTestCase {
    private func attributed(_ body: String, size: CGFloat = 22) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 6
        paragraph.paragraphSpacing = 12
        return NSAttributedString(string: body, attributes: [.font: UIFont.systemFont(ofSize: size), .paragraphStyle: paragraph])
    }

    func testPagesCoverOriginalTextExactlyAcrossSupportedSizesAndUnicode() {
        let body = (0..<60).map { "Paragraph \($0) 中文 😀 e\u{301} 👩‍👩‍👧‍👦 " + String(repeating: "continuous text 中文 ", count: 20) }.joined(separator: "\r\n\n") + "\u{2028}End\u{2029}"
        for size: CGFloat in [16, 22, 36] {
            let layout = ReadingPagination(text: attributed(body, size: size), pageSize: CGSize(width: 316, height: 420))
            XCTAssertGreaterThan(layout.ranges.count, 2)
            var end = 0
            var reconstructed = ""
            for range in layout.ranges {
                XCTAssertEqual(range.location, end, "No omitted or duplicated characters")
                XCTAssertGreaterThan(range.length, 0)
                reconstructed += (body as NSString).substring(with: range)
                end = NSMaxRange(range)
                let container = layout.manager.textContainers[layout.ranges.firstIndex(of: range)!]
                XCTAssertLessThanOrEqual(layout.manager.usedRect(for: container).maxY, 420.5)
            }
            XCTAssertEqual(end, (body as NSString).length)
            XCTAssertEqual(reconstructed, body)
        }
    }

    func testEmptyAndSinglePageDoNotInventRightPageContent() {
        for body in ["", "Short chapter 😀\n"] {
            let layout = ReadingPagination(text: attributed(body), pageSize: CGSize(width: 400, height: 500))
            XCTAssertEqual(layout.ranges.count, 1)
            XCTAssertEqual(layout.ranges[0], NSRange(location: 0, length: (body as NSString).length))
            XCTAssertEqual(layout.page(containing: (body as NSString).length), 0)
        }
    }

    func testReflowKeepsParagraphWithoutUserSamplesAndTurnsAdvanceLongParagraph() {
        let body = "First\n" + String(repeating: "A long paragraph 中文 😀 e\u{301} ", count: 600) + "\nLast"
        let view = AnchoredTextView()
        view.delegate = view
        view.isEditable = false
        let host = UIViewController()
        host.view = view
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1100, height: 760))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        var samples: [Int] = []
        view.configure(chapterKey: "book/chapter", body: body, style: ReadingStyle(),
                       restoration: ReadingRestoration(identity: "token", utf16Offset: 6), onDisplayed: nil,
                       onParagraphScroll: { _, offset in samples.append(offset) })
        view.layoutIfNeeded()
        XCTAssertTrue(view.usesSpreads)
        let pages = view.spreadView!
        XCTAssertTrue(renderedSpreadRanges(in: view).contains { NSLocationInRange(6, $0) })
        let pagination = pages.pagination!
        for (index, container) in pagination.manager.textContainers.enumerated() {
            let glyphs = pagination.manager.glyphRange(for: container)
            XCTAssertEqual(pagination.manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil),
                           pagination.ranges[index], "Attaching actual text views must preserve pagination")
        }
        pages.scrollViewWillBeginDragging(pages)
        pages.setContentOffset(CGPoint(x: pages.bounds.width, y: 0), animated: false)
        pages.scrollViewDidEndDragging(pages, willDecelerate: false)
        XCTAssertEqual(pages.spread, 1)
        XCTAssertEqual(view.anchor, 6, "Long paragraph keeps paragraph-level progress while pages advance")
        view.setNeedsLayout(); view.layoutIfNeeded()
        XCTAssertEqual(pages.spread, 1, "Routine layout must not jump back to the paragraph's first page")
        var style = ReadingStyle(); style.size = 36
        view.configure(chapterKey: "book/chapter", body: body, style: style,
                       restoration: ReadingRestoration(identity: "token", utf16Offset: 0), onDisplayed: nil,
                       onParagraphScroll: { _, offset in samples.append(offset) })
        view.layoutIfNeeded()
        XCTAssertEqual(view.anchor, 6)
        XCTAssertTrue(renderedSpreadRanges(in: view).contains { NSLocationInRange(6, $0) })
        window.frame = CGRect(x: 0, y: 0, width: 850, height: 760)
        view.setNeedsLayout(); view.layoutIfNeeded()
        XCTAssertFalse(view.usesSpreads)
        XCTAssertEqual(view.anchor, 6)
        XCTAssertTrue(samples.isEmpty, "No displayed acknowledgment means no durable progress sampling")
    }
    func testAccessibleTurnsSaveOnlyDisplayedActiveToken() async throws {
        let body = (0..<120).map { "Paragraph \($0) " + String(repeating: "中文 text ", count: 20) }.joined(separator: "\n")
        let view = AnchoredTextView()
        view.delegate = view
        let host = UIViewController(); host.view = view
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1100, height: 760))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        var displayed: [String] = []
        var samples: [String] = []
        func configure(_ token: String, active: Bool) {
            view.configure(chapterKey: token, body: body, style: ReadingStyle(),
                           restoration: ReadingRestoration(identity: token, utf16Offset: 0),
                           onDisplayed: { id, _ in displayed.append(id) },
                           onParagraphScroll: { id, _ in samples.append(id) }, isReading: active)
            view.layoutIfNeeded()
        }
        configure("A", active: true)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(displayed, ["A"])
        XCTAssertTrue(view.accessibilityScroll(.left))
        XCTAssertGreaterThan(view.anchor, 0)
        XCTAssertEqual(samples, ["A"])
        configure("A", active: false)
        let anchor = view.anchor
        _ = view.accessibilityScroll(.left)
        XCTAssertEqual(view.anchor, anchor)
        XCTAssertEqual(samples, ["A"])
        configure("B", active: true)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(view.anchor, 0)
        XCTAssertEqual(displayed, ["A", "B"])
        XCTAssertFalse(view.accessibilityScroll(.right), "Chapter start must not advance or save")
        XCTAssertEqual(samples, ["A"])
        XCTAssertTrue(view.accessibilityScroll(.left))
        XCTAssertEqual(samples, ["A", "B"])
    }

}
