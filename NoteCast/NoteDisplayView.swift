//
//  NoteDisplayView.swift
//  NoteCast
//
//  Read-only note window with copy/edit/delete actions.
//

import AppKit
import SwiftData
import SwiftUI

struct NoteDisplayView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var windowManager: NoteWindowManager

    let note: Note
    let didDelete: () -> Void
    let close: () -> Void

    @State private var errorMessage: String?

    init(
        note: Note,
        didDelete: @escaping () -> Void = {},
        close: @escaping () -> Void
    ) {
        self.note = note
        self.didDelete = didDelete
        self.close = close
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            ScrollView {
                Text(note.text)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .accessibilityIdentifier("NoteDisplay.text")
                    .accessibilityLabel(note.text)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.separator, lineWidth: 1)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("NoteDisplay.errorText")
            }

            HStack {
                Button("Copy") {
                    copyToClipboard()
                }
                .accessibilityIdentifier("NoteDisplay.copyButton")

                Button("Edit") {
                    windowManager.openEntryWindow(editing: note)
                }
                .accessibilityIdentifier("NoteDisplay.editButton")

                Spacer()

                Button("Delete", role: .destructive) {
                    deleteNote()
                }
                .accessibilityIdentifier("NoteDisplay.deleteButton")
            }
        }
        .padding(20)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(note.displayTitle)
                .font(.headline)
                .textSelection(.enabled)

            Text("Created \(note.created_at.formatted(date: .abbreviated, time: .shortened)) via \(note.created_via)")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("Updated \(note.updated_at.formatted(date: .abbreviated, time: .shortened)) • \(note.mimetype)")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("Folder: \(note.folder?.displayName ?? "Unfiled")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func copyToClipboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(note.text, forType: .string)
    }

    private func deleteNote() {
        modelContext.delete(note)

        do {
            try modelContext.save()
            didDelete()
            close()
        } catch {
            errorMessage = "Could not delete note: \(String(describing: error))"
        }
    }
}
