//
//  NoteBrowserView.swift
//  NoteCast
//
//  Main macOS browser window composition.
//

import AppKit
import SwiftData
import SwiftUI

/// The main window users see from the Dock, app menu, and "Open NoteCast" menu
/// bar item.
///
/// This file intentionally stays small. The sidebar, detail pane, editor,
/// Markdown preview, and command palette each live in their own files so the
/// browser remains easy to scan and each file stays under the project line
/// budget.
struct NoteBrowserView: View {
    @EnvironmentObject private var windowManager: NoteWindowManager

    /// View-model that owns the browser's SwiftData context.
    @StateObject private var store: NoteBrowserStore

    /// Active editor Save/Revert commands for the palette.
    @StateObject private var editorCommandBridge = NoteBrowserEditorCommandBridge()

    /// Drives the create/rename folder sheet.
    @State private var folderSheetMode: FolderSheetMode?

    /// Global mode for the active note editor.
    ///
    /// The titlebar segmented control, app menu commands, and command palette
    /// all update this single value so the UI never has dueling edit states.
    @State private var editorMode: EditorDisplayMode = .preview

    /// Current split-view sidebar visibility.
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .all

    /// Presents the keyboard-first command palette.
    @State private var isCommandPalettePresented = false

    /// Set when a palette command requests a destructive note action.
    @State private var noteIDPendingPaletteDelete: UUID?

    init(modelContainer: ModelContainer) {
        _store = StateObject(wrappedValue: NoteBrowserStore(modelContainer: modelContainer))
    }

