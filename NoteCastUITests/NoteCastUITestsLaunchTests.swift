//
//  NoteCastUITestsLaunchTests.swift
//  NoteCastUITests
//
//  A small launch smoke test using the same isolated UI-test mode as the main
//  end-to-end UI test.
//

import XCTest

final class NoteCastUITestsLaunchTests: XCTestCase {
    private var temporaryDirectory: URL!

    override class var runsForEachTargetApplicationUIConfiguration: Bool {
        false
    }

    override func setUpWithError() throws {
        continueAfterFailure = false

        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NoteCastLaunchUITests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
    }

    @MainActor
    func testLaunchesUITestHarness() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launchEnvironment["NOTECAST_STORE_URL"] = temporaryDirectory
            .appendingPathComponent("NoteCastLaunchUITest.store")
            .path
        app.launch()

        XCTAssertTrue(app.textViews["NoteEntry.textView"].waitForExistence(timeout: 10), app.debugDescription)

        app.terminate()
    }
}
