# AGENTS.md - NoteCast Project Guide

This file is for coding agents working on the NoteCast repository. It describes the project, where important code lives, and the rules to follow when changing it.

## Project overview

NoteCast is a macOS Markdown notes app with both a full application window and a fast menu bar companion.

Main features:
- Opens as a normal Dock/app-window macOS application.
- Keeps a `MenuBarExtra` for quick capture, recent-note access, and Start at Login control; the menu bar function is part of the app, not a separate product.
- Uses a Tahoe-inspired SwiftUI layout: left sidebar, translucent materials, rounded note cards, and a large editor surface.
- Stores notes and folders with SwiftData in a shared on-disk store.
- Supports folders through a shared `NoteFolder` model and an optional `Note.folder` relationship.
- Allows drag and drop of notes onto folders or back to Unfiled.
- Supports basic fuzzy note search in the main sidebar and in `cast search` / `cast list --query`.
- Shows a main note display/edit view with title, folder picker, metadata, a compact titlebar Preview/Edit segmented control, Markdown text editor, in-place Swift Markdown/WebKit preview, Revert/Save actions, and `Cmd+S` save.
- Exposes note-level Copy Markdown/Delete Note actions from right-click context menus on note rows and cards.
- Still opens a compact centered note entry window from the menu bar for quick notes and preserves `Cmd+Return` save there.
- Shows the last 10 notes in the menu bar menu.
- Opens a compact display window for a selected menu note with Copy/Edit/Delete actions.
- Ships a Swift CLI tool named `cast` for scripts, pipes, and coding agents.

## Targets

- `NoteCast`: macOS SwiftUI/AppKit application with a full window plus menu bar extra.
- `cast`: Swift command-line tool.
- `NoteCastTests`: unit test target.
- `NoteCastUITests`: end-to-end UI test target.

The app target depends on the `cast` target and embeds the built CLI at:

```text
NoteCast.app/Contents/Resources/bin/cast
```

A user can install a Sublime-style shell command with:

```bash
ln -sf "/Applications/NoteCast.app/Contents/Resources/bin/cast" /usr/local/bin/cast
```

## Important files

```text
Shared/Models/Note.swift                 SwiftData Note model shared by app and CLI
Shared/Models/NoteFolder.swift           SwiftData folder model and Note relationship inverse
Shared/Persistence/NotePersistence.swift Shared SwiftData store/schema setup
Shared/Persistence/NoteExternalChangeSignal.swift Cross-process app/CLI refresh signal
Shared/Search/NoteSearch.swift           Shared app/CLI fuzzy note search scorer
NoteCast/App/NoteCastApp.swift           App entry point, main Window, MenuBarExtra, open-file handling, and app commands
NoteCast/Browser/NoteBrowserStore.swift  View-model/context owner for the main library window
NoteCast/Browser/NoteBrowserView.swift   Main browser composition, toolbar, folder sheet, command palette, and note/folder actions
NoteCast/Browser/NoteBrowserSidebar.swift Sidebar search, collections, folders, notes, and drag/drop targets
NoteCast/Browser/NoteBrowserDetail.swift Detail pane and collection landing views
NoteCast/Browser/NoteBrowserEditorView.swift Main note title/body/folder editor and preview/edit controls
NoteCast/Browser/NoteBrowserEditorCommandBridge.swift Focused Save/Revert command bridge for menus and palette
NoteCast/Browser/NoteBrowserNoteActions.swift Shared note context-menu actions
NoteCast/Browser/FolderNameSheet.swift   Create/rename folder sheet
NoteCast/CommandPalette/CommandPaletteModels.swift Testable command metadata and palette search/ranking
NoteCast/CommandPalette/CommandPaletteView.swift Keyboard-first command palette UI
NoteCast/MenuBar/NoteMenuView.swift      Menu bar menu contents, Start at Login toggle, and recent-note refresh
NoteCast/MenuBar/NoteWindowManager.swift AppKit utility-window creation/retention and external refresh monitoring
NoteCast/MenuBar/NoteEntryView.swift     Compact create/edit UI and Cmd+Return handling
NoteCast/MenuBar/NoteDisplayView.swift   Compact read-only note window with Copy/Edit/Delete
NoteCast/MenuBar/LaunchAtLoginController.swift ServiceManagement wrapper for Start at Login
NoteCast/Preview/MarkdownPreview.swift   Swift Markdown HTML generation and WebKit preview
NoteCast/Preview/github-markdown.css     Vendored github-markdown-css preview stylesheet
NoteCast/Services/NoteFileImporter.swift Markdown file import service for Finder/Dock open events
NoteCast/Services/NoteNotificationController.swift User notification scheduling
NoteCast/TestingSupport/UITestingSupport.swift Test-only launch flag and seed-data helper
NoteCast/TestingSupport/UITestHarnessView.swift Test-only window used by UI automation
Cast/main.swift                          `cast` CLI implementation
Cast/CastSupport.swift                   `cast` CLI helper functions and JSON formatting
skills/notecast-cast/SKILL.md            Agent-facing `cast` usage skill
```

