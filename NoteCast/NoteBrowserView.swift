//
//  NoteBrowserView.swift
//  NoteCast
//
//  Full macOS application window for browsing, organizing, and editing notes.
//

import AppKit
import Markdown
import SwiftData
import SwiftUI
import WebKit

/// The main window users see from the Dock, app menu, and "Open NoteCast" menu
/// bar item.
///
/// NoteCast still keeps its fast menu bar capture workflow, but it is no longer
/// only a menu bar utility. This view is the proper application surface: a
/// sidebar for library/folder navigation and a large detail area for reading and
/// editing Markdown notes.
struct NoteBrowserView: View {
    @EnvironmentObject private var windowManager: NoteWindowManager

    /// View-model that owns the browser's SwiftData context.
    @StateObject private var store: NoteBrowserStore

    /// Drives the create/rename folder sheet.
    @State private var folderSheetMode: FolderSheetMode?

    /// Global mode for the active note editor.
    ///
    /// This lives at the browser level instead of inside the editor view so the
    /// titlebar segmented control and app menu commands can both drive the same
    /// Preview/Edit state.
    @State private var editorMode: EditorDisplayMode = .preview

    /// Current split-view sidebar visibility. Keeping this state here gives the
    /// app's Cmd+0 sidebar command a SwiftUI fallback when the AppKit standard
    /// toggle action is unavailable.
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .all

    init(modelContainer: ModelContainer) {
        _store = StateObject(wrappedValue: NoteBrowserStore(modelContainer: modelContainer))
    }

    var body: some View {
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
                moveDraggedNotes: moveDraggedNotes
            )
            .navigationSplitViewColumnWidth(min: 250, ideal: 310, max: 420)
        } detail: {
            NoteBrowserDetail(
                store: store,
                editorMode: $editorMode,
                createNote: createNote,
                saveNote: saveNote,
                deleteNote: deleteNote,
                copyNote: copyNote
            )
        }
        .navigationTitle("NoteCast")
        .toolbar {
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
        .focusedSceneValue(\.noteBrowserEditorMode, $editorMode)
        .focusedSceneValue(\.noteBrowserSidebarVisibility, $sidebarVisibility)
        .sheet(item: $folderSheetMode) { mode in
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
        .onAppear {
            store.reload()
        }
        .onChange(of: windowManager.notesRevision) { _, _ in
            // The menu bar windows and `cast` CLI announce changes through the
            // same revision counter. Refetch here so the main app window is just
            // as live as the menu bar menu.
            store.reload()
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
        .help("Preview: ⌘1 • Edit: ⌘2")
        .accessibilityIdentifier("NoteBrowser.editorModeSegmentedControl")
    }

    private func createNote() {
        if store.createNote() {
            windowManager.notesDidChange()
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
}

// MARK: - Sidebar

/// Left-hand library navigation.
///
/// The sidebar intentionally shows both collections (All Notes, Unfiled,
/// folders) and individual notes. Dragging a note row onto a folder row updates
/// the `Note.folder` relationship in SwiftData.
private struct NoteBrowserSidebar: View {
    @ObservedObject var store: NoteBrowserStore

    let createFolder: () -> Void
    let renameFolder: (NoteFolder) -> Void
    let deleteFolder: (NoteFolder) -> Void
    let deleteNote: (UUID) -> Void
    let copyNote: (Note) -> Void
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
                        NoteSidebarRow(note: note, copy: copyNote, delete: deleteNote)
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
                        NoteSidebarRow(note: note, copy: copyNote, delete: deleteNote)
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
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.72), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
            .noteActionsContextMenu(note: note, copy: copy, delete: delete)
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
                        NoteSidebarRow(note: note, copy: copyNote, delete: deleteNote)
                    }
                }
            } label: {
                Label(folder.displayName, systemImage: "folder")
                    .badge(notes.count)
            }
            .tag(NoteBrowserSelection.folder(folderID))
            .contextMenu {
                Button("Rename Folder…", action: rename)
                Button("Delete Folder", role: .destructive, action: delete)
            }
            .dropDestination(for: String.self) { stableIDs, _ in
                _ = moveDraggedNotes(stableIDs, folderID)
            }
        }
    }
}

