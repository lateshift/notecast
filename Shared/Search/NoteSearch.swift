//
//  NoteSearch.swift
//  NoteCast
//
//  Lightweight fuzzy search shared by the app and the `cast` CLI.
//

import Foundation

struct NoteSearchResult {
    let note: Note
    let score: Int
}

enum NoteSearch {
    static func normalizedQuery(_ query: String) -> String? {
        let normalized = normalizedText(query).trimmingCharacters(in: .whitespacesAndNewlines)
        let terms = normalized
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        return terms.isEmpty ? nil : normalized
    }

    static func search(_ notes: [Note], query: String) -> [NoteSearchResult] {
        let terms = searchTerms(in: query)
        guard !terms.isEmpty else {
            return notes.map { NoteSearchResult(note: $0, score: 0) }
        }

        let scored: [(result: NoteSearchResult, index: Int)] = notes.enumerated().compactMap { index, note in
            let score = score(note: note, terms: terms)
            guard score > 0 else { return nil }
            return (NoteSearchResult(note: note, score: score), index)
        }

        return scored
            .sorted { lhs, rhs in
                if lhs.result.score != rhs.result.score {
                    return lhs.result.score > rhs.result.score
                }

                if lhs.result.note.updated_at != rhs.result.note.updated_at {
                    return lhs.result.note.updated_at > rhs.result.note.updated_at
                }

                return lhs.index < rhs.index
            }
            .map(\.result)
    }

    private static func score(note: Note, terms: [String]) -> Int {
        let fields: [(text: String, weight: Int)] = [
            (normalizedText(note.displayTitle), 8),
            (normalizedText(note.folder?.displayName ?? ""), 5),
            (normalizedText(note.text), 3),
            (normalizedText(note.created_via), 1),
            (normalizedText(note.mimetype), 1),
            (normalizedText(note.stableID), 1)
        ]

        var total = 0
        for term in terms {
            let bestScore = fields
                .map { textScore(for: term, in: $0.text) * $0.weight }
                .max() ?? 0

            guard bestScore > 0 else { return 0 }
            total += bestScore
        }

        return total
    }

    private static func searchTerms(in query: String) -> [String] {
        guard let normalized = normalizedQuery(query) else { return [] }

        return normalized
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private static func normalizedText(_ text: String) -> String {
        text
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }

    private static func textScore(for term: String, in text: String) -> Int {
        guard !term.isEmpty, !text.isEmpty else { return 0 }

        if text == term { return 120 }
        if text.hasPrefix(term) { return 110 }

        let words = words(in: text)
        if words.contains(term) { return 105 }
        if words.contains(where: { $0.hasPrefix(term) }) { return 96 }
        if text.contains(term) { return 86 }

        if let typoScore = typoScore(for: term, words: words) {
            return typoScore
        }

        let acronym = words.compactMap(\.first).map(String.init).joined()
        if term.count >= 2, acronym.hasPrefix(term) {
            return 74
        }

        if term.count >= 3, let subsequenceScore = subsequenceScore(for: term, in: text) {
            return subsequenceScore
        }

        return 0
    }

    private static func words(in text: String) -> [String] {
        text
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private static func typoScore(for term: String, words: [String]) -> Int? {
        guard term.count >= 3 else { return nil }

        let maxDistance = term.count <= 4 ? 1 : 2
        let scores = words.compactMap { word -> Int? in
            guard let distance = editDistance(term, word, maximum: maxDistance) else { return nil }
            return max(48, 78 - (distance * 14))
        }

        return scores.max()
    }

    private static func subsequenceScore(for term: String, in text: String) -> Int? {
        let pattern = Array(term)
        let characters = Array(text)
        var patternIndex = 0
        var previousMatchIndex: Int?
        var gapCount = 0

        for index in characters.indices where patternIndex < pattern.count {
            guard characters[index] == pattern[patternIndex] else { continue }

            if let previousMatchIndex {
                gapCount += index - previousMatchIndex - 1
            }
            previousMatchIndex = index
            patternIndex += 1
        }

        guard patternIndex == pattern.count else { return nil }
        return max(38, 70 - min(gapCount, 32))
    }

    private static func editDistance(_ lhs: String, _ rhs: String, maximum: Int) -> Int? {
        let left = Array(lhs)
        let right = Array(rhs)

        guard abs(left.count - right.count) <= maximum else { return nil }

        var previous = Array(0...right.count)
        for leftIndex in left.indices {
            var current = Array(repeating: 0, count: right.count + 1)
            current[0] = leftIndex + 1
            var rowMinimum = current[0]

            for rightIndex in right.indices {
                let substitutionCost = left[leftIndex] == right[rightIndex] ? 0 : 1
                current[rightIndex + 1] = min(
                    previous[rightIndex + 1] + 1,
                    current[rightIndex] + 1,
                    previous[rightIndex] + substitutionCost
                )
                rowMinimum = min(rowMinimum, current[rightIndex + 1])
            }

            guard rowMinimum <= maximum else { return nil }
            previous = current
        }

        return previous[right.count] <= maximum ? previous[right.count] : nil
    }
}
