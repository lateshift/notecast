//
//  main.swift
//  cast
//
//  Command line note capture tool.
//
//  The command intentionally stays dependency-free and script-friendly. Humans
//  can use the short text output, while agents should pass `--json` for stable
//  machine-readable results.
//

import Darwin
import Foundation
import SwiftData

// MARK: - Small terminal helpers

private func printLine(_ message: String = "") {
    FileHandle.standardOutput.write(Data((message + "\n").utf8))
}

private func eprint(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

private func stdinIsTerminal() -> Bool {
    isatty(STDIN_FILENO) == 1
}

/// Read piped stdin, but never block an interactive terminal waiting for input.
private func readPipedStdin() -> String? {
    guard !stdinIsTerminal() else { return nil }
    let data = FileHandle.standardInput.readDataToEndOfFile()
    return String(data: data, encoding: .utf8)
}

private func nonEmpty(_ text: String?) -> String? {
    guard let cleaned = text?.trimmingCharacters(in: .whitespacesAndNewlines),
          !cleaned.isEmpty else {
        return nil
    }

    return cleaned
}

// MARK: - Errors

private struct CommandError: Error, CustomStringConvertible {
    let description: String

    static func message(_ description: String) -> CommandError {
        CommandError(description: description)
    }
}

// MARK: - JSON output

/// JSON shape used by `cast --json` commands.
///
/// The field names mirror the SwiftData model where practical, and use `id` for
/// the stable UUID that agents should pass back to `read`, `update`, or `delete`.
private struct NoteRecord: Encodable {
    let id: String
    let title: String
    let mimetype: String
    let created_at: Date
    let updated_at: Date
    let created_via: String
    let preview: String
    let text: String?

    init(note: Note, includeText: Bool = false) {
        self.id = note.stableID
        self.title = note.displayTitle
        self.mimetype = note.mimetype
        self.created_at = note.created_at
        self.updated_at = note.updated_at
        self.created_via = note.created_via
        self.preview = note.bodyPreview
        self.text = includeText ? note.text : nil
    }
}

private func printJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(value)
    FileHandle.standardOutput.write(data)
    printLine()
}

// MARK: - Command implementation

private final class CastCommand {
    private let arguments: [String]
    private let container: ModelContainer
    private let context: ModelContext

    init(arguments: [String]) throws {
        self.arguments = arguments
        self.container = try NotePersistence.makeModelContainer()
        self.context = ModelContext(container)
    }

    func run() throws {
        guard let command = arguments.first else {
            try add(arguments: [], fencePipedInput: true)
            return
        }

        let rest = Array(arguments.dropFirst())

        switch command {
        case "help", "--help", "-h":
            printUsage()
        case "add", "new", "create":
            try add(arguments: rest)
        case "list", "ls":
            try list(arguments: rest)
        case "search", "find":
            try search(arguments: rest)
        case "read", "show", "cat":
            try read(arguments: rest)
        case "update", "edit":
            try update(arguments: rest)
        case "delete", "rm":
            try delete(arguments: rest)
        case "path", "store":
            printLine(try NotePersistence.storeURL().path)
        default:
            // Backward-compatible quick add:
            //
            //     cast remember to buy milk
            //
            // Piped input with no command still works too. Bare piped quick
            // adds are human-friendly command-output captures, so they are
            // saved as Markdown code blocks. Explicit `cast add` and JSON
            // quick-adds keep piped text exact for scripts and agents.
            //
            //     ls -1 | cast
            try add(arguments: arguments, fencePipedInput: true)
        }
    }

    // MARK: Add

