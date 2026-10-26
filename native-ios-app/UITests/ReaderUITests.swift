import XCTest

final class ReaderUITests: XCTestCase {
    @MainActor func testChapterFindAcrossLayoutsAndDurablePosition() async throws {
        let app = launchControlsReader()
        let identity = readingIdentity(app)
        waitForStableViewport(app)
        let original = anchor(app)
        let stored = app.staticTexts["fixture.stored"].value as? String
        let sourcePart = try XCTUnwrap(identity.first { $0.hasPrefix("source=") })
        let source = String(sourcePart.dropFirst("source=".count))
        let requestsURL = try XCTUnwrap(URL(string: source + "/control/requests"))
        let (before, _) = try await URLSession.shared.data(from: requestsURL)
        XCTAssertTrue(app.buttons["reader.find"].waitForExistence(timeout: 10)); app.buttons["reader.find"].tap()
        let query = app.textFields["reader.find.query"]
        XCTAssertTrue(query.waitForExistence(timeout: 5)); query.tap(); query.typeText("第80段\n")
        wait(app) { app.staticTexts["reader.find.status"].label == "1 match" }
        waitForStableViewport(app)
        XCTAssertEqual(anchor(app), original, "Typing must not navigate")
        XCTAssertEqual(app.staticTexts["fixture.stored"].value as? String, stored, "Typing/highlighting must not save progress")
        app.buttons["reader.find.next"].tap()
        wait(app) { app.staticTexts["reader.find.status"].label == "1 of 1" && self.anchor(app) > original }
        waitForStableViewport(app)
        var position = anchor(app)
        XCTAssertGreaterThan(position, 0)
        capture("find-portrait-explicit-match")
        XCUIDevice.shared.orientation = .landscapeLeft
        wait(app) { app.frame.width > app.frame.height && self.state(app).contains("layout=spread;") }
        assertRenderedAnchor(app, identity: identity, position: position)
        capture("find-landscape-same-occurrence")
        app.buttons["reader.typography"].tap()
        XCTAssertTrue(app.buttons["typography.larger"].waitForExistence(timeout: 5)); app.buttons["typography.larger"].tap()
        app.buttons["Done"].tap()
        wait(app) { app.staticTexts["reader.find.status"].label == "1 of 1" }
        assertRenderedAnchor(app, identity: identity, position: position)
        app.buttons["reader.find.previous"].tap()
        wait(app) { app.staticTexts["reader.find.status"].label == "1 of 1" && self.anchor(app) == position }
        let foundPosition = position
        app.textViews["reader.text"].swipeLeft()
        wait(app) { self.anchor(app) > foundPosition }
        position = anchor(app)
        app.buttons["reader.typography"].tap()
        XCTAssertTrue(app.buttons["typography.larger"].waitForExistence(timeout: 5)); app.buttons["typography.larger"].tap()
        app.buttons["Done"].tap()
        assertRenderedAnchor(app, identity: identity, position: position)
        XCTAssertEqual(app.staticTexts["reader.find.status"].label, "1 of 1", "Manual reading retains the query and selected result identity")
        capture("find-manual-page-turn-survives-reflow")
        app.buttons["reader.find.close"].tap()
        XCTAssertFalse(query.exists)
        XCTAssertEqual(anchor(app), position, "Closing must not undo an explicit reading jump")
        let (after, _) = try await URLSession.shared.data(from: requestsURL)
        XCTAssertEqual(before, after, "Find and reflow must not request chapter/source data")
        app.buttons["reader.shelf"].tap()
        let book = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "shelf.book.")).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 15)); book.tap()
        wait(app) { self.state(app).contains("chapter=1;") && self.anchor(app) == position }
        app.terminate(); app.launchEnvironment["READER_UI_RESET"] = "0"; app.launchEnvironment["READER_UI_SCENARIO"] = "shelf"; app.launch()
        XCTAssertTrue(book.waitForExistence(timeout: 40)); book.tap()
        wait(app) { self.anchor(app) == position && self.state(app).contains("chapter=1;") }
        XCTAssertEqual(readingIdentity(app), identity)
        XCTAssertFalse(query.exists, "Find state is transient")
        capture("find-relaunched-saved-paragraph")
        app.terminate()
    }

    @MainActor func testChapterFindNoMatchesSelectionFailureAndChapterRetirement() throws {
        let app = launchControlsReader()
        let original = anchor(app)
        app.buttons["reader.find"].tap()
        let query = app.textFields["reader.find.query"]
        XCTAssertTrue(query.waitForExistence(timeout: 5)); query.tap(); query.typeText("missing-phrase")
        wait(app) { app.staticTexts["reader.find.status"].label == "No matches" }
        XCTAssertFalse(app.buttons["reader.find.next"].isEnabled)
        XCTAssertFalse(app.buttons["reader.find.previous"].isEnabled)
        app.buttons["reader.find.clear"].tap()
        wait(app) { app.staticTexts["reader.find.status"].label == "Enter text to find" }
        query.typeText("第120段\n")
        wait(app) { app.staticTexts["reader.find.status"].label == "1 match" }
        XCTAssertEqual(anchor(app), original)
        let body = app.textViews["reader.text"]
        let selectedPoint = selectionPoint(app)
        body.coordinate(withNormalizedOffset: selectedPoint).press(forDuration: 1.2)
        wait(app) { self.selectionLength(app) > 0 }
        capture("find-native-selection")
        body.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.60)).tap()
        wait(app) { self.selectionLength(app) == 0 }
        XCTAssertTrue(query.exists)
        verifyFindRejectedSaveAndChapterRetirement(app, query: query, original: original)
        app.terminate()
    }

    @MainActor func testChapterFindLandscapeRejectedSaveAndChapterRetirement() throws {
        let app = launchControlsReader()
        let original = anchor(app)
        let stored = app.staticTexts["fixture.stored"].value as? String
        XCUIDevice.shared.orientation = .landscapeLeft
        wait(app) { self.state(app).contains("layout=spread;") && app.frame.width > app.frame.height }
        app.buttons["reader.find"].tap()
        let query = app.textFields["reader.find.query"]
        XCTAssertTrue(query.waitForExistence(timeout: 5))
        for attempt in 0..<3 {
            if attempt > 0 { app.buttons["reader.find.clear"].tap() }
            query.tap(); query.typeText("第120段\n")
            wait(app) { app.staticTexts["reader.find.status"].label == "1 match" }
            XCTAssertTrue(app.frame.width > app.frame.height)
            XCTAssertEqual(anchor(app), original, "Typing must not navigate")
            XCTAssertEqual(app.staticTexts["fixture.stored"].value as? String, stored, "Typing must not save progress")
        }
        capture("find-direct-landscape-query")
        verifyFindRejectedSaveAndChapterRetirement(app, query: query, original: original)
        app.terminate()
    }

    @MainActor private func verifyFindRejectedSaveAndChapterRetirement(_ app: XCUIApplication, query: XCUIElement, original: Int) {
        app.buttons["fixture.saveFailure"].tap()
        app.buttons["reader.find.next"].tap()
        wait(app) { self.anchor(app) > original }
        let position = anchor(app)
        XCTAssertTrue(app.buttons["Retry save"].waitForExistence(timeout: 15))
        XCTAssertEqual(query.value as? String, "第120段")
        XCTAssertEqual(app.staticTexts["reader.find.status"].label, "1 of 1")
        capture("find-position-save-rejection")
        app.buttons["fixture.saveFailure"].tap(); app.buttons["Retry save"].tap()
        wait(app) { !app.buttons["Retry save"].exists }
        XCTAssertEqual(anchor(app), position)
        app.buttons["reader.previous"].tap()
        wait(app) { self.state(app).contains("chapter=0;") }
        XCTAssertFalse(query.exists, "A chapter change must retire the find panel")
        app.buttons["reader.find"].tap()
        XCTAssertTrue(query.waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["reader.find.status"].label, "Enter text to find")
        XCTAssertFalse(app.buttons["reader.find.next"].isEnabled)
        app.buttons["reader.find.close"].tap()
    }

    @MainActor func testShelfGroupingAndGridListManagement() throws {
        let app = XCUIApplication()
        app.launchEnvironment["READER_UI_RESET"] = "1"
        app.launchEnvironment["READER_UI_SCENARIO"] = "shelf"
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        XCTAssertTrue(app.buttons["shelf.newGroup"].waitForExistence(timeout: 40))
        app.buttons["shelf.newGroup"].tap()
        let name = app.textFields["shelf.groupName"]
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText("Later")
        app.buttons["shelf.group.save"].tap()
        let group = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "shelf.group.")).firstMatch
        XCTAssertTrue(group.waitForExistence(timeout: 10))
        let menu = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "shelf.bookMenu.")).firstMatch
        XCTAssertTrue(menu.exists); menu.tap()
        app.buttons["Set groups"].tap()
        let membership = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "shelf.membership.group.")).firstMatch
        XCTAssertTrue(membership.waitForExistence(timeout: 5)); membership.tap()
        app.buttons["shelf.membership.save"].tap()
        wait(app) { app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "shelf.book.")).count == 0 }
        capture("shelf-home-group-grid")
        group.tap()
        XCTAssertTrue(app.buttons["shelf.home"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "shelf.book.")).count, 1)
        app.buttons["shelf.layout.list"].tap()
        XCUIDevice.shared.orientation = .landscapeLeft
        wait(app) { app.frame.width > app.frame.height }
        capture("shelf-group-list-landscape")
        app.buttons["shelf.home"].tap()
        let groupMenu = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "shelf.groupMenu.")).firstMatch
        groupMenu.tap(); app.buttons["Delete group"].tap()
        let confirmDeletion = app.buttons.matching(identifier: "shelf.deleteGroup.confirm").firstMatch
        XCTAssertTrue(confirmDeletion.waitForExistence(timeout: 5)); confirmDeletion.tap()
        wait(app) { app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "shelf.group.")).count == 0 }
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "shelf.book.")).count, 1)
        app.terminate()
        app.launchEnvironment["READER_UI_RESET"] = "0"
        app.launch()
        XCTAssertTrue(app.buttons["shelf.layout.list"].waitForExistence(timeout: 40))
        XCTAssertEqual(app.buttons["shelf.layout.list"].value as? String, "Selected")
        capture("shelf-ungrouped-list-relaunched")
        app.terminate()
    }
    @MainActor func testShelfMixedMembershipBatchScopeAndRemoval() throws {
        let app = XCUIApplication()
        app.launchEnvironment["READER_UI_RESET"] = "1"
        app.launchEnvironment["READER_UI_SCENARIO"] = "shelf-mixed"
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        let books = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "shelf.book."))
        wait(app) { books.count == 2 }
        func group(_ title: String) -> XCUIElement {
            app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "shelf.group.", title)).firstMatch
        }
        func book(_ second: Bool) -> XCUIElement {
            app.buttons.matching(NSPredicate(format: second ? "identifier BEGINSWITH %@ AND label CONTAINS %@" : "identifier BEGINSWITH %@ AND NOT (label CONTAINS %@)", "shelf.book.", "Second")).firstMatch
        }
        func bookMenu(_ second: Bool) -> XCUIElement {
            app.buttons.matching(NSPredicate(format: second ? "identifier BEGINSWITH %@ AND label CONTAINS %@" : "identifier BEGINSWITH %@ AND NOT (label CONTAINS %@)", "shelf.bookMenu.", "Second")).firstMatch
        }
        func create(_ name: String) {
            app.buttons["shelf.newGroup"].tap()
            let field = app.textFields["shelf.groupName"]
            XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText(name)
            app.buttons["shelf.group.save"].tap()
            XCTAssertTrue(group(name).waitForExistence(timeout: 10))
        }
        create("Later"); create("Fiction")
        let laterID = group("Later").identifier.replacingOccurrences(of: "shelf.group.", with: "")
        let fictionID = group("Fiction").identifier.replacingOccurrences(of: "shelf.group.", with: "")
        bookMenu(false).tap(); app.buttons["Set groups"].tap()
        XCTAssertTrue(app.buttons["shelf.membership.group." + laterID].waitForExistence(timeout: 5))
        app.buttons["shelf.membership.group." + laterID].tap()
        app.buttons["shelf.membership.save"].tap()
        wait(app) { books.count == 1 }
        capture("shelf-mixed-home-grid")
        app.buttons["shelf.select"].tap(); app.buttons["shelf.selectAll"].tap()
        XCTAssertEqual(app.staticTexts["shelf.selectionCount"].label, "1 selected", "Closed groups must not expand Select all")
        app.buttons["shelf.select"].tap()
        bookMenu(true).tap(); app.buttons["Set groups"].tap()
        XCTAssertTrue(app.buttons["shelf.membership.group." + laterID].waitForExistence(timeout: 5))
        app.buttons["shelf.membership.group." + laterID].tap()
        app.buttons["shelf.membership.group." + fictionID].tap()
        app.buttons["Cancel"].tap()
        XCTAssertTrue(book(true).waitForExistence(timeout: 5), "Cancel must leave this book ungrouped")
        bookMenu(true).tap(); app.buttons["Set groups"].tap()
        app.buttons["shelf.membership.group." + laterID].tap()
        app.buttons["shelf.membership.group." + fictionID].tap()
        app.buttons["shelf.membership.save"].tap()
        wait(app) { books.count == 0 }
        group("Later").tap(); wait(app) { books.count == 2 }
        app.buttons["shelf.select"].tap(); app.buttons["shelf.selectAll"].tap()
        XCTAssertEqual(app.staticTexts["shelf.selectionCount"].label, "2 selected")
        app.buttons["shelf.selectionActions"].tap(); app.buttons["Set groups"].tap()
        let fiction = app.buttons["shelf.membership.group." + fictionID]
        XCTAssertTrue(fiction.waitForExistence(timeout: 5))
        XCTAssertEqual(fiction.value as? String, "Some books")
        capture("shelf-mixed-membership-checklist")
        app.buttons["shelf.membership.save"].tap()
        XCTAssertTrue(app.buttons["shelf.home"].waitForExistence(timeout: 5))
        app.buttons["shelf.home"].tap(); group("Fiction").tap()
        wait(app) { books.count == 1 }
        XCTAssertTrue(book(true).exists, "Untouched mixed membership must not add the other book")
        app.buttons["shelf.home"].tap(); group("Later").tap()
        bookMenu(false).tap(); app.buttons["Remove from this group"].tap()
        wait(app) { books.count == 1 }
        app.buttons["shelf.home"].tap()
        XCTAssertTrue(book(false).waitForExistence(timeout: 5), "Last-group removal returns the book to home")
        group("Later").tap(); bookMenu(true).tap(); app.buttons["Remove from shelf"].tap()
        let confirm = app.buttons.matching(identifier: "shelf.remove.confirm").firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5)); confirm.tap()
        wait(app) { books.count == 0 }
        app.buttons["shelf.home"].tap(); group("Fiction").tap()
        wait(app) { books.count == 0 }
        app.buttons["shelf.home"].tap()
        XCTAssertTrue(book(false).exists)
        XCUIDevice.shared.orientation = .landscapeLeft
        wait(app) { app.frame.width > app.frame.height }
        app.buttons["shelf.layout.list"].tap()
        capture("shelf-mixed-home-list-after-removal")
        app.terminate()
        app.launchEnvironment["READER_UI_RESET"] = "0"; app.launch()
        XCTAssertTrue(app.buttons["shelf.newGroup"].waitForExistence(timeout: 40))
        XCTAssertEqual(books.count, 1)
        XCTAssertEqual(app.buttons["shelf.layout.list"].value as? String, "Selected")
        app.terminate()
    }

    @MainActor func testShelfSaveFailureKeepsSelectionAndStaleEditorRequiresReview() throws {
        let app = XCUIApplication()
        app.launchEnvironment["READER_UI_RESET"] = "1"
        app.launchEnvironment["READER_UI_SCENARIO"] = "shelf-mixed"
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        XCTAssertTrue(app.buttons["shelf.newGroup"].waitForExistence(timeout: 40))
        app.buttons["shelf.newGroup"].tap()
        let field = app.textFields["shelf.groupName"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText("Later")
        app.buttons["shelf.group.save"].tap()
        let group = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "shelf.group.")).firstMatch
        XCTAssertTrue(group.waitForExistence(timeout: 10))
        let id = group.identifier.replacingOccurrences(of: "shelf.group.", with: "")
        XCTAssertTrue(app.buttons["fixture.groupSaveFailure"].exists)
        app.buttons["fixture.groupSaveFailure"].tap()
        app.buttons["shelf.select"].tap(); app.buttons["shelf.selectAll"].tap()
        app.buttons["shelf.selectionActions"].tap(); app.buttons["Set groups"].tap()
        XCTAssertTrue(app.buttons["shelf.membership.group." + id].waitForExistence(timeout: 5))
        app.buttons["shelf.membership.group." + id].tap(); app.buttons["shelf.membership.save"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Synthetic group save rejection")).firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["shelf.membership.save"].exists, "Save failure must leave the draft available")
        capture("shelf-membership-save-failure")
        app.buttons["Cancel"].tap()
        XCTAssertEqual(app.staticTexts["shelf.selectionCount"].label, "2 selected")
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "shelf.book.")).count, 2)
        app.buttons["fixture.groupSaveFailure"].tap()
        app.buttons["fixture.externalGroupChange"].tap()
        XCTAssertTrue(app.staticTexts["fixture.shelfMutation"].waitForExistence(timeout: 5))
        wait(app) { app.staticTexts["fixture.shelfMutation"].value as? String == "changed" }
        app.buttons["shelf.selectionActions"].tap(); app.buttons["Set groups"].tap()
        app.buttons["shelf.membership.group." + id].tap(); app.buttons["shelf.membership.save"].tap()
        let staleMessage = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Cancel and reopen")).firstMatch
        XCTAssertTrue(staleMessage.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["shelf.membership.save"].isEnabled)
        capture("shelf-stale-editor-review-required")
        app.buttons["Cancel"].tap()
        XCTAssertEqual(app.staticTexts["shelf.selectionCount"].label, "2 selected")
        app.buttons["shelf.selectionActions"].tap(); app.buttons["Set groups"].tap()
        let renamed = app.buttons["shelf.membership.group." + id]
        XCTAssertTrue(renamed.waitForExistence(timeout: 5))
        XCTAssertTrue(renamed.label.contains("Later updated"))
        XCTAssertTrue(app.buttons["shelf.membership.save"].isEnabled)
        renamed.tap(); app.buttons["shelf.membership.save"].tap()
        wait(app) { app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "shelf.book.")).count == 0 }
        app.terminate()
    }

    @MainActor func testEmptyShelfAuthorSearchTrialAdmissionRemovalAndReadmission() throws {
        let app = XCUIApplication()
        app.launchEnvironment["READER_UI_RESET"] = "1"
        app.launchEnvironment["READER_UI_SCENARIO"] = "shelf-empty"
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        XCTAssertTrue(app.buttons["Find a book"].waitForExistence(timeout: 40))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "shelf.book.")).count, 0)
        capture("shelf-empty-home")
        func findByAuthor() {
            let field = app.textFields["search.query"]
            XCTAssertTrue(field.waitForExistence(timeout: 10)); field.tap()
            if let value = field.value as? String, value != "Book title or author", !value.isEmpty {
                field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count))
            }
            field.typeText("Fixture Author\n")
            let work = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "discovered sources")).firstMatch
            XCTAssertTrue(work.waitForExistence(timeout: 15))
            let candidate = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "search.candidate.")).firstMatch
            if !candidate.exists { work.tap() }
            XCTAssertTrue(candidate.waitForExistence(timeout: 10)); candidate.tap()
            XCTAssertTrue(app.buttons["details.read"].waitForExistence(timeout: 15))
        }
        app.buttons["Find a book"].tap(); findByAuthor()
        app.buttons["details.read"].tap()
        XCTAssertTrue(app.buttons["reader.shelf"].waitForExistence(timeout: 15))
        app.buttons["reader.shelf"].tap()
        XCTAssertTrue(app.buttons["Find a book"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "shelf.book.")).count, 0, "Trial reading must not admit the work")
        app.buttons["navigation.search"].tap(); findByAuthor()
        app.buttons["details.add"].tap()
        XCTAssertTrue(app.staticTexts["Added to shelf."].waitForExistence(timeout: 15))
        app.buttons["reader.shelf"].tap()
        let book = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "shelf.book.")).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 15))
        let bookIdentifier = book.identifier
        func group(_ title: String) -> XCUIElement {
            app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "shelf.group.", title)).firstMatch
        }
        func createGroup(_ title: String) -> String {
            app.buttons["shelf.newGroup"].tap()
            let field = app.textFields["shelf.groupName"]
            XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText(title)
            app.buttons["shelf.group.save"].tap()
            XCTAssertTrue(group(title).waitForExistence(timeout: 10))
            return group(title).identifier.replacingOccurrences(of: "shelf.group.", with: "")
        }
        let laterID = createGroup("Later")
        let fictionID = createGroup("Fiction")
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "shelf.bookMenu.")).firstMatch.tap()
        app.buttons["Set groups"].tap()
        XCTAssertTrue(app.buttons["shelf.membership.group." + laterID].waitForExistence(timeout: 5))
        app.buttons["shelf.membership.group." + laterID].tap()
        app.buttons["shelf.membership.group." + fictionID].tap()
        app.buttons["shelf.membership.save"].tap()
        wait(app) { !book.exists }
        group("Later").tap()
        XCTAssertTrue(app.buttons[bookIdentifier].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "shelf.book.")).count, 1)
        app.buttons[bookIdentifier].tap()
        XCTAssertTrue(app.buttons["reader.contents"].waitForExistence(timeout: 15))
        app.buttons["reader.contents"].tap()
        let chapter = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "contents.chapter.", "Chapter 2")).firstMatch
        XCTAssertTrue(chapter.waitForExistence(timeout: 10)); chapter.tap()
        let body = app.textViews["reader.text"]
        wait(app) { self.state(app).contains("chapter=1;") && (body.value as? String ?? "").contains("第199段") }
        body.swipeUp(); body.swipeUp()
        wait(app) { self.anchor(app) > 0 }
        waitForStableViewport(app)
        let position = anchor(app)
        let identity = readingIdentity(app)
        XCTAssertGreaterThan(position, 0, "The shared reading position must be a nonzero paragraph")
        XCTAssertEqual(identity.count, 3, "Observe source, book and chapter identity")
        capture("shelf-group-a-nonzero-reading-position")
        app.buttons["reader.shelf"].tap()
        XCTAssertTrue(app.buttons["shelf.home"].waitForExistence(timeout: 10))
        app.buttons["shelf.home"].tap(); group("Fiction").tap()
        XCTAssertTrue(app.buttons[bookIdentifier].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "shelf.book.")).count, 1)
        app.buttons[bookIdentifier].tap()
        wait(app) { self.state(app).contains("chapter=1;") && self.anchor(app) == position }
        XCTAssertEqual(readingIdentity(app), identity, "Both group appearances must open the same book and active source")
        capture("shelf-group-b-shared-reading-position")
        app.buttons["reader.shelf"].tap()
        app.terminate(); app.launchEnvironment["READER_UI_RESET"] = "0"; app.launch()
        XCTAssertTrue(app.buttons["shelf.newGroup"].waitForExistence(timeout: 40))
        for title in ["Later", "Fiction"] {
            XCTAssertTrue(group(title).exists)
            group(title).tap()
            XCTAssertTrue(app.buttons[bookIdentifier].waitForExistence(timeout: 10))
            XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "shelf.book.")).count, 1)
            app.buttons[bookIdentifier].tap()
            wait(app) { self.state(app).contains("chapter=1;") && self.anchor(app) == position }
            XCTAssertEqual(readingIdentity(app), identity, "Relaunch must preserve one shared source, chapter and paragraph")
            capture("shelf-relaunched-" + title.lowercased() + "-shared-position")
            app.buttons["reader.shelf"].tap()
            XCTAssertTrue(app.buttons["shelf.home"].waitForExistence(timeout: 10)); app.buttons["shelf.home"].tap()
        }
        for id in [laterID, fictionID] {
            app.buttons["shelf.groupMenu." + id].tap(); app.buttons["Delete group"].tap()
            app.buttons.matching(identifier: "shelf.deleteGroup.confirm").firstMatch.tap()
            wait(app) { !app.buttons["shelf.group." + id].exists }
        }
        XCTAssertTrue(book.waitForExistence(timeout: 10), "Deleting the populated groups keeps the same book ungrouped")
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "shelf.bookMenu.")).firstMatch.tap()
        app.buttons["Remove from shelf"].tap()
        app.buttons.matching(identifier: "shelf.remove.confirm").firstMatch.tap()
        wait(app) { !book.exists }
        XCTAssertFalse(app.staticTexts["shelf.notice"].exists, "A completed removal must not display an earlier admission/save notice")
        app.terminate(); app.launchEnvironment["READER_UI_RESET"] = "0"; app.launch()
        XCTAssertTrue(app.buttons["Find a book"].waitForExistence(timeout: 40))
        XCTAssertFalse(book.exists, "An empty shelf remains empty across relaunch")
        app.buttons["Find a book"].tap(); findByAuthor()
        app.buttons["details.read"].tap()
        XCTAssertTrue(app.buttons["reader.shelf"].waitForExistence(timeout: 15)); app.buttons["reader.shelf"].tap()
        XCTAssertTrue(app.buttons["Find a book"].waitForExistence(timeout: 10))
        XCTAssertFalse(book.exists, "Reading a removed work must not re-admit it")
        app.buttons["navigation.search"].tap(); findByAuthor(); app.buttons["details.add"].tap()
        XCTAssertTrue(app.staticTexts["Added to shelf."].waitForExistence(timeout: 15))
        app.buttons["reader.shelf"].tap()
        XCTAssertTrue(book.waitForExistence(timeout: 10)); book.tap()
        XCTAssertTrue(app.buttons["reader.contents"].waitForExistence(timeout: 15))
        wait(app) { self.state(app).contains("chapter=1;") && self.anchor(app) == position }
        XCTAssertEqual(readingIdentity(app), identity, "Re-admission preserves the same active source and reading position")
        capture("shelf-readmission-retains-chapter")
        app.terminate()
    }

    @MainActor private func launchDiscovery(_ scenario: String = "discovery") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["READER_UI_RESET"] = "1"
        app.launchEnvironment["READER_UI_SCENARIO"] = scenario
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        let source = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "discovery.source.")).firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 40))
        return app
    }
    @MainActor private func openDiscoverySource(_ app: XCUIApplication) {
        let source = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "discovery.source.")).firstMatch
        source.tap()
        XCTAssertTrue(app.buttons["discovery.category.Popular"].waitForExistence(timeout: 15))
    }
    @MainActor private func discoveryBook(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "discovery.book.")).firstMatch
    }

    @MainActor func testDiscoveryBrowseDetailsTrialShelfReturnAndRelaunch() throws {
        let app = launchDiscovery()
        app.buttons["discovery.groupFilter"].tap()
        XCTAssertTrue(app.buttons["Discovery"].waitForExistence(timeout: 5)); app.buttons["Discovery"].tap()
        let filter = app.textFields["discovery.sourceFilter"]
        filter.tap(); filter.typeText("missing-source")
        wait(app) { app.staticTexts["No matching sources."].exists }
        filter.tap(); filter.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 14))
        filter.typeText("\n")
        openDiscoverySource(app)
        capture("discovery-categories-portrait")
        app.buttons["discovery.category.Popular"].tap()
        XCTAssertTrue(discoveryBook(app).waitForExistence(timeout: 15))
        app.buttons["discovery.more"].tap()
        wait(app) { app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "discovery.book.")).count == 2 }
        XCUIDevice.shared.orientation = .landscapeLeft
        wait(app) { app.frame.width > app.frame.height }
        capture("discovery-books-landscape")
        let shelfBookIdentifier = discoveryBook(app).identifier.replacingOccurrences(of: "discovery.book.", with: "shelf.book.")
        discoveryBook(app).tap()
        XCTAssertTrue(app.buttons["details.read"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["details.add"].exists)
        app.buttons["details.read"].tap()
        XCTAssertTrue(app.buttons["reader.contents"].waitForExistence(timeout: 15))
        capture("discovery-unshelved-trial-reading")
        app.buttons["reader.contents"].tap()
        XCTAssertTrue(app.buttons["navigation.searchResults"].waitForExistence(timeout: 10))
        app.buttons["navigation.searchResults"].tap()
        XCTAssertTrue(app.staticTexts["End of category."].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "discovery.book.")).count, 2)
        discoveryBook(app).tap()
        XCTAssertTrue(app.buttons["details.add"].waitForExistence(timeout: 15)); app.buttons["details.add"].tap()
        XCTAssertTrue(app.staticTexts["Added to shelf."].waitForExistence(timeout: 15))
        app.buttons["details.read"].tap()
        XCTAssertTrue(app.buttons["reader.contents"].waitForExistence(timeout: 15))
        capture("discovery-shelved-reading")
        app.buttons["reader.contents"].tap()
        XCTAssertTrue(app.buttons["navigation.searchResults"].waitForExistence(timeout: 10))
        app.buttons["navigation.searchResults"].tap()
        XCTAssertTrue(app.staticTexts["End of category."].waitForExistence(timeout: 10))
        app.terminate()
        app.launchEnvironment["READER_UI_RESET"] = "0"
        app.launchEnvironment["READER_UI_SCENARIO"] = "shelf"
        app.launch()
        let book = app.buttons[shelfBookIdentifier]
        XCTAssertTrue(book.waitForExistence(timeout: 40)); book.tap()
        XCTAssertTrue(app.buttons["reader.contents"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts["fixture.failure"].exists)
        capture("discovery-shelf-reopened")
        app.terminate()
    }

    @MainActor func testDiscoveryRetryAndCrossEngineDisableEndVisibleLoading() throws {
        let app = launchDiscovery("discovery-held")
        openDiscoverySource(app)
        app.buttons["discovery.category.Retry pages"].tap()
        XCTAssertTrue(app.buttons["discovery.more"].waitForExistence(timeout: 15)); app.buttons["discovery.more"].tap()
        XCTAssertTrue(app.buttons["discovery.retry"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "discovery.book.")).count, 1)
        capture("discovery-failed-page-retains-first")
        app.buttons["discovery.retry"].tap()
        wait(app) { app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "discovery.book.")).count == 2 }
        app.buttons["discovery.allCategories"].tap()
        XCTAssertTrue(app.buttons["discovery.category.Held pages"].waitForExistence(timeout: 10))
        app.buttons["discovery.category.Held pages"].tap()
        XCTAssertTrue(app.buttons["discovery.more"].waitForExistence(timeout: 15)); app.buttons["discovery.more"].tap()
        XCTAssertTrue(app.buttons["Stop browsing"].waitForExistence(timeout: 10))
        app.buttons["fixture.invalidateDiscovery"].tap()
        XCTAssertTrue(app.staticTexts["Browsing stopped. Results may be incomplete."].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Stop browsing"].exists)
        XCTAssertFalse(app.buttons["discovery.more"].exists)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "discovery.book.")).count, 1)
        XCTAssertFalse(app.staticTexts["fixture.failure"].exists)
        capture("discovery-external-disable-terminal")
        app.terminate()
    }

    @MainActor func testDiscoveryOptionsEmptyUnsupportedAndVisibilityPersist() throws {
        let app = launchDiscovery()
        openDiscoverySource(app)
        let unsupported = app.otherElements["discovery.unsupported"]
        if !unsupported.isHittable { app.swipeUp() }
        XCTAssertTrue(app.staticTexts["This category needs controls that are not available in this native reader yet."].exists)
        app.buttons["discovery.category.Empty"].tap()
        XCTAssertTrue(app.staticTexts["No books in this category."].waitForExistence(timeout: 15))
        app.buttons["discovery.allCategories"].tap()
        XCTAssertTrue(app.buttons["discovery.category.Options"].waitForExistence(timeout: 10))
        app.buttons["discovery.category.Options"].tap()
        XCTAssertTrue(app.buttons["discovery.option.Order"].waitForExistence(timeout: 15))
        app.buttons["discovery.option.Order"].tap(); app.buttons["New"].tap()
        wait(app) { self.discoveryBook(app).label.contains("new") }
        capture("discovery-native-option-new")
        app.buttons["discovery.allCategories"].tap()
        XCTAssertTrue(app.buttons["discovery.category.Dynamic options"].waitForExistence(timeout: 10))
        app.buttons["discovery.category.Dynamic options"].tap()
        XCTAssertTrue(app.buttons["discovery.retry"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["discovery.option.Order"].exists)
        capture("discovery-dynamic-option-after-failure")
        app.buttons["discovery.option.Order"].tap(); app.buttons["Working"].tap()
        wait(app) { self.discoveryBook(app).exists && self.discoveryBook(app).label.contains("working") }
        XCTAssertFalse(app.buttons["discovery.retry"].exists)
        capture("discovery-dynamic-option-recovered")
        app.buttons["Sources"].tap()
        let source = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Discovery Fixture Source")).firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 10)); source.tap()
        let visible = app.switches["sources.discoveryEnabled"]
        XCTAssertTrue(visible.waitForExistence(timeout: 10)); XCTAssertEqual(visible.value as? String, "1")
        visible.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        wait(app) { visible.value as? String == "0" }
        app.buttons["Done"].tap(); app.buttons["Discover"].tap()
        XCTAssertTrue(app.buttons["discovery.allSources"].waitForExistence(timeout: 10))
        app.buttons["discovery.allSources"].tap()
        XCTAssertTrue(app.staticTexts["Hidden from Discover"].waitForExistence(timeout: 10))
        app.terminate(); app.launchEnvironment["READER_UI_RESET"] = "0"; app.launch()
        XCTAssertTrue(app.staticTexts["Hidden from Discover"].waitForExistence(timeout: 40))
        XCTAssertFalse(app.staticTexts["Source is disabled"].exists)
        capture("discovery-visibility-persisted")
        app.terminate()
    }

    @MainActor func testOtherEngineSourceChangeEndsVisibleSearch() throws {
        let app = XCUIApplication()
        app.launchEnvironment["READER_UI_RESET"] = "1"
        app.launchEnvironment["READER_UI_SCENARIO"] = "search-invalidation"
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        XCTAssertTrue(app.buttons["Stop"].waitForExistence(timeout: 40))
        capture("search-before-external-source-change")
        app.buttons["fixture.invalidateSearch"].tap()
        let terminal = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Incomplete search")).firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Stop"].exists)
        XCTAssertTrue(app.staticTexts["Results may be incomplete. A discovered candidate does not guarantee readable chapters."].exists)
        XCTAssertFalse(app.staticTexts["fixture.failure"].exists)
        capture("search-after-external-source-change")
        app.terminate()
    }

    @MainActor func testSourceImportGroupsDisableAndRelaunch() throws {
        let app = XCUIApplication()
        app.launchEnvironment["READER_UI_RESET"] = "1"
        app.launchEnvironment["READER_UI_SCENARIO"] = "sources"
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        let confirm = app.buttons["sources.confirmImport"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 40))
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "http://127.0.0.1:18769/runs/ui-")).count, 2,
                       "Same-name sources must show distinct identities in review")
        capture("sources-import-review")
        confirm.tap()
        let select = app.buttons["sources.select"]
        XCTAssertTrue(select.waitForExistence(timeout: 20))
        wait(app) { !confirm.exists && select.isEnabled }
        select.tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.exists); search.tap(); search.typeText("second")
        wait(app) { app.staticTexts["Sources (1)"].exists }
        app.buttons["Select visible"].tap()
        XCTAssertTrue(app.staticTexts["1 selected"].exists)
        search.tap(); search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 6))
        wait(app) { app.staticTexts["Sources (2)"].exists }
        XCTAssertTrue(app.staticTexts["1 selected"].exists)
        app.buttons["Select visible"].tap()
        app.segmentedControls["sources.status"].buttons["Disabled"].tap()
        wait(app) { app.staticTexts["No matching text sources."].exists }
        XCTAssertTrue(app.staticTexts["2 selected"].exists)
        app.segmentedControls["sources.status"].buttons["All"].tap()
        app.buttons["Groups"].tap()
        let field = app.textFields["sources.groupName"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText("Favorites")
        XCTAssertTrue(app.buttons["Add to group"].isEnabled)
        app.buttons["Add to group"].tap()
        print("SOURCE REPLIES AFTER TAP: " + String(describing: app.staticTexts["fixture.sourceReplies"].value))
        let grouped = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS %@", "Path C Controlled Source", "Favorites"))
        wait(app) { !field.exists && grouped.count == 2 }
        print("SOURCE REPLIES: " + String(describing: app.staticTexts["fixture.sourceReplies"].value))
        app.buttons["sources.groupFilter"].tap()
        app.buttons["Favorites"].tap()
        wait(app) { app.buttons["sources.groupFilter"].label.contains("Favorites") }
        XCTAssertTrue(app.staticTexts["2 selected"].exists)
        app.buttons["Groups"].tap()
        app.buttons["Remove from Path C"].tap()
        wait(app) { !app.buttons["Remove from Path C"].exists }
        app.buttons["Disable"].tap()
        wait(app) { app.switches.matching(NSPredicate(format: "label BEGINSWITH %@", "Enable Path C")).firstMatch.value as? String == "0" }
        capture("sources-disabled-portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        wait(app) { app.frame.width > app.frame.height }
        capture("sources-groups-landscape")
        app.terminate()
        app.launchEnvironment["READER_UI_RESET"] = "0"
        app.launch()
        XCTAssertTrue(app.buttons["sources.select"].waitForExistence(timeout: 40))
        let toggle = app.switches.matching(NSPredicate(format: "label BEGINSWITH %@", "Enable Path C")).firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 10)); XCTAssertEqual(toggle.value as? String, "0")
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS %@", "Path C Controlled Source", "Favorites")).count, 2)
        XCTAssertFalse(app.staticTexts["Path C"].exists)
        capture("sources-persisted-after-relaunch")
        app.buttons["sources.select"].tap(); app.buttons["Select visible"].tap()
        app.buttons["Export"].tap()
        let cancelExport = app.buttons["Cancel"]
        XCTAssertTrue(cancelExport.waitForExistence(timeout: 10))
        capture("sources-system-export")
        cancelExport.tap()
        app.terminate()
    }

    @MainActor func testGlobalPrefetchToggleCachesTwoAndSurvivesRelaunch() async throws {
        let app = XCUIApplication()
        app.launchEnvironment["READER_UI_RESET"] = "1"
        app.launchEnvironment["READER_UI_SCENARIO"] = "offline"
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        let book = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Path C Book")).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 40)); book.tap()
        XCTAssertTrue(app.buttons["reader.typography"].waitForExistence(timeout: 15))
        app.buttons["reader.typography"].tap()
        let toggle = app.switches["offline.prefetch"]
        for _ in 0..<5 where !toggle.isHittable { app.swipeUp() }
        XCTAssertEqual(toggle.value as? String, "0")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        wait(app) { toggle.value as? String == "1" }
        capture("offline-global-prefetch-enabled")
        app.buttons["Done"].tap()
        wait(app) { self.state(app).contains("cached=2;cacheRunning=false;") }
        app.buttons["reader.contents"].tap(); app.buttons["contents.details"].tap()
        wait(app) { app.staticTexts["offline.count"].label == "3 of 26 chapters available offline" }
        app.terminate()
        app.launchEnvironment["READER_UI_RESET"] = "0"
        app.launchEnvironment["READER_UI_SCENARIO"] = "shelf"
        app.launch()
        XCTAssertTrue(book.waitForExistence(timeout: 40)); book.tap()
        XCTAssertTrue(app.buttons["reader.typography"].waitForExistence(timeout: 15))
        app.buttons["reader.typography"].tap()
        for _ in 0..<5 where !toggle.isHittable { app.swipeUp() }
        XCTAssertEqual(toggle.value as? String, "1")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        wait(app) { toggle.value as? String == "0" }
        app.terminate()
    }

    @MainActor func testOfflineCacheControlsAndProtectedRelaunch() async throws {
        let app = XCUIApplication()
        app.launchEnvironment["READER_UI_RESET"] = "1"
        app.launchEnvironment["READER_UI_SCENARIO"] = "offline"
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        let book = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Path C Book")).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 40)); book.tap()
        XCTAssertTrue(app.buttons["reader.contents"].waitForExistence(timeout: 15))
        wait(app) { self.state(app).contains("canSave=true;") }
        let source = try XCTUnwrap(state(app).components(separatedBy: ";").first { $0.hasPrefix("source=") })
            .replacingOccurrences(of: "source=", with: "")
        app.buttons["reader.contents"].tap()
        app.buttons["contents.details"].tap()
        let cache = app.buttons["offline.cache"]
        for _ in 0..<5 where !cache.isHittable { app.swipeUp() }
        app.buttons["fixture.hold"].tap()
        XCTAssertTrue(cache.isHittable); cache.tap()
        let (entered, _) = try await URLSession.shared.data(from: XCTUnwrap(URL(string: source + "/control/entered/chapter")))
        XCTAssertEqual(String(decoding: entered, as: UTF8.self), "entered")
        XCUIDevice.shared.press(.home)
        app.activate()
        wait(app) { app.staticTexts["offline.progress"].label.contains("Cancelled") }
        app.buttons["fixture.hold"].tap()
        let (released, _) = try await URLSession.shared.data(from: XCTUnwrap(URL(string: source + "/control/completed/chapter")))
        XCTAssertEqual(String(decoding: released, as: UTF8.self), "completed")
        XCTAssertEqual(app.staticTexts["offline.count"].label, "1 of 26 chapters available offline")
        capture("offline-background-cancelled")
        XCTAssertTrue(cache.isHittable); cache.tap()
        wait(app) { app.staticTexts["offline.count"].label == "21 of 26 chapters available offline" }
        capture("offline-ready-portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        wait(app) { app.frame.width > app.frame.height }
        let clear = app.buttons["offline.clear"]
        for _ in 0..<5 where !clear.isHittable { app.swipeUp() }
        capture("offline-ready-landscape")
        clear.tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.alerts.firstMatch.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Remove 20 cached chapters")).firstMatch.exists)
        capture("offline-protected-clear-confirmation")
        app.alerts.buttons["Clear cached chapters"].tap()
        wait(app) { app.staticTexts["offline.count"].label == "1 of 26 chapters available offline" }
        let (before, _) = try await URLSession.shared.data(from: XCTUnwrap(URL(string: source + "/offline/disable")))
        app.terminate()
        app.launchEnvironment["READER_UI_RESET"] = "0"
        app.launchEnvironment["READER_UI_SCENARIO"] = "shelf"
        app.launch()
        XCTAssertTrue(book.waitForExistence(timeout: 40)); book.tap()
        wait(app) { self.state(app).contains("chapter=0;") && self.state(app).contains("canSave=true;") }
        let (after, _) = try await URLSession.shared.data(from: XCTUnwrap(URL(string: source + "/offline/count")))
        XCTAssertEqual(before, after, "Offline relaunch must not request chapter text")
        capture("offline-resume-after-clear-and-relaunch")
        app.buttons["reader.contents"].tap()
        wait(app) { app.buttons["contents.currentChapter"].label.contains("Available offline") }
        capture("offline-catalog-availability")
        app.terminate()
    }

    @MainActor func testSourceSwitchProcessLossBeforeCommitAndAfterCommitBeforeAcknowledgment() throws {
        let app = XCUIApplication()
        app.launchEnvironment["READER_UI_RESET"] = "1"
        app.launchEnvironment["READER_UI_SCENARIO"] = "catalog"
        app.launchEnvironment["READER_UI_DROP_SWITCH_ACK"] = "1"
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        func openBook() {
            let book = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Path C Book")).firstMatch
            XCTAssertTrue(book.waitForExistence(timeout: 40)); book.tap()
            XCTAssertTrue(app.buttons["reader.changeSource"].waitForExistence(timeout: 15))
        }
        func prepare() {
            app.buttons["reader.changeSource"].tap()
            let work = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "discovered sources")).firstMatch
            XCTAssertTrue(work.waitForExistence(timeout: 15)); work.tap()
            let alternate = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND identifier CONTAINS %@", "search.candidate.", "-alternate")).firstMatch
            XCTAssertTrue(alternate.waitForExistence(timeout: 15)); alternate.tap()
            let chapter = app.buttons["switch.chapter.0"]
            XCTAssertTrue(chapter.waitForExistence(timeout: 15)); chapter.tap()
            XCTAssertTrue(app.buttons["switch.confirm"].waitForExistence(timeout: 15))
        }
        openBook(); prepare()
        capture("switch-before-commit-termination")
        app.terminate()
        app.launchEnvironment["READER_UI_RESET"] = "0"
        app.launchEnvironment["READER_UI_SCENARIO"] = "shelf"
        app.launch(); openBook()
        wait(app) { !self.state(app).contains("-alternate") && self.state(app).contains("chapter=0;") }
        prepare()
        app.buttons["switch.confirm"].tap()
        wait(app) { app.staticTexts["fixture.switchCommit"].value as? String == "true" }
        XCTAssertTrue(app.staticTexts["Switching source…"].exists)
        capture("switch-committed-before-acknowledgment")
        app.terminate()
        app.launch(); openBook()
        wait(app) { self.state(app).contains("-alternate") && self.state(app).contains("chapter=0;") && self.anchor(app) == 0 }
        capture("switch-lost-acknowledgment-recovered")
        app.terminate()
    }

    @MainActor func testExplicitSourceSwitchAndRelaunch() throws {
        let app = XCUIApplication()
        app.launchEnvironment["READER_UI_RESET"] = "1"
        app.launchEnvironment["READER_UI_SCENARIO"] = "catalog"
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        let book = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Path C Book")).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 40)); book.tap()
        XCTAssertTrue(app.buttons["reader.changeSource"].waitForExistence(timeout: 15))
        app.buttons["reader.find"].tap()
        let findQuery = app.textFields["reader.find.query"]
        XCTAssertTrue(findQuery.waitForExistence(timeout: 5)); findQuery.tap(); findQuery.typeText("C1-FIRST\n")
        wait(app) { app.staticTexts["reader.find.status"].label == "1 match" }
        app.buttons["reader.changeSource"].tap()
        XCTAssertFalse(findQuery.exists, "Source preparation must retire old find state")
        let work = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "discovered sources")).firstMatch
        XCTAssertTrue(work.waitForExistence(timeout: 15)); work.tap()
        let alternate = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND identifier CONTAINS %@", "search.candidate.", "-alternate")).firstMatch
        XCTAssertTrue(alternate.waitForExistence(timeout: 15)); alternate.tap()
        let chapter = app.buttons["switch.chapter.0"]
        XCTAssertTrue(chapter.waitForExistence(timeout: 15)); chapter.tap()
        XCTAssertTrue(app.buttons["switch.confirm"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["switch.originalSource"].exists)
        XCTAssertTrue(app.staticTexts["switch.replacementSource"].exists)
        capture("switch-prepared-portrait")
        app.buttons["switch.cancel"].tap()
        wait(app) { self.state(app).contains("chapter=0;") && !self.state(app).contains("-alternate") }
        app.buttons["reader.changeSource"].tap()
        XCTAssertTrue(work.waitForExistence(timeout: 15)); work.tap()
        XCTAssertTrue(alternate.waitForExistence(timeout: 15)); alternate.tap()
        XCTAssertTrue(chapter.waitForExistence(timeout: 15)); chapter.tap()
        XCTAssertTrue(app.buttons["switch.confirm"].waitForExistence(timeout: 15))
        XCUIDevice.shared.orientation = .landscapeLeft
        wait(app) { app.frame.width > app.frame.height && app.buttons["switch.confirm"].isHittable }
        capture("switch-prepared-landscape")
        app.buttons["switch.confirm"].tap()
        wait(app) { self.state(app).contains("-alternate") && self.state(app).contains("canSave=true;") && self.anchor(app) == 0 }
        app.buttons["reader.find"].tap()
        XCTAssertTrue(findQuery.waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["reader.find.status"].label, "Enter text to find")
        app.buttons["reader.find.close"].tap()
        capture("switch-committed")
        app.buttons["reader.shelf"].tap()
        XCTAssertTrue(book.waitForExistence(timeout: 15))
        app.terminate()
        app.launchEnvironment["READER_UI_RESET"] = "0"
        app.launchEnvironment["READER_UI_SCENARIO"] = "shelf"
        app.launch()
        XCTAssertTrue(book.waitForExistence(timeout: 40)); book.tap()
        wait(app) { self.state(app).contains("-alternate") && self.state(app).contains("chapter=0;") && self.anchor(app) == 0 }
        capture("switch-reopened")
        app.terminate()
    }

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
        XCTAssertTrue(body.frame.intersects(app.buttons["reader.contents"].frame), "Controls overlay the stable reading viewport")
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

    @MainActor func testTwoPageTurnsReflowAndDurableRecovery() {
        let app = XCUIApplication()
        app.launchEnvironment["READER_UI_RESET"] = "1"
        app.launchEnvironment["READER_UI_SCENARIO"] = "two-page"
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        let book = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Path C Book")).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 40))
        book.tap()
        XCTAssertTrue(app.textViews["reader.text"].waitForExistence(timeout: 20))
        app.buttons["reader.next"].tap()
        wait(app) { self.state(app).contains("chapter=1;") }
        let identity = readingIdentity(app)
        XCTAssertEqual(identity.count, 3)
        XCUIDevice.shared.orientation = .landscapeLeft
        wait(app) { self.state(app).contains("layout=spread;") }
        XCTAssertTrue(app.buttons["reader.contents"].isHittable)
        XCTAssertTrue(app.frame.contains(app.buttons["reader.contents"].frame))
        XCTAssertTrue(app.textViews["reader.text"].frame.intersects(app.buttons["reader.contents"].frame), "Controls overlay the stable reading viewport")
        capture("two-page-initial")
        let body = app.textViews["reader.text"]
        body.swipeLeft()
        wait(app) { self.state(app).contains("spread=1;") && self.anchor(app) > 0 }
        var position = anchor(app)
        capture("two-page-after-turn")
        body.swipeRight()
        wait(app) { self.state(app).contains("spread=0;") && self.anchor(app) == 0 }
        body.swipeLeft()
        wait(app) { self.anchor(app) == position }
        app.buttons["reader.typography"].tap()
        XCTAssertTrue(app.buttons["typography.larger"].waitForExistence(timeout: 5))
        app.buttons["typography.larger"].tap()
        app.buttons["Done"].tap()
        wait(app) { self.anchor(app) == position && self.state(app).contains("layout=spread;") }
        assertRenderedAnchor(app, identity: identity, position: position)
        capture("two-page-larger-text")
        app.buttons["fixture.readerWidth"].tap()
        wait(app) { self.anchor(app) == position && self.state(app).contains("layout=scroll;") }
        XCTAssertEqual(readingIdentity(app), identity)
        XCTAssertLessThanOrEqual(body.frame.width, 850)
        body.swipeUp()
        wait(app) { self.anchor(app) > position && self.state(app).contains("dragging=false;decelerating=false;") }
        position = anchor(app)
        XCTAssertEqual(readingIdentity(app), identity)
        capture("two-page-narrow-viewport")
        app.buttons["fixture.readerWidth"].tap()
        wait(app) { self.state(app).contains("layout=spread;") }
        assertRenderedAnchor(app, identity: identity, position: position)
        XCUIDevice.shared.orientation = .portrait
        wait(app) { self.anchor(app) == position && self.state(app).contains("layout=scroll;") }
        XCTAssertEqual(readingIdentity(app), identity)
        capture("two-page-portrait-reflow")
        XCUIDevice.shared.orientation = .landscapeRight
        wait(app) { self.anchor(app) == position && self.state(app).contains("layout=spread;") }
        for entry in ["contents.continue", "contents.currentChapter"] {
            app.buttons["reader.contents"].tap()
            XCTAssertTrue(app.buttons[entry].waitForExistence(timeout: 10))
            app.buttons[entry].tap()
            wait(app) { self.anchor(app) == position && app.buttons["reader.contents"].exists }
            assertRenderedAnchor(app, identity: identity, position: position)
        }
        app.buttons["fixture.saveFailure"].tap()
        app.buttons["reader.shelf"].tap()
        XCTAssertTrue(app.buttons["Retry save"].waitForExistence(timeout: 10))
        XCTAssertEqual(anchor(app), position)
        capture("two-page-save-rejected")
        app.buttons["fixture.saveFailure"].tap()
        app.buttons["Retry save"].tap()
        wait(app) { !app.buttons["Retry save"].exists }
        app.buttons["reader.shelf"].tap()
        XCTAssertTrue(book.waitForExistence(timeout: 10))
        app.terminate()
        app.launchEnvironment["READER_UI_RESET"] = "0"
        app.launch()
        XCTAssertTrue(book.waitForExistence(timeout: 30))
        book.tap()
        wait(app) { self.anchor(app) == position && self.state(app).contains("chapter=1;") && self.state(app).contains("layout=spread;") }
        XCTAssertFalse(app.staticTexts["fixture.failure"].exists)
        assertRenderedAnchor(app, identity: identity, position: position)
        capture("two-page-relaunched")
    }

    @MainActor func testReadingControlsTapKeepsViewportAndSelection() {
        let app = launchControlsReader()
        let body = app.textViews["reader.text"]
        let identity = readingIdentity(app)
        for mode in ["portrait", "spread", "narrow"] {
            if mode == "spread" {
                XCUIDevice.shared.orientation = .landscapeLeft
                wait(app) { self.state(app).contains("layout=spread;") }
            } else if mode == "narrow" {
                app.buttons["fixture.readerWidth"].tap()
                wait(app) { self.state(app).contains("layout=scroll;") && body.frame.width <= 850 }
            }
            waitForStableViewport(app)
            let before = viewportState(app)
            let position = anchor(app)
            for _ in 0..<3 {
                body.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.5)).tap()
                wait(app) { !app.buttons["reader.contents"].exists }
                XCTAssertFalse(app.buttons["reader.shelf"].exists)
                XCTAssertTrue(app.buttons["reader.controls"].isHittable)
                waitForStableViewport(app)
                XCTAssertEqual(viewportState(app), before)
                XCTAssertEqual(anchor(app), position)
                XCTAssertEqual(readingIdentity(app), identity)
                capture("controls-\(mode)-hidden")
                body.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.5)).tap()
                wait(app) { app.buttons["reader.contents"].isHittable }
                waitForStableViewport(app)
                XCTAssertEqual(viewportState(app), before)
                XCTAssertEqual(anchor(app), position)
            }
            capture("controls-\(mode)-shown")
            app.buttons["reader.controls"].tap()
            let previous = viewportState(app)
            if mode == "spread" { body.swipeLeft() } else { body.swipeUp() }
            waitForStableViewport(app)
            XCTAssertNotEqual(viewportState(app), previous, "The real gesture must move text")
            XCTAssertFalse(app.buttons["reader.contents"].exists, "A drag must not show controls")
            app.buttons["reader.controls"].tap()
            XCTAssertTrue(app.buttons["reader.contents"].isHittable)
            // Exercise actual lettering on both spread pages, not whitespace or the gutter.
            for prefix in mode == "spread" ? ["selection", "selectionRight"] : ["selection"] {
                let target = selectionPoint(app, prefix: prefix)
                body.coordinate(withNormalizedOffset: target).press(forDuration: 1.2)
                wait(app) { self.selectionLength(app) > 0 }
                XCTAssertTrue(app.buttons["reader.contents"].exists)
                capture("controls-\(mode)-\(prefix)-native-selection")
                body.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.60)).tap()
                wait(app) { self.selectionLength(app) == 0 }
                XCTAssertTrue(app.buttons["reader.contents"].exists, "Dismissing selection must not hide controls")
            }
        }
        app.terminate()
    }

    @MainActor func testHiddenControlsKeepFailureAndCancelActionsAvailable() {
        let app = launchControlsReader(openSecondChapter: false)
        let firstIdentity = readingIdentity(app)
        app.buttons["fixture.hold"].tap()
        app.buttons["reader.next"].tap()
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 10))
        app.buttons["reader.controls"].tap()
        XCTAssertTrue(app.buttons["Cancel"].isHittable)
        capture("controls-hidden-loading")
        app.buttons["Cancel"].tap()
        app.buttons["fixture.hold"].tap()
        wait(app) { !app.buttons["Cancel"].exists }
        XCTAssertEqual(readingIdentity(app), firstIdentity)
        XCTAssertEqual(anchor(app), 0)
        XCTAssertFalse(app.buttons["reader.contents"].exists)
        app.buttons["reader.controls"].tap()
        app.buttons["reader.next"].tap()
        wait(app) { self.state(app).contains("chapter=1;") }
        let body = app.textViews["reader.text"]
        let identity = readingIdentity(app)
        body.swipeUp()
        waitForStableViewport(app)
        let position = anchor(app)
        XCTAssertGreaterThan(position, 0)
        app.buttons["fixture.saveFailure"].tap()
        app.buttons["reader.shelf"].tap()
        XCTAssertTrue(app.buttons["Retry save"].waitForExistence(timeout: 15))
        app.buttons["reader.controls"].tap()
        XCTAssertFalse(app.buttons["reader.contents"].exists)
        for name in ["Retry save", "Return without saving", "Dismiss"] {
            XCTAssertTrue(app.buttons[name].isHittable)
        }
        XCTAssertEqual(anchor(app), position)
        XCTAssertEqual(readingIdentity(app), identity)
        capture("controls-hidden-save-rejection")
        app.buttons["fixture.saveFailure"].tap()
        app.buttons["Retry save"].tap()
        wait(app) { !app.buttons["Retry save"].exists }
        XCTAssertFalse(app.buttons["reader.contents"].exists)
        app.buttons["reader.controls"].tap()
        app.buttons["reader.next"].tap()
        XCTAssertTrue(app.buttons["Retry"].waitForExistence(timeout: 15))
        app.buttons["reader.controls"].tap()
        XCTAssertTrue(app.buttons["Retry"].isHittable)
        XCTAssertEqual(readingIdentity(app), identity)
        capture("controls-hidden-network-failure")
        app.buttons["Retry"].tap()
        wait(app) { self.state(app).contains("chapter=2;") }
        XCTAssertFalse(app.buttons["reader.contents"].exists)
        app.terminate()
    }

    @MainActor private func launchControlsReader(openSecondChapter: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["READER_UI_RESET"] = "1"
        app.launchEnvironment["READER_UI_SCENARIO"] = "two-page"
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        let book = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Path C Book")).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 40)); book.tap()
        XCTAssertTrue(app.buttons["reader.next"].waitForExistence(timeout: 20))
        if openSecondChapter {
            app.buttons["reader.next"].tap()
            wait(app) { self.state(app).contains("chapter=1;") }
        }
        XCTAssertTrue(app.buttons["reader.contents"].isHittable)
        return app
    }

    @MainActor private func selectionPoint(_ app: XCUIApplication, prefix: String = "selection") -> CGVector {
        func number(_ key: String) -> Double {
            let part = state(app).components(separatedBy: ";").first { $0.hasPrefix(key + "=") }
            return part.flatMap { Double($0.dropFirst(key.count + 1)) } ?? -1
        }
        let x = number(prefix + "X"), y = number(prefix + "Y")
        XCTAssertTrue((0...1).contains(x) && (0...1).contains(y), "Actual glyph must be in the viewport")
        return CGVector(dx: x, dy: y)
    }

    @MainActor private func selectionLength(_ app: XCUIApplication) -> Int {
        let value = state(app).components(separatedBy: ";").first { $0.hasPrefix("selected=") }
        return value.flatMap { Int($0.dropFirst("selected=".count)) } ?? -1
    }

    @MainActor private func viewportState(_ app: XCUIApplication) -> [String] {
        state(app).components(separatedBy: ";").filter { part in
            ["viewport=", "offset=", "rendered=", "scrollRendered=", "spread=", "layout="].contains { part.hasPrefix($0) }
        }
    }

    @MainActor private func waitForStableViewport(_ app: XCUIApplication) {
        var previous: [String] = []
        var stable = 0
        wait(app) {
            let current = self.viewportState(app)
            stable = current == previous ? stable + 1 : 0
            previous = current
            return stable >= 3 && !current.isEmpty && self.state(app).contains("dragging=false;decelerating=false;")
        }
    }

    @MainActor private func readingIdentity(_ app: XCUIApplication) -> [String] {
        state(app).components(separatedBy: ";").filter {
            $0.hasPrefix("source=") || $0.hasPrefix("book=") || $0.hasPrefix("id=")
        }
    }

    @MainActor private func assertRenderedAnchor(_ app: XCUIApplication, identity: [String], position: Int,
                                                file: StaticString = #filePath, line: UInt = #line) {
        wait(app, {
            guard let rendered = self.state(app).components(separatedBy: ";").first(where: { $0.hasPrefix("rendered=") }) else { return false }
            return rendered.dropFirst("rendered=".count).split(separator: ",").contains { item in
                let values = item.split(separator: ":").compactMap { Int($0) }
                return values.count == 2 && NSLocationInRange(position, NSRange(location: values[0], length: values[1]))
            }
        }, file: file, line: line)
        XCTAssertEqual(readingIdentity(app), identity, file: file, line: line)
        XCTAssertEqual(anchor(app), position, file: file, line: line)
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
