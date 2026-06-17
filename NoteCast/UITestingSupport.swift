//
//  UITestingSupport.swift
//  NoteCast
//
//  Small helpers used only when the app is launched by UI tests.
//

import Foundation

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
}
