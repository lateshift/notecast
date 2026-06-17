---
name: notecast-cast
description: Use NoteCast's bundled `cast` CLI to create, list, fuzzy search, read, update, and delete Markdown notes. Use this when a task asks to remember information, inspect saved notes, retrieve project/user notes, or operate on NoteCast from an agent/script.
---

# NoteCast `cast` Skill

`cast` is the supported automation interface for NoteCast. Do not read or modify the SwiftData database directly; use `cast` so schema repair, title generation, timestamps, and shared store behavior stay consistent.

## Locate the command

If `cast` is on `PATH`, use it directly:

```bash
cast list --json
```

If it is not on `PATH`, use the bundled binary inside the app:

```bash
/Applications/NoteCast.app/Contents/Resources/bin/cast list --json
```

For a development build, the app bundle is usually under Xcode DerivedData:

```bash
find ~/Library/Developer/Xcode/DerivedData -path '*/NoteCast.app/Contents/Resources/bin/cast' -type f | tail -1
```

## Rules for agents

1. Prefer `--json` for all non-trivial operations.
2. Treat `id` as the stable note identifier.
3. Short id prefixes are accepted, but use full ids when available.
4. Default note MIME type is `text/markdown`.
5. Always provide a useful `--title` when adding notes if you know one.
6. Do not repeat the note title inside the Markdown body. If you pass `--title "My title"`, do not start the body with `# My title`, `My title`, or another duplicate title line; begin with the actual note content.
7. If no title is provided, NoteCast generates `random-word yyyy-MM-dd HH:mm`.
8. Use `cast read ID --raw` only when you need the body exactly.
9. Use explicit subcommands such as `cast add --json`; do not rely on bare `... | cast` for automation because bare piped quick-adds are formatted as Markdown code blocks for humans.
10. Do not parse the human-readable table output if JSON is available.
11. Use `cast search QUERY --json` or `cast list --query QUERY --json` before broad `list --all` calls when looking for known content.
12. Search is fuzzy/ranked and can handle small typos, word prefixes, acronyms, and subsequence-style matches, but read the selected note before relying on exact body text.
13. Do not access `~/Library/Application Support/NoteCast/NoteCast.store` directly.

## JSON record shape

`cast --json` returns objects like:

```json
{
  "id": "9813773C-CF54-47AE-8C8E-DF2A42D76BB9",
  "title": "Release notes draft",
  "mimetype": "text/markdown",
  "created_at": "2026-06-15T10:11:32Z",
  "updated_at": "2026-06-15T10:11:32Z",
  "created_via": "CLI",
  "preview": "Short one-line body preview",
  "text": "Full note body when requested"
}
```

`text` is included by:
- `cast add --json`
- `cast read --json`
- `cast update --json`
- `cast list --json --text`

It is omitted from normal `list --json` results to keep listings compact.

## Common workflows

### Add a note from known text

Keep the title in `--title` only; do not duplicate it as a Markdown heading or first body line.

```bash
cast add --title "Decision: use Markdown notes" --json <<'EOF'
We store NoteCast note bodies as Markdown.
Default mimetype: text/markdown.
EOF
```

Expected result: one JSON note record including `id` and `text`.

### Add a note from a pipeline

Use explicit `cast add` so the piped body is stored exactly. Bare `git status --short | cast` is a human quick-capture shortcut and wraps the pipeline output in a Markdown code block.

```bash
git status --short | cast add --title "Working tree snapshot" --json
```

### List recent notes

```bash
cast list --limit 10 --json
```

### List all notes with full bodies

Use sparingly; this can be large.

```bash
cast list --all --json --text
```

### Search notes

Search is lightweight app-side fuzzy ranking over fetched notes. It searches
titles, folder names, bodies, ids, MIME types, and creation source metadata.
Title matches rank highest. It is not SQLite FTS, so use it for practical
retrieval rather than database-style query syntax.

```bash
cast search "release notes" --json
```

Typo-tolerant queries are fine:

```bash
cast search "relese noets" --json
```

Equivalent explicit query form:

```bash
cast list --query "release notes" --json
```

Include full note bodies only when needed:

```bash
cast search "release notes" --json --text
```

### Read a note

```bash
cast read 9813773C-CF54-47AE-8C8E-DF2A42D76BB9 --json
```

Body only:

```bash
cast read 9813773C-CF54-47AE-8C8E-DF2A42D76BB9 --raw
```

### Update a note body

```bash
cast update 9813773C-CF54-47AE-8C8E-DF2A42D76BB9 --json <<'EOF'
Updated Markdown body.
EOF
```

### Update title and body

```bash
cast update 9813773C-CF54-47AE-8C8E-DF2A42D76BB9 --title "Updated title" --json <<'EOF'
Updated body.
EOF
```

### Delete a note

Only delete when the task explicitly asks for deletion.

```bash
cast delete 9813773C-CF54-47AE-8C8E-DF2A42D76BB9 --json
```

## Error handling

`cast` prints errors to stderr and exits non-zero.

Common errors:
- `no note matches id '<id>'`: list/search notes and choose a valid id.
- `id '<prefix>' is ambiguous`: retry with a longer id prefix or full id.
- `nothing to add`: pass text arguments or pipe stdin.
- `nothing to update`: pass `--title`, `--mime`, text arguments, or piped stdin.

Agent recovery pattern:

```bash
if ! json=$(cast read "$id" --json 2>err.txt); then
  cat err.txt >&2
  cast list --limit 20 --json
fi
```

## Store path

For diagnostics only:

```bash
cast path
```

Do not mutate the returned database path directly.
