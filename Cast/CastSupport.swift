//
//  CastSupport.swift
//  cast
//
//  Small helpers shared by the cast command implementation.
//

import Darwin
import Foundation

// MARK: - Terminal helpers

func printLine(_ message: String = "") {
    FileHandle.standardOutput.write(Data((message + "\n").utf8))
}

func eprint(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func stdinIsTerminal() -> Bool {
    isatty(STDIN_FILENO) == 1
}

/// Read piped stdin, but never block an interactive terminal waiting for input.
func readPipedStdin() -> String? {
    guard !stdinIsTerminal() else { return nil }
    let data = FileHandle.standardInput.readDataToEndOfFile()
    return String(data: data, encoding: .utf8)
}

func nonEmpty(_ text: String?) -> String? {
    guard let cleaned = text?.trimmingCharacters(in: .whitespacesAndNewlines),
          !cleaned.isEmpty else {
        return nil
    }

    return cleaned
}

// MARK: - Errors

struct CommandError: Error, CustomStringConvertible {
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
struct NoteRecord: Encodable {
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

func printJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(value)
    FileHandle.standardOutput.write(data)
    printLine()
}

// MARK: - Formatting

func shortID(_ note: Note) -> String {
    String(note.stableID.prefix(8))
}

func fencedMarkdownCodeBlock(_ text: String) -> String {
    let fence = markdownCodeFence(for: text)
    return "\(fence)\n\(text)\n\(fence)"
}

/// Pick a fence long enough that command output containing backticks still
/// renders as one code block in Markdown.
func markdownCodeFence(for text: String) -> String {
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

func plainDate(_ date: Date) -> String {
    plainDateFormatter.string(from: date)
}

private let plainDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return formatter
}()
