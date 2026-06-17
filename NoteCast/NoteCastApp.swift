//
//  NoteCastApp.swift
//  NoteCast
//
//  App entry point for the full macOS application and its menu bar companion.
//

import AppKit
import SwiftData
import SwiftUI

@main
struct NoteCastApp: App {
    /// AppKit delegate used only for lifecycle edge cases SwiftUI does not
    /// expose as scene modifiers.
    @NSApplicationDelegateAdaptor(NoteCastAppDelegate.self) private var appDelegate

    /// The one SwiftData container used by all app views and windows.
    private let modelContainer: ModelContainer

    /// Owns the AppKit utility windows that are opened from the menu bar.
    ///
    /// The app now also has a normal SwiftUI `Window` for browsing notes,
    /// but the menu bar still needs a tiny AppKit manager for quick floating
    /// note-entry and note-display windows.
    @StateObject private var windowManager: NoteWindowManager

    init() {
        let container = NotePersistence.makeModelContainerOrCrash()
        let manager = NoteWindowManager(modelContainer: container)
        self.modelContainer = container
        self._windowManager = StateObject(wrappedValue: manager)
        appDelegate.configure(modelContainer: container, windowManager: manager)

        // UI tests need a predictable harness window they can automate. The
        // production app opens the normal NoteCast window; this extra harness
        // appears only with `--ui-testing` and mounts the compact views tested
        // by the existing UI automation.
        if UITestingSupport.isEnabled {
            Task { @MainActor in
                manager.openUITestHarnessWindow()
            }
        }
    }

    var body: some Scene {
        Window("NoteCast", id: "main") {
            Group {
                if PreviewRuntime.isActive {
                    Color.clear
                        .frame(width: 1, height: 1)
                } else {
                    NoteBrowserView(modelContainer: modelContainer)
                        .environmentObject(windowManager)
                        .modelContainer(modelContainer)
                }
            }
            .onOpenURL { url in
                appDelegate.importOpenedFileURLs([url], activateApp: false)
            }
            .background {
                MainWindowRegistrationView(appDelegate: appDelegate)
            }
        }
        .defaultSize(width: 1080, height: 720)
        .commands {
            NoteBrowserCommands()
        }

        // The menu bar extra is intentionally still part of the app. It offers
        // fast capture and recent-note access while the full window provides the
        // richer folder/sidebar/editor experience.
        MenuBarExtra("NoteCast", systemImage: "note.text") {
            if PreviewRuntime.isActive {
                EmptyView()
            } else {
                NoteMenuView()
                    .id(windowManager.notesRevision)
                    .environmentObject(windowManager)
                    .modelContainer(modelContainer)
            }
        }
        .menuBarExtraStyle(.menu)
    }
}

enum PreviewRuntime {
    static let isActive: Bool = {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
            || environment["XCODE_RUNNING_FOR_PLAYGROUNDS"] == "1"
    }()
}

/// Suppresses SwiftUI's automatic main-window presentation while the user is
/// working with menu-bar utility windows.
///
/// Now that NoteCast is a normal Dock app, AppKit/SwiftUI may try to reopen the
/// default `Window` scene when the app is activated and then left with no visible
/// windows. That is correct for Dock clicks, but wrong for menu-bar workflows:
/// opening a compact note window from the menu bar and closing it should return
/// the user to what they were doing, not reveal the full NoteCast browser.
final class NoteCastAppDelegate: NSObject, NSApplicationDelegate {
    private static weak var activeDelegate: NoteCastAppDelegate?
    private static let duplicateOpenEventInterval: TimeInterval = 2

    private var fileImporter: NoteFileImporter?
    private weak var windowManager: NoteWindowManager?
    private weak var mainWindow: NSWindow?
    private var openMainWindow: (() -> Void)?
    private var recentlyImportedFileURLs: [URL: Date] = [:]
    private var suppressMainWindowPresentationUntil = Date.distantPast

    override init() {
        super.init()
        Self.activeDelegate = self
    }

    func configure(modelContainer: ModelContainer, windowManager: NoteWindowManager) {
        fileImporter = NoteFileImporter(modelContainer: modelContainer)
        self.windowManager = windowManager
    }

    func registerMainWindow(_ window: NSWindow?) {
        guard let window else { return }
        window.identifier = NSUserInterfaceItemIdentifier("NoteCast.mainWindow")
        mainWindow = window
    }

    func configureMainWindowOpener(_ openMainWindow: @escaping () -> Void) {
        self.openMainWindow = openMainWindow
    }

    /// Temporarily prevent automatic presentation of the main SwiftUI window.
    ///
    /// Menu-bar note windows call this before they activate and again as they
    /// close. The window remains fully usable, but any AppKit "reopen" event
    /// produced by that short utility-window lifecycle is ignored.
    static func suppressAutomaticMainWindowPresentation() {
        activeDelegate?.suppressMainWindowPresentationUntil = Date().addingTimeInterval(1.5)
    }

    private var isSuppressingMainWindowPresentation: Bool {
        Date() < suppressMainWindowPresentationUntil
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow(sender)
        return false
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        !isSuppressingMainWindowPresentation
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let urls = filenames.map { URL(fileURLWithPath: $0) }
        let didImport = importOpenedFileURLs(urls, activateApp: true)
        sender.reply(toOpenOrPrint: didImport ? .success : .failure)
    }

    func application(_ sender: NSApplication, open urls: [URL]) {
        importOpenedFileURLs(urls, activateApp: true)
    }

