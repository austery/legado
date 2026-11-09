import XCTest

extension ReaderUITests {
    /// The body starts below the shown header in both layouts, and toggling controls keeps its frame.
    @MainActor func testReadingHeaderLeavesFirstBodyLineUncovered() {
        let app = XCUIApplication()
        app.launchEnvironment["READER_UI_RESET"] = "1"
        app.launchEnvironment["READER_UI_SCENARIO"] = "two-page"
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        let book = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Path C Book")).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 40)); book.tap()
        XCTAssertTrue(app.buttons["reader.next"].waitForExistence(timeout: 20))

        let body = app.textViews["reader.text"]
        let title = app.descendants(matching: .any)["reader.headerTitle"]
        let shelf = app.buttons["reader.shelf"]
        let toggle = app.buttons["reader.controls"]

        for layout in ["scroll", "spread"] {
            if layout == "spread" { XCUIDevice.shared.orientation = .landscapeLeft }
            let settled = NSPredicate { _, _ in
                (app.staticTexts["fixture.position"].value as? String ?? "").contains("layout=\(layout);")
            }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: settled, object: nil)], timeout: 20), .completed)
            XCTAssertTrue(title.waitForExistence(timeout: 10))

            let shown = body.frame
            XCTAssertLessThanOrEqual(title.frame.maxY, shown.minY + 0.5, "\(layout): the title must not cover the body")
            XCTAssertLessThanOrEqual(shelf.frame.maxY, shown.minY + 0.5, "\(layout): Shelf must not cover the body")
            if layout == "spread" {
                // Pages expose their text as the label, so find the left page by its first line.
                let page = app.textViews.matching(NSPredicate(format: "label CONTAINS %@", "C1-FIRST")).firstMatch
                XCTAssertTrue(page.waitForExistence(timeout: 10))
                XCTAssertGreaterThanOrEqual(page.frame.minY, title.frame.maxY, "The left page must start below the title")
            }
            let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screenshot.name = "header-\(layout)-controls-shown"; screenshot.lifetime = .keepAlways; add(screenshot)

            toggle.tap()
            let hidden = NSPredicate { _, _ in !shelf.exists }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: hidden, object: nil)], timeout: 10), .completed)
            XCTAssertEqual(body.frame, shown, "\(layout): hiding controls must not move the body")
            let hiddenShot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            hiddenShot.name = "header-\(layout)-controls-hidden"; hiddenShot.lifetime = .keepAlways; add(hiddenShot)

            toggle.tap()
            XCTAssertTrue(shelf.waitForExistence(timeout: 10))
            XCTAssertEqual(body.frame, shown, "\(layout): showing controls must not move the body")
        }
        XCUIDevice.shared.orientation = .portrait
        app.terminate()
    }
}
