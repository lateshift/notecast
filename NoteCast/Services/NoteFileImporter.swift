//
//  NoteFileImporter.swift
//  NoteCast
//
//  Imports Markdown files opened by Finder/Dock into the NoteCast database.
//

import Foundation
import SwiftData
import UniformTypeIdentifiers

/// Creates unfiled notes from Markdown files the user opens with NoteCast.
///
/// This lives outside `NoteCastAppDelegate` so the AppKit delegate stays small
/// and the import behavior can be unit-tested without launching Finder or the
/// Dock. Imported notes use the same shared SwiftData model as the app and CLI.
struct NoteFileImporter {
    private let modelContainer: ModelContainer

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    @discardableResult
    func importMarkdownFiles(at urls: [URL]) -> NoteFileImportSummary {
        let context = ModelContext(modelContainer)
        var importedNoteIDs: [UUID] = []
        var importedNotificationPayloads: [NoteAddedNotificationPayload] = []
        var failures: [NoteFileImportFailure] = []

        for url in urls {
            do {
                guard Self.isSupportedMarkdownFile(url) else {
                    throw NoteFileImportError.unsupportedFileType
                }

                let note = try Self.makeNote(from: url)
                context.insert(note)

                if let noteID = note.uuid {
                    importedNoteIDs.append(noteID)
                }
                importedNotificationPayloads.append(NoteAddedNotificationPayload(note: note))
            } catch {
                failures.append(NoteFileImportFailure(url: url, errorDescription: Self.errorDescription(for: error)))
            }
        }

        guard !importedNoteIDs.isEmpty else {
            return NoteFileImportSummary(
                importedNoteIDs: [],
                importedNotificationPayloads: [],
                failures: failures
            )
        }

        do {
            try context.save()
            return NoteFileImportSummary(
                importedNoteIDs: importedNoteIDs,
                importedNotificationPayloads: importedNotificationPayloads,
                failures: failures
            )
        } catch {
            let saveFailure = NoteFileImportFailure(
                url: nil,
                errorDescription: "Could not save imported notes: \(String(describing: error))"
            )
            return NoteFileImportSummary(
                importedNoteIDs: [],
                importedNotificationPayloads: [],
                failures: failures + [saveFailure]
            )
        }
    }

    private static func makeNote(from url: URL) throws -> Note {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let resourceValues = try url.resourceValues(forKeys: [.isRegularFileKey])
        guard resourceValues.isRegularFile == true else {
            throw NoteFileImportError.notARegularFile
        }

        let text = try markdownText(from: url)
        let createdAt = Date.now

        return Note(
            title: title(for: url, createdAt: createdAt),
            text: text,
            mimetype: NotePersistence.defaultMimetype,
            created_at: createdAt,
            created_via: NotePersistence.createdViaApp
        )
    }

    private static func markdownText(from url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let encodings: [String.Encoding] = [.utf8, .utf16, .utf16LittleEndian, .utf16BigEndian, .macOSRoman]

        for encoding in encodings {
            if let text = String(data: data, encoding: encoding) {
                return text
            }
        }

        throw NoteFileImportError.unreadableTextEncoding
    }

    private static func title(for url: URL, createdAt: Date) -> String {
        let filenameTitle = url.deletingPathExtension().lastPathComponent
        return Note.cleanTitle(filenameTitle) ?? Note.makeAutomaticTitle(createdAt: createdAt)
    }

    private static func isSupportedMarkdownFile(_ url: URL) -> Bool {
        if supportedMarkdownExtensions.contains(url.pathExtension.lowercased()) {
            return true
        }

        guard let contentType = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType else {
            return false
        }

        if contentType.identifier == markdownTypeIdentifier {
            return true
        }

        guard let markdownType = UTType(markdownTypeIdentifier) else {
            return false
        }

        return contentType.conforms(to: markdownType)
    }

    private static func errorDescription(for error: Error) -> String {
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription {
            return description
        }

        return error.localizedDescription
    }

    private static let markdownTypeIdentifier = "net.daringfireball.markdown"

    private static let supportedMarkdownExtensions: Set<String> = [
        "md",
        "markdown",
        "mdown",
        "mdwn",
        "mkd"
    ]
}

struct NoteFileImportSummary {
    let importedNoteIDs: [UUID]
    let importedNotificationPayloads: [NoteAddedNotificationPayload]
    let failures: [NoteFileImportFailure]

    var didImportNotes: Bool {
        !importedNotificationPayloads.isEmpty
    }
}

struct NoteFileImportFailure {
    let url: URL?
    let errorDescription: String
}

private enum NoteFileImportError: LocalizedError {
    case notARegularFile
    case unreadableTextEncoding
    case unsupportedFileType

    var errorDescription: String? {
        switch self {
        case .notARegularFile:
            return "The dropped item is not a regular file."
        case .unreadableTextEncoding:
            return "The file could not be read as text."
        case .unsupportedFileType:
            return "Only Markdown files can be imported."
        }
    }
}
