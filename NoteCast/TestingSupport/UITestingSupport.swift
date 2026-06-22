//
//  UITestingSupport.swift
//  NoteCast
//
//  Small helpers used only when the app is launched by UI tests.
//

import Foundation
import SwiftData

/// UI tests launch the real app with `--ui-testing`.
///
/// Normal users never pass this argument, so the extra test harness window is
/// not shown in regular builds. Keeping the hook this small lets the UI tests
/// exercise the real NoteEntryView and NoteDisplayView without making the
/// production app or menu bar workflow more complicated.
enum UITestingSupport {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("--ui-testing")
    }

    /// Seeds the browser store for main-window UI tests.
    ///
    /// The hook is inert unless a UI test passes JSON through the environment,
    /// and UI tests also provide `NOTECAST_STORE_URL`, so this never writes to a
    /// developer's real NoteCast library.
    @MainActor
    static func seedBrowserNotesIfRequested(in modelContainer: ModelContainer) {
        let key = "NOTECAST_UI_TEST_SEED_NOTES_JSON"
        guard let json = ProcessInfo.processInfo.environment[key],
              let data = json.data(using: .utf8) else {
            return
        }

        do {
            let seeds = try JSONDecoder().decode([SeedNote].self, from: data)
            let context = ModelContext(modelContainer)
            for (index, seed) in seeds.enumerated() {
                let createdAt = Date(timeIntervalSince1970: TimeInterval(index + 1))
                context.insert(Note(
                    title: seed.title,
                    text: seed.text,
                    mimetype: NotePersistence.defaultMimetype,
                    created_at: createdAt,
                    created_via: NotePersistence.createdViaApp
                ))
            }
            try context.save()
        } catch {
            NSLog("NoteCast UI-test seed failed: %@", String(describing: error))
        }
    }

    private struct SeedNote: Decodable {
        let title: String
        let text: String
    }
}
