//
//  NoteWindowManager.swift
//  NoteCast
//
//  Small AppKit helper for opening menu-bar utility windows.
//

import AppKit
import Combine
import Darwin
import SwiftData
import SwiftUI

/// Creates and tracks NoteCast's floating windows.
///
/// `MenuBarExtra` gives us a nice SwiftUI menu, but it does not provide a
/// normal parent window. This class creates plain `NSWindow` instances and puts
/// SwiftUI views inside them using `NSHostingController`.
@MainActor
final class NoteWindowManager: NSObject, ObservableObject {
    private let modelContainer: ModelContainer

    /// Incremented whenever an app window changes the note database.
    ///
    /// `MenuBarExtra` can keep its SwiftUI content alive between openings, so a
    /// plain `onAppear` refresh is not enough. Publishing this counter gives the
    /// menu an explicit signal to reload its "last 10 notes" list immediately
    /// after creating, editing, or deleting a note.
    @Published private(set) var notesRevision = 0

    /// Windows must be retained by our code. If we only created a local
    /// variable, the window would disappear immediately after the function
    /// returned.
    private var windows: [UUID: NSWindow] = [:]
    private var delegates: [UUID: WindowCloseDelegate] = [:]

    /// Last external revision token observed from the CLI-created revision file.
    private var observedExternalRevisionToken: String?

    /// Distributed-notification observer used when `cast` changes notes.
    private var externalChangeObserver: NSObjectProtocol?

    /// Directory watcher used as a fallback if the distributed notification is missed.
    private var revisionDirectorySource: DispatchSourceFileSystemObject?

    /// Debounces bursts of filesystem events caused by atomic revision-file writes.
    private var revisionDirectoryDebounce: DispatchWorkItem?

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
        super.init()

