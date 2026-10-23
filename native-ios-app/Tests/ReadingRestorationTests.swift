import SwiftUI
import UIKit
import XCTest
@testable import NativeReader

@MainActor
final class ReadingRestorationTests: XCTestCase {
    private func settle(_ host: UIViewController) async throws {
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 100_000_000)
        host.view.layoutIfNeeded()
    }

    private func textView(_ root: UIView) -> AnchoredTextView? {
        if let view = root as? AnchoredTextView { return view }
        return root.subviews.lazy.compactMap { self.textView($0) }.first
    }

    func testRestoresParagraphOnlyAfterAttachedLayoutAndDoesNotSampleRestoration() async throws {
        let body = (0..<160).map { "Paragraph \($0) 中文 😀 e\u{301} 👩‍👩‍👧‍👦 continued reading." }.joined(separator: "\r\n")
        let target = (body as NSString).range(of: "Paragraph 90 ").location
        var displayed: [(String, Int)] = []
        var samples: [Int] = []
        let host = UIHostingController(rootView: ReadingText(chapterKey: "body", text: body, style: ReadingStyle(),
            restoration: ReadingRestoration(identity: "token", utf16Offset: target + 4),
            onDisplayed: { displayed.append(($0, $1)) }, onParagraphScroll: { _, offset in samples.append(offset) }))
        host.loadViewIfNeeded()
        try await settle(host)
        XCTAssertTrue(displayed.isEmpty, "Detached layout is not displayed body evidence")
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 768, height: 1024))
        window.rootViewController = host
        host.view.isHidden = true
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await settle(host)
        XCTAssertTrue(displayed.isEmpty, "Hidden layout is not displayed body evidence")
        host.view.isHidden = false
        textView(host.view)?.setNeedsLayout()
        try await settle(host)
        XCTAssertEqual(displayed.map(\.0), ["token"])
        XCTAssertEqual(displayed.map(\.1), [target])
        XCTAssertTrue(samples.isEmpty)
        let view = try XCTUnwrap(textView(host.view))
        XCTAssertGreaterThan(view.contentOffset.y, 0)
        let position = try XCTUnwrap(view.position(from: view.beginningOfDocument, offset: target))
        XCTAssertTrue(view.bounds.intersects(view.caretRect(for: position)))
    }

    func testStableTokenIgnoresEvolvingOffsetAndStyleDoesNotEmitUserSamples() async throws {
        let body = (0..<160).map { "Paragraph \($0): Chinese 中文 and emoji 😀 with enough text." }.joined(separator: "\n")
        let target = (body as NSString).range(of: "Paragraph 90:").location
        var displayed: [Int] = []
        var samples: [Int] = []
        var style = ReadingStyle()
        let host = UIHostingController(rootView: ReadingText(chapterKey: "body", text: body, style: style,
            restoration: ReadingRestoration(identity: "stable", utf16Offset: target),
            onDisplayed: { _, offset in displayed.append(offset) }, onParagraphScroll: { _, offset in samples.append(offset) }))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 768, height: 1024))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await settle(host)
        let view = try XCTUnwrap(textView(host.view))
        style.size = 30; style.margin = 45
        host.rootView = ReadingText(chapterKey: "body", text: body, style: style,
            restoration: ReadingRestoration(identity: "stable", utf16Offset: 0),
            onDisplayed: { _, offset in displayed.append(offset) }, onParagraphScroll: { _, offset in samples.append(offset) })
        window.frame = CGRect(x: 0, y: 0, width: 1024, height: 768)
        try await settle(host)
        XCTAssertEqual(displayed, [target])
        XCTAssertTrue(samples.isEmpty)
        XCTAssertNotNil(view.spreadView)
        XCTAssertTrue(view.usesSpreads)
        XCTAssertTrue(renderedSpreadRanges(in: view).contains { NSLocationInRange(target, $0) })
        // Return to the narrow layout and drive the public scroll delegate lifecycle on the real laid-out UITextView.
        window.frame = CGRect(x: 0, y: 0, width: 768, height: 1024)
        try await settle(host)
        XCTAssertFalse(view.usesSpreads)
        view.scrollViewWillBeginDragging(view)
        view.setContentOffset(CGPoint(x: 0, y: 0), animated: false)
        view.scrollViewDidScroll(view)
        view.scrollViewDidEndDragging(view, willDecelerate: false)
        XCTAssertEqual(samples.last, 0)
        XCTAssertEqual(displayed, [target])
        host.rootView = ReadingText(chapterKey: "body", text: body, style: style,
            restoration: ReadingRestoration(identity: "stable", utf16Offset: target),
            onDisplayed: { _, offset in displayed.append(offset) }, onParagraphScroll: { _, offset in samples.append(offset) })
        try await settle(host)
        XCTAssertEqual(view.contentOffset.y, 0, accuracy: 1)
        XCTAssertEqual(displayed, [target])
    }

    func testCanonicalUtf16DelimitersEndAndInvalidPositions() async throws {
        let body = "A😀\r\nB\nC\rD\u{2028}E\u{2029}"
        let cases: [(Int, Int?)] = [(0, 0), (2, nil), (3, 0), (4, 0), (5, 5), (6, 5), (7, 7), (8, 7), (9, 9), (10, 9), (11, 11), (12, 11), (13, 13), (-1, nil), (14, nil)]
        var displayed: [Int] = []
        let host = UIHostingController(rootView: ReadingText(chapterKey: "body", text: body, style: ReadingStyle()))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 768, height: 1024))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        for (index, item) in cases.enumerated() {
            displayed = []
            host.rootView = ReadingText(chapterKey: "body", text: body, style: ReadingStyle(),
                restoration: ReadingRestoration(identity: "case-\(index)", utf16Offset: item.0),
                onDisplayed: { _, offset in displayed.append(offset) })
            try await settle(host)
            XCTAssertEqual(displayed, item.1.map { [$0] } ?? [], "Input offset \(item.0)")
        }
        displayed = []
        host.rootView = ReadingText(chapterKey: "last", text: "First\nLast😀", style: ReadingStyle(),
            restoration: ReadingRestoration(identity: "end", utf16Offset: 12),
            onDisplayed: { _, offset in displayed.append(offset) })
        try await settle(host)
        XCTAssertEqual(displayed, [6])
        for (index, item) in [("First\n\nLast", 7, 7), ("e\u{301}👩‍👩‍👧‍👦中文", 2, 0), ("", 0, 0)].enumerated() {
            displayed = []
            host.rootView = ReadingText(chapterKey: "extra", text: item.0, style: ReadingStyle(),
                restoration: ReadingRestoration(identity: "extra-\(index)", utf16Offset: item.1),
                onDisplayed: { _, offset in displayed.append(offset) })
            try await settle(host)
            XCTAssertEqual(displayed, [item.2])
        }
    }
}
