//
//  NoteBrowserDetail.swift
//  NoteCast
//
//  Detail pane and collection landing views.
//

import SwiftUI

/// Right-hand content area for either a selected note or a selected collection.
struct NoteBrowserDetail: View {
    @ObservedObject var store: NoteBrowserStore

    @ObservedObject var editorCommandBridge: NoteBrowserEditorCommandBridge

    @Binding var editorMode: EditorDisplayMode

    let createNote: () -> Void
    let saveNote: (_ noteID: UUID, _ title: String, _ text: String, _ folderID: UUID?) -> Bool
    let deleteNote: (_ noteID: UUID) -> Void
    let copyNote: (Note) -> Void
    let copyNoteUID: (Note) -> Void

    var body: some View {
        ZStack {
            TahoeWindowBackground()

            if let note = store.selectedNote {
                NoteBrowserEditorView(
                    note: note,
                    folders: store.folders,
                    commandBridge: editorCommandBridge,
                    editorMode: $editorMode,
                    save: saveNote
                )
                .id(note.stableID)
            } else {
                NoteCollectionLanding(
                    title: store.selectedCollectionTitle,
                    notes: store.notesForSelectedCollection,
                    select: { note in
                        guard let noteID = note.uuid else { return }
                        store.selection = .note(noteID)
                    },
                    createNote: createNote,
                    copyNote: copyNote,
                    copyNoteUID: copyNoteUID,
                    deleteNote: deleteNote
                )
            }
        }
    }
}

/// Soft, modern background inspired by macOS Tahoe's layered glass aesthetic.
///
/// This uses only standard SwiftUI materials and color, which keeps the visual
/// direction portable across app and preview builds.
struct TahoeWindowBackground: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color(nsColor: .windowBackgroundColor),
                Color.accentColor.opacity(0.10),
                Color(nsColor: .controlBackgroundColor)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
        .overlay {
            Rectangle()
                .fill(.ultraThinMaterial)
                .opacity(0.55)
                .ignoresSafeArea()
        }
    }
}

/// Landing view shown when the user has selected a collection instead of a note.
private struct NoteCollectionLanding: View {
    let title: String
    let notes: [Note]
    let select: (Note) -> Void
    let createNote: () -> Void
    let copyNote: (Note) -> Void
    let copyNoteUID: (Note) -> Void
    let deleteNote: (UUID) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                            .font(.largeTitle.bold())
                        Text("\(notes.count) note\(notes.count == 1 ? "" : "s")")
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button(action: createNote) {
                        Label("New Note", systemImage: "square.and.pencil")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }

                if notes.isEmpty {
                    ContentUnavailableView(
                        "No Notes Here",
                        systemImage: "note.text.badge.plus",
                        description: Text("Create a note or drag existing notes into this folder.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 360)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else {
                    LazyVStack(spacing: 12) {
                        ForEach(notes) { note in
                            Button {
                                select(note)
                            } label: {
                                NoteCard(note: note)
                            }
                            .buttonStyle(.plain)
                            .draggable(note.stableID) {
                                Label(note.displayTitle, systemImage: "note.text")
                                    .padding(8)
                            }
                            .noteActionsContextMenu(note: note, copy: copyNote, copyUID: copyNoteUID, delete: deleteNote)
                        }
                    }
                }
            }
            .padding(32)
            .frame(maxWidth: 900, alignment: .leading)
        }
    }
}

/// Large card used in collection landing lists.
private struct NoteCard: View {
    let note: Note

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(note.displayTitle)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Text(note.updated_at.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(note.bodyPreview)
                .font(.body)
                .foregroundStyle(.secondary)
                .lineLimit(3)

            HStack(spacing: 8) {
                Label(note.folder?.displayName ?? "Unfiled", systemImage: note.folder == nil ? "tray" : "folder")
                Text("-")
                Text(note.mimetype)
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.white.opacity(0.18), lineWidth: 1)
        }
    }
}
