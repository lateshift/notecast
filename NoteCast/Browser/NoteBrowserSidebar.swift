//
//  NoteBrowserSidebar.swift
//  NoteCast
//
//  Sidebar navigation for the main note browser.
//

import SwiftUI

/// Left-hand library navigation.
///
/// The sidebar shows collections, folders, and note rows. Dragging a note row
/// onto a folder row updates the shared `Note.folder` relationship through the
/// store action passed in from `NoteBrowserView`.
struct NoteBrowserSidebar: View {
    @ObservedObject var store: NoteBrowserStore

    let createFolder: () -> Void
    let renameFolder: (NoteFolder) -> Void
    let deleteFolder: (NoteFolder) -> Void
    let deleteNote: (UUID) -> Void
    let copyNote: (Note) -> Void
    let copyNoteUID: (Note) -> Void
    let moveDraggedNotes: (_ stableIDs: [String], _ folderID: UUID?) -> Bool

    var body: some View {
        VStack(spacing: 0) {
            searchField
            sidebarList
            sidebarFooter
        }
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private var sidebarList: some View {
        if store.isSearching {
            searchList
        } else {
            libraryList
        }
    }

    private var searchList: some View {
        List(selection: $store.selection) {
            librarySection

            Section("Search Results") {
                if store.searchResults.isEmpty {
                    Text("No matching notes")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.searchResults, id: \.stableID) { note in
                        NoteSidebarRow(note: note, copy: copyNote, copyUID: copyNoteUID, delete: deleteNote)
                    }
                }
            }
        }
        .id("search")
        .listStyle(.sidebar)
    }

    private var libraryList: some View {
        List(selection: $store.selection) {
            librarySection

            if !store.unfiledNotes.isEmpty {
                Section("Unfiled Notes") {
                    ForEach(store.unfiledNotes, id: \.stableID) { note in
                        NoteSidebarRow(note: note, copy: copyNote, copyUID: copyNoteUID, delete: deleteNote)
                    }
                }
            }

            Section {
                ForEach(store.folders) { folder in
                    FolderDisclosureRow(
                        folder: folder,
                        notes: store.notes(in: folder),
                        rename: { renameFolder(folder) },
                        delete: { deleteFolder(folder) },
                        copyNote: copyNote,
                        copyNoteUID: copyNoteUID,
                        deleteNote: deleteNote,
                        moveDraggedNotes: moveDraggedNotes
                    )
                }
            } header: {
                HStack {
                    Text("Folders")
                    Spacer()
                    Button(action: createFolder) {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.plain)
                    .help("New Folder")
                }
            }
        }
        .id("library")
        .listStyle(.sidebar)
    }

    private var librarySection: some View {
        Section("Library") {
            Label("All Notes", systemImage: "tray.full")
                .badge(store.notes.count)
                .tag(NoteBrowserSelection.allNotes)

            dropTargetRow(
                title: "Unfiled",
                systemImage: "tray",
                count: store.unfiledNotes.count,
                selection: .unfiled,
                folderID: nil
            )
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Search notes", text: $store.searchText)
                .textFieldStyle(.plain)
                .accessibilityIdentifier("NoteBrowser.searchField")

            if store.isSearching {
                Button {
                    store.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
                .accessibilityIdentifier("NoteBrowser.clearSearchButton")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            Color(nsColor: .controlBackgroundColor).opacity(0.72),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var sidebarFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let errorMessage = store.errorMessage {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                    Spacer(minLength: 0)
                    Button {
                        store.errorMessage = nil
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .help("Dismiss")
                }
            } else if store.isSearching {
                Label("\(store.searchResults.count) match\(store.searchResults.count == 1 ? "" : "es")", systemImage: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Label("Drag notes onto folders", systemImage: "hand.draw")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func dropTargetRow(
        title: String,
        systemImage: String,
        count: Int,
        selection: NoteBrowserSelection,
        folderID: UUID?
    ) -> some View {
        Label(title, systemImage: systemImage)
            .badge(count)
            .tag(selection)
            .dropDestination(for: String.self) { stableIDs, _ in
                _ = moveDraggedNotes(stableIDs, folderID)
            }
    }
}

/// One draggable note row in the sidebar.
private struct NoteSidebarRow: View {
    let note: Note
    let copy: (Note) -> Void
    let copyUID: (Note) -> Void
    let delete: (UUID) -> Void

    var body: some View {
        if let noteID = note.uuid {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(note.displayTitle)
                        .lineLimit(1)

                    Text(note.bodyPreview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } icon: {
                Image(systemName: "note.text")
            }
            .tag(NoteBrowserSelection.note(noteID))
            .draggable(note.stableID) {
                Label(note.displayTitle, systemImage: "note.text")
                    .padding(8)
            }
            .noteActionsContextMenu(note: note, copy: copy, copyUID: copyUID, delete: delete)
        }
    }
}

/// Folder row with an expandable list of contained notes.
private struct FolderDisclosureRow: View {
    let folder: NoteFolder
    let notes: [Note]
    let rename: () -> Void
    let delete: () -> Void
    let copyNote: (Note) -> Void
    let copyNoteUID: (Note) -> Void
    let deleteNote: (UUID) -> Void
    let moveDraggedNotes: (_ stableIDs: [String], _ folderID: UUID?) -> Bool

    var body: some View {
        if let folderID = folder.uuid {
            DisclosureGroup {
                if notes.isEmpty {
                    Text("No notes")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(notes) { note in
                        NoteSidebarRow(note: note, copy: copyNote, copyUID: copyNoteUID, delete: deleteNote)
                    }
                }
            } label: {
                Label(folder.displayName, systemImage: "folder")
                    .badge(notes.count)
            }
            .tag(NoteBrowserSelection.folder(folderID))
            .contextMenu {
                Button("Rename Folder...", action: rename)
                Button("Delete Folder", role: .destructive, action: delete)
            }
            .dropDestination(for: String.self) { stableIDs, _ in
                _ = moveDraggedNotes(stableIDs, folderID)
            }
        }
    }
}
