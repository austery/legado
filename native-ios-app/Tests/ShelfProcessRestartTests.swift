import XCTest
import ReaderEngine
import SwiftUI
@testable import NativeReader

/// Opt-in phases run in separate test-host processes; normal suites skip both.
@MainActor
final class ShelfProcessRestartTests: XCTestCase {
    private struct Manifest: Codable {
        let processID: Int32
        let sourceID: String
        let bookID: String
        let chapters: [String]
        let readingChapter: String
        let paragraphOffset: Int32
    }
    private let key = "SPEC003.disposableSimulator.restartManifest"

    private func findText(_ root: UIView) -> AnchoredTextView? {
        if let view = root as? AnchoredTextView { return view }
        return root.subviews.lazy.compactMap { self.findText($0) }.first
    }

    private func settle(_ model: ReaderModel) async throws {
        let deadline = Date().addingTimeInterval(20)
        while model.busy && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertFalse(model.busy)
        XCTAssertNil(model.message)
    }

    func testPrepare() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SPEC003_RESTART_PHASE"] == "prepare")
        let model = ReaderModel()
        model.start(); try await settle(model)
        let run = UUID().uuidString
        let base = "http://127.0.0.1:18769/runs/\(run)"
        let (data, _) = try await URLSession.shared.data(from: XCTUnwrap(URL(string: base + "/sources.json")))
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
            .replacingOccurrences(of: "class.name@text", with: "class.name@text##$## " + run)
            .replacingOccurrences(of: "tag.h1@text", with: "tag.h1@text##$## " + run)
            .replacingOccurrences(of: "id.content@text", with: "id.content@text##第##\\n第")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(run + ".json")
        try Data(json.utf8).write(to: file)
        model.importFile(file); try await settle(model)
        model.sourceID = base; model.query = "Path"; model.search(); try await settle(model)
        model.select(try XCTUnwrap(model.results.first)); try await settle(model)
        model.addCurrentBook(); try await settle(model)
        let book = try XCTUnwrap(model.book)
        model.read(model.chapters[1]); try await settle(model)
        let readingChapter = try XCTUnwrap(model.content?.chapter.id)
        XCTAssertEqual(model.route, .reading)
        XCTAssertTrue(model.content?.reading?.canSave == true)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 768, height: 1024))
        let host = UIHostingController(rootView: ReaderScreen(model: model))
        window.rootViewController = host; window.makeKeyAndVisible()
        host.loadViewIfNeeded(); host.view.layoutIfNeeded()
        defer { window.isHidden = true }
        let deadline = Date().addingTimeInterval(3)
        while !model.canRetryPosition && Date() < deadline {
            host.view.layoutIfNeeded()
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(model.canRetryPosition)
        let view = try XCTUnwrap(findText(host.view))
        let target = (view.text as NSString).range(of: "第80段")
        XCTAssertNotEqual(target.location, NSNotFound)
        view.layoutManager.ensureLayout(for: view.textContainer)
        let glyph = view.layoutManager.glyphRange(forCharacterRange: target, actualCharacterRange: nil)
        let rect = view.layoutManager.boundingRect(forGlyphRange: glyph, in: view.textContainer)
        view.scrollViewWillBeginDragging(view)
        view.setContentOffset(CGPoint(x: 0, y: rect.minY), animated: false)
        view.scrollViewDidScroll(view)
        view.scrollViewDidEndDragging(view, willDecelerate: false)
        let offset = view.anchor
        XCTAssertGreaterThan(offset, 0)
        model.showShelf(); try await settle(model)
        XCTAssertNil(model.resumeNotice)
        let manifest = Manifest(processID: getpid(), sourceID: book.sourceId, bookID: book.id,
            chapters: model.chapters.map(\.id), readingChapter: readingChapter, paragraphOffset: Int32(offset))
        try Data(json.replacingOccurrences(of: "\"enabled\": true", with: "\"enabled\": false").utf8).write(to: file)
        model.importFile(file); try await settle(model)
        UserDefaults.standard.set(try JSONEncoder().encode(manifest), forKey: key)
        XCTAssertTrue(UserDefaults.standard.synchronize())
        print("SPEC003 prepare PID=\(getpid()) book=\(book.id)")
    }

    func testVerify() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SPEC003_RESTART_PHASE"] == "verify")
        let manifest = try JSONDecoder().decode(Manifest.self, from: XCTUnwrap(UserDefaults.standard.data(forKey: key)))
        XCTAssertNotEqual(getpid(), manifest.processID, "Verification requires a new app process")
        let model = ReaderModel()
        model.start(); try await settle(model)
        XCTAssertEqual(model.route, .shelf)
        XCTAssertFalse(model.sources.contains { $0.id == manifest.sourceID })
        let entry = try XCTUnwrap(model.shelf.first { $0.book.id == manifest.bookID && $0.book.sourceId == manifest.sourceID })
        model.openShelfBook(entry); try await settle(model)
        XCTAssertEqual(model.chapters.map(\.id), manifest.chapters)
        XCTAssertEqual(model.route, .reading)
        XCTAssertEqual(model.content?.chapter.id, manifest.readingChapter)
        XCTAssertEqual(model.content?.reading?.paragraphUtf16Offset, manifest.paragraphOffset)
        XCTAssertGreaterThan(manifest.paragraphOffset, 0)
        XCTAssertTrue(model.content?.fromCache == true)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 768, height: 1024))
        let host = UIHostingController(rootView: ReaderScreen(model: model))
        window.rootViewController = host; window.makeKeyAndVisible()
        host.loadViewIfNeeded(); host.view.layoutIfNeeded()
        defer { window.isHidden = true }
        let deadline = Date().addingTimeInterval(3)
        while !model.canRetryPosition && Date() < deadline {
            host.view.layoutIfNeeded()
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(model.canRetryPosition)
        let view = try XCTUnwrap(findText(host.view))
        let position = try XCTUnwrap(view.position(from: view.beginningOfDocument, offset: Int(manifest.paragraphOffset)))
        XCTAssertTrue(view.bounds.intersects(view.caretRect(for: position)))
        let attachment = XCTAttachment(image: UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        })
        attachment.name = "C3 paragraph restored after process restart with source disabled"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("SPEC003 verify PID=\(getpid()) previousPID=\(manifest.processID) book=\(manifest.bookID)")
    }
}
