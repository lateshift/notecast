//
//  NoteCastUITests.swift
//  NoteCastUITests
//
//  End-to-end UI coverage for the real note entry/display views.
//

import AppKit
import XCTest

final class NoteCastUITests: XCTestCase {
    private var app: XCUIApplication!
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false

        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NoteCastUITests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )

        app = XCUIApplication()

        // `--ui-testing` opens a small test-only window in the app. The window
        // hosts the same NoteEntryView and NoteDisplayView that the menu bar
        // app uses, which gives us stable UI automation without trying to click
        // the system menu bar.
        app.launchArguments = ["--ui-testing"]

        // Use a private SwiftData store for this test run. This prevents tests
        // from seeing or changing the developer/user's real notes.
        app.launchEnvironment["NOTECAST_STORE_URL"] = temporaryDirectory
            .appendingPathComponent("NoteCastUITest.store")
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
    func testCreateCopyEditAndDeleteNoteThroughTheUI() throws {
        app.launch()

        let originalTitle = "UI title \(UUID().uuidString)"
        let editedTitle = "Edited UI title \(UUID().uuidString)"
        let originalText = "UI test note \(UUID().uuidString)"
        let editedText = "Edited UI test note \(UUID().uuidString)"

        // Create a note with the keyboard shortcut users rely on: Command+Return.
        let titleField = app.textFields["NoteEntry.titleField"].firstMatch
        XCTAssertTrue(titleField.waitForExistence(timeout: 10), app.debugDescription)
        titleField.click()
        pasteTextIntoFocusedEditor(originalTitle)

        let editor = app.textViews["NoteEntry.textView"].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10), app.debugDescription)
        editor.click()
        pasteTextIntoFocusedEditor(originalText)
        app.typeKey(.return, modifierFlags: [.command])

        assertNoEntrySaveErrorAndWaitForSavedState()

        // The real display view should be present; subsequent checks use its
        // action buttons to verify the underlying note body.
        XCTAssertTrue(app.staticTexts["NoteDisplay.text"].firstMatch.waitForExistence(timeout: 5), app.debugDescription)

        // Copy should put the exact note body on the macOS pasteboard. This is
        // also a reliable way to verify that the note shown by the display view
        // is the note we just created.
        copyDisplayedNoteAndAssertPasteboardEquals(originalText)

        // The mounted NoteMenuView should refresh without restarting the app.
        XCTAssertTrue(app.buttons[originalTitle].waitForExistence(timeout: 5), app.debugDescription)

        // Edit reuses the entry window, then Command+Return saves the update.
        app.buttons["NoteDisplay.editButton"].click()
        let editEditor = app.textViews["NoteEntry.textView"].firstMatch
        XCTAssertTrue(editEditor.waitForExistence(timeout: 5), app.debugDescription)

        // Regression check for the edit-window sizing bug: the editor should
        // open at the normal note-entry width, not as a tiny sliver.
        XCTAssertGreaterThan(editEditor.frame.width, 600)

        let editTitleField = app.textFields["NoteEntry.titleField"].firstMatch
        XCTAssertTrue(editTitleField.waitForExistence(timeout: 5), app.debugDescription)
        editTitleField.click()
        app.typeKey("a", modifierFlags: [.command])
        pasteTextIntoFocusedEditor(editedTitle)

        editEditor.click()
        app.typeKey("a", modifierFlags: [.command])
        pasteTextIntoFocusedEditor(editedText)
        app.typeKey(.return, modifierFlags: [.command])
        waitForEntryWindowToCloseOrFail()
        copyDisplayedNoteAndAssertPasteboardEquals(editedText)
        XCTAssertTrue(app.buttons[editedTitle].waitForExistence(timeout: 5), app.debugDescription)

        // Delete should remove the note and return the test harness to its
        // deleted state. This verifies the delete button's save path too.
        app.buttons["NoteDisplay.deleteButton"].click()
        XCTAssertTrue(app.staticTexts["UITest.deletedLabel"].waitForExistence(timeout: 5), app.debugDescription)
    }

    private func assertNoEntrySaveErrorAndWaitForSavedState(
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let savedLabel = app.staticTexts["UITest.savedLabel"]
        if savedLabel.waitForExistence(timeout: 5) {
            return
        }

        failWithEntryErrorOrDebugDescription(
            "The note was not saved and no error was shown.",
            file: file,
            line: line
        )
    }

    private func waitForEntryWindowToCloseOrFail(
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let editor = app.textViews["NoteEntry.textView"].firstMatch
        let closedPredicate = NSPredicate(format: "exists == false")

        // Use XCTest's normal predicate waiting API so failures include the
        // element state, then add the save error text when available.
        let expectation = XCTNSPredicateExpectation(predicate: closedPredicate, object: editor)
        if XCTWaiter().wait(for: [expectation], timeout: 5) == .completed {
            return
        }

        failWithEntryErrorOrDebugDescription(
            "The edit window did not close after saving.",
            file: file,
            line: line
        )
    }

    private func copyDisplayedNoteAndAssertPasteboardEquals(
        _ expectedText: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        NSPasteboard.general.clearContents()
        app.buttons["NoteDisplay.copyButton"].click()
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), expectedText, file: file, line: line)
    }

    private func pasteTextIntoFocusedEditor(_ text: String) {
        // Pasting is much less flaky than synthesizing dozens of individual
        // keystrokes, especially on busy CI machines.
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        app.typeKey("v", modifierFlags: [.command])
    }

    private func failWithEntryErrorOrDebugDescription(
        _ fallbackMessage: String,
        file: StaticString,
        line: UInt
    ) {
        let errorText = app.staticTexts["NoteEntry.errorText"]
        if errorText.exists {
            XCTFail(errorText.label, file: file, line: line)
        } else {
            XCTFail("\(fallbackMessage)\n\(app.debugDescription)", file: file, line: line)
        }
    }
}
