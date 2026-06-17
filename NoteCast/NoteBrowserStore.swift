//
//  NoteBrowserStore.swift
//  NoteCast
//
//  View-model layer for the full macOS notes browser window.
//

import Combine
import Foundation
import SwiftData

/// Sidebar/detail selection for the full NoteCast library window.
///
/// The SwiftUI `List(selection:)` API needs a stable `Hashable` value. We use
/// the public UUIDs from the models instead of SwiftData's internal persistent
/// identifiers so selection survives manual refetches and context replacement.
enum NoteBrowserSelection: Hashable {
    case allNotes
    case unfiled
    case folder(UUID)
    case note(UUID)
}

/// Errors shown by the browser UI.
struct NoteBrowserError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

/// Owns the SwiftData context used by the main browser window.
///
/// NoteCast UI surfaces and the `cast` CLI can both mutate the shared store. To
/// make the main window resilient to those cross-process changes, the store fetches
/// manually and can replace its `ModelContext` during `reload()`. UI selection is
/// held by model UUID, not object identity, so the visible selection remains
/// meaningful after a refetch.
@MainActor
final class NoteBrowserStore: ObservableObject {
    private let modelContainer: ModelContainer

    /// Current context for the objects published below.
    ///
    /// A `ModelContext` owns the live `Note` and `NoteFolder` instances returned
    /// by SwiftData. Replacing it on reload gives the full window the same
    /// freshness behavior as the menu bar menu, which also fetches from a fresh
    /// context when notes change externally.
    private var context: ModelContext

    /// All folders, sorted for display in the sidebar.
    @Published private(set) var folders: [NoteFolder] = []

    /// All notes, sorted with the most recently updated first.
    @Published private(set) var notes: [Note] = []

    /// User-entered fuzzy search query for the main browser window.
    @Published var searchText = "" {
        didSet {
            updateSelectionAfterSearchChange()
        }
    }

    /// Current sidebar selection. `nil` means the first load has not chosen a
    /// default yet.
    @Published var selection: NoteBrowserSelection?