// MARK: - Detail area

/// Right-hand content area for either a selected note or a selected collection.
private struct NoteBrowserDetail: View {
    @ObservedObject var store: NoteBrowserStore

    @Binding var editorMode: EditorDisplayMode

    let createNote: () -> Void
    let saveNote: (_ noteID: UUID, _ title: String, _ text: String, _ folderID: UUID?) -> Bool
    let deleteNote: (_ noteID: UUID) -> Void
    let copyNote: (Note) -> Void

    var body: some View {
        ZStack {
            TahoeWindowBackground()

            if let note = store.selectedNote {
                NoteBrowserEditorView(
                    note: note,
                    folders: store.folders,
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
                    deleteNote: deleteNote
                )
            }
        }
    }
}

/// Soft, modern background inspired by macOS Tahoe's layered glass aesthetic.
///
/// The app avoids private APIs and sticks to standard SwiftUI materials, subtle
/// gradients, and large continuous-radius cards so it looks at home on modern
/// macOS while still remaining straightforward to maintain.
private struct TahoeWindowBackground: View {
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
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
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
                            .noteActionsContextMenu(note: note, copy: copyNote, delete: deleteNote)
                        }
                    }
                }
            }
            .padding(32)
            .frame(maxWidth: 900, alignment: .leading)
        }
    }
}

/// Reusable right-click menu for note actions.
///
/// The main window keeps the visible chrome focused on reading/editing. Less
/// common note-level actions live with the note items themselves: right-click a
/// note row or card to copy or delete it. The modifier owns the confirmation
/// dialog so every item gets the same safe delete behavior.
private struct NoteActionsContextMenu: ViewModifier {
    let note: Note
    let copy: (Note) -> Void
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

                Divider()

                Button(role: .destructive) {
                    isConfirmingDelete = true
                } label: {
                    Label("Delete Note…", systemImage: "trash")
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

private extension View {
    func noteActionsContextMenu(
        note: Note,
        copy: @escaping (Note) -> Void,
        delete: @escaping (UUID) -> Void
    ) -> some View {
        modifier(NoteActionsContextMenu(note: note, copy: copy, delete: delete))
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
                Text("•")
                Text(note.mimetype)
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(.white.opacity(0.18), lineWidth: 1)
        }
    }
}

// MARK: - Note editor

/// Main read/edit surface for a single note.
private struct NoteBrowserEditorView: View {
    let note: Note
    let folders: [NoteFolder]
    @Binding var editorMode: EditorDisplayMode
    let save: (_ noteID: UUID, _ title: String, _ text: String, _ folderID: UUID?) -> Bool

    @AppStorage("NoteBrowser.previewColorScheme") private var previewColorScheme: MarkdownPreviewColorScheme = .light

    @State private var titleDraft: String
    @State private var bodyDraft: String
    @State private var folderIDDraft: UUID?
    @State private var statusMessage: String?

    /// HTML generated by Swift Markdown for the preview pane.
    ///
    /// The HTML is stored instead of recomputed directly in `body` so the WebView
    /// only reloads when the user switches to Preview, changes the title while
    /// previewing, or reverts/reloads the selected note.
    @State private var previewHTML: String

    init(
        note: Note,
        folders: [NoteFolder],
        editorMode: Binding<EditorDisplayMode>,
        save: @escaping (_ noteID: UUID, _ title: String, _ text: String, _ folderID: UUID?) -> Bool
    ) {
        self.note = note
        self.folders = folders
        self._editorMode = editorMode
        self.save = save
        self._titleDraft = State(initialValue: note.displayTitle)
        self._bodyDraft = State(initialValue: note.text)
        self._folderIDDraft = State(initialValue: note.folder?.uuid)
        self._previewHTML = State(initialValue: MarkdownPreviewHTML.documentHTML(
            markdown: note.text,
            title: note.displayTitle,
            colorScheme: .light
        ))
    }

    private var hasChanges: Bool {
        titleDraft != note.displayTitle
            || bodyDraft != note.text
            || folderIDDraft != note.folder?.uuid
    }

