//
//  NoteExternalChangeSignal.swift
//  NoteCast
//
//  Cross-process refresh signal shared by the app and the CLI.
//

import Foundation

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

        let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    /// Write a new durable revision token and return it.
    @discardableResult
    static func writeRevisionFile() throws -> String {
        let token = "\(Date().timeIntervalSinceReferenceDate) \(UUID().uuidString)"
        let url = try revisionFileURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try (token + "\n").write(to: url, atomically: true, encoding: .utf8)
        return token
    }

    /// Publish a best-effort cross-process note-change signal.
    ///
    /// This is deliberately non-throwing. Once the note mutation has saved, a
    /// refresh notification failure should not make `cast` report the whole
    /// command as failed.
    static func publishNotesDidChange() {
        _ = try? writeRevisionFile()

        DistributedNotificationCenter.default().postNotificationName(
            notificationName,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }
}