    /// Last user-visible persistence problem.
    @Published var errorMessage: String?

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
        self.context = ModelContext(modelContainer)
    }

    /// The note currently selected in the sidebar, if the selection is a note.
    var selectedNote: Note? {
        guard case .note(let noteID) = selection else { return nil }
        return note(with: noteID)
    }

    var isSearching: Bool {
        NoteSearch.normalizedQuery(searchText) != nil
    }

    var searchResults: [Note] {
        NoteSearch.search(notes, query: searchText).map(\.note)
    }

    /// Notes that match the selected collection row.
    ///
    /// This powers the friendly empty/collection state in the detail area when
    /// the user selects "All Notes", "Unfiled", or a folder instead of a note.
    var notesForSelectedCollection: [Note] {
        if isSearching {
            return searchResults
        }

        switch selection {
        case .allNotes, nil:
            return notes
        case .unfiled:
            return unfiledNotes
        case .folder(let folderID):
            return notes(inFolderWithID: folderID)
        case .note:
            return []
        }
    }

    /// Human-readable title for the selected collection.
    var selectedCollectionTitle: String {
        if isSearching {
            return "Search Results"
        }

        switch selection {
        case .allNotes, nil:
            return "All Notes"
        case .unfiled:
            return "Unfiled"
        case .folder(let folderID):
            return folder(with: folderID)?.displayName ?? "Folder"
        case .note:
            return "Note"
        }
    }

    var unfiledNotes: [Note] {
        notes.filter { $0.folder == nil }
    }

    func notes(in folder: NoteFolder) -> [Note] {
        guard let folderID = folder.uuid else { return [] }
        return notes(inFolderWithID: folderID)
    }

    func notes(inFolderWithID folderID: UUID) -> [Note] {
        notes.filter { $0.folder?.uuid == folderID }
    }

    func note(with noteID: UUID) -> Note? {
        notes.first { $0.uuid == noteID }
    }

    func folder(with folderID: UUID) -> NoteFolder? {
        folders.first { $0.uuid == folderID }
    }

    /// Fetch the latest model objects from SwiftData.
    ///
    /// `selecting` is used after create/save/move operations so the UI can keep
    /// focus on the note the user just acted on. If the selected note was
    /// deleted elsewhere, the store gracefully falls back to the newest note or
    /// the top-level collection.
    func reload(selecting noteIDToSelect: UUID? = nil) {
        let freshContext = ModelContext(modelContainer)

        do {
            let folderDescriptor = FetchDescriptor<NoteFolder>(sortBy: [
                // `name` is optional for migration safety, so sort by the
                // non-optional creation date in SwiftData and alphabetize with
                // `displayName` in memory after metadata repair.
                SortDescriptor(\NoteFolder.created_at)
            ])

            let noteDescriptor = FetchDescriptor<Note>(sortBy: [
                SortDescriptor(\Note.updated_at, order: .reverse),
                SortDescriptor(\Note.created_at, order: .reverse)
            ])

            // Existing NoteCast stores created before folder support do not
            // physically contain the `NoteFolder` table until the first folder
            // is inserted. Fetch notes even if the folder fetch fails so an old
            // library never appears "dead" just because it has not created a
            // folder yet. `createFolder(named:)` below will insert the first
            // folder and SwiftData/Core Data will create the missing folder
            // table/relationship column as part of that save.
            let fetchedFolders: [NoteFolder]
            do {
                fetchedFolders = try freshContext.fetch(folderDescriptor)
            } catch {
                fetchedFolders = []
            }

            let fetchedNotes = try freshContext.fetch(noteDescriptor)

            var repairedMetadata = false
            for folder in fetchedFolders {
                if folder.repairMissingMetadataIfNeeded() {
                    repairedMetadata = true
                }
            }
            for note in fetchedNotes {
                if note.repairMissingMetadataIfNeeded() {
                    repairedMetadata = true
                }
            }
            if repairedMetadata {
                try freshContext.save()
            }

            let sortedFolders = fetchedFolders.sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }

            context = freshContext
            folders = sortedFolders
            notes = fetchedNotes
            errorMessage = nil

            updateSelectionAfterReload(selecting: noteIDToSelect)
            updateSelectionAfterSearchChange()
        } catch {
            folders = []
            notes = []
            errorMessage = "Could not load notes: \(String(describing: error))"
        }
    }

    /// Create a blank note in the currently selected folder (if any).
    ///
    /// The full app window intentionally allows an empty note body while the
    /// user is editing. The compact menu-bar entry window still requires text
    /// before save because it is designed for quick one-shot capture.
    @discardableResult
    func createNote() -> Bool {
        do {
            let createdAt = Date.now
            let note = Note(
                title: Note.makeAutomaticTitle(createdAt: createdAt),
                text: "",
                mimetype: NotePersistence.defaultMimetype,
                created_at: createdAt,
                created_via: NotePersistence.createdViaApp
            )
            note.folder = folderForNewNote()

            context.insert(note)
            try context.save()

            let newNoteID = note.uuid
            reload(selecting: newNoteID)
            return true
        } catch {
            errorMessage = "Could not create note: \(String(describing: error))"
            return false
        }
    }

    @discardableResult
    func updateNote(noteID: UUID, title: String, text: String, folderID: UUID?) -> Bool {
        do {
            guard let note = note(with: noteID) else {
                throw NoteBrowserError(message: "The selected note no longer exists.")
            }

            note.title = Note.cleanTitle(title) ?? Note.makeAutomaticTitle(createdAt: note.created_at)
            note.text = text
            note.mimetype = NotePersistence.defaultMimetype
            note.folder = folderID.flatMap { folder(with: $0) }
            note.updated_at = .now
            note.repairMissingMetadataIfNeeded()

            try context.save()
            reload(selecting: noteID)
            return true
        } catch {
            errorMessage = "Could not save note: \(String(describing: error))"
            return false
        }
    }

    @discardableResult
    func deleteNote(noteID: UUID) -> Bool {
        do {
            guard let note = note(with: noteID) else {
                throw NoteBrowserError(message: "The selected note no longer exists.")
            }

            context.delete(note)
            try context.save()
            reload()
            return true
        } catch {
            errorMessage = "Could not delete note: \(String(describing: error))"
            return false
        }
    }

    @discardableResult
    func createFolder(named name: String) -> Bool {
        do {
            let folder = NoteFolder(name: name)
            context.insert(folder)
            try context.save()

            let folderID = folder.uuid
            reload()
            if let folderID {
                selection = .folder(folderID)
            }
            return true
        } catch {
            errorMessage = "Could not create folder: \(String(describing: error))"
            return false
        }
    }

    @discardableResult
    func renameFolder(folderID: UUID, to newName: String) -> Bool {
        do {
            guard let folder = folder(with: folderID) else {
                throw NoteBrowserError(message: "The selected folder no longer exists.")
            }

            folder.name = NoteFolder.cleanName(newName) ?? folder.displayName
            folder.updated_at = .now
            folder.repairMissingMetadataIfNeeded()

            try context.save()
            reload()
            selection = .folder(folderID)
            return true
        } catch {
            errorMessage = "Could not rename folder: \(String(describing: error))"
            return false
        }
    }

    @discardableResult
    func deleteFolder(folderID: UUID) -> Bool {
        do {
            guard let folder = folder(with: folderID) else {
                throw NoteBrowserError(message: "The selected folder no longer exists.")
            }

            // Be explicit even though the relationship uses `.nullify`. Updating
            // the in-memory note objects before deleting the folder keeps the UI
            // and SwiftData change tracking easy to reason about.
            for note in notes(inFolderWithID: folderID) {
                note.folder = nil
            }

            context.delete(folder)
            try context.save()
            reload()
            selection = .unfiled
            return true
        } catch {
            errorMessage = "Could not delete folder: \(String(describing: error))"
            return false
        }
    }

    /// Move dragged notes into a folder or back to Unfiled.
    ///
    /// SwiftUI drag/drop passes lightweight strings instead of live SwiftData
    /// objects. We match those strings against each note's stable UUID and then
    /// assign the relationship in the current context.
    @discardableResult
    func moveNotes(withStableIDs stableIDs: [String], toFolderID folderID: UUID?) -> Bool {
        do {
            let targetFolder = folderID.flatMap { folder(with: $0) }
            let normalizedIDs = Set(stableIDs.map { $0.lowercased() })
            let notesToMove = notes.filter { normalizedIDs.contains($0.stableID.lowercased()) }

            guard !notesToMove.isEmpty else {
                return false
            }

            for note in notesToMove {
                note.folder = targetFolder
                note.updated_at = .now
            }

            try context.save()
            reload(selecting: notesToMove.first?.uuid)
            return true
        } catch {
            errorMessage = "Could not move note: \(String(describing: error))"
            return false
        }
    }

    private func folderForNewNote() -> NoteFolder? {
        switch selection {
        case .folder(let folderID):
            return folder(with: folderID)
        case .note(let noteID):
            return note(with: noteID)?.folder
        default:
            return nil
        }
    }

    private func updateSelectionAfterReload(selecting noteIDToSelect: UUID?) {
        if let noteIDToSelect, note(with: noteIDToSelect) != nil {
            selection = .note(noteIDToSelect)
            return
        }

        switch selection {
        case .note(let selectedNoteID):
            if note(with: selectedNoteID) == nil {
                selection = notes.first?.uuid.map(NoteBrowserSelection.note) ?? .allNotes
            }
        case .folder(let selectedFolderID):
            if folder(with: selectedFolderID) == nil {
                selection = .allNotes
            }
        case nil:
            selection = notes.first?.uuid.map(NoteBrowserSelection.note) ?? .allNotes
        case .allNotes, .unfiled:
            break
        }
    }

    private func updateSelectionAfterSearchChange() {
        guard isSearching else { return }

        if case .note(let selectedNoteID) = selection,
           searchResults.contains(where: { $0.uuid == selectedNoteID }) {
            return
        }

        selection = .allNotes
    }
}
