//
//  UITestHarnessView.swift
//  NoteCast
//
//  A tiny test-only window that makes compact note views UI-testable.
//

import SwiftData
import SwiftUI

/// Hosts the real note entry and display views for automated UI tests.
///
/// Menu bar extras themselves are awkward to drive from XCTest because they
/// live in the system menu bar. This harness is only created when the app is
/// launched with `--ui-testing`; it lets tests interact with the same compact
/// views and save path that users get from the menu bar quick-note workflow.
struct UITestHarnessView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var windowManager: NoteWindowManager

    private enum Mode {
        case entry
        case display
        case deleted
        case failed(String)
    }

    @State private var mode: Mode = .entry
    @State private var savedNote: Note?

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            mainTestContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Menu Preview")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("UITest.menuPreviewTitle")

                // Keep the real menu content mounted while the test creates and
                // edits notes. This verifies the refresh path that was buggy:
                // NoteMenuView must reload when `notesRevision` changes.
                NoteMenuView()
                    .environmentObject(windowManager)
            }
            .padding(12)
            .frame(width: 280, alignment: .topLeading)
        }
        .frame(minWidth: 980, minHeight: 520)
    }

    @ViewBuilder
    private var mainTestContent: some View {
        VStack(spacing: 0) {
            switch mode {
            case .entry:
                NoteEntryView(note: nil, didSave: {
                    windowManager.notesDidChange()
                }) {
                    loadMostRecentNoteAfterSave()
                }

            case .display:
                if let savedNote {
                    Text("Saved")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("UITest.savedLabel")

                    NoteDisplayView(note: savedNote, didDelete: {
                        windowManager.notesDidChange()
                    }) {
                        self.savedNote = nil
                        mode = .deleted
                    }
                    .environmentObject(windowManager)
                } else {
                    Text("No saved note found")
                        .accessibilityIdentifier("UITest.failureLabel")
                }

            case .deleted:
                Text("Deleted")
                    .font(.title2)
                    .padding(40)
                    .accessibilityIdentifier("UITest.deletedLabel")

            case .failed(let message):
                Text(message)
                    .foregroundStyle(.red)
                    .padding(40)
                    .accessibilityIdentifier("UITest.failureLabel")
            }
        }
    }

    private func loadMostRecentNoteAfterSave() {
        var descriptor = FetchDescriptor<Note>(sortBy: [
            SortDescriptor(\Note.created_at, order: .reverse)
        ])
        descriptor.fetchLimit = 1

        do {
            savedNote = try modelContext.fetch(descriptor).first
            mode = savedNote == nil ? .failed("Save finished, but no note was found") : .display
        } catch {
            mode = .failed("Could not reload saved note: \(String(describing: error))")
        }
    }
}