    var body: some View {
        VStack(spacing: 0) {
            editorHeader

            editorBody

            editorFooter
        }
        .onAppear {
            renderPreview()
        }
        .onChange(of: editorMode) { _, newMode in
            if newMode == .preview {
                renderPreview()
            }
        }
        .onChange(of: titleDraft) { _, _ in
            if editorMode == .preview {
                renderPreview()
            }
        }
        .onChange(of: previewColorScheme) { _, _ in
            if editorMode == .preview {
                renderPreview()
            }
        }
        .onChange(of: note.updated_at) { _, _ in
            // If another window or the CLI changed this note while it is open,
            // refresh the drafts to match the newly fetched model object.
            resetDrafts()
        }
    }

    @ViewBuilder
    private var editorBody: some View {
        if editorMode == .preview {
            previewBody
        } else {
            editBody
        }
    }

    private var previewBody: some View {
        MarkdownPreviewWebView(html: previewHTML, colorScheme: previewColorScheme)
            .accessibilityIdentifier("NoteBrowser.previewWebView")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.82))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.horizontal, 24)
            .padding(.bottom, 14)
    }

    private var editBody: some View {
        TextEditor(text: $bodyDraft)
            .font(.system(.body, design: .monospaced))
            .scrollContentBackground(.hidden)
            .overlay(alignment: .topLeading) {
                if bodyDraft.isEmpty {
                    Text("Write Markdown here…")
                        .foregroundStyle(.tertiary)
                        .padding(.top, 8)
                        .padding(.leading, 6)
                        .allowsHitTesting(false)
                }
            }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(12)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.82), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 24)
        .padding(.bottom, 14)
    }

    private var editorHeader: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    titleView

                    HStack(spacing: 10) {
                        metadataPill(systemImage: "calendar", text: "Created \(note.created_at.formatted(date: .abbreviated, time: .shortened))")
                        metadataPill(systemImage: "clock", text: "Updated \(note.updated_at.formatted(date: .abbreviated, time: .shortened))")
                        metadataPill(systemImage: "keyboard", text: note.created_via)
                    }
                }

                Spacer(minLength: 20)

                HStack(spacing: 8) {
                    folderPicker
                    previewColorSchemePicker
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 14)
    }

    @ViewBuilder
    private var titleView: some View {
        if editorMode == .preview {
            Text(Note.cleanTitle(titleDraft) ?? note.displayTitle)
                .font(.largeTitle.bold())
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            TextField("Title", text: $titleDraft)
                .font(.largeTitle.bold())
                .textFieldStyle(.plain)
        }
    }

    private var folderPicker: some View {
        Picker("Folder", selection: $folderIDDraft) {
            Label("Unfiled", systemImage: "tray")
                .tag(Optional<UUID>.none)

            ForEach(folders) { folder in
                if let folderID = folder.uuid {
                    Label(folder.displayName, systemImage: "folder")
                        .tag(Optional(folderID))
                }
            }
        }
        .pickerStyle(.menu)
        .frame(width: 210)
    }

    private var previewColorSchemePicker: some View {
        Picker("Preview Appearance", selection: $previewColorScheme) {
            Image(systemName: "sun.max")
                .tag(MarkdownPreviewColorScheme.light)
                .accessibilityLabel("Light Preview")
            Image(systemName: "moon")
                .tag(MarkdownPreviewColorScheme.dark)
                .accessibilityLabel("Dark Preview")
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .frame(width: 76)
        .help("Preview appearance")
        .accessibilityIdentifier("NoteBrowser.previewColorSchemeSegmentedControl")
    }

    private var editorFooter: some View {
        HStack(spacing: 10) {
            if let statusMessage {
                Label(statusMessage, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            } else {
                Text("⌘S saves changes")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Revert") {
                resetDrafts()
            }
            .disabled(!hasChanges)

            Button {
                saveDrafts()
            } label: {
                Label("Save", systemImage: "checkmark")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!hasChanges)
            .keyboardShortcut("s", modifiers: [.command])
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 18)
    }

    private func metadataPill(systemImage: String, text: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.thinMaterial, in: Capsule())
    }

    private func renderPreview() {
        previewHTML = MarkdownPreviewHTML.documentHTML(
            markdown: bodyDraft,
            title: Note.cleanTitle(titleDraft) ?? note.displayTitle,
            colorScheme: previewColorScheme
        )
    }

    private func saveDrafts() {
        guard let noteID = note.uuid else { return }

        if save(noteID, titleDraft, bodyDraft, folderIDDraft) {
            statusMessage = "Saved"
        }
    }

    private func resetDrafts() {
        titleDraft = note.displayTitle
        bodyDraft = note.text
        folderIDDraft = note.folder?.uuid
        statusMessage = nil

        if editorMode == .preview {
            renderPreview()
        }
    }
}

