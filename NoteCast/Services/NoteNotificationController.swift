//
//  NoteNotificationController.swift
//  NoteCast
//
//  App-layer local notifications for successful note creation.
//

import Combine
import Foundation
import UserNotifications

struct NoteAddedNotificationPayload: Equatable, Sendable {
    let id: UUID?
    let title: String
    let preview: String?

    init(id: UUID?, title: String, preview: String?) {
        self.id = id
        self.title = title
        self.preview = preview
    }

    init(note: Note, includePreview: Bool = true) {
        self.init(
            id: note.uuid,
            title: note.displayTitle,
            preview: includePreview ? note.bodyPreview : nil
        )
    }
}

@MainActor
protocol NoteNotificationScheduling: AnyObject {
    func requestAuthorizationIfNeeded()
    func notifyNoteAdded(id: UUID?, title: String, preview: String?)
    func notifyNotesImported(_ notes: [NoteAddedNotificationPayload])
}

extension NoteNotificationScheduling {
    func notifyNoteAdded(_ payload: NoteAddedNotificationPayload) {
        notifyNoteAdded(id: payload.id, title: payload.title, preview: payload.preview)
    }
}

@MainActor
final class NoteNotificationController: NSObject, ObservableObject, NoteNotificationScheduling {
    private let center: UNUserNotificationCenter
    private var didRequestAuthorization = false

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
        super.init()
    }

    func requestAuthorizationIfNeeded() {
        guard !didRequestAuthorization else { return }
        didRequestAuthorization = true

        Task { [center] in
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .notDetermined else { return }

            do {
                _ = try await center.requestAuthorization(options: [.alert, .sound])
            } catch {
                NSLog("NoteCast could not request notification authorization: %@", String(describing: error))
            }
        }
    }

    func notifyNoteAdded(id: UUID?, title: String, preview: String?) {
        let content = UNMutableNotificationContent()
        content.title = "Note added"
        content.body = Self.notificationBody(forTitle: title)
        content.sound = .default

        var userInfo: [String: String] = ["event": "noteAdded"]
        if let id {
            userInfo["noteID"] = id.uuidString
        }
        content.userInfo = userInfo

        let identifier = id.map { "note-added.\($0.uuidString)" } ?? "note-added.\(UUID().uuidString)"
        schedule(content: content, identifier: identifier)
    }

    func notifyNotesImported(_ notes: [NoteAddedNotificationPayload]) {
        guard !notes.isEmpty else { return }

        if notes.count == 1, let note = notes.first {
            notifyNoteAdded(note)
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "\(notes.count) notes imported"
        content.body = "Added to NoteCast"
        content.sound = .default
        content.userInfo = [
            "event": "notesImported",
            "noteIDs": notes.compactMap { $0.id?.uuidString }
        ]

        let firstID = notes.compactMap(\.id).first?.uuidString ?? UUID().uuidString
        schedule(content: content, identifier: "notes-imported.\(firstID).\(notes.count)")
    }

    private func schedule(content: UNNotificationContent, identifier: String) {
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)

        Task { [center] in
            let settings = await center.notificationSettings()
            switch settings.authorizationStatus {
            case .authorized, .provisional:
                break
            case .notDetermined:
                do {
                    guard try await center.requestAuthorization(options: [.alert, .sound]) else {
                        return
                    }
                } catch {
                    NSLog("NoteCast could not request notification authorization: %@", String(describing: error))
                    return
                }
            case .denied:
                return
            @unknown default:
                return
            }

            do {
                try await center.add(request)
            } catch {
                NSLog("NoteCast could not schedule note notification: %@", String(describing: error))
            }
        }
    }

    private static func notificationBody(forTitle title: String) -> String {
        let cleanedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedTitle.isEmpty else { return "Untitled note" }
        return cleanedTitle
    }
}

@MainActor
final class NoOpNoteNotificationScheduler: NoteNotificationScheduling {
    func requestAuthorizationIfNeeded() {}

    func notifyNoteAdded(id: UUID?, title: String, preview: String?) {}

    func notifyNotesImported(_ notes: [NoteAddedNotificationPayload]) {}
}
