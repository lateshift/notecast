//
//  CommandPaletteModels.swift
//  NoteCast
//
//  Testable command palette data and search logic.
//

import Foundation

/// Lightweight context used to decide which static commands are enabled.
///
/// The palette intentionally receives plain values instead of reaching into the
/// browser store. That keeps search/ranking deterministic and easy to test.
struct CommandPaletteContext: Equatable {
    let selectedNoteID: UUID?
    let selectedNoteTitle: String?
    let canSave: Bool
    let canRevert: Bool

    init(
        selectedNoteID: UUID?,
        selectedNoteTitle: String?,
        canSave: Bool = false,
        canRevert: Bool = false
    ) {
        self.selectedNoteID = selectedNoteID
        self.selectedNoteTitle = selectedNoteTitle
        self.canSave = canSave
        self.canRevert = canRevert
    }

    var hasSelectedNote: Bool {
        selectedNoteID != nil
    }
}

/// One grouped section in the palette results list.
struct CommandPaletteSection: Identifiable, Equatable {
    let title: String
    let items: [CommandPaletteItem]

    var id: String { title }
}

/// One selectable row in the palette.
struct CommandPaletteItem: Identifiable, Equatable {
    let id: String
    let kind: CommandPaletteItemKind
    let title: String
    let subtitle: String
    let systemImage: String
    let shortcutHint: String?
    let isEnabled: Bool
    let score: Int
}

enum CommandPaletteItemKind: Equatable {
    case folder(UUID)
    case command(CommandPaletteCommand)
}

/// Static commands supported by the first palette implementation.
///
/// Keep command metadata here so the UI layer only draws rows and dispatches the
/// chosen command. Adding a command should mostly mean adding one case here and
/// one action branch in `NoteBrowserView`.
enum CommandPaletteCommand: String, CaseIterable, Equatable {
    case newNote
    case saveNote
    case revertChanges
    case copyMarkdown
    case switchToPreview
    case switchToEdit
    case toggleSidebar
    case showAllNotes
    case showUnfiled
    case createFolder
    case deleteSelectedNote

    var title: String {
        switch self {
        case .newNote:
            return "New Note"
        case .saveNote:
            return "Save Note"
        case .revertChanges:
            return "Revert Changes"
        case .copyMarkdown:
            return "Copy Markdown"
        case .switchToPreview:
            return "Switch to Preview"
        case .switchToEdit:
            return "Switch to Edit"
        case .toggleSidebar:
            return "Toggle Sidebar"
        case .showAllNotes:
            return "Show All Notes"
        case .showUnfiled:
            return "Show Unfiled"
        case .createFolder:
            return "Create Folder"
        case .deleteSelectedNote:
            return "Delete Selected Note"
        }
    }

    var subtitle: String {
        switch self {
        case .newNote:
            return "Create a note in the current context"
        case .saveNote:
            return "Save the active editor draft"
        case .revertChanges:
            return "Discard unsaved editor changes"
        case .copyMarkdown:
            return "Copy the selected note body"
        case .switchToPreview:
            return "Render the selected note"
        case .switchToEdit:
            return "Edit the selected note"
        case .toggleSidebar:
            return "Show or hide the library sidebar"
        case .showAllNotes:
            return "Select the full library"
        case .showUnfiled:
            return "Select notes without a folder"
        case .createFolder:
            return "Open the folder name sheet"
        case .deleteSelectedNote:
            return "Remove the selected note after confirmation"
        }
    }

    var systemImage: String {
        switch self {
        case .newNote:
            return "square.and.pencil"
        case .saveNote:
            return "checkmark"
        case .revertChanges:
            return "arrow.uturn.backward"
        case .copyMarkdown:
            return "doc.on.doc"
        case .switchToPreview:
            return "doc.richtext"
        case .switchToEdit:
            return "pencil"
        case .toggleSidebar:
            return "sidebar.left"
        case .showAllNotes:
            return "tray.full"
        case .showUnfiled:
            return "tray"
        case .createFolder:
            return "folder.badge.plus"
        case .deleteSelectedNote:
            return "trash"
        }
    }

    var shortcutHint: String? {
        switch self {
        case .newNote:
            return "Cmd+N"
        case .saveNote:
            return "Cmd+S"
        case .switchToPreview:
            return "Cmd+1"
        case .switchToEdit:
            return "Cmd+2"
        case .toggleSidebar:
            return "Cmd+0"
        default:
            return nil
        }
    }

    var keywords: [String] {
        switch self {
        case .newNote:
            return ["new note", "create note", "capture"]
        case .saveNote:
            return ["save", "commit", "write changes"]
        case .revertChanges:
            return ["revert", "discard", "undo changes"]
        case .copyMarkdown:
            return ["copy markdown", "copy note", "clipboard"]
        case .switchToPreview:
            return ["preview", "render", "read"]
        case .switchToEdit:
            return ["edit", "write", "draft"]
        case .toggleSidebar:
            return ["sidebar", "library", "toggle"]
        case .showAllNotes:
            return ["all notes", "library", "everything"]
        case .showUnfiled:
            return ["unfiled", "inbox", "no folder"]
        case .createFolder:
            return ["folder", "new folder", "create folder"]
        case .deleteSelectedNote:
            return ["delete", "trash", "remove note"]
        }
    }