enum EditorDisplayMode: Hashable {
    case preview
    case edit
}

private enum MarkdownPreviewColorScheme: String, Hashable {
    case light
    case dark

    var colorSchemeContent: String {
        rawValue
    }

    var previewTitle: String {
        switch self {
        case .light:
            return "Light"
        case .dark:
            return "Dark"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .light:
            return NSAppearance(named: .aqua)
        case .dark:
            return NSAppearance(named: .darkAqua)
        }
    }
}

private struct NoteBrowserEditorModeFocusedValueKey: FocusedValueKey {
    typealias Value = Binding<EditorDisplayMode>
}

private struct NoteBrowserSidebarVisibilityFocusedValueKey: FocusedValueKey {
    typealias Value = Binding<NavigationSplitViewVisibility>
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
}

// MARK: - Markdown preview

/// Converts Markdown source into a complete HTML document for the preview pane.
///
/// NoteCast deliberately uses Swift Markdown here rather than a hand-written
/// parser. The package builds a CommonMark tree and `HTMLFormatter` turns that
/// tree into HTML. NoteCast then wraps the body in app-specific CSS so the
/// WebView preview inherits the same clean, readable macOS feel as the native
/// SwiftUI editor without adding another nested card border.
private enum MarkdownPreviewHTML {
    static func documentHTML(markdown: String, title: String, colorScheme: MarkdownPreviewColorScheme) -> String {
        let renderedBody = HTMLFormatter.format(
            markdown,
            options: [.parseAsides, .parseInlineAttributeClass]
        )
        let bodyHTML = renderedBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "<p class=\"empty\">Nothing to preview yet.</p>"
            : renderedBody
        let escapedTitle = escapedHTML(title)
        let escapedColorScheme = escapedHTML(colorScheme.rawValue)
        let colorSchemeContent = colorScheme.colorSchemeContent

        return """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <meta name="color-scheme" content="\(colorSchemeContent)">
          <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data: https: file:; media-src data: https: file:; style-src 'unsafe-inline'; font-src data:;">
          <style>
            \(githubMarkdownCSS)
            \(noteCastPreviewCSS)
          </style>
        </head>
        <body>
          <article class="markdown-body" data-theme="\(escapedColorScheme)">
            <header class="notecast-preview-header">
              <h1>\(escapedTitle)</h1>
            </header>
            \(bodyHTML)
          </article>
        </body>
        </html>
        """
    }

