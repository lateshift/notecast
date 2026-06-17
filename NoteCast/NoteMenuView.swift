//
//  NoteMenuView.swift
//  NoteCast
//
//  Contents of the macOS menu bar menu.
//

import AppKit
import SwiftData
import SwiftUI

struct NoteMenuView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var windowManager: NoteWindowManager
    @StateObject private var launchAtLogin = LaunchAtLoginController()

    /// The 10 notes shown in the menu.
    ///
    /// This is fetched manually whenever the menu appears or a refresh signal
    /// arrives instead of using `@Query`. A manual fetch from a fresh context
    /// makes notes written by the separate `cast` process visible.
    @State private var recentNotes: [Note] = []

    /// Retains the context that owns `recentNotes`. SwiftData model objects are
    /// tied to the context that fetched them, so the context must live at least
    /// as long as the menu entries do.
    @State private var recentNotesContext: ModelContext?

    @State private var fetchError: String?

    var body: some View {
        Group {
            Button("Open NoteCast") {
                openWindow(id: "main")
            }

            Button("New Quick Note…") {
                windowManager.openEntryWindow()
            }
            .keyboardShortcut("n", modifiers: [.command])

            Divider()

            if let fetchError {
                Text(fetchError)
                    .foregroundStyle(.red)
            } else if recentNotes.isEmpty {
                Text("No notes yet")
                    .foregroundStyle(.secondary)
            } else {
                Text("Last 10 Notes")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(recentNotes) { note in
                    Button(note.menuPreview) {
                        windowManager.openDisplayWindow(for: note)
                    }
                }
            }

            Divider()

            Toggle("Start at Login", isOn: Binding(
                get: { launchAtLogin.isEnabled },
                set: { launchAtLogin.setEnabled($0) }
            ))
            .accessibilityIdentifier("NoteMenu.startAtLoginToggle")

            if let statusMessage = launchAtLogin.statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Button("Quit NoteCast") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: [.command])
        }
        .onAppear {
            refreshNotes()
            launchAtLogin.refreshStatus()
        }
        .onChange(of: windowManager.notesRevision) { _, _ in
            refreshNotes()
        }
    }

    private func refreshNotes() {
        let context = ModelContext(modelContext.container)
        var descriptor = FetchDescriptor<Note>(sortBy: [
            SortDescriptor(\Note.created_at, order: .reverse)
        ])
        descriptor.fetchLimit = 10

        do {
            // Keep the context alive for as long as the menu is showing. The
            // fetched Note objects belong to this context.
            recentNotesContext = context
            recentNotes = try context.fetch(descriptor)
            fetchError = nil
        } catch {
            recentNotes = []
            recentNotesContext = nil
            fetchError = "Could not load notes"
        }
    }
}