## Project organization

The Xcode project uses file-system-synchronized groups for `NoteCast`, `Shared`, `Cast`, and the test targets. Logical folders in Xcode are therefore real folders on disk. Prefer adding new files to the existing folder that owns the behavior:

- `Shared/Models`: SwiftData model types and model-level repair/display helpers.
- `Shared/Persistence`: schema, store location, model-container setup, and cross-process refresh signaling.
- `Shared/Search`: app/CLI search and ranking logic.
- `NoteCast/App`: app lifecycle, app delegate, scene setup, and app-wide commands.
- `NoteCast/Browser`: the normal full-window library/sidebar/editor experience.
- `NoteCast/CommandPalette`: command palette UI and ranking logic.
- `NoteCast/MenuBar`: menu bar menu, compact utility windows, Start at Login, and utility-window retention.
- `NoteCast/Preview`: Markdown rendering and preview resources.
- `NoteCast/Services`: app services that are not themselves views, such as import and notification scheduling.
- `NoteCast/TestingSupport`: app code that exists only to support UI automation.

When moving or adding files, do not hand-edit Xcode virtual groups unless the project stops using synchronized groups. Keep paths in README and this guide current so humans and agents can find the right owner quickly.

## Data model

`Note` is a SwiftData model with:

- `uuid`: stable UUID used by the CLI and app selection as the public note id.
- `title`: user-facing title. New notes always get a title.
- `folder`: optional relationship to `NoteFolder`; `nil` means Unfiled.
- `text`: note body.
- `mimetype`: defaults to `text/markdown`.
- `created_at`: creation timestamp.
- `updated_at`: last update timestamp.
- `created_via`: currently `APP` or `CLI`.

`NoteFolder` is a SwiftData model with:

- `uuid`: stable folder id.
- `name`: user-facing folder name.
- `created_at`: creation timestamp.
- `updated_at`: last folder metadata update.
- `notes`: inverse relationship for notes contained by the folder.

Important compatibility detail:
- `uuid`, `title`, folder names, and the `Note.folder` relationship are optional/migration-safe where needed.
- New notes and folders always set UUID/title/name metadata.
- Old notes/folders are repaired lazily by `repairMissingMetadataIfNeeded()`.
- Deleting a folder must not delete notes. The model uses `.nullify`, and UI code also clears affected notes explicitly before deleting the folder.

Default title behavior:
- If no title is supplied, a random word plus local date/time is generated, e.g. `ember 2026-06-15 12:04`.

## Persistence

The app and CLI must use the same store. Do not switch back to SwiftData's default per-binary location.

Production store:

```text
~/Library/Application Support/NoteCast/NoteCast.store
```

Test store behavior:
- UI tests pass `NOTECAST_STORE_URL` to isolate test data.
- Unit-test-host launches use a process-specific temp store as a safety net.

## UI architecture notes

The app has two UI surfaces:

1. **Main app window** (`Window` in `NoteCastApp`)
   `NoteBrowserView` is the normal macOS app interface. It uses `NavigationSplitView`, a left sidebar, folder drag/drop, fuzzy search, collection cards, and an editable note detail pane. `NoteBrowserStore` owns a manual SwiftData context and refetches on revision changes so external CLI writes appear reliably.

2. **Menu bar companion** (`MenuBarExtra` in `NoteCastApp`)
   `NoteMenuView` keeps quick-note workflows available. It can open the main app window, open the compact quick-entry window, and show recent notes.

`NoteWindowManager` still owns AppKit `NSWindow` objects for compact utility windows and the UI-test harness. The manager retains windows in a dictionary; otherwise windows can disappear immediately.

Window sizing detail:
- `showWindow(...)` sets `contentViewController`, then explicitly calls `setContentSize(size)` and sets `minSize`.
- This avoids a previous bug where the edit window opened as a tiny sliver.

