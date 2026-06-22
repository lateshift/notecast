//
//  NoteBrowserNoteActions.swift
//  NoteCast
//
//  Shared note context-menu actions.
//

import SwiftUI

/// Reusable right-click menu for note actions.
///
/// The confirmation state lives in the modifier so note rows and note cards get
/// the same safe delete behavior without duplicating UI code.
private struct NoteActionsContextMenu: ViewModifier {
    let note: Note
    let copy: (Note) -> Void
    let copyUID: (Note) -> Void
    let delete: (UUID) -> Void

    @State private var isConfirmingDelete = false

    func body(content: Content) -> some View {
        content
            .contextMenu {
                Button {
                    copy(note)
                } label: {
                    Label("Copy Markdown", systemImage: "doc.on.doc")
                }

                Button {
                    copyUID(note)
                } label: {
                    Label("Copy UID", systemImage: "number")
                }
                .disabled(note.uuid == nil)

                Divider()

                Button(role: .destructive) {
                    isConfirmingDelete = true
                } label: {
                    Label("Delete Note...", systemImage: "trash")
                }
                .disabled(note.uuid == nil)
            }
            .confirmationDialog(
                "Delete this note?",
                isPresented: $isConfirmingDelete,
                titleVisibility: .visible
            ) {
                Button("Delete Note", role: .destructive) {
                    guard let noteID = note.uuid else { return }
                    delete(noteID)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This cannot be undone.")
            }
    }
}

extension View {
    func noteActionsContextMenu(
        note: Note,
        copy: @escaping (Note) -> Void,
        copyUID: @escaping (Note) -> Void,
        delete: @escaping (UUID) -> Void
    ) -> some View {
        modifier(NoteActionsContextMenu(note: note, copy: copy, copyUID: copyUID, delete: delete))
    }
}
