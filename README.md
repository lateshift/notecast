# NoteCast

NoteCast is a macOS Markdown notes app with a full notes window, a fast menu bar companion, and a scriptable `cast` command-line tool.

## Video

https://github.com/user-attachments/assets/8b471507-fd8c-49c3-83b3-82946cdda25f

## Features

- Normal macOS app window with a left sidebar and large note editor.
- Menu bar extra for quick capture, recent notes, and Start at Login control.
- Folder support backed by SwiftData.
- Drag notes onto folders, or onto **Unfiled** to remove them from a folder.
- Markdown-friendly plain-text editor with `Cmd+S` save in the main window.
- In-place Markdown preview powered by Swift Markdown and rendered in a WebKit view.
- Basic fuzzy note search in the sidebar and through the `cast` CLI.
- Compact quick-note window from the menu bar with `Cmd+Return` save.
- Shared persistent store for the app and CLI.
- Bundled `cast` CLI for terminal, scripts, pipes, and coding agents.

## Main app workflow

1. Launch NoteCast from Xcode or Finder.
2. Use the sidebar to select **All Notes**, **Unfiled**, a folder, or an individual note.
3. Click **New Note** to create a note in the selected folder context.
4. Click **New Folder** to organize notes.
5. Drag note rows/cards onto folders to move them.
6. Edit title/body/folder in the main note pane and press `Cmd+S` or click **Save**.
7. Right-click a note row or note card for note-level actions such as **Copy Markdown** and **Delete Note**.

The menu bar extra remains available while the full app is running. Use it for quick notes, recent-note access, or reopening the main NoteCast window.

## CLI quick start

The app embeds the CLI at:

```text
NoteCast.app/Contents/Resources/bin/cast
```

Install a convenient shell command:

```bash
ln -sf "/Applications/NoteCast.app/Contents/Resources/bin/cast" /usr/local/bin/cast
```

Examples:

```bash
cast add --title "Release idea" "Ship folder drag and drop"
ls -1 | cast                         # quick command-output capture, saved as a Markdown code block
echo "Piped markdown" | cast add --json  # exact piped body for scripts/agents
cast list --json
cast search "relese noets" --json       # fuzzy/ranked search
cast read NOTE_ID --raw
cast update NOTE_ID --title "Better title" "Updated body"
cast delete NOTE_ID --json
cast path
```

`cast search TEXT` and `cast list --query TEXT` use the same lightweight fuzzy
ranking as the app sidebar search. They search note titles, folder names, note
bodies, ids, MIME types, and creation source metadata, with title matches ranked
highest. The matcher handles exact matches, word prefixes, small typos, acronyms,
and subsequence-style matches. It is intentionally app-side search over the
SwiftData notes, not SQLite FTS.

## Agent skill installation

This repository includes an Agent Skills-compatible helper at `skills/notecast-cast/` so coding agents know how to use the `cast` CLI safely. Install it by symlinking or copying that directory into your agent's skills directory:

```bash
# From the NoteCast repository root
mkdir -p ~/.codex/skills ~/.claude/skills ~/.pi/agent/skills
ln -sfn "$PWD/skills/notecast-cast" ~/.codex/skills/notecast-cast   # Codex
ln -sfn "$PWD/skills/notecast-cast" ~/.claude/skills/notecast-cast   # Claude
ln -sfn "$PWD/skills/notecast-cast" ~/.pi/agent/skills/notecast-cast # Pi
```

Restart the agent after installing. The skill expects either `cast` to be on `PATH` or the bundled command to exist at `/Applications/NoteCast.app/Contents/Resources/bin/cast`.

### Using the skill in an agent harness

After restarting the agent, either ask for a NoteCast-related task naturally or name the skill explicitly in the prompt.

Example:

```text
Create a note listing your three favorite scripting languages. For each one, add a brief explanation of why you like it.
```

Other useful prompts:

```text
Use NoteCast to remember this decision: keep the CLI JSON output stable for scripts.
List my 10 most recent NoteCast notes.
Search my NoteCast notes for release decisions.
Read the NoteCast note with id NOTE_ID.
Update NOTE_ID with this new Markdown body: ...
```

## Markdown preview

The main editor defaults to **Preview** mode. Use the compact Preview/Edit segmented control in the window titlebar, the **Editor** menu, `Cmd+1` for Preview, or `Cmd+2` for Edit to switch between rendered HTML and Markdown source editing. `Cmd+0` toggles the sidebar. Preview mode parses the current Markdown with Apple's Swift Markdown package, generates HTML, and displays it inside the existing editor pane using `WKWebView`. The default preview stylesheet is vendored from `github-markdown-css`, with a small NoteCast wrapper for readable width and app integration. It does not open a separate preview window.

## Data location

NoteCast intentionally uses one shared SwiftData store for the app and CLI:

```text
~/Library/Application Support/NoteCast/NoteCast.store
```

## Build

```bash
xcodebuild -project NoteCast.xcodeproj -scheme NoteCast -configuration Debug build
xcodebuild -project NoteCast.xcodeproj -scheme cast -configuration Debug build
```

Run tests:

```bash
xcodebuild test -project NoteCast.xcodeproj -scheme NoteCast -configuration Debug -destination 'platform=macOS,arch=arm64'
```

## Project layout

```text
Shared/Note.swift                  Note model
Shared/NoteFolder.swift            Folder model
Shared/NotePersistence.swift       Shared SwiftData schema/store setup
Shared/NoteSearch.swift            Shared app/CLI fuzzy note search
NoteCast/NoteCastApp.swift         Main app window + menu bar extra
NoteCast/NoteBrowserStore.swift    Main-window data/view model
NoteCast/NoteBrowserView.swift     Sidebar, folders, drag/drop, editor, Markdown preview WebView
NoteCast/github-markdown.css       Vendored github-markdown-css preview stylesheet
NoteCast/LaunchAtLoginController.swift Start at Login registration wrapper
NoteCast/NoteMenuView.swift        Menu bar menu
Cast/main.swift                    cast CLI
```