    @discardableResult
    func importOpenedFileURLs(_ urls: [URL], activateApp: Bool) -> Bool {
        guard let fileImporter else {
            return false
        }

        let openFileEvent = urlsToImport(from: urls)
        guard !openFileEvent.urls.isEmpty else {
            return openFileEvent.skippedDuplicate
        }

        let summary = fileImporter.importMarkdownFiles(at: openFileEvent.urls)
        logImportFailures(summary.failures)

        guard summary.didImportNotes else {
            return false
        }

        rememberImportedURLs(openFileEvent.urls)
        windowManager?.notesDidChange()

        if activateApp {
            NSApp.activate(ignoringOtherApps: true)
        }

        return true
    }

    private func logImportFailures(_ failures: [NoteFileImportFailure]) {
        for failure in failures {
            let path = failure.url?.path ?? "NoteCast store"
            NSLog("NoteCast could not import %@: %@", path, failure.errorDescription)
        }
    }

    private func urlsToImport(from urls: [URL]) -> (urls: [URL], skippedDuplicate: Bool) {
        let now = Date()
        recentlyImportedFileURLs = recentlyImportedFileURLs.filter {
            now.timeIntervalSince($0.value) < Self.duplicateOpenEventInterval
        }

        var skippedDuplicate = false
        let importableURLs = urls
            .filter(\.isFileURL)
            .map(normalizedFileURL)
            .filter { url in
                if let importedAt = recentlyImportedFileURLs[url],
                   now.timeIntervalSince(importedAt) < Self.duplicateOpenEventInterval {
                    skippedDuplicate = true
                    return false
                }

                return true
            }

        return (importableURLs, skippedDuplicate)
    }

    private func rememberImportedURLs(_ urls: [URL]) {
        let now = Date()
        for url in urls {
            recentlyImportedFileURLs[normalizedFileURL(url)] = now
        }
    }

    private func normalizedFileURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private func showMainWindow(_ sender: NSApplication) {
        if let mainWindow {
            if mainWindow.isMiniaturized {
                mainWindow.deminiaturize(nil)
            }
            mainWindow.makeKeyAndOrderFront(nil)
            sender.activate(ignoringOtherApps: true)
            return
        }

        openMainWindow?()
        DispatchQueue.main.async { [weak self, weak sender] in
            if let mainWindow = self?.mainWindow {
                if mainWindow.isMiniaturized {
                    mainWindow.deminiaturize(nil)
                }
                mainWindow.makeKeyAndOrderFront(nil)
            }
            sender?.activate(ignoringOtherApps: true)
        }
    }
}

/// Registers the SwiftUI main window with the AppKit delegate.
///
/// `applicationShouldHandleReopen` does not get SwiftUI's `openWindow`
/// environment directly. This tiny background view bridges that gap so a Dock
/// click can reopen the main window deterministically on the first click.
private struct MainWindowRegistrationView: View {
    let appDelegate: NoteCastAppDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        MainWindowAccessor { window in
            appDelegate.registerMainWindow(window)
        }
        .frame(width: 0, height: 0)
        .onAppear {
            appDelegate.configureMainWindowOpener {
                openWindow(id: "main")
            }
        }
    }
}

private struct MainWindowAccessor: NSViewRepresentable {
    let onWindowChange: (NSWindow?) -> Void

    func makeNSView(context: Context) -> WindowProbeView {
        WindowProbeView(onWindowChange: onWindowChange)
    }

    func updateNSView(_ view: WindowProbeView, context: Context) {
        DispatchQueue.main.async {
            onWindowChange(view.window)
        }
    }

    final class WindowProbeView: NSView {
        let onWindowChange: (NSWindow?) -> Void

        init(onWindowChange: @escaping (NSWindow?) -> Void) {
            self.onWindowChange = onWindowChange
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowChange(window)
        }
    }
}

/// App menu commands for the main note browser.
///
/// The editor segmented control lives in the window titlebar. These commands put
/// sidebar and editor actions in the macOS menu bar and own the global shortcuts
/// so users can switch modes without reaching for the mouse.
private struct NoteBrowserCommands: Commands {
    @FocusedBinding(\.noteBrowserEditorMode) private var editorMode
    @FocusedBinding(\.noteBrowserSidebarVisibility) private var sidebarVisibility

    var body: some Commands {
        CommandGroup(replacing: .sidebar) {
            Button(sidebarVisibility == .detailOnly ? "Show Sidebar" : "Hide Sidebar") {
                toggleSidebar()
            }
            .keyboardShortcut("0", modifiers: [.command])
            .disabled(sidebarVisibility == nil)
        }

        CommandMenu("Editor") {
            Button("Preview") {
                editorMode = .preview
            }
            .keyboardShortcut("1", modifiers: [.command])
            .disabled(editorMode == nil)

            Button("Edit") {
                editorMode = .edit
            }
            .keyboardShortcut("2", modifiers: [.command])
            .disabled(editorMode == nil)
        }
    }

    private func toggleSidebar() {
        // Prefer AppKit's responder-chain action so the system split-view
        // animation is used. The SwiftUI state change is only a fallback for
        // cases where no split view handled the standard action.
        if NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil) {
            return
        }

        guard let sidebarVisibility else { return }
        withAnimation {
            self.sidebarVisibility = sidebarVisibility == .detailOnly ? .all : .detailOnly
        }
    }
}
