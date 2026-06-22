//
//  NoteFolder.swift
//  NoteCast
//
//  Shared folder model used by the full app window and the `cast` tool.
//

import Foundation
import SwiftData

/// A user-created folder that can contain many notes.
///
/// The model is deliberately small. Folders are metadata for organizing notes;
/// note text remains in `Note`, and a note can also live with no folder at all.
/// Keeping the relationship optional on `Note` gives old databases a safe
/// migration path and gives quick-captured notes an "Unfiled" home.
@Model
final class NoteFolder {
    /// Stable id used by the SwiftUI sidebar and future automation.
    ///
    /// Like `Note.uuid`, this is optional in the stored schema so metadata can
    /// be repaired lazily if a future migration ever needs it.
    var uuid: UUID?

    /// User-facing folder name.
    var name: String?

    /// Folder creation timestamp.
    var created_at: Date

    /// Last time the folder's own metadata changed.
    var updated_at: Date

    /// Notes assigned to this folder.
    ///
    /// The inverse relationship is `Note.folder`. The `.nullify` delete rule
    /// means deleting a folder does not delete its notes; SwiftData simply clears
    /// the notes' `folder` pointer so they return to the Unfiled area.
    @Relationship(deleteRule: .nullify, inverse: \Note.folder)
    var notes: [Note]

    init(
        name: String,
        created_at: Date = .now,
        updated_at: Date? = nil
    ) {
        self.uuid = UUID()
        self.name = NoteFolder.cleanName(name) ?? "Folder"
        self.created_at = created_at
        self.updated_at = updated_at ?? created_at
        self.notes = []
    }
}

extension NoteFolder {
    /// Name that is always safe to show in the sidebar.
    var displayName: String {
        NoteFolder.cleanName(name) ?? "Folder"
    }

    /// Stable string id for drag/drop and debugging.
    var stableID: String {
        uuid?.uuidString ?? "missing-folder-uuid"
    }

    /// Repair lazily-added metadata for migration safety.
    @discardableResult
    func repairMissingMetadataIfNeeded() -> Bool {
        var changed = false

        if uuid == nil {
            uuid = UUID()
            changed = true
        }

        if NoteFolder.cleanName(name) == nil {
            name = "Folder"
            changed = true
        }

        return changed
    }

    static func cleanName(_ name: String?) -> String? {
        guard let cleaned = name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !cleaned.isEmpty else {
            return nil
        }

        return cleaned
    }
}
