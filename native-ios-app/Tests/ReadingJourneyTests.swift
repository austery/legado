import XCTest
import ReaderEngine
import SwiftUI
@testable import NativeReader

@MainActor
final class ReadingJourneyTests: XCTestCase {
    private func findText(_ view: UIView) -> UITextView? {
        if let text = view as? UITextView { return text }
        return view.subviews.lazy.compactMap { self.findText($0) }.first
    }

    private func checkDirectoryRoundTrip(_ model: ReaderModel) async throws {
        let host = UIHostingController(rootView: ReaderScreen(model: model))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 768, height: 1024))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(nanoseconds: 200_000_000)
        host.view.layoutIfNeeded()
        let text = try XCTUnwrap(findText(host.view))
        text.layoutManager.ensureLayout(for: text.textContainer)
        let glyphs = text.layoutManager.glyphRange(forCharacterRange: (text.text as NSString).range(of: "第50段"), actualCharacterRange: nil)
        let rect = text.layoutManager.boundingRect(forGlyphRange: glyphs, in: text.textContainer)
        text.setContentOffset(CGPoint(x: 0, y: rect.minY), animated: false)
        try await Task.sleep(nanoseconds: 100_000_000)
        let offset = text.contentOffset.y
        XCTAssertGreaterThan(offset, 0)
        model.navigate(.contents)
        try await Task.sleep(nanoseconds: 100_000_000)
        model.navigate(.reading)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(findText(host.view) === text)
        XCTAssertEqual(text.contentOffset.y, offset, accuracy: 2)
        let attachment = XCTAttachment(image: UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true) })
        attachment.name = "Reader controls after contents round trip"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testTypographyAndResizeKeepVisibleParagraph() async throws {
        let text = (0..<200).map { "第\($0)段：春天的风吹过窗前，读者继续阅读。标点、中文与 emoji 🌿 都应保持完整。" }.joined(separator: "\n\n")
        var style = ReadingStyle()
        let host = UIHostingController(rootView: ReadingText(chapterKey: "sample", text: text, style: style))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 768, height: 1024))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(nanoseconds: 200_000_000)
        host.view.layoutIfNeeded()
        let view = try XCTUnwrap(findText(host.view))
        let target = (text as NSString).range(of: "第100段")
        view.layoutManager.ensureLayout(for: view.textContainer)
        let targetGlyphs = view.layoutManager.glyphRange(forCharacterRange: target, actualCharacterRange: nil)
        let targetRect = view.layoutManager.boundingRect(forGlyphRange: targetGlyphs, in: view.textContainer)
        view.setContentOffset(CGPoint(x: 0, y: targetRect.minY), animated: false)
        try await Task.sleep(nanoseconds: 100_000_000)
        let point = CGPoint(x: view.textContainerInset.left + 1, y: view.contentOffset.y + view.textContainerInset.top + 1)
        let position = try XCTUnwrap(view.closestPosition(to: point))
        let anchor = view.offset(from: view.beginningOfDocument, to: position)
        let paragraph = (text as NSString).paragraphRange(for: NSRange(location: anchor, length: 0))
        XCTAssertGreaterThan(paragraph.location, 0)
        style.size = 30; style.lineSpacing = 12; style.paragraphSpacing = 24; style.margin = 48
        host.rootView = ReadingText(chapterKey: "sample", text: text, style: style)
        window.frame = CGRect(x: 0, y: 0, width: 1024, height: 768)
        try await Task.sleep(nanoseconds: 200_000_000)
        host.view.layoutIfNeeded()
        let visible = view.layoutManager.glyphRange(forBoundingRect: CGRect(x: 0, y: view.contentOffset.y, width: view.bounds.width, height: view.bounds.height), in: view.textContainer)
        let characters = view.layoutManager.characterRange(forGlyphRange: visible, actualGlyphRange: nil)
        XCTAssertTrue(NSIntersectionRange(characters, paragraph).length > 0, "Original paragraph must remain visible")
        XCTAssertEqual(view.text, text)
        let attachment = XCTAttachment(image: UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true) })
        attachment.name = "Long Chinese text after typography and landscape resize"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func settle(_ model: ReaderModel, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(20)
        while model.busy && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertFalse(model.busy, "Operation did not finish", file: file, line: line)
    }

    func testRealImportSearchContentsReadingAndCancellation() async throws {
        let model = ReaderModel()
        model.start()
        model.cancel()
        XCTAssertFalse(model.initialized)
        model.start()
        try await settle(model)
        XCTAssertNil(model.message)
        let sourceURL = try XCTUnwrap(URL(string: "http://127.0.0.1:18769/runs/\(UUID().uuidString)/sources.json"))
        let (data, _) = try await URLSession.shared.data(from: sourceURL)
        let importURL = FileManager.default.temporaryDirectory.appendingPathComponent("sources-\(UUID().uuidString).json")
        try data.write(to: importURL)
        model.importFile(importURL)
        try await settle(model)
        XCTAssertNil(model.message)
        XCTAssertTrue(model.importDetails?.contains(importURL.lastPathComponent) == true)
        model.sourceID = String(sourceURL.absoluteString.dropLast("/sources.json".count))
        XCTAssertTrue(model.sources.contains { $0.id == model.sourceID })
        model.query = "Path"
        model.search()
        try await settle(model)
        XCTAssertNil(model.message)
        let book = try XCTUnwrap(model.results.first)
        XCTAssertEqual(book.title, "Path C Book")
        model.select(book)
        try await settle(model)
        XCTAssertNil(model.message)
        XCTAssertEqual(model.route, .contents)
        XCTAssertEqual(model.chapters.count, 3)
        let chapter = try XCTUnwrap(model.chapters.first)
        model.read(chapter)
        try await settle(model)
        XCTAssertEqual(model.route, .reading)
        let first = try XCTUnwrap(model.content)
        XCTAssertTrue(first.text.contains("C1-FIRST"))
        XCTAssertTrue(first.text.contains("C1-MIDDLE"))
        XCTAssertTrue(first.text.contains("C1-LAST"))
        XCTAssertFalse(first.fromCache)
        model.moveChapter(1)
        try await settle(model)
        XCTAssertTrue(model.content?.text.contains("C2-LAST") == true)
        XCTAssertEqual(model.chapterPosition, 1)
        try await checkDirectoryRoundTrip(model)
        let second = try XCTUnwrap(model.content)
        model.moveChapter(-1)
        model.cancel()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNil(model.message)
        XCTAssertEqual(model.content?.chapter.id, second.chapter.id)
        XCTAssertEqual(model.content?.text, second.text)
        model.moveChapter(1)
        try await settle(model)
        XCTAssertNotNil(model.message)
        XCTAssertTrue(model.canRetry)
        XCTAssertEqual(model.content?.chapter.id, second.chapter.id)
        XCTAssertEqual(model.content?.text, second.text)
        model.retry()
        try await settle(model)
        XCTAssertNil(model.message)
        XCTAssertTrue(model.content?.text.contains("C3-LAST") == true)
        model.navigate(.contents)
        model.navigate(.reading)
        XCTAssertEqual(model.content?.chapter.id, model.chapters[2].id)
        model.navigate(.search)
        model.query = "slow"
        model.search()
        model.query = "missing"
        model.search()
        try await settle(model)
        XCTAssertNil(model.message)
        XCTAssertTrue(model.hasSearched)
        XCTAssertTrue(model.results.isEmpty)
        model.query = "http-error"
        model.search()
        try await settle(model)
        XCTAssertNotNil(model.message)
        XCTAssertTrue(model.results.isEmpty)
        model.reportFileError("File provider unavailable")
        XCTAssertFalse(model.canRetry)
        XCTAssertEqual(model.message, "Unable to import file: File provider unavailable")
        XCTAssertNil(model.importDetails)
        model.importFile(FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString).json"))
        XCTAssertNotNil(model.message)
        XCTAssertFalse(model.canRetry)
        model.cancel()
        XCTAssertNil(model.message)
        XCTAssertFalse(model.busy)
        let invalidURL = FileManager.default.temporaryDirectory.appendingPathComponent("invalid-\(UUID().uuidString).json")
        try Data("{".utf8).write(to: invalidURL)
        let sourceIDs = model.sources.map(\.id)
        model.importFile(invalidURL)
        try await settle(model)
        XCTAssertTrue(model.message?.contains("Malformed source JSON") == true)
        XCTAssertTrue(model.importDetails?.contains(invalidURL.lastPathComponent) == true)
        XCTAssertTrue(model.importDetails?.contains("1 bytes") == true)
        XCTAssertEqual(model.sources.map(\.id), sourceIDs)
    }
}
