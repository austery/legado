import XCTest

final class ReaderUITests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false }

    @MainActor func testShelfReadingRecoveryAndResume() throws {
        let app = XCUIApplication()
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        let book = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Path C Book")).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 40), app.debugDescription)
        capture("after-shelf")
        // Default tap targets the row centre, which failed on the original plain label.
        book.tap()
        let body = app.textViews["reader.text"]
        XCTAssertTrue(body.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue((body.value as? String ?? "").contains("C1-FIRST"))
        XCTAssertTrue((body.value as? String ?? "").contains("C1-LAST"))
        XCTAssertFalse(app.buttons["reader.previous"].isEnabled)
        capture("after-first-chapter")

        app.buttons["fixture.hold"].tap()
        XCTAssertTrue(app.buttons["Release chapter"].waitForExistence(timeout: 5))
        app.buttons["reader.next"].tap()
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 10))
        app.buttons["Cancel"].tap()
        app.buttons["fixture.hold"].tap()
        wait(app) { self.state(app).contains("chapter=0;") && !app.buttons["Cancel"].exists }
        XCTAssertTrue((body.value as? String ?? "").contains("C1-FIRST"))
        capture("after-cancelled-chapter")

        app.buttons["reader.next"].tap()
        wait(app) { (body.value as? String ?? "").contains("第199段") }
        XCTAssertTrue((body.value as? String ?? "").contains("C2-FIRST"))
        XCTAssertTrue((body.value as? String ?? "").contains("C2-LAST"))
        capture("after-long-chapter")
        body.swipeUp(); body.swipeUp()
        wait(app) { self.anchor(app) > 0 }
        let position = anchor(app)
        print("UI POSITION after real swipes: \(state(app))")
        capture("after-scroll")

        app.buttons["reader.contents"].tap()
        XCTAssertTrue(app.buttons["contents.continue"].waitForExistence(timeout: 10))
        capture("after-contents")
        app.buttons["contents.continue"].tap()
        wait(app) { self.anchor(app) == position && self.state(app).contains("chapter=1;") }
        XCTAssertTrue((body.value as? String ?? "").contains("第199段"))

        app.buttons["reader.controls"].tap()
        XCTAssertFalse(app.buttons["reader.contents"].exists)
        wait(app) { self.anchor(app) == position }
        capture("after-controls-hidden")
        app.buttons["reader.controls"].tap()
        app.buttons["reader.typography"].tap()
        XCTAssertTrue(app.buttons["typography.larger"].waitForExistence(timeout: 5))
        app.buttons["typography.larger"].tap(); app.buttons["typography.larger"].tap()
        capture("after-typography")
        app.buttons["Done"].tap()
        wait(app) { self.anchor(app) == position }
        XCUIDevice.shared.orientation = .landscapeLeft
        wait(app) { self.anchor(app) == position && app.frame.width > app.frame.height }
        capture("after-landscape")
        XCUIDevice.shared.orientation = .portrait
        wait(app) { self.anchor(app) == position && app.frame.width < app.frame.height }

        app.buttons["fixture.saveFailure"].tap()
        app.buttons["reader.shelf"].tap()
        XCTAssertTrue(app.buttons["Retry save"].waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(body.exists, "Failed save must keep the body on screen")
        XCTAssertEqual(anchor(app), position)
        XCTAssertFalse(book.exists)
        capture("after-save-rejected")
        app.buttons["Return without saving"].tap()
        XCTAssertTrue(app.buttons["Keep reading"].waitForExistence(timeout: 5))
        app.buttons["Keep reading"].tap()
        XCTAssertTrue(body.exists)
        app.buttons["fixture.saveFailure"].tap()
        app.buttons["Retry save"].tap()
        wait(app) { !app.buttons["Retry save"].exists }
        XCTAssertTrue(body.exists)
        app.buttons["reader.shelf"].tap()
        XCTAssertTrue(app.staticTexts["shelf.notice"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["shelf.notice"].label.contains("Reading position saved."))
        capture("after-saved-shelf")
        book.tap()
        wait(app) { self.anchor(app) == position && self.state(app).contains("chapter=1;") }
        print("UI POSITION after shelf reopen: \(state(app))")
        capture("after-reopened-position")
        app.buttons["reader.shelf"].tap()
        XCTAssertTrue(book.waitForExistence(timeout: 10))
        app.terminate(); app.launch()
        XCTAssertTrue(book.waitForExistence(timeout: 20))
        book.tap()
        wait(app) { self.anchor(app) == position && self.state(app).contains("chapter=1;") }
        XCTAssertTrue((app.textViews["reader.text"].value as? String ?? "").contains("C2-LAST"))
        print("UI POSITION after process relaunch: \(state(app))")
        capture("after-relaunched-position")
    }

    @MainActor private func state(_ app: XCUIApplication) -> String {
        app.staticTexts["fixture.position"].value as? String ?? ""
    }
    @MainActor private func anchor(_ app: XCUIApplication) -> Int {
        let value = state(app).split(separator: ";").first { $0.hasPrefix("anchor=") }
        return value.flatMap { Int($0.dropFirst(7)) } ?? -1
    }
    @MainActor private func wait(_ app: XCUIApplication, _ condition: @escaping () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
        let expected = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        let result = XCTWaiter.wait(for: [expected], timeout: 20)
        if result != .completed { print("UI condition failed: \(state(app)); frame=\(app.frame)"); capture("failed-condition") }
        XCTAssertEqual(result, .completed, app.debugDescription, file: file, line: line)
    }
    @MainActor private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