    private static func escapedHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }


    /// Default Markdown preview stylesheet.
    ///
    /// The CSS file is vendored from `github-markdown-css` and copied into the
    /// app bundle as a resource. Keeping it as a standalone file makes future
    /// stylesheet refreshes easy and keeps this Swift view focused on app code.
    ///
    /// Source: https://github.com/sindresorhus/github-markdown-css
    private static var githubMarkdownCSS: String {
        guard let url = Bundle.main.url(forResource: "github-markdown", withExtension: "css"),
              let css = try? String(contentsOf: url, encoding: .utf8) else {
            // Tiny fallback used only if a development build forgets to copy the
            // resource. Production builds should use the full vendored file.
            return """
            .markdown-body {
              color: #1f2328;
              background: #ffffff;
              font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif;
              font-size: 16px;
              line-height: 1.5;
            }
            @media (prefers-color-scheme: dark) {
              .markdown-body { color: #f0f6fc; background: transparent; }
            }
            .markdown-body pre, .markdown-body code { font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; }
            .markdown-body pre { padding: 16px; overflow: auto; background: rgba(125, 125, 125, 0.14); }
            .markdown-body blockquote { padding-left: 1em; color: #656d76; border-left: 0.25em solid #d0d7de; }
            .markdown-body table { border-collapse: collapse; }
            .markdown-body th, .markdown-body td { padding: 6px 13px; border: 1px solid #d0d7de; }
            """
        }

        return css
    }

    /// Small app-specific wrapper around GitHub's stylesheet.
    ///
    /// The upstream CSS styles Markdown content itself. These rules only make it
    /// fit inside NoteCast's in-app WebView: transparent outer page, readable
    /// line length, and a title header that does not add another heavy card.
    private static let noteCastPreviewCSS = """
    :root,
    html,
    body {
      color-scheme: light dark;
      background: transparent !important;
      background-color: transparent !important;
    }
    
    * {
      box-sizing: border-box;
    }
    
    body {
      margin: 0;
      padding: 18px;
    }
    
    .markdown-body {
      min-width: 200px;
      max-width: 78ch;
      margin: 0 auto;
      padding: 20px 6px 32px;
      background: transparent !important;
      background-color: transparent !important;
    }

    .markdown-body[data-theme="light"],
    .markdown-body[data-theme="dark"] {
      --bgColor-default: transparent;
    }
    
    .markdown-body .notecast-preview-header {
      margin: 0 0 20px;
      padding: 0 0 12px;
      border-bottom: 1px solid var(--borderColor-default);
    }
    
    .markdown-body .notecast-preview-header h1 {
      margin: 0;
      padding-bottom: 0;
      border-bottom: 0;
    }
    
    .markdown-body .empty {
      color: var(--fgColor-muted);
      font-style: italic;
    }
    
    .markdown-body pre,
    .markdown-body img {
      border-radius: 8px;
    }
    """
}

/// In-app WebKit preview for generated Markdown HTML.
///
/// This is an `NSViewRepresentable` because SwiftUI does not provide a native
/// WebView. It lives inside the existing editor pane; opening preview never
/// creates another NoteCast window.
private struct MarkdownPreviewWebView: NSViewRepresentable {
    let html: String
    let colorScheme: MarkdownPreviewColorScheme

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let webpagePreferences = WKWebpagePreferences()
        webpagePreferences.allowsContentJavaScript = false
        configuration.defaultWebpagePreferences = webpagePreferences

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.appearance = colorScheme.nsAppearance
        webView.underPageBackgroundColor = .clear
        webView.allowsBackForwardNavigationGestures = false
        webView.wantsLayer = true
        webView.layer?.backgroundColor = NSColor.clear.cgColor
        webView.layer?.isOpaque = false
        webView.layerContentsRedrawPolicy = .onSetNeedsDisplay
        clearWebViewBackground(webView)
        configureScrollViewRedraw(in: webView)
        DispatchQueue.main.async {
            clearWebViewBackground(webView)
            configureScrollViewRedraw(in: webView)
        }
        webView.loadHTMLString(html, baseURL: nil)
        context.coordinator.lastHTML = html
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        webView.appearance = colorScheme.nsAppearance
        webView.underPageBackgroundColor = .clear
        clearWebViewBackground(webView)
        guard context.coordinator.lastHTML != html else { return }
        context.coordinator.lastHTML = html
        webView.loadHTMLString(html, baseURL: nil)
    }

    private func clearWebViewBackground(_ webView: WKWebView) {
        if webView.responds(to: Selector(("setDrawsBackground:"))) {
            webView.setValue(false, forKey: "drawsBackground")
        }
        webView.layer?.backgroundColor = NSColor.clear.cgColor
        webView.layer?.isOpaque = false
    }

    private func configureScrollViewRedraw(in view: NSView) {
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        view.layer?.isOpaque = false

        if let scrollView = view as? NSScrollView {
            scrollView.drawsBackground = false
            scrollView.backgroundColor = .clear
            scrollView.contentView.copiesOnScroll = false
        }

        if let clipView = view as? NSClipView {
            clipView.drawsBackground = false
            clipView.backgroundColor = .clear
        }

        for subview in view.subviews {
            configureScrollViewRedraw(in: subview)
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var lastHTML = ""

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }
    }
}

// MARK: - Folder sheet

/// Modal action for creating or renaming a folder.
private enum FolderSheetMode: Identifiable {
    case create
    case rename(folderID: UUID, currentName: String)