    private func add(arguments: [String], fencePipedInput: Bool = false) throws {
        var title: String?
        var mimetype = NotePersistence.defaultMimetype
        var wantsJSON = false
        var textParts: [String] = []

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--title", "-t":
                index += 1
                guard index < arguments.count else { throw CommandError.message("--title needs a value") }
                title = arguments[index]
            case "--mime", "--mimetype", "-m":
                index += 1
                guard index < arguments.count else { throw CommandError.message("--mime needs a value") }
                mimetype = arguments[index]
            case "--json":
                wantsJSON = true
            case "--help", "-h":
                printAddUsage()
                return
            case "--":
                textParts.append(contentsOf: arguments.dropFirst(index + 1))
                index = arguments.count
                continue
            default:
                textParts.append(argument)
            }
            index += 1
        }

        let argumentText = nonEmpty(textParts.joined(separator: " "))
        let pipedText = readPipedStdin().flatMap(nonEmpty)
        let shouldFencePipedInput = fencePipedInput && !wantsJSON
        let text: String?
        if let argumentText {
            text = argumentText
        } else if let pipedText {
            text = shouldFencePipedInput ? fencedMarkdownCodeBlock(pipedText) : pipedText
        } else {
            text = nil
        }

        guard let text else {
            throw CommandError.message("nothing to add; pass text arguments or pipe text into cast")
        }

        let note = Note(
            title: title,
            text: text,
            mimetype: mimetype,
            created_via: NotePersistence.createdViaCLI
        )
        context.insert(note)
        try context.save()
        NoteExternalChangeSignal.publishNoteAdded(
            noteID: note.uuid,
            title: note.displayTitle,
            preview: note.bodyPreview
        )

        if wantsJSON {
            try printJSON(NoteRecord(note: note, includeText: true))
        } else {
            printLine(note.stableID)
        }
    }

    // MARK: List / search

    private func list(arguments: [String], forcedQuery: String? = nil) throws {
        var limit = 10
        var wantsJSON = false
        var includeText = false
        var query = forcedQuery

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--limit", "-n":
                index += 1
                guard index < arguments.count, let parsedLimit = Int(arguments[index]), parsedLimit > 0 else {
                    throw CommandError.message("--limit needs a positive number")
                }
                limit = parsedLimit
            case "--all":
                limit = Int.max
            case "--json":
                wantsJSON = true
            case "--text":
                includeText = true
            case "--query", "-q":
                index += 1
                guard index < arguments.count else { throw CommandError.message("--query needs a value") }
                query = arguments[index]
            case "--help", "-h":
                printListUsage()
                return
            default:
                // `cast list something` is treated as a search query for
                // convenience. Agents may prefer explicit `--query`.
                query = ([query, argument].compactMap { $0 }).joined(separator: " ")
            }
            index += 1
        }

        let notes = try fetchNotes(limit: limit, query: query)

        if wantsJSON {
            try printJSON(notes.map { NoteRecord(note: $0, includeText: includeText) })
        } else if notes.isEmpty {
            printLine("No notes found")
        } else {
            for note in notes {
                printLine("\(shortID(note))\t\(note.displayTitle)\t\(plainDate(note.created_at))\t\(note.created_via)\t\(note.bodyPreview)")
            }
        }
    }

    private func search(arguments: [String]) throws {
        var queryParts: [String] = []
        var listArguments: [String] = []

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--limit", "-n", "--query", "-q":
                listArguments.append(argument)
                index += 1
                guard index < arguments.count else {
                    throw CommandError.message("\(argument) needs a value")
                }
                listArguments.append(arguments[index])
            case "--all", "--json", "--text", "--help", "-h":
                listArguments.append(argument)
            default:
                queryParts.append(argument)
            }
            index += 1
        }

        let query = queryParts.isEmpty ? nil : queryParts.joined(separator: " ")
        try list(arguments: listArguments, forcedQuery: query)
    }

    // MARK: Read

    private func read(arguments: [String]) throws {
        var wantsJSON = false
        var rawTextOnly = false
        var id: String?

        for argument in arguments {
            switch argument {
            case "--json":
                wantsJSON = true
            case "--raw":
                rawTextOnly = true
            case "--help", "-h":
                printReadUsage()
                return
            default:
                if id == nil {
                    id = argument
                } else {
                    throw CommandError.message("read accepts one note id")
                }
            }
        }

        guard let id else { throw CommandError.message("read needs a note id") }
        let note = try findNote(matching: id)

        if wantsJSON {
            try printJSON(NoteRecord(note: note, includeText: true))
        } else if rawTextOnly {
            printLine(note.text)
        } else {
            printLine("# \(note.displayTitle)")
            printLine("id: \(note.stableID)")
            printLine("created_at: \(plainDate(note.created_at))")
            printLine("updated_at: \(plainDate(note.updated_at))")
            printLine("created_via: \(note.created_via)")
            printLine("mimetype: \(note.mimetype)")
            printLine()
            printLine(note.text)
        }
    }

    // MARK: Update / delete

    private func update(arguments: [String]) throws {
        var id: String?
        var titleWasProvided = false
        var newTitle: String?
        var newMimetype: String?
        var wantsJSON = false
        var textParts: [String] = []

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--title", "-t":
                titleWasProvided = true
                index += 1
                guard index < arguments.count else { throw CommandError.message("--title needs a value") }
                newTitle = arguments[index]
            case "--mime", "--mimetype", "-m":
                index += 1
                guard index < arguments.count else { throw CommandError.message("--mime needs a value") }
                newMimetype = arguments[index]
            case "--json":
                wantsJSON = true
            case "--help", "-h":
                printUpdateUsage()
                return
            case "--":
                textParts.append(contentsOf: arguments.dropFirst(index + 1))
                index = arguments.count
                continue
            default:
                if id == nil {
                    id = argument
                } else {
                    textParts.append(argument)
                }
            }
            index += 1
        }

        guard let id else { throw CommandError.message("update needs a note id") }
        let note = try findNote(matching: id)

        var changed = false
        if titleWasProvided {
            note.title = Note.cleanTitle(newTitle) ?? Note.makeAutomaticTitle(createdAt: note.created_at)
            changed = true
        }

        if let newMimetype {
            note.mimetype = newMimetype
            changed = true
        }

        if let text = nonEmpty(textParts.joined(separator: " ")) ?? readPipedStdin().flatMap(nonEmpty) {
            note.text = text
            changed = true
        }

        guard changed else {
            throw CommandError.message("nothing to update; pass --title, --mime, text arguments, or piped text")
        }

        note.updated_at = .now
        note.repairMissingMetadataIfNeeded()
        try context.save()
        NoteExternalChangeSignal.publishNotesDidChange()

        if wantsJSON {
            try printJSON(NoteRecord(note: note, includeText: true))
        } else {
            printLine("updated \(note.stableID) \(note.displayTitle)")
        }
    }

    private func delete(arguments: [String]) throws {
        var wantsJSON = false
        var id: String?

        for argument in arguments {
            switch argument {
            case "--json":
                wantsJSON = true
            case "--help", "-h":
                printDeleteUsage()
                return
            default:
                if id == nil {
                    id = argument
                } else {
                    throw CommandError.message("delete accepts one note id")
                }
            }
        }

        guard let id else { throw CommandError.message("delete needs a note id") }
        let note = try findNote(matching: id)
        let record = NoteRecord(note: note, includeText: false)
        context.delete(note)
        try context.save()
        NoteExternalChangeSignal.publishNotesDidChange()

        if wantsJSON {
            try printJSON(record)
        } else {
            printLine("deleted \(record.id) \(record.title)")
        }
    }

    // MARK: Fetching and matching

    private func fetchNotes(limit: Int, query: String?) throws -> [Note] {
        var descriptor = FetchDescriptor<Note>(sortBy: [
            SortDescriptor(\Note.created_at, order: .reverse)
        ])

        // If there is no query, SwiftData can apply the limit directly. If we
        // are searching, fetch first then apply the limit after filtering.
        if query == nil, limit != Int.max {
            descriptor.fetchLimit = limit
        }

        var notes = try context.fetch(descriptor)
        try repairMetadata(in: notes)

        if let query = nonEmpty(query) {
            notes = NoteSearch.search(notes, query: query).map(\.note)
        }

        if limit == Int.max || notes.count <= limit {
            return notes
        }

        return Array(notes.prefix(limit))
    }

    private func findNote(matching userInput: String) throws -> Note {
        let needle = userInput.lowercased()
        let notes = try fetchNotes(limit: Int.max, query: nil)

        if let exactMatch = notes.first(where: { $0.stableID.lowercased() == needle }) {
            return exactMatch
        }

        let prefixMatches = notes.filter { $0.stableID.lowercased().hasPrefix(needle) }
        switch prefixMatches.count {
        case 1:
            return prefixMatches[0]
        case 0:
            throw CommandError.message("no note matches id '\(userInput)'")
        default:
            let choices = prefixMatches
                .prefix(5)
                .map { "\(shortID($0)) \($0.displayTitle)" }
                .joined(separator: ", ")
            throw CommandError.message("id '\(userInput)' is ambiguous: \(choices)")
        }
    }

    private func repairMetadata(in notes: [Note]) throws {
        var changed = false
        for note in notes {
            if note.repairMissingMetadataIfNeeded() {
                changed = true
            }
        }

        if changed {
            try context.save()
        }
    }

    // MARK: Formatting

    private func shortID(_ note: Note) -> String {
        String(note.stableID.prefix(8))
    }

    private func fencedMarkdownCodeBlock(_ text: String) -> String {
        let fence = markdownCodeFence(for: text)
        return "\(fence)\n\(text)\n\(fence)"
    }

    /// Pick a fence long enough that command output containing backticks still
    /// renders as one code block in Markdown.
    private func markdownCodeFence(for text: String) -> String {
        var longestBacktickRun = 0
        var currentBacktickRun = 0

        for scalar in text.unicodeScalars {
            if scalar.value == 96 {
                currentBacktickRun += 1
                longestBacktickRun = max(longestBacktickRun, currentBacktickRun)
            } else {
                currentBacktickRun = 0
            }
        }

        return String(repeating: "`", count: max(3, longestBacktickRun + 1))
    }

    private func plainDate(_ date: Date) -> String {
        Self.plainDateFormatter.string(from: date)
    }

    private static let plainDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    // MARK: Help text

    private func printUsage() {
        printLine("""
        cast - NoteCast command line notes

        Quick add:
          ls -1 | cast                    # saved as a Markdown code block
          cast remember to write release notes

        Exact piped Markdown for scripts/agents:
          echo "markdown note" | cast add --json

        Agent-friendly commands:
          cast add [--title TITLE] [--mime TYPE] [--json] [TEXT...]
          cast list [--limit N|--all] [--query TEXT] [--json] [--text]
          cast search TEXT [--json]
          cast read ID [--json|--raw]
          cast update ID [--title TITLE] [--mime TYPE] [--json] [TEXT...]
          cast delete ID [--json]
          cast path

        Defaults:
          mimetype: \(NotePersistence.defaultMimetype)
          title: random word + local date/time when omitted
        """)
    }

    private func printAddUsage() {
        printLine("Usage: cast add [--title TITLE] [--mime TYPE] [--json] [TEXT...]")
    }

    private func printListUsage() {
        printLine("Usage: cast list [--limit N|--all] [--query TEXT] [--json] [--text]")
    }

    private func printReadUsage() {
        printLine("Usage: cast read ID [--json|--raw]")
    }

    private func printUpdateUsage() {
        printLine("Usage: cast update ID [--title TITLE] [--mime TYPE] [--json] [TEXT...]")
    }

    private func printDeleteUsage() {
        printLine("Usage: cast delete ID [--json]")
    }
}

// MARK: - Entry point

do {
    try CastCommand(arguments: Array(CommandLine.arguments.dropFirst())).run()
} catch let error as CommandError {
    eprint("cast: \(error.description)")
    exit(1)
} catch {
    eprint("cast: \(String(describing: error))")
    exit(1)
}
