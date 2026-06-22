//
//  CommandPaletteTests.swift
//  NoteCastTests
//
//  Unit coverage for command palette ranking and command availability.
//

import Foundation
import Testing
@testable import NoteCast

struct CommandPaletteTests {
    @MainActor
    @Test func paletteDoesNotSearchNotes() {
        let target = Note(
            title: "Command Palette Spec",
            text: "Keyboard-first navigation for notes and folders.",
            created_at: Date(timeIntervalSince1970: 20),
            created_via: NotePersistence.createdViaApp
        )
        let other = Note(
            title: "Lunch",
            text: "Soup and bread.",
            created_at: Date(timeIntervalSince1970: 10),
            created_via: NotePersistence.createdViaApp
        )

        let sections = CommandPaletteSearch.sections(
            notes: [other, target],
            folders: [],
            query: "command palette spec",
            context: CommandPaletteContext(selectedNoteID: nil, selectedNoteTitle: nil)
        )

        #expect(sections.isEmpty)
    }

    @MainActor
    @Test func paletteSearchFindsFoldersAndCommands() throws {
        let folder = NoteFolder(name: "Project Specs")
        let sections = CommandPaletteSearch.sections(
            notes: [],
            folders: [folder],
            query: "specs",
            context: CommandPaletteContext(selectedNoteID: nil, selectedNoteTitle: nil)
        )

        let folderItems = try #require(sections.first { $0.title == "Folders" }?.items)
        #expect(folderItems.first?.title == "Project Specs")

        let commandSections = CommandPaletteSearch.sections(
            notes: [],
            folders: [],
            query: "preview",
            context: CommandPaletteContext(selectedNoteID: nil, selectedNoteTitle: nil)
        )
        let commandItems = try #require(commandSections.first { $0.title == "Commands" }?.items)
        #expect(commandItems.contains { $0.kind == .command(.switchToPreview) })
    }

    @Test func noteSpecificPaletteCommandsRequireASelectedNote() {
        let emptyContext = CommandPaletteContext(selectedNoteID: nil, selectedNoteTitle: nil)
        #expect(!CommandPaletteCommand.copyMarkdown.isEnabled(in: emptyContext))
        #expect(!CommandPaletteCommand.deleteSelectedNote.isEnabled(in: emptyContext))
        #expect(!CommandPaletteCommand.saveNote.isEnabled(in: emptyContext))
        #expect(!CommandPaletteCommand.revertChanges.isEnabled(in: emptyContext))

        let selectedContext = CommandPaletteContext(
            selectedNoteID: UUID(uuidString: "11111111-1111-1111-1111-111111111111"),
            selectedNoteTitle: "Selected",
            canSave: true,
            canRevert: true
        )
        #expect(CommandPaletteCommand.copyMarkdown.isEnabled(in: selectedContext))
        #expect(CommandPaletteCommand.deleteSelectedNote.isEnabled(in: selectedContext))
        #expect(CommandPaletteCommand.saveNote.isEnabled(in: selectedContext))
        #expect(CommandPaletteCommand.revertChanges.isEnabled(in: selectedContext))
    }
}