    var id: String {
        switch self {
        case .create:
            return "create"
        case .rename(let folderID, _):
            return "rename-\(folderID.uuidString)"
        }
    }

    var title: String {
        switch self {
        case .create:
            return "New Folder"
        case .rename:
            return "Rename Folder"
        }
    }

    var initialName: String {
        switch self {
        case .create:
            return ""
        case .rename(_, let currentName):
            return currentName
        }
    }

    var saveButtonTitle: String {
        switch self {
        case .create:
            return "Create"
        case .rename:
            return "Rename"
        }
    }
}

/// Small sheet used for folder names.
private struct FolderNameSheet: View {
    let mode: FolderSheetMode
    let cancel: () -> Void
    let save: (String) -> Void

    @State private var name: String

    init(mode: FolderSheetMode, cancel: @escaping () -> Void, save: @escaping (String) -> Void) {
        self.mode = mode
        self.cancel = cancel
        self.save = save
        self._name = State(initialValue: mode.initialName)
    }

    private var canSave: Bool {
        NoteFolder.cleanName(name) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(mode.title)
                .font(.title2.bold())

            TextField("Folder name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
                .onSubmit(submit)

            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button(mode.saveButtonTitle, action: submit)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
    }

    private func submit() {
        guard canSave else { return }
        save(name)
    }
}

// MARK: - Previews

#Preview("Markdown Stylesheet - Light") {
    MarkdownPreviewStylesheetPreview(colorScheme: .light)
}

#Preview("Markdown Stylesheet - Dark") {
    MarkdownPreviewStylesheetPreview(colorScheme: .dark)
}

private struct MarkdownPreviewStylesheetPreview: View {
    let colorScheme: MarkdownPreviewColorScheme

    private let sampleMarkdown = """
    # Markdown stylesheet sampler

    This preview exercises the **GitHub Markdown CSS** that NoteCast uses in the
    reader. It includes _inline emphasis_, `inline code`, links, lists, tables,
    blockquotes, alerts, and code blocks.

    ## Text rhythm

    Markdown previews should feel readable over longer passages. Paragraphs keep
    a comfortable line length, headings create clear hierarchy, and muted text
    such as blockquotes remains legible in both appearances.

    > A blockquote can hold a short citation, a captured idea, or a clipped note.
    > It should stand apart without feeling heavier than the note itself.

    ## Lists

    - Capture quick notes from the menu bar.
    - File notes into folders later.
    - Preview Markdown without leaving the editor.

    1. Draft the note.
    2. Review the rendered Markdown.
    3. Save the polished version.

    - [x] Task list item
    - [ ] Unfinished task item

    ## Table

    | Element | Purpose | Style signal |
    | --- | --- | --- |
    | Heading | Structure | Bold scale and spacing |
    | Code | Exact text | Monospace contrast |
    | Quote | Context | Muted color and left rule |

    ## Code

    ```swift
    struct NoteSummary: View {
        let title: String
        let updatedAt: Date

        var body: some View {
            VStack(alignment: .leading) {
                Text(title).font(.headline)
                Text(updatedAt.formatted()).foregroundStyle(.secondary)
            }
        }
    }
    ```

    > [!NOTE]
    > GitHub-style alerts use the same stylesheet variables as the rest of the
    > preview, so they should stay balanced in light and dark mode.

    ---

    A final paragraph checks horizontal rules, spacing after rich blocks, and the
    default body color.
    """

    var body: some View {
        previewPane(title: colorScheme.previewTitle, colorScheme: colorScheme)
        .padding(18)
        .frame(width: 760, height: 820)
        .background(TahoeWindowBackground())
    }

    private func previewPane(title: String, colorScheme: MarkdownPreviewColorScheme) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: colorScheme == .light ? "sun.max" : "moon")
                .font(.headline)
                .foregroundStyle(.secondary)

            MarkdownPreviewWebView(
                html: MarkdownPreviewHTML.documentHTML(
                    markdown: sampleMarkdown,
                    title: "Stylesheet sampler",
                    colorScheme: colorScheme
                ),
                colorScheme: colorScheme
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(.secondary.opacity(0.22), lineWidth: 1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