        startExternalChangeMonitoring()
    }

    deinit {
        if let externalChangeObserver {
            DistributedNotificationCenter.default().removeObserver(externalChangeObserver)
        }
        revisionDirectoryDebounce?.cancel()
        revisionDirectorySource?.cancel()
    }

    /// Open the note creation/editing window.
    func openEntryWindow(editing note: Note? = nil) {
        let id = UUID()
        let title = note == nil ? "New Note" : "Edit Note"

        // For edits, reuse the note's existing context when possible. For
        // example, an Edit button in a display window should update that same
        // display window after saving. New notes get a fresh context.
        let context: ModelContext
        let noteForWindow: Note?
        if let note, let existingContext = note.modelContext {
            context = existingContext
            noteForWindow = note
        } else {
            context = ModelContext(modelContainer)
            noteForWindow = note.flatMap { context.model(for: $0.persistentModelID) as? Note }
        }

        let view = NoteEntryView(note: noteForWindow, didSave: { [weak self] in
            self?.notesDidChange()
        }) { [weak self] in
            self?.closeWindow(id)
        }
        .modelContext(context)

        showWindow(
            id: id,
            title: title,
            size: NSSize(width: 720, height: 440),
            rootView: view
        )
    }

    /// Open the test-only harness window used by XCTest UI tests.
    func openUITestHarnessWindow() {
        let id = UUID()
        let context = ModelContext(modelContainer)

        let view = UITestHarnessView()
            .environmentObject(self)
            .modelContext(context)

        showWindow(
            id: id,
            title: "NoteCast UI Test",
            size: NSSize(width: 760, height: 520),
            activatesApp: true,
            rootView: view
        )
    }

    /// Open a read-only note display window.
    func openDisplayWindow(for note: Note) {
        let id = UUID()

        // Re-fetch the selected note in a context owned by this window. This is
        // safer than sharing the menu's context, because the menu view can go
        // away immediately after the user chooses an item.
        let context = ModelContext(modelContainer)
        guard let noteForWindow = context.model(for: note.persistentModelID) as? Note else {
            return
        }

        let view = NoteDisplayView(note: noteForWindow, didDelete: { [weak self] in
            self?.notesDidChange()
        }) { [weak self] in
            self?.closeWindow(id)
        }
        .environmentObject(self)
        .modelContext(context)

        showWindow(
            id: id,
            title: "Note",
            size: NSSize(width: 640, height: 420),
            rootView: view
        )
    }

    /// Tell any menu views to reload their recent notes.
    ///
    /// This is internal so the UI-test harness can exercise the same refresh
    /// path as the real menu bar menu.
    func notesDidChange() {
        notesRevision += 1
    }

    /// Listen for changes written by the separate `cast` CLI process.
    private func startExternalChangeMonitoring() {
        observedExternalRevisionToken = NoteExternalChangeSignal.currentRevisionToken()

        externalChangeObserver = DistributedNotificationCenter.default().addObserver(
            forName: NoteExternalChangeSignal.notificationName,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let manager = self else { return }
            Task { @MainActor in
                manager.refreshFromExternalSignal(force: true)
            }
        }

        startRevisionDirectoryWatcher()
    }

    /// Watch the directory that contains the revision file.
    ///
    /// `NoteExternalChangeSignal.writeRevisionFile()` writes atomically, which
    /// replaces the file. Watching the containing directory survives that rename
    /// and catches missed distributed notifications without watching SwiftData's
    /// SQLite/WAL files directly.
    private func startRevisionDirectoryWatcher() {
        guard let directoryURL = try? NoteExternalChangeSignal.revisionDirectoryURL() else {
            return
        }

        let fileDescriptor = open(directoryURL.path, O_EVTONLY)
        guard fileDescriptor >= 0 else {
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .delete, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.scheduleExternalRevisionCheck()
        }
        source.setCancelHandler {
            close(fileDescriptor)
        }
        source.resume()

        revisionDirectorySource = source
    }

    private func scheduleExternalRevisionCheck() {
        revisionDirectoryDebounce?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            self?.refreshFromExternalSignal(force: false)
        }
        revisionDirectoryDebounce = workItem

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: workItem)
    }

    /// Refresh after an external signal if it represents a new revision.
    ///
    /// Filesystem events are noisy, so they only refresh when the durable token
    /// changes. A distributed notification is allowed to force a refresh if the
    /// revision file could not be read, because the notification itself means an
    /// external writer believes the store changed.
    private func refreshFromExternalSignal(force: Bool) {
        if let latestToken = NoteExternalChangeSignal.currentRevisionToken() {
            guard latestToken != observedExternalRevisionToken else {
                return
            }

            observedExternalRevisionToken = latestToken
            notesDidChange()
        } else if force {
            notesDidChange()
        }
    }

    private func showWindow<Content: View>(
        id: UUID,
        title: String,
        size: NSSize,
        activatesApp: Bool = false,
        rootView: Content
    ) {
        let hostingController = NSHostingController(rootView: rootView)

        let window: NSWindow
        if activatesApp {
            window = NSWindow(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
        } else {
            // Menu-bar note windows should behave like lightweight utility
            // panels: they can receive keyboard focus, but they do not activate
            // the whole app or unhide/reopen the full browser window.
            let panel = NoteUtilityPanel(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.hidesOnDeactivate = false
            window = panel
        }
        window.title = title
        window.contentViewController = hostingController

        // Setting the content size *after* installing the SwiftUI hosting
        // controller is intentional. On macOS, a hosted SwiftUI view can report
        // a very small fitting size during its first layout pass; if AppKit uses
        // that value the edit window may open as a tiny sliver. This forces the
        // requested default size for every newly opened NoteCast window.
        window.setContentSize(size)
        window.minSize = size
        window.isReleasedWhenClosed = false

        let delegate = WindowCloseDelegate { [weak self] in
            // Closing a menu-bar utility window should not trigger SwiftUI to
            // reopen the full browser window. Suppress the automatic main-window
            // lifecycle briefly while AppKit processes the close/reopen events.
            NoteCastAppDelegate.suppressAutomaticMainWindowPresentation()
            self?.windows[id] = nil
            self?.delegates[id] = nil
        }
        window.delegate = delegate

        windows[id] = window
        delegates[id] = delegate

        // Center on the current main screen and bring the window forward.
        NoteCastAppDelegate.suppressAutomaticMainWindowPresentation()
        window.center()

        if activatesApp {
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
        } else {
            // `orderFrontRegardless()` makes the compact menu-bar window visible
            // above the current app without activating NoteCast as a whole.
            // That prevents the main browser window from appearing after the
            // user closes a quick note/display window.
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    }

    private func closeWindow(_ id: UUID) {
        windows[id]?.close()
        windows[id] = nil
        delegates[id] = nil
    }
}

/// Non-activating panel used for compact menu-bar note windows.
///
/// `NSApplication.activate(...)` brings the whole app forward, which can unhide
/// or reopen the main browser window. A non-activating panel lets the small note
/// window come forward on its own, preserving the menu-bar workflow.
private final class NoteUtilityPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Retained delegate object that lets us remove closed windows from the
/// dictionaries above. Without this cleanup, closed windows would stay in
/// memory until the app quits.
private final class WindowCloseDelegate: NSObject, NSWindowDelegate {
    private let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}
