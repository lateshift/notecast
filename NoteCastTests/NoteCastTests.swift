//
//  NoteCastTests.swift
//  NoteCastTests
//

import Foundation
import SwiftData
import Testing
@testable import NoteCast

struct NoteCastTests {

    @MainActor
    @Test func markdownFileImporterCreatesNoteFromFileContents() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NoteCastImportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let storeURL = temporaryDirectory.appendingPathComponent("NoteCast.store")
        let container = try makeTestModelContainer(storeURL: storeURL)
        let markdownURL = temporaryDirectory.appendingPathComponent("Dragged Note.md")
        let markdown = """
        # Dragged note

        This body came from a Markdown file.
        """
        try markdown.write(to: markdownURL, atomically: true, encoding: .utf8)

        let summary = NoteFileImporter(modelContainer: container).importMarkdownFiles(at: [markdownURL])
        #expect(summary.importedNoteIDs.count == 1)
        #expect(summary.importedNotificationPayloads.count == 1)
        #expect(summary.importedNotificationPayloads.first?.id == summary.importedNoteIDs.first)
        #expect(summary.importedNotificationPayloads.first?.title == "Dragged Note")
        #expect(summary.failures.isEmpty)

        let context = ModelContext(container)
        let notes = try context.fetch(FetchDescriptor<Note>())
        #expect(notes.count == 1)
        #expect(notes.first?.displayTitle == "Dragged Note")
        #expect(notes.first?.text == markdown)
        #expect(notes.first?.mimetype == NotePersistence.defaultMimetype)
        #expect(notes.first?.created_via == NotePersistence.createdViaApp)
        #expect(notes.first?.folder == nil)
    }

    @MainActor
    @Test func noteBrowserStoreCreateNoteReturnsNotificationPayload() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NoteCastBrowserStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let storeURL = temporaryDirectory.appendingPathComponent("NoteCast.store")
        let container = try makeTestModelContainer(storeURL: storeURL)
        let store = NoteBrowserStore(modelContainer: container)
        store.reload()

        let payload = try #require(store.createNote())
        #expect(payload.id != nil)
        #expect(!payload.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(payload.preview == nil)

        let context = ModelContext(container)
        let notes = try context.fetch(FetchDescriptor<Note>())
        #expect(notes.count == 1)
        #expect(notes.first?.uuid == payload.id)
        #expect(notes.first?.displayTitle == payload.title)
    }

    @Test func externalChangeSignalParsesTypedEventsAndLegacyTokens() throws {
        let noteID = try #require(UUID(uuidString: "7D855790-9F45-4BDB-80D7-2B91E905E701"))
        let event = NoteExternalChangeEvent(
            kind: .noteAdded,
            revisionToken: "typed-token",
            noteID: noteID,
            title: "Typed event",
            preview: "Preview"
        )
        let eventData = try JSONEncoder().encode(event)
        let eventText = try #require(String(data: eventData, encoding: .utf8))

        #expect(NoteExternalChangeSignal.event(fromRevisionFileText: eventText) == event)
        #expect(NoteExternalChangeSignal.revisionToken(fromRevisionFileText: eventText) == "typed-token")
        #expect(NoteExternalChangeSignal.event(fromRevisionFileText: "legacy-token\n") == nil)
        #expect(NoteExternalChangeSignal.revisionToken(fromRevisionFileText: "legacy-token\n") == "legacy-token")
        #expect(NoteExternalChangeSignal.revisionToken(fromRevisionFileText: " \n ") == nil)
    }

    @Test func castMutationsWriteTypedExternalChangeEvents() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NoteCastCastEventTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let storeURL = temporaryDirectory.appendingPathComponent("NoteCast.store")
        let add = try runCast(
            ["add", "--title", "CLI event title", "--json", "CLI event body"],
            storeURL: storeURL
        )
        try requireSuccess(add)
        let addedRecord = try decodeRecord(from: add.stdout)
        let addedEvent = try readRevisionEvent(forStoreAt: storeURL)
        #expect(addedEvent.kind == .noteAdded)
        #expect(addedEvent.noteID?.uuidString == addedRecord.id)
        #expect(addedEvent.title == "CLI event title")
        #expect(addedEvent.preview == "CLI event body")

        let update = try runCast(
            ["update", addedRecord.id, "--json", "updated body"],
            storeURL: storeURL
        )
        try requireSuccess(update)
        let updatedEvent = try readRevisionEvent(forStoreAt: storeURL)
        #expect(updatedEvent.kind == .notesChanged)
        #expect(updatedEvent.noteID == nil)
        #expect(updatedEvent.title == nil)

        let delete = try runCast(["delete", addedRecord.id, "--json"], storeURL: storeURL)
        try requireSuccess(delete)
        let deletedEvent = try readRevisionEvent(forStoreAt: storeURL)
        #expect(deletedEvent.kind == .notesChanged)
        #expect(deletedEvent.noteID == nil)
        #expect(deletedEvent.title == nil)
    }

    @Test func pipedQuickAddFencesCommandOutputButAutomationStaysExact() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NoteCastCastTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let storeURL = temporaryDirectory.appendingPathComponent("NoteCast.store")
        let commandOutput = "alpha\nbeta"

        let quickAdd = try runCast([], stdin: commandOutput, storeURL: storeURL)
        try requireSuccess(quickAdd)
        let quickID = quickAdd.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(!quickID.isEmpty)

        let quickRead = try runCast(["read", quickID, "--json"], storeURL: storeURL)
        try requireSuccess(quickRead)
        let quickRecord = try decodeRecord(from: quickRead.stdout)
        #expect(quickRecord.text == "```\nalpha\nbeta\n```")

        let jsonQuickAdd = try runCast(["--json"], stdin: commandOutput, storeURL: storeURL)
        try requireSuccess(jsonQuickAdd)
        let jsonQuickRecord = try decodeRecord(from: jsonQuickAdd.stdout)
        #expect(jsonQuickRecord.text == commandOutput)

        let explicitAdd = try runCast(
            ["add", "--title", "Agent exact body", "--json"],
            stdin: commandOutput,
            storeURL: storeURL
        )
        try requireSuccess(explicitAdd)
        let explicitRecord = try decodeRecord(from: explicitAdd.stdout)
        #expect(explicitRecord.text == commandOutput)
    }

    private func runCast(
        _ arguments: [String],
        stdin: String? = nil,
        storeURL: URL
    ) throws -> CastProcessResult {
        let process = Process()
        process.executableURL = try castExecutableURL()
        process.arguments = arguments

        var environment = ProcessInfo.processInfo.environment
        environment["NOTECAST_STORE_URL"] = storeURL.path
        process.environment = environment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let input: Pipe?
        if stdin != nil {
            let pipe = Pipe()
            process.standardInput = pipe
            input = pipe
        } else {
            input = nil
        }

        try process.run()

        if let stdin, let input {
            input.fileHandleForWriting.write(Data(stdin.utf8))
            input.fileHandleForWriting.closeFile()
        }

        process.waitUntilExit()

        return CastProcessResult(
            terminationStatus: process.terminationStatus,
            stdout: String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            stderr: String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        )
    }

    private func castExecutableURL() throws -> URL {
        let candidates = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/bin/cast"),
            Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("cast")
        ]

        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }

        throw CastTestError.missingCastExecutable(candidates.map(\.path).joined(separator: ", "))
    }

    private func decodeRecord(from json: String) throws -> CastNoteRecord {
        try JSONDecoder().decode(CastNoteRecord.self, from: Data(json.utf8))
    }

    private func readRevisionEvent(forStoreAt storeURL: URL) throws -> NoteExternalChangeEvent {
        let revisionURL = storeURL
            .deletingLastPathComponent()
            .appendingPathComponent(NoteExternalChangeSignal.revisionFileName)
        let text = try String(contentsOf: revisionURL, encoding: .utf8)
        return try #require(NoteExternalChangeSignal.event(fromRevisionFileText: text))
    }

    private func requireSuccess(_ result: CastProcessResult) throws {
        guard result.terminationStatus == 0 else {
            throw CastTestError.commandFailed(result)
        }
    }

    private func makeTestModelContainer(storeURL: URL) throws -> ModelContainer {
        let schema = NotePersistence.schema
        let configuration = ModelConfiguration(
            "NoteCastImportTest",
            schema: schema,
            url: storeURL,
            cloudKitDatabase: .none
        )

        return try ModelContainer(for: schema, configurations: [configuration])
    }
}

private struct CastProcessResult: Sendable {
    let terminationStatus: Int32
    let stdout: String
    let stderr: String
}

private struct CastNoteRecord: Decodable {
    let id: String
    let text: String?
}

private enum CastTestError: Error, CustomStringConvertible {
    case missingCastExecutable(String)
    case commandFailed(CastProcessResult)

    var description: String {
        switch self {
        case .missingCastExecutable(let paths):
            return "Could not find cast executable. Checked: \(paths)"
        case .commandFailed(let result):
            return "cast exited \(result.terminationStatus)\nstdout:\n\(result.stdout)\nstderr:\n\(result.stderr)"
        }
    }
}
