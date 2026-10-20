import XCTest

final class ReaderUITests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false }

    @MainActor func testShelfReadingRecoveryAndResume() throws {
        let app = XCUIApplication()
        app.launchEnvironment["READER_UI_RESET"] = "1"
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
        XCTAssertFalse(app.buttons["reader.next"].isEnabled)
        XCTAssertFalse(app.buttons["reader.shelf"].isEnabled)
        XCTAssertFalse(app.buttons["reader.contents"].isEnabled)
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

        // Both directory return paths must resume the same saved paragraph.
        app.buttons["reader.contents"].tap()
        XCTAssertTrue(app.buttons["contents.currentChapter"].waitForExistence(timeout: 10))
        app.buttons["contents.currentChapter"].tap()
        wait(app) { self.anchor(app) == position && self.state(app).contains("chapter=1;") }
        capture("after-current-chapter-resume")

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
        for id in ["reader.previous", "reader.next", "reader.contents", "reader.typography", "reader.shelf", "reader.controls"] {
            XCTAssertTrue(app.buttons[id].isHittable, "Landscape control must be hittable: \(id)")
            XCTAssertTrue(app.frame.contains(app.buttons[id].frame), "Landscape control must be inside window: \(id)")
        }
        XCTAssertLessThanOrEqual(body.frame.maxY, app.buttons["reader.contents"].frame.minY + 1)
        app.buttons["reader.controls"].tap()
        XCTAssertFalse(app.buttons["reader.contents"].exists)
        wait(app) { self.anchor(app) == position }
        app.buttons["reader.controls"].tap()
        app.buttons["reader.contents"].tap()
        XCTAssertTrue(app.buttons["contents.continue"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["contents.continue"].isHittable)
        capture("landscape-contents")
        app.buttons["contents.continue"].tap()
        wait(app) { self.anchor(app) == position && self.state(app).contains("chapter=1;") }
        app.buttons["reader.contents"].tap()
        XCTAssertTrue(app.buttons["contents.currentChapter"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["contents.currentChapter"].isHittable)
        app.buttons["contents.currentChapter"].tap()
        wait(app) { self.anchor(app) == position && self.state(app).contains("chapter=1;") }
        app.buttons["reader.typography"].tap()
        XCTAssertTrue(app.buttons["typography.larger"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["typography.larger"].isHittable)
        app.buttons["typography.larger"].tap()
        capture("landscape-typography")
        app.buttons["typography.smaller"].tap()
        XCTAssertTrue(app.buttons["Done"].isHittable)
        app.buttons["Done"].tap()
        wait(app) { self.anchor(app) == position }
        print("LANDSCAPE directory and typography: \(state(app)); frame=\(app.frame)")
        capture("landscape-restored-reading")

        app.buttons["fixture.saveFailure"].tap()
        app.buttons["reader.shelf"].tap()
        XCTAssertTrue(app.buttons["Retry save"].waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(body.exists, "Failed save must keep the body on screen")
        XCTAssertEqual(anchor(app), position)
        XCTAssertFalse(book.exists)
        capture("after-save-rejected")
        XCTAssertGreaterThan(app.frame.width, app.frame.height)
        for name in ["Retry save", "Return without saving", "Dismiss"] {
            XCTAssertTrue(app.buttons[name].isHittable)
            XCTAssertTrue(app.frame.contains(app.buttons[name].frame))
        }
        capture("landscape-save-rejected")
        app.buttons["Return without saving"].tap()
        XCTAssertTrue(app.buttons["Keep reading"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Keep reading"].isHittable)
        capture("landscape-discard-confirmation")
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
        print("LANDSCAPE save recovery and reopen: \(state(app)); frame=\(app.frame)")
        XCUIDevice.shared.orientation = .portrait
        wait(app) { self.anchor(app) == position && app.frame.width < app.frame.height }
        capture("portrait-after-landscape-interactions")
        app.buttons["reader.shelf"].tap()
        XCTAssertTrue(book.waitForExistence(timeout: 10))
        app.terminate(); app.launchEnvironment.removeValue(forKey: "READER_UI_RESET"); app.launch()
        XCTAssertTrue(book.waitForExistence(timeout: 20))
        book.tap()
        wait(app) { self.anchor(app) == position && self.state(app).contains("chapter=1;") }
        XCTAssertTrue((app.textViews["reader.text"].value as? String ?? "").contains("C2-LAST"))
        print("UI POSITION after process relaunch: \(state(app))")
        capture("after-relaunched-position")
    }

    @MainActor func testSearchDetailsCatalogAndGlobalPreferences() throws {
        let app = XCUIApplication()
        app.launchEnvironment["READER_UI_RESET"] = "1"
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        XCTAssertTrue(app.buttons["navigation.sources"].waitForExistence(timeout: 40))
        app.buttons["navigation.sources"].tap()
        XCTAssertTrue(app.buttons["sources.import"].waitForExistence(timeout: 10))
        capture("everyday-sources")
        app.buttons["navigation.search"].tap()
        XCTAssertTrue(app.textFields["search.query"].waitForExistence(timeout: 10))
        app.buttons["search.submit"].tap()
        let work = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "discovered sources")).firstMatch
        XCTAssertTrue(work.waitForExistence(timeout: 15), app.debugDescription)
        work.tap()
        let candidate = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "search.candidate.")).firstMatch
        XCTAssertTrue(candidate.waitForExistence(timeout: 10), app.debugDescription)
        capture("everyday-expanded-search")
        candidate.tap()
        XCTAssertTrue(app.buttons["details.read"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["details.add"].isHittable)
        capture("everyday-details")
        app.buttons["navigation.searchResults"].tap()
        XCTAssertTrue(candidate.waitForExistence(timeout: 10), "Returning to search keeps the expanded candidate")
        candidate.tap()
        XCTAssertTrue(app.buttons["details.contents"].waitForExistence(timeout: 15))
        app.buttons["details.contents"].tap()
        let filter = app.textFields["contents.filter"]
        XCTAssertTrue(filter.waitForExistence(timeout: 10))
        filter.tap(); filter.typeText("no-matching-chapter")
        XCTAssertTrue(app.staticTexts["No matching chapters. Try another title or clear the filter."].waitForExistence(timeout: 5))
        app.buttons["contents.clearFilter"].tap()
        filter.tap(); filter.typeText("Chapter 2")
        let chapter = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "contents.chapter.")).firstMatch
        XCTAssertTrue(chapter.waitForExistence(timeout: 5))
        capture("everyday-filtered-catalog")
        chapter.tap()
        let body = app.textViews["reader.text"]
        XCTAssertTrue(body.waitForExistence(timeout: 15))
        wait(app) { (body.value as? String ?? "").contains("C2-LAST") }
        body.swipeUp(); body.swipeUp()
        wait(app) { self.anchor(app) > 0 }
        let position = anchor(app)
        app.buttons["reader.contents"].tap()
        XCTAssertTrue(app.buttons["contents.locate"].waitForExistence(timeout: 10))
        app.buttons["contents.locate"].tap()
        XCTAssertTrue(app.buttons["contents.currentChapter"].isHittable)
        app.buttons["contents.continue"].tap()
        wait(app) { self.anchor(app) == position }
        app.buttons["reader.typography"].tap()
        XCTAssertTrue(app.buttons["typography.larger"].waitForExistence(timeout: 5))
        app.buttons["typography.larger"].tap()
        let darkAppearance = app.switches["appearance.dark"]
        darkAppearance.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        wait(app) { darkAppearance.value as? String == "1" }
        XCTAssertEqual(app.staticTexts["typography.size"].label, "24")
        capture("everyday-global-settings")
        app.buttons["Done"].tap()
        wait(app) { self.anchor(app) == position }
        app.buttons["reader.shelf"].tap()
        let book = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Path C Book")).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 10))
        app.terminate(); app.launchEnvironment.removeValue(forKey: "READER_UI_RESET"); app.launch()
        XCTAssertTrue(book.waitForExistence(timeout: 30)); book.tap()
        wait(app) { self.anchor(app) == position && self.state(app).contains("chapter=1;") }
        app.buttons["reader.typography"].tap()
        XCTAssertTrue(app.staticTexts["typography.size"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["typography.size"].label, "24")
        XCTAssertEqual(app.switches["appearance.dark"].value as? String, "1")
        app.buttons["Done"].tap()
        capture("everyday-reopened-dark-reading")
        app.terminate()
    }

    @MainActor func testCatalogFilterResetsForAnotherSourceAndPreferencesApply() throws {
        let app = XCUIApplication()
        app.launchEnvironment["READER_UI_RESET"] = "1"
        app.launchEnvironment["READER_UI_SCENARIO"] = "catalog"
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        XCTAssertTrue(app.buttons["navigation.search"].waitForExistence(timeout: 40))
        app.buttons["navigation.search"].tap()
        app.buttons["search.submit"].tap()
        let work = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "discovered sources")).firstMatch
        XCTAssertTrue(work.waitForExistence(timeout: 15)); work.tap()
        let original = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND NOT identifier CONTAINS %@", "search.candidate.", "-alternate")).firstMatch
        let alternate = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND identifier CONTAINS %@", "search.candidate.", "-alternate")).firstMatch
        XCTAssertTrue(alternate.waitForExistence(timeout: 15), app.debugDescription); original.tap()
        XCTAssertTrue(app.buttons["details.read"].waitForExistence(timeout: 15))
        app.buttons["details.read"].tap()
        XCTAssertTrue(app.buttons["reader.typography"].waitForExistence(timeout: 15))
        app.buttons["reader.typography"].tap()
        app.buttons["typography.larger"].tap()
        app.buttons["Done"].tap()
        app.buttons["reader.contents"].tap()
        let filter = app.textFields["contents.filter"]
        XCTAssertTrue(filter.waitForExistence(timeout: 10)); filter.tap(); filter.typeText("no-matching-chapter")
        XCTAssertTrue(app.buttons["contents.clearFilter"].waitForExistence(timeout: 5))
        app.buttons["navigation.searchResults"].tap()
        XCTAssertTrue(alternate.waitForExistence(timeout: 10)); alternate.tap()
        XCTAssertTrue(app.buttons["details.contents"].waitForExistence(timeout: 15)); app.buttons["details.contents"].tap()
        XCTAssertTrue(filter.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["contents.clearFilter"].exists, "A different source entry starts with an unfiltered catalog")
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "contents.chapter.")).count, 3)
        capture("everyday-new-source-unfiltered-catalog")
        app.buttons["contents.details"].tap()
        XCTAssertTrue(app.buttons["details.read"].waitForExistence(timeout: 5)); app.buttons["details.read"].tap()
        XCTAssertTrue(app.buttons["reader.typography"].waitForExistence(timeout: 15)); app.buttons["reader.typography"].tap()
        XCTAssertEqual(app.staticTexts["typography.size"].label, "24", "Presentation settings apply to another source entry too")
        app.buttons["Done"].tap()
        wait(app) { self.state(app).contains("-alternate") && self.state(app).contains("canSave=nil;") }
        app.buttons["reader.shelf"].tap()
        let book = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Path C Book")).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 10)); book.tap()
        wait(app) { !self.state(app).contains("-alternate") && self.state(app).contains("chapter=0;") }
        app.terminate()
    }

    @MainActor func testUnshelvedDirectoryReturnKeepsSession() throws {
        try checkSessionReturn(scenario: "preview", canSave: "nil")
    }

    @MainActor func testReadOnlyDirectoryReturnKeepsSessionAndStoredRecord() throws {
        try checkSessionReturn(scenario: "readonly", canSave: "false")
    }

    @MainActor private func checkSessionReturn(scenario: String, canSave: String) throws {
        let app = XCUIApplication()
        app.launchEnvironment["READER_UI_RESET"] = "1"
        app.launchEnvironment["READER_UI_SCENARIO"] = scenario
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        let body = app.textViews["reader.text"]
        XCTAssertTrue(body.waitForExistence(timeout: 40), app.debugDescription)
        wait(app) { self.state(app).contains("canSave=\(canSave);") && self.state(app).contains("chapter=1;") }
        XCTAssertTrue((body.value as? String ?? "").contains("C2-LAST"))
        body.swipeUp(); body.swipeUp()
        wait(app) { self.anchor(app) > 0 }
        var lastAnchor = -1
        var stableSamples = 0
        wait(app) {
            let current = self.anchor(app)
            stableSamples = current == lastAnchor ? stableSamples + 1 : 0
            lastAnchor = current
            return stableSamples >= 3 && current > 0 && self.state(app).contains("dragging=false;decelerating=false;")
        }
        let position = anchor(app)
        print("SESSION BASELINE \(scenario): expected=\(position); \(state(app))")
        let stored = app.staticTexts["fixture.stored"].value as? String ?? ""
        if scenario == "preview" {
            XCTAssertEqual(stored, "resume=none;books=0")
        } else {
            XCTAssertTrue(stored.contains("ui-unsupported"), stored)
            XCTAssertTrue(stored.contains("/chapter/1"), stored)
        }
        capture("\(scenario)-before-contents")
        for entry in ["contents.continue", "contents.currentChapter"] {
            app.buttons["reader.contents"].tap()
            XCTAssertTrue(app.buttons[entry].waitForExistence(timeout: 10))
            print("SESSION DIRECTORY \(scenario): \(state(app))")
            app.buttons[entry].tap()
            wait(app) { app.buttons["reader.contents"].exists && self.anchor(app) == position && self.state(app).contains("chapter=1;") }
            XCTAssertTrue((body.value as? String ?? "").contains("C2-LAST"))
            XCTAssertEqual(app.staticTexts["fixture.stored"].value as? String, stored)
            XCTAssertFalse(app.staticTexts["fixture.failure"].exists)
            print("SESSION \(scenario) \(entry): \(state(app)); stored=\(stored)")
            capture("\(scenario)-\(entry)-returned")
        }
        app.buttons["reader.shelf"].tap()
        wait(app) { !app.buttons["reader.contents"].exists }
        XCTAssertEqual(app.staticTexts["fixture.stored"].value as? String, stored)
        app.terminate()
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
