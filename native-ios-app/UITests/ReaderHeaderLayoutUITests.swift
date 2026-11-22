import XCTest

extension ReaderUITests {
    /// The measured header stays above the body and keeps its footprint when controls change.
    @MainActor func testReadingHeaderLeavesFirstBodyLineUncovered() {
        let app = XCUIApplication()
        app.launchEnvironment["READER_UI_RESET"] = "1"
        defer {
            app.terminate()
            XCUIDevice.shared.orientation = .portrait
        }

        let body = app.textViews["reader.text"]
        let title = app.descendants(matching: .any)["reader.headerTitle"]
        let shelf = app.buttons["reader.shelf"]
        let toggle = app.buttons["reader.controls"]
        let position = app.staticTexts["fixture.position"]

        func geometry() -> [Substring] {
            let keys = ["chapter", "anchor", "layout", "spread", "visible", "rendered", "scrollRendered"]
            return (position.value as? String ?? "").split(separator: ";").filter { component in
                keys.contains { component.hasPrefix($0 + "=") }
            }
        }

        for largeTitle in [false, true] {
            app.launchEnvironment["READER_UI_SCENARIO"] = largeTitle ? "reader-header-long-title" : "two-page"
            XCUIDevice.shared.orientation = .portrait
            app.launch()
            let book = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Path C Book")).firstMatch
            XCTAssertTrue(book.waitForExistence(timeout: 40))
            book.tap()

            for layout in ["scroll", "spread"] {
                if layout == "spread" { XCUIDevice.shared.orientation = .landscapeLeft }
                let settled = NSPredicate { _, _ in
                    (position.value as? String ?? "").contains("layout=\(layout);")
                }
                XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: settled, object: nil)], timeout: 20), .completed)
                XCTAssertTrue(title.waitForExistence(timeout: 10))

                let shown = body.frame
                let shownGeometry = geometry()
                XCTAssertTrue(shownGeometry.contains("anchor=0"))
                XCTAssertLessThanOrEqual(title.frame.maxY, shown.minY + 0.5, "\(layout): title must leave the first line clear")
                XCTAssertLessThanOrEqual(shelf.frame.maxY, shown.minY + 0.5, "\(layout): Shelf must leave the first line clear")
                XCTAssertGreaterThanOrEqual(toggle.frame.height, 44)
                if largeTitle {
                    XCTAssertTrue(title.label.contains("old house above the valley"), title.label)
                    XCTAssertGreaterThan(title.frame.height, 70, "The large title should wrap within the header")
                } else {
                    XCTAssertLessThanOrEqual(shown.minY - shelf.frame.minY, 44.5, "Short titles fit inside the button height")
                }

                let firstPage = layout == "spread"
                    ? app.textViews.matching(NSPredicate(format: "label CONTAINS %@", "C1-FIRST")).firstMatch
                    : body
                XCTAssertTrue(firstPage.waitForExistence(timeout: 10))
                let firstPageFrame = firstPage.frame
                XCTAssertGreaterThanOrEqual(firstPageFrame.minY, title.frame.maxY - 0.5)
                let size = largeTitle ? "large" : "standard"
                captureHeader("header-\(size)-\(layout)-shown")

                toggle.tap()
                let hidden = NSPredicate { _, _ in !shelf.exists && !title.exists }
                XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: hidden, object: nil)], timeout: 10), .completed)
                XCTAssertEqual(body.frame, shown, "\(layout): hiding controls keeps the body frame")
                XCTAssertEqual(firstPage.frame, firstPageFrame, "\(layout): hiding controls keeps the first text page")
                XCTAssertEqual(geometry(), shownGeometry, "\(layout): hiding controls keeps ranges and anchors")
                captureHeader("header-\(size)-\(layout)-hidden")

                toggle.tap()
                XCTAssertTrue(shelf.waitForExistence(timeout: 10))
                XCTAssertEqual(body.frame, shown, "\(layout): showing controls keeps the body frame")
                XCTAssertEqual(firstPage.frame, firstPageFrame, "\(layout): showing controls keeps the first text page")
                XCTAssertEqual(geometry(), shownGeometry, "\(layout): showing controls keeps ranges and anchors")
            }
            app.terminate()
        }
    }

    @MainActor private func captureHeader(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
