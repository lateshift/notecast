//
//  Note.swift
//  NoteCast
//
//  Shared by the NoteCast app and the `cast` command line tool.
//

import Foundation
import SwiftData

/// One note stored in SwiftData.
///
/// SwiftData turns this class into a persistent database entity. The app and
/// the CLI compile this same file, so both programs agree on the database
/// schema and can read/write the same store file.
@Model
final class Note {
    /// Stable public id used by the `cast` CLI.
    ///
    /// SwiftData has its own internal persistent id, but it is not nice to type
    /// or expose to scripts. A UUID gives humans and agents a stable id they can
    /// use with commands such as `cast read <id>`.
    var uuid: UUID?

    /// Human-readable note title.
    ///
    /// This is optional in the stored schema so existing NoteCast databases can
    /// migrate smoothly. New notes always get a title, and old notes are given
    /// one lazily the next time the CLI lists/reads them or the app edits them.
    var title: String?

    /// Optional folder relationship used by the full macOS library window.
    ///
    /// This stays optional for two reasons:
    /// 1. Existing stores can migrate without inventing folders for old notes.
    /// 2. Users often want a lightweight inbox/unfiled area for quick captures
    ///    from the menu bar or `cast` CLI.
    var folder: NoteFolder?

    /// The actual note body. The task only listed metadata fields, but a note
    /// also needs somewhere to keep the text the user typed or piped in.
    var text: String

    /// MIME type for the note contents. NoteCast now defaults to Markdown.
    var mimetype: String

    /// Creation timestamp. Kept with the requested snake_case name so the data
    /// model reads exactly like the task description.
    var created_at: Date

    /// Last update timestamp. New notes start with the same value as
    /// `created_at`; edits bump this to the current time.
    var updated_at: Date

    /// Where the note came from: currently either "APP" or "CLI".
    var created_via: String

    init(
        title: String? = nil,
        text: String,
        mimetype: String = "text/markdown",
        created_at: Date = .now,
        updated_at: Date? = nil,
        created_via: String
    ) {
        self.uuid = UUID()
        self.created_at = created_at
        // If no explicit update date is supplied, a new note is considered
        // "updated" at the same instant it was created.
        self.updated_at = updated_at ?? created_at
        self.title = Note.cleanTitle(title) ?? Note.makeAutomaticTitle(createdAt: created_at)
        self.text = text
        self.mimetype = mimetype
        self.created_via = created_via
    }
}

extension Note {
    /// A compact title that is always safe to show in the UI or CLI.
    var displayTitle: String {
        Note.cleanTitle(title) ?? Note.makeAutomaticTitle(createdAt: created_at)
    }

    /// Stable id string for CLI output. Call `repairMissingMetadataIfNeeded()`
    /// before using this for old notes so `uuid` is guaranteed to exist.
    var stableID: String {
        uuid?.uuidString ?? "missing-uuid"
    }

    /// Short body preview used by the menu and CLI list output.
    var bodyPreview: String {
        let oneLine = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !oneLine.isEmpty else { return "Empty note" }

        if oneLine.count <= 70 {
            return oneLine
        }

        return String(oneLine.prefix(67)) + "…"
    }

    /// A compact one-line preview for the menu bar menu.
    var menuPreview: String {
        displayTitle
    }

    /// Fill metadata that might be missing on notes created before these fields
    /// existed. The return value tells callers whether they should save.
    @discardableResult
    func repairMissingMetadataIfNeeded() -> Bool {
        var changed = false

        if uuid == nil {
            uuid = UUID()
            changed = true
        }

        if Note.cleanTitle(title) == nil {
            title = Note.makeAutomaticTitle(createdAt: created_at)
            changed = true
        }

        return changed
    }

    static func cleanTitle(_ title: String?) -> String? {
        guard let cleaned = title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !cleaned.isEmpty else {
            return nil
        }

        return cleaned
    }

    /// Generate a friendly fallback title.
    ///
    /// The title uses a random word plus local date/time, for example:
    ///
    ///     ember 2026-06-15 12:04
    static func makeAutomaticTitle(createdAt date: Date = .now) -> String {
        let word = automaticTitleWords.randomElement() ?? "note"
        return "\(word) \(titleDateFormatter.string(from: date))"
    }

    private static let automaticTitleWords = [
        "amber", "atlas", "birch", "bright", "cedar", "comet", "ember", "fern",
        "harbor", "juniper", "lumen", "meadow", "nova", "orbit", "pebble", "raven",
        "river", "sage", "signal", "spruce", "thread", "violet", "willow", "zephyr"
    ]

    private static let titleDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
}
