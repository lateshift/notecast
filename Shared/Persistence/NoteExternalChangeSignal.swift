//
//  NoteExternalChangeSignal.swift
//  NoteCast
//
//  Cross-process refresh signal shared by the app and the CLI.
//

import Foundation

/// Durable cross-process event written by app/CLI store mutations.
///
/// Older NoteCast builds wrote only a plain revision token to the revision file.
/// `NoteExternalChangeSignal.currentRevisionToken()` still understands that old
/// format, while newer builds can decode this richer event and distinguish a
/// newly added note from updates, deletes, and other generic refreshes.
struct NoteExternalChangeEvent: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case noteAdded
        case notesChanged
    }

    let kind: Kind
    let revisionToken: String
    let noteID: UUID?
    let title: String?
    let preview: String?

    init(
        kind: Kind,
        revisionToken: String,
        noteID: UUID? = nil,
        title: String? = nil,
        preview: String? = nil
    ) {
        self.kind = kind
        self.revisionToken = revisionToken
        self.noteID = noteID
        self.title = title
        self.preview = preview
    }
}

/// Lets a separate NoteCast process announce that it changed the shared store.
///
/// The `cast` CLI can write notes while the NoteCast app is already running.
/// SwiftData does not automatically notify another process that its persistent
/// store changed, so the CLI writes a tiny revision file and posts a distributed
/// notification after successful mutations. The app uses the notification for a
/// quick wake-up and the revision file as a durable fallback for missed events.
enum NoteExternalChangeSignal {
    static let notificationName = Notification.Name("com.spacks.NoteCast.notesDidChange")
    static let revisionFileName = "NoteCast.revision"

    /// Directory that contains the active SwiftData store and revision file.
    ///
    /// This intentionally derives from `storeURL()` instead of the production
    /// Application Support directory directly, so UI/unit tests that set
    /// `NOTECAST_STORE_URL` get an isolated revision file too.
    static func revisionDirectoryURL() throws -> URL {
        try NotePersistence.storeURL().deletingLastPathComponent()
    }

    static func revisionFileURL() throws -> URL {
        try revisionDirectoryURL().appendingPathComponent(revisionFileName)
    }

    /// Read the latest durable revision token, if one has been written.
    static func currentRevisionToken() -> String? {
        guard let url = try? revisionFileURL(),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }

        return revisionToken(fromRevisionFileText: text)
    }

    /// Read the latest typed event, if the revision file uses the JSON format.
    static func currentRevisionEvent() -> NoteExternalChangeEvent? {
        guard let url = try? revisionFileURL(),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }

        return event(fromRevisionFileText: text)
    }

    static func revisionToken(fromRevisionFileText text: String) -> String? {
        if let event = event(fromRevisionFileText: text) {
            return event.revisionToken
        }

        let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    static func event(fromRevisionFileText text: String) -> NoteExternalChangeEvent? {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty,
              let data = cleaned.data(using: .utf8) else {
            return nil
        }

        return try? JSONDecoder().decode(NoteExternalChangeEvent.self, from: data)
    }

    /// Write a new durable revision token and return it.
    @discardableResult
    static func writeRevisionFile() throws -> String {
        try writeRevisionEvent(kind: .notesChanged).revisionToken
    }

    /// Write a typed durable revision event and return it.
    @discardableResult
    static func writeRevisionEvent(
        kind: NoteExternalChangeEvent.Kind,
        noteID: UUID? = nil,
        title: String? = nil,
        preview: String? = nil
    ) throws -> NoteExternalChangeEvent {
        let token = "\(Date().timeIntervalSinceReferenceDate) \(UUID().uuidString)"
        let event = NoteExternalChangeEvent(
            kind: kind,
            revisionToken: token,
            noteID: noteID,
            title: title,
            preview: preview
        )
        let url = try revisionFileURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(event)
        try data.write(to: url, options: .atomic)
        return event
    }

    /// Publish a best-effort cross-process note-change signal.
    ///
    /// This is deliberately non-throwing. Once the note mutation has saved, a
    /// refresh notification failure should not make `cast` report the whole
    /// command as failed.
    static func publishNotesDidChange() {
        _ = try? writeRevisionEvent(kind: .notesChanged)

        postDistributedChangeNotification()
    }

    /// Publish a note-added event so a running app can show a creation-only
    /// notification without treating updates or deletes as new notes.
    static func publishNoteAdded(noteID: UUID?, title: String?, preview: String?) {
        _ = try? writeRevisionEvent(
            kind: .noteAdded,
            noteID: noteID,
            title: title,
            preview: preview
        )

        postDistributedChangeNotification()
    }

    private static func postDistributedChangeNotification() {
        DistributedNotificationCenter.default().postNotificationName(
            notificationName,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }
}