Refresh detail:
- The main editor defaults to Preview mode and uses a compact Preview/Edit segmented control in the window titlebar plus matching **Editor** menu commands. `Cmd+0` toggles the sidebar, `Cmd+1` switches to Preview, and `Cmd+2` switches to Edit. Preview uses the `swift-markdown` package (`Markdown.HTMLFormatter`) to generate HTML, the vendored `github-markdown-css` stylesheet (`NoteCast/Preview/github-markdown.css`) as the default reading style, and `WKWebView` to display it in-place. Keep preview UI inside `NoteBrowserView`; do not open a separate preview window.
- `NoteWindowManager.notesRevision` increments when app windows create/edit/delete/move notes or folders.
- `NoteMenuView` listens to that revision and refetches recent notes.
- `NoteBrowserView` also listens to that revision and refetches the full library.
- `NoteWindowManager` monitors `NoteExternalChangeSignal` so `cast` changes update app UI.

## CLI behavior

`cast` is both a human CLI and an agent-friendly interface. It currently creates and edits unfiled notes; folder organization is app-side.

`cast search TEXT` and `cast list --query TEXT` use the shared `Shared/Search/NoteSearch.swift`
basic fuzzy scorer. The scorer ranks title matches highest, then folder/body and
metadata/id matches, and supports exact matches, word prefixes, small typos,
acronyms, and subsequence-style matches. This is app-side search over fetched
SwiftData notes; it is not SQLite FTS. Keep app and CLI search behavior shared
through `NoteSearch` rather than duplicating query logic.

Core commands:

```bash
cast add [--title TITLE] [--mime TYPE] [--json] [TEXT...]
cast list [--limit N|--all] [--query TEXT] [--json] [--text]
cast search TEXT [--limit N|--all] [--json] [--text]
cast read ID [--json|--raw]
cast update ID [--title TITLE] [--mime TYPE] [--json] [TEXT...]
cast delete ID [--json]
cast path
```

Backward-compatible quick add:

```bash
ls -1 | cast          # saved as a Markdown code block
cast body text here
```

Explicit `cast add` preserves piped bodies exactly and is the safe automation path. Agents should prefer `cast add --json` and other `--json` subcommands. See `skills/notecast-cast/SKILL.md` for agent-facing workflows.

## Build and test commands

Use these before handing off changes:

```bash
xcodebuild -project NoteCast.xcodeproj -scheme NoteCast -configuration Debug build
xcodebuild -project NoteCast.xcodeproj -scheme cast -configuration Debug build
xcodebuild test -project NoteCast.xcodeproj -scheme NoteCast -configuration Debug -destination 'platform=macOS,arch=arm64'
xcodebuild -project NoteCast.xcodeproj -scheme NoteCast -configuration Release build
xcodebuild -project NoteCast.xcodeproj -scheme cast -configuration Release build
```

For a focused UI test:

```bash
xcodebuild test \
  -project NoteCast.xcodeproj \
  -scheme NoteCast \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:NoteCastUITests/NoteCastUITests/testCreateCopyEditAndDeleteNoteThroughTheUI
```

## Coding guidelines

- Keep code simple and direct.
- Comment SwiftData/AppKit/SwiftUI details clearly; this project is intentionally educational.
- Keep app and CLI schema code shared in `Shared/Models` and `Shared/Persistence`.
- Do not duplicate model definitions between targets.
- Do not re-enable sandboxing unless persistence and CLI sharing are redesigned.
- Do not write tests against the user's real NoteCast store.
- Prefer stable accessibility identifiers for UI-testable controls.
- Preserve `Cmd+Return` save behavior in `NoteEntryView`.
- Preserve `cast --json` output stability for agents/scripts.
- When adding SwiftData properties to existing models, prefer optional/migration-safe fields.
- When changing folders, remember that notes may be unfiled and folder deletion must not delete note content.
- Keep the Swift Package dependency on `swift-markdown` attached to the app target if preview code imports `Markdown`.

## Known pitfalls

- SwiftData migrations: new stored properties should generally be optional or otherwise migration-safe.
- `MenuBarExtra` content can remain alive between openings; explicit refresh signaling is needed.
- `NSWindow` instances must be retained outside local variables.
- AppKit can initially size hosted SwiftUI views incorrectly; keep the explicit content-size call in `showWindow(...)`.
- UI tests may leave a stuck app process if interrupted; kill `NoteCast` before rerunning if XCTest cannot terminate it.
