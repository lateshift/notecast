//
//  CommandPaletteUITests.swift
//  NoteCastUITests
//
//  UI coverage for the main-window command palette.
//

import AppKit
import XCTest

final class CommandPaletteUITests: XCTestCase {
    private var app: XCUIApplication!
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false

        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NoteCastPaletteUITests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )

        app = XCUIApplication()
        app.launchEnvironment["NOTECAST_STORE_URL"] = temporaryDirectory
            .appendingPathComponent("NoteCastPaletteUITest.store")
            .path
    }

    override func tearDownWithError() throws {
        app?.terminate()

        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }

        app = nil
        temporaryDirectory = nil
    }

    @MainActor
    func testCommandPaletteExcludesNotesAndMovesSelectionWithArrowKeys() throws {
        let targetTitle = "Palette target \(UUID().uuidString)"
        let otherTitle = "Later note \(UUID().uuidString)"
        try seedNotes([
            ["title": targetTitle, "text": "The command palette should find this body."],
            ["title": otherTitle, "text": "This newer note should be selected first."]
        ])

        app.launch()
        app.activate()

        openMainWindowFromMenuBarIfNeeded()
        XCTAssertTrue(app.textFields["NoteBrowser.searchField"].firstMatch.waitForExistence(timeout: 10), app.debugDescription)

        openCommandPaletteFromMenu()
        let paletteRow = app.buttons["CommandPalette.row.command-newNote"].firstMatch
        XCTAssertTrue(paletteRow.waitForExistence(timeout: 5), app.debugDescription)

        pasteTextIntoFocusedEditor(targetTitle)

        let noteResult = app.buttons
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "CommandPalette.row.note-"))
            .firstMatch
        XCTAssertFalse(noteResult.waitForExistence(timeout: 1), app.debugDescription)
        XCTAssertTrue(app.staticTexts["No Results"].firstMatch.waitForExistence(timeout: 5), app.debugDescription)

        app.typeKey("a", modifierFlags: [.command])
        pasteTextIntoFocusedEditor("show")

        let showAllNotesRow = app.buttons["CommandPalette.row.command-showAllNotes"].firstMatch
        let showUnfiledRow = app.buttons["CommandPalette.row.command-showUnfiled"].firstMatch
        XCTAssertTrue(showAllNotesRow.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(showUnfiledRow.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(showAllNotesRow.value as? String, "Selected")

        app.typeKey(.downArrow, modifierFlags: [])
        XCTAssertEqual(showUnfiledRow.value as? String, "Selected")

        app.typeKey(.upArrow, modifierFlags: [])
        XCTAssertEqual(showAllNotesRow.value as? String, "Selected")
    }

    private func seedNotes(_ notes: [[String: String]]) throws {
        let data = try JSONSerialization.data(withJSONObject: notes)
        app.launchEnvironment["NOTECAST_UI_TEST_SEED_NOTES_JSON"] = try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    private func openCommandPaletteFromMenu() {
        app.menuBars.menuBarItems["View"].click()
        app.menuItems["Command Palette..."].click()
    }

    private func openMainWindowFromMenuBarIfNeeded() {
        if app.textFields["NoteBrowser.searchField"].firstMatch.exists {
            return
        }

        let statusItem = app.menuBars.statusItems["NoteCast"].firstMatch.exists
            ? app.menuBars.statusItems["NoteCast"].firstMatch
            : app.menuBars.statusItems.firstMatch

        guard statusItem.waitForExistence(timeout: 5) else {
            return
        }

        statusItem.click()
        let openItem = app.menuItems["Open NoteCast"].firstMatch
        if openItem.waitForExistence(timeout: 5) {
            openItem.click()
            app.activate()
        }
    }

    private func pasteTextIntoFocusedEditor(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        app.typeKey("v", modifierFlags: [.command])
    }
}
