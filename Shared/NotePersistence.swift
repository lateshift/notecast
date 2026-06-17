//
//  NotePersistence.swift
//  NoteCast
//
//  The small persistence helper used by both the app and the CLI.
//

import Foundation
import SwiftData

/// All constants and setup code for the SwiftData store live here.
///
/// SwiftData's default location depends on the running app/binary. That would
/// make the app and the `cast` CLI write to different databases. To
/// keep things simple and predictable we explicitly store everything in:
///
///     ~/Library/Application Support/NoteCast/NoteCast.store
///
/// The app target has sandboxing disabled so the app and the CLI can both use
/// that same normal user-library location.
enum NotePersistence {
    static let defaultMimetype = "text/markdown"
    static let createdViaApp = "APP"
    static let createdViaCLI = "CLI"

    /// Build the schema from the model classes SwiftData should manage.
    ///
    /// `NoteFolder` is listed beside `Note` because app and CLI both compile the
    /// shared model layer. The CLI does not need folder commands to keep writing
    /// unfiled notes, but it must still know the complete schema when opening
    /// the same SwiftData store as the app.
    static var schema: Schema {
        Schema([Note.self, NoteFolder.self])
    }

    /// Directory that contains the persistent store.
    static func storeDirectoryURL() throws -> URL {
        guard let applicationSupportURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw NotePersistenceError.missingApplicationSupportDirectory
        }

        let directoryURL = applicationSupportURL.appendingPathComponent("NoteCast", isDirectory: true)

        // `createDirectory` with `withIntermediateDirectories: true` is safe if
        // the directory already exists; it simply leaves it in place.
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )

        return directoryURL
    }

    /// Full file URL for SwiftData's store.
    static func storeURL() throws -> URL {
        if let url = try storeURLFromEnvironment() {
            return url
        }

        if let url = try storeURLForUnitTests() {
            return url
        }

        return try storeDirectoryURL().appendingPathComponent("NoteCast.store")
    }

    /// Test hook: lets UI tests point the app at an isolated temporary store.
    ///
    /// Production launches do not set this environment variable, so they keep
    /// using the normal Application Support location above. Tests set it to a
    /// temp path so they never read or damage the user's real notes.
    private static func storeURLFromEnvironment() throws -> URL? {
        guard let path = ProcessInfo.processInfo.environment["NOTECAST_STORE_URL"],
              !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let url = URL(fileURLWithPath: path)
        let directoryURL = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )

        return url
    }

    /// Unit-test safety net.
    ///
    /// Xcode's regular unit-test target launches the app as a test host before
    /// individual tests can set environment variables. When that happens we use
    /// a process-specific temp store instead of the user's real NoteCast store.
    /// UI tests still use `NOTECAST_STORE_URL`, which is checked first above.
    private static func storeURLForUnitTests() throws -> URL? {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil else {
            return nil
        }

        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("NoteCastUnitTests-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )

        return directoryURL.appendingPathComponent("NoteCast.store")
    }

    /// Create a SwiftData container using the shared store URL.
    ///
    /// `ModelContainer` is the top-level SwiftData object. Think of it as the
    /// connection to the database. Views and command line code create
    /// `ModelContext`s from this container to insert, fetch, update, and delete
    /// notes.
    static func makeModelContainer() throws -> ModelContainer {
        let schema = NotePersistence.schema
        let configuration = ModelConfiguration(
            "NoteCast",
            schema: schema,
            url: try storeURL(),
            cloudKitDatabase: .none
        )

        return try ModelContainer(for: schema, configurations: [configuration])
    }

    /// Convenience used by the app startup path. If the app cannot open its
    /// database, crashing early gives a clear Xcode error instead of leaving the
    /// app half-running with no storage.
    static func makeModelContainerOrCrash() -> ModelContainer {
        do {
            return try makeModelContainer()
        } catch {
            fatalError("Could not create NoteCast SwiftData store: \(error)")
        }
    }
}

enum NotePersistenceError: LocalizedError {
    case missingApplicationSupportDirectory

    var errorDescription: String? {
        switch self {
        case .missingApplicationSupportDirectory:
            return "Could not find the user's Application Support directory."
        }
    }
}