    func isEnabled(in context: CommandPaletteContext) -> Bool {
        switch self {
        case .saveNote:
            return context.canSave
        case .revertChanges:
            return context.canRevert
        case .copyMarkdown, .deleteSelectedNote:
            return context.hasSelectedNote
        default:
            return true
        }
    }
}

/// Pure search/ranking layer for the command palette.
///
/// Folders and static commands use a small local matcher because they are
/// lightweight metadata, not full note bodies.
enum CommandPaletteSearch {
    static func sections(
        notes: [Note],
        folders: [NoteFolder],
        query: String,
        context: CommandPaletteContext
    ) -> [CommandPaletteSection] {
        if CommandPaletteText.normalizedTerms(query).isEmpty {
            return defaultSections(notes: notes, folders: folders, context: context)
        }

        return searchSections(notes: notes, folders: folders, query: query, context: context)
    }

    private static func defaultSections(
        notes: [Note],
        folders: [NoteFolder],
        context: CommandPaletteContext
    ) -> [CommandPaletteSection] {
        [
            section(title: "Commands", items: commandItems(context: context, query: nil)),
            section(title: "Folders", items: folders.prefix(8).compactMap { folderItem(folder: $0, notes: notes, score: 0) })
        ].compactMap { $0 }
    }

    private static func searchSections(
        notes: [Note],
        folders: [NoteFolder],
        query: String,
        context: CommandPaletteContext
    ) -> [CommandPaletteSection] {
        let folderItems = folders.compactMap { folder -> CommandPaletteItem? in
            let score = CommandPaletteText.score(query: query, candidates: [folder.displayName])
            guard score > 0 else { return nil }
            return folderItem(folder: folder, notes: notes, score: score)
        }
        .sorted { $0.score > $1.score }
        .prefix(8)

        let commandItems = commandItems(context: context, query: query)

        return [
            section(title: "Folders", items: Array(folderItems)),
            section(title: "Commands", items: commandItems)
        ].compactMap { $0 }
    }

    private static func section(title: String, items: [CommandPaletteItem]) -> CommandPaletteSection? {
        items.isEmpty ? nil : CommandPaletteSection(title: title, items: items)
    }

    private static func folderItem(folder: NoteFolder, notes: [Note], score: Int) -> CommandPaletteItem? {
        guard let folderID = folder.uuid else { return nil }
        let noteCount = notes.filter { $0.folder?.uuid == folderID }.count
        return CommandPaletteItem(
            id: "folder-\(folderID.uuidString)",
            kind: .folder(folderID),
            title: folder.displayName,
            subtitle: "\(noteCount) note\(noteCount == 1 ? "" : "s")",
            systemImage: "folder",
            shortcutHint: nil,
            isEnabled: true,
            score: score
        )
    }

    private static func commandItems(context: CommandPaletteContext, query: String?) -> [CommandPaletteItem] {
        CommandPaletteCommand.allCases.compactMap { command in
            let score: Int
            if let query {
                score = CommandPaletteText.score(query: query, candidates: [command.title] + command.keywords)
                guard score > 0 else { return nil }
            } else {
                score = 0
            }

            return CommandPaletteItem(
                id: "command-\(command.rawValue)",
                kind: .command(command),
                title: command.title,
                subtitle: command.subtitle,
                systemImage: command.systemImage,
                shortcutHint: command.shortcutHint,
                isEnabled: command.isEnabled(in: context),
                score: score
            )
        }
        .sorted { lhs, rhs in
            if lhs.isEnabled != rhs.isEnabled {
                return lhs.isEnabled
            }
            if lhs.score != rhs.score {
                return lhs.score > rhs.score
            }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }
}

/// Tiny text matcher used for folders and static commands.
///
/// It deliberately stays simpler than `NoteSearch`: exact and prefix matches
/// rank highest, contains matches are good enough for commands, and a final
/// subsequence pass catches compact queries such as "sn" for "Show Notes".
enum CommandPaletteText {
    static func normalizedTerms(_ query: String) -> [String] {
        query
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    static func score(query: String, candidates: [String]) -> Int {
        let terms = normalizedTerms(query)
        guard !terms.isEmpty else { return 0 }

        var total = 0
        for term in terms {
            let best = candidates.map { score(term: term, in: $0) }.max() ?? 0
            guard best > 0 else { return 0 }
            total += best
        }
        return total
    }

    private static func score(term: String, in candidate: String) -> Int {
        let text = candidate
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()

        guard !term.isEmpty, !text.isEmpty else { return 0 }
        if text == term { return 120 }
        if text.hasPrefix(term) { return 110 }
        if text.components(separatedBy: CharacterSet.alphanumerics.inverted).contains(term) { return 100 }
        if text.contains(term) { return 84 }
        return subsequenceScore(term: term, in: text)
    }

    private static func subsequenceScore(term: String, in text: String) -> Int {
        let pattern = Array(term)
        let characters = Array(text)
        var patternIndex = 0

        for character in characters where patternIndex < pattern.count {
            if character == pattern[patternIndex] {
                patternIndex += 1
            }
        }

        return patternIndex == pattern.count ? 54 : 0
    }
}