    var body: some View {
        ZStack {
            browserSplitView

            if isCommandPalettePresented {
                CommandPaletteView(
                    notes: store.notes,
                    folders: store.folders,
                    context: commandPaletteContext,
                    perform: performPaletteItem,
                    performSecondary: performSecondaryPaletteItem,
                    close: closeCommandPalette
                )
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
                .zIndex(1)
            }
        }
        .navigationTitle("NoteCast")
        .toolbar { browserToolbar }
        .focusedSceneValue(\.noteBrowserEditorMode, $editorMode)
        .focusedSceneValue(\.noteBrowserSidebarVisibility, $sidebarVisibility)
        .focusedSceneValue(\.noteBrowserCommandPalettePresented, $isCommandPalettePresented)
        .sheet(item: $folderSheetMode, content: folderSheet)
        .confirmationDialog(
            "Delete selected note?",
            isPresented: isConfirmingPaletteDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Note", role: .destructive) {
                guard let noteID = noteIDPendingPaletteDelete else { return }
                deleteNote(noteID: noteID)
                noteIDPendingPaletteDelete = nil
            }

            Button("Cancel", role: .cancel) {
                noteIDPendingPaletteDelete = nil
            }
        } message: {
            Text("This cannot be undone.")
        }
        .onAppear {
            store.reload()
        }
        .onChange(of: windowManager.notesRevision) { _, _ in
            // Menu bar windows and the `cast` CLI announce changes through this
            // shared revision counter. Refetch here so the main window stays
            // live when notes change elsewhere.
            store.reload()
        }
    }

    private var browserSplitView: some View {
        NavigationSplitView(columnVisibility: $sidebarVisibility) {
            NoteBrowserSidebar(
                store: store,
                createFolder: { folderSheetMode = .create },
                renameFolder: { folder in
                    guard let folderID = folder.uuid else { return }
                    folderSheetMode = .rename(folderID: folderID, currentName: folder.displayName)
                },
                deleteFolder: deleteFolder,
                deleteNote: deleteNote,
                copyNote: copyNote,
                copyNoteUID: copyNoteUID,
                moveDraggedNotes: moveDraggedNotes
            )
            .navigationSplitViewColumnWidth(min: 250, ideal: 310, max: 420)
        } detail: {
            NoteBrowserDetail(
                store: store,
                editorCommandBridge: editorCommandBridge,
                editorMode: $editorMode,
                createNote: createNote,
                saveNote: saveNote,
                deleteNote: deleteNote,
                copyNote: copyNote,
                copyNoteUID: copyNoteUID
            )
        }
    }

    @ToolbarContentBuilder
    private var browserToolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                createNote()
            } label: {
                Label("New Note", systemImage: "square.and.pencil")
            }
            .keyboardShortcut("n", modifiers: [.command])
            .help("Create a new note in the selected folder")

            Button {
                folderSheetMode = .create
            } label: {
                Label("New Folder", systemImage: "folder.badge.plus")
            }
            .help("Create a folder")
        }

        ToolbarItem(placement: .principal) {
            editorModeTitlebarPicker
                .disabled(store.selectedNote == nil)
        }
    }

    private var editorModeTitlebarPicker: some View {
        Picker("Editor Mode", selection: $editorMode) {
            Text("Preview")
                .tag(EditorDisplayMode.preview)
            Text("Edit")
                .tag(EditorDisplayMode.edit)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .frame(width: 150)
        .help("Preview: Cmd+1 / Edit: Cmd+2")
        .accessibilityIdentifier("NoteBrowser.editorModeSegmentedControl")
    }

    private var commandPaletteContext: CommandPaletteContext {
        CommandPaletteContext(
            selectedNoteID: store.selectedNote?.uuid,
            selectedNoteTitle: store.selectedNote?.displayTitle,
            canSave: editorCommandBridge.canSave,
            canRevert: editorCommandBridge.canRevert
        )
    }

    private var isConfirmingPaletteDelete: Binding<Bool> {
        Binding {
            noteIDPendingPaletteDelete != nil
        } set: { isPresented in
            if !isPresented {
                noteIDPendingPaletteDelete = nil
            }
        }
    }

    private func folderSheet(_ mode: FolderSheetMode) -> some View {
        FolderNameSheet(mode: mode) {
            folderSheetMode = nil
        } save: { name in
            switch mode {
            case .create:
                if store.createFolder(named: name) {
                    windowManager.notesDidChange()
                }
            case .rename(let folderID, _):
                if store.renameFolder(folderID: folderID, to: name) {
                    windowManager.notesDidChange()
                }
            }

            folderSheetMode = nil
        }
    }

    private func createNote() {
        if let payload = store.createNote() {
            windowManager.notesDidChange()
            windowManager.notifyNoteAdded(payload)
        }
    }

    private func saveNote(noteID: UUID, title: String, text: String, folderID: UUID?) -> Bool {
        let saved = store.updateNote(noteID: noteID, title: title, text: text, folderID: folderID)
        if saved {
            windowManager.notesDidChange()
        }
        return saved
    }

    private func deleteNote(noteID: UUID) {
        if store.deleteNote(noteID: noteID) {
            windowManager.notesDidChange()
        }
    }

    private func deleteFolder(_ folder: NoteFolder) {
        guard let folderID = folder.uuid else { return }
        if store.deleteFolder(folderID: folderID) {
            windowManager.notesDidChange()
        }
    }

    private func moveDraggedNotes(stableIDs: [String], folderID: UUID?) -> Bool {
        let moved = store.moveNotes(withStableIDs: stableIDs, toFolderID: folderID)
        if moved {
            windowManager.notesDidChange()
        }
        return moved
    }

    private func copyNote(_ note: Note) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(note.text, forType: .string)
    }

    private func copyNoteUID(_ note: Note) {
        guard let noteID = note.uuid else { return }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(noteID.uuidString, forType: .string)
    }

    private func closeCommandPalette() {
        withAnimation(.easeOut(duration: 0.12)) {
            isCommandPalettePresented = false
        }
    }

    private func performPaletteItem(_ item: CommandPaletteItem) {
        guard item.isEnabled else { return }

        switch item.kind {
        case .folder(let folderID):
            store.searchText = ""
            store.selection = .folder(folderID)
            closeCommandPalette()
        case .command(let command):
            performPaletteCommand(command)
        }
    }

    private func performSecondaryPaletteItem(_ item: CommandPaletteItem) {
        guard item.isEnabled else { return }

        switch item.kind {
        case .folder, .command:
            performPaletteItem(item)
        }
    }

    private func performPaletteCommand(_ command: CommandPaletteCommand) {
        switch command {
        case .newNote:
            createNote()
            closeCommandPalette()
        case .saveNote:
            editorCommandBridge.save()
            closeCommandPalette()
        case .revertChanges:
            editorCommandBridge.revert()
            closeCommandPalette()
        case .copyMarkdown:
            if let note = store.selectedNote {
                copyNote(note)
            }
            closeCommandPalette()
        case .switchToPreview:
            editorMode = .preview
            closeCommandPalette()
        case .switchToEdit:
            editorMode = .edit
            closeCommandPalette()
        case .toggleSidebar:
            toggleSidebar()
            closeCommandPalette()
        case .showAllNotes:
            store.searchText = ""
            store.selection = .allNotes
            closeCommandPalette()
        case .showUnfiled:
            store.searchText = ""
            store.selection = .unfiled
            closeCommandPalette()
        case .createFolder:
            folderSheetMode = .create
            closeCommandPalette()
        case .deleteSelectedNote:
            noteIDPendingPaletteDelete = store.selectedNote?.uuid
            closeCommandPalette()
        }
    }

    private func toggleSidebar() {
        withAnimation {
            sidebarVisibility = sidebarVisibility == .detailOnly ? .all : .detailOnly
        }
    }
}

private struct NoteBrowserEditorModeFocusedValueKey: FocusedValueKey {
    typealias Value = Binding<EditorDisplayMode>
}

private struct NoteBrowserSidebarVisibilityFocusedValueKey: FocusedValueKey {
    typealias Value = Binding<NavigationSplitViewVisibility>
}

private struct NoteBrowserCommandPalettePresentedFocusedValueKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

extension FocusedValues {
    var noteBrowserEditorMode: Binding<EditorDisplayMode>? {
        get { self[NoteBrowserEditorModeFocusedValueKey.self] }
        set { self[NoteBrowserEditorModeFocusedValueKey.self] = newValue }
    }

    var noteBrowserSidebarVisibility: Binding<NavigationSplitViewVisibility>? {
        get { self[NoteBrowserSidebarVisibilityFocusedValueKey.self] }
        set { self[NoteBrowserSidebarVisibilityFocusedValueKey.self] = newValue }
    }

    var noteBrowserCommandPalettePresented: Binding<Bool>? {
        get { self[NoteBrowserCommandPalettePresentedFocusedValueKey.self] }
        set { self[NoteBrowserCommandPalettePresentedFocusedValueKey.self] = newValue }
    }
}
