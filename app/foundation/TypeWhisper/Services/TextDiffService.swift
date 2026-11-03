import Foundation

struct CorrectionSuggestion: Identifiable {
    let id = UUID()
    let original: String
    let replacement: String
}

/// A vocabulary hint is deliberately weaker than a global text replacement.
/// This distinction keeps “kiwi” valid even after learning the product name “Kivi”.
struct CorrectionLearningCandidate: Equatable {
    enum Kind: String, Codable { case spelling, vocabulary }
    let original: String
    let replacement: String
    let kind: Kind
    var key: String { "\(kind.rawValue)|\(original.lowercased())|\(replacement.lowercased())" }
}

enum CorrectionLearningAnalysis {
    // Deterministic English exclusions. These are guardrails, not a claim of semantic
    // understanding. Unknown/ambiguous edits abstain; no model confidence is trusted.
    private static let ordinary = Set("""
    a an the and or but if then than that this these those there here where when why how
    not no yes now can cant can't cannot could couldn't would wouldn't should shouldn't
    will won't wont may might must true false before after more less most least very
    today tomorrow yesterday monday tuesday wednesday thursday friday saturday sunday
    january february march april june july august september october november december
    one two three four five six seven eight nine ten hundred thousand million billion
    first second third fourth fifth last next previous earlier later morning evening night
    send sent receive received pay paid buy bought sell sold increase decrease include exclude
    accept reject approve deny allow refuse enable disable delete keep add remove change
    meet met meeting review design project work working write written read reading
    have has had do does did done is are was were be been being get got make made
    i me my mine we us our ours you your yours he him his she her hers it its they them their
    good bad great fine ready sorry please thanks thank hello hi bye dear regards
    in on at to for from with without into onto over under about between through until
    all any some each every either neither both other another only also just really
    time day week month year date number amount price cost money dollars rupees percent
    organize organise color colour center centre favorite favourite cancelled canceled
    apple apples kiwi kiwis fruit fruits cloud clouds flow intent notion word words
    john joan jon jane sarah sara mike michael david peter paul mark mary james robert
    document message email file folder code text list table button window screen
    small large big little short long new old right wrong open close closed start stop
    east west north south positive negative increase decreased before afterwards
    """.split(whereSeparator: \.isWhitespace).map(String.init))

    static func candidates(original: String, edited: String) -> [CorrectionLearningCandidate] {
        guard original.count <= 2_000, edited.count <= 2_000,
              !original.contains("`"), !edited.contains("`"),
              !original.contains("_"), !edited.contains("_") else { return [] }
        let lhs = tokens(maskProtectedText(original)), rhs = tokens(maskProtectedText(edited))
        guard !lhs.isEmpty, !rhs.isEmpty, lhs.count <= 400, rhs.count <= 400 else { return [] }
        // LCS over lexical tokens: punctuation is its own token, so fixing a comma
        // does not invalidate an otherwise independent name correction.
        var table = Array(repeating: Array(repeating: 0, count: rhs.count + 1), count: lhs.count + 1)
        for i in (0..<lhs.count).reversed() {
            for j in (0..<rhs.count).reversed() {
                table[i][j] = lhs[i] == rhs[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var i = 0, j = 0, removed: [String] = [], added: [String] = []
        var groups: [([String], [String])] = []
        func flush() {
            if !removed.isEmpty || !added.isEmpty { groups.append((removed, added)) }
            removed = []; added = []
        }
        while i < lhs.count || j < rhs.count {
            if i < lhs.count, j < rhs.count, lhs[i] == rhs[j] {
                flush(); i += 1; j += 1
            } else if i < lhs.count, j == rhs.count || table[i + 1][j] >= table[i][j + 1] {
                removed.append(lhs[i]); i += 1
            } else {
                added.append(rhs[j]); j += 1
            }
        }
        flush()
        // Broad rewrites are not reliable teaching signals, even when they happen
        // to contain a pair of similarly spelled words.
        let changedWords = groups.reduce(0) { $0 + max($1.0.filter(isWord).count, $1.1.filter(isWord).count) }
        guard changedWords <= max(2, max(lhs.filter(isWord).count, rhs.filter(isWord).count) / 2) else { return [] }
        var seen = Set<String>()
        return groups.compactMap { old, new -> CorrectionLearningCandidate? in
            let old = old.filter { !$0.allSatisfy(\.isPunctuation) }
            let new = new.filter { !$0.allSatisfy(\.isPunctuation) }
            let a = old.filter(isWord), b = new.filter(isWord)
            // Numbers, symbols and punctuation *inside* a replacement make that
            // group ambiguous. Independent punctuation-only groups are harmless.
            guard !a.isEmpty, !b.isEmpty, a.count <= 3, b.count <= 3,
                  old.allSatisfy(isWord), new.allSatisfy(isWord) else { return nil }
            let source = a.joined(separator: " "), target = b.joined(separator: " ")
            let flatA = a.joined().lowercased(), flatB = b.joined().lowercased()
            guard flatA.count >= 3, flatB.count >= 3, max(source.count, target.count) <= 64,
                  !b.contains(where: { ordinary.contains($0.lowercased()) }),
                  b.contains(where: { $0.first?.isUppercase == true }) else { return nil }
            let distance = editDistance(flatA, flatB)
            guard distance <= 3, Double(distance) / Double(max(flatA.count, flatB.count)) <= 0.34,
                  source != target else { return nil }
            let commonSource = a.contains { ordinary.contains($0.lowercased()) }
            // Case-only and common-word confusions can teach vocabulary, never a
            // global substitution. Split/merged proper terms are supported.
            let kind: CorrectionLearningCandidate.Kind = commonSource || flatA == flatB ? .vocabulary : .spelling
            let candidate = CorrectionLearningCandidate(original: source, replacement: target, kind: kind)
            return seen.insert(candidate.key).inserted ? candidate : nil
        }.prefix(4).map { $0 }
    }

    private static func tokens(_ text: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: #"[\p{L}\p{M}]+(?:['’-][\p{L}\p{M}]+)*|[0-9]+(?:[.,][0-9]+)*|[^\s]"#)
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { (text as NSString).substring(with: $0.range) }
    }

    private static func maskProtectedText(_ text: String) -> String {
        // Never mine names from email addresses, web addresses or file paths.
        // Keep independent edits elsewhere in the same paragraph eligible.
        let regex = try! NSRegularExpression(pattern: #"(?i)(?:https?://|www\.|~?/)[^\s]+|[\p{L}\p{N}._%+-]+@[\p{L}\p{N}.-]+|[\p{L}\p{N}-]+\.[a-z]{2,}(?:/[^\s]*)?"#)
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "\u{FFFC}")
    }

    private static func isWord(_ text: String) -> Bool {
        text.first?.isLetter == true && text.allSatisfy { $0.isLetter || $0 == "'" || $0 == "’" || $0 == "-" }
    }

    private static func editDistance(_ a: String, _ b: String) -> Int {
        let lhs = Array(a), rhs = Array(b)
        var row = Array(0...rhs.count)
        for (i, letter) in lhs.enumerated() {
            var next = [i + 1] + Array(repeating: 0, count: rhs.count)
            for (j, other) in rhs.enumerated() {
                next[j + 1] = min(row[j + 1] + 1, next[j] + 1, row[j] + (letter == other ? 0 : 1))
            }
            row = next
        }
        return row[rhs.count]
    }
}

enum DiffSegment: Equatable, Sendable {
    case unchanged(String)
    case removed(String)
    case added(String)
}

final class TextDiffService {
    /// Number of LCS cells compared between two `checkCancellation` calls in `wordDiff`.
    static let cancellationCheckInterval = 1 << 16

    func computeWordDiff(original: String, processed: String) -> [DiffSegment] {
        Self.wordDiff(original: original, processed: processed, maxComparisonCells: .max) ?? []
    }

    /// Computes the same word diff as `computeWordDiff`, but returns `nil` instead of
    /// building an LCS table with more than `maxComparisonCells` cells. The table costs
    /// O(m·n) time and one byte per cell, so callers can present a fallback for very long texts.
    static func wordDiff(original: String, processed: String, maxComparisonCells: Int) -> [DiffSegment]? {
        wordDiff(original: original, processed: processed, maxComparisonCells: maxComparisonCells) {}
    }

    /// Like `wordDiff(original:processed:maxComparisonCells:)`, but runs `checkCancellation`
    /// before the table is built and after every `cancellationCheckInterval` compared cells,
    /// also within a single wide row, so a background caller can abandon the comparison by
    /// throwing. The remaining work outside the table is linear in the word count.
    static func wordDiff(
        original: String,
        processed: String,
        maxComparisonCells: Int,
        checkCancellation: () throws -> Void
    ) rethrows -> [DiffSegment]? {
        let origWords = original.split(omittingEmptySubsequences: true, whereSeparator: \.isWhitespace).map(String.init)
        let procWords = processed.split(omittingEmptySubsequences: true, whereSeparator: \.isWhitespace).map(String.init)

        if origWords.isEmpty && procWords.isEmpty { return [] }
        if origWords.isEmpty { return procWords.map { .added($0) } }
        if procWords.isEmpty { return origWords.map { .removed($0) } }

        // Backtracking always consumes an equal suffix first. Excluding it from
        // the table preserves the original tie-breaking, including repeated words.
        // An equal prefix cannot be trimmed with that same guarantee.
        var m = origWords.count, n = procWords.count
        while m > 0 && n > 0 && origWords[m - 1] == procWords[n - 1] {
            m -= 1
            n -= 1
        }

        let (cellCount, overflow) = m.multipliedReportingOverflow(by: n)
        guard !overflow, cellCount <= maxComparisonCells else { return nil }

        try checkCancellation()
        // Keep only the current LCS row and one byte per backtracking direction,
        // rather than an Int for every cell in a nested copy-on-write array.
        var row = Array(repeating: 0, count: n + 1)
        var directions = Array(repeating: UInt8(0), count: m * n)
        if m > 0 && n > 0 {
            var cellsUntilCancellationCheck = cancellationCheckInterval
            for i in 1...m {
                var diagonal = 0
                let rowOffset = (i - 1) * n
                for j in 1...n {
                    cellsUntilCancellationCheck -= 1
                    if cellsUntilCancellationCheck == 0 {
                        cellsUntilCancellationCheck = cancellationCheckInterval
                        try checkCancellation()
                    }
                    let above = row[j]
                    if origWords[i - 1] == procWords[j - 1] {
                        row[j] = diagonal + 1
                    } else if row[j - 1] >= above {
                        row[j] = row[j - 1]
                        directions[rowOffset + j - 1] = 1 // added (left wins ties)
                    } else {
                        directions[rowOffset + j - 1] = 2 // removed
                    }
                    diagonal = above
                }
            }
        }

        // Backtrack to produce segments
        var segments: [DiffSegment] = []
        segments.reserveCapacity(origWords.count + procWords.count)
        for word in origWords[m...].reversed() {
            segments.append(.unchanged(word))
        }
        var i = m, j = n
        while i > 0 || j > 0 {
            if i > 0 && j > 0 && directions[(i - 1) * n + j - 1] == 0 {
                segments.append(.unchanged(origWords[i - 1]))
                i -= 1; j -= 1
            } else if j > 0 && (i == 0 || directions[(i - 1) * n + j - 1] == 1) {
                segments.append(.added(procWords[j - 1]))
                j -= 1
            } else {
                segments.append(.removed(origWords[i - 1]))
                i -= 1
            }
        }
        segments.reverse()
        return segments
    }

    func extractCorrections(original: String, edited: String) -> [CorrectionSuggestion] {
        let originalWords = original.split(separator: " ").map(String.init)
        let editedWords = edited.split(separator: " ").map(String.init)

        // Skip if too different (massive rewrite)
        let maxLen = max(originalWords.count, editedWords.count)
        guard maxLen > 0 else { return [] }

        let diff = editedWords.difference(from: originalWords)

        let removals = diff.compactMap { change -> (offset: Int, element: String)? in
            if case .remove(let offset, let element, _) = change {
                return (offset, element)
            }
            return nil
        }
        let insertions = diff.compactMap { change -> (offset: Int, element: String)? in
            if case .insert(let offset, let element, _) = change {
                return (offset, element)
            }
            return nil
        }

        // If more than 50% changed, treat as rewrite
        let changeCount = removals.count + insertions.count
        if changeCount > maxLen { return [] }

        var suggestions: [CorrectionSuggestion] = []
        var usedInsertions = Set<Int>()

        for removal in removals {
            // Find nearest insertion within 3 positions
            var bestMatch: (index: Int, distance: Int)?
            for (i, insertion) in insertions.enumerated() {
                guard !usedInsertions.contains(i) else { continue }
                let distance = abs(removal.offset - insertion.offset)
                if distance <= 3 {
                    if bestMatch == nil || distance < bestMatch!.distance {
                        bestMatch = (i, distance)
                    }
                }
            }

            if let match = bestMatch {
                let insertion = insertions[match.index]
                usedInsertions.insert(match.index)

                // Strip surrounding punctuation from words
                let origStripped = removal.element.trimmingCharacters(in: .punctuationCharacters)
                let replStripped = insertion.element.trimmingCharacters(in: .punctuationCharacters)

                // Skip empty or punctuation-only tokens
                guard !origStripped.isEmpty, !replStripped.isEmpty else { continue }

                // Skip if only punctuation or case changed
                if origStripped.lowercased() == replStripped.lowercased() { continue }

                suggestions.append(CorrectionSuggestion(
                    original: origStripped,
                    replacement: replStripped
                ))
            }
        }

        return suggestions
    }

    func extractHighConfidenceCorrections(
        original: String,
        edited: String,
        maxSuggestions: Int = 3
    ) -> [CorrectionSuggestion] {
        let originalTokens = Self.wordTokens(in: original)
        let editedTokens = Self.wordTokens(in: edited)

        guard maxSuggestions > 0,
              !originalTokens.isEmpty,
              originalTokens.count == editedTokens.count else {
            return []
        }

        var suggestion: CorrectionSuggestion?

        for (originalToken, editedToken) in zip(originalTokens, editedTokens) where originalToken != editedToken {
            guard suggestion == nil else {
                return []
            }

            let originalStripped = Self.strippedWordToken(originalToken)
            let editedStripped = Self.strippedWordToken(editedToken)

            guard !originalStripped.isEmpty, !editedStripped.isEmpty else {
                return []
            }

            guard originalStripped.lowercased() != editedStripped.lowercased() else {
                return []
            }

            guard !Self.isPunctuationOnly(originalToken),
                  !Self.isPunctuationOnly(editedToken) else {
                return []
            }

            suggestion = CorrectionSuggestion(
                original: originalStripped,
                replacement: editedStripped
            )
        }

        guard let suggestion else { return [] }
        return [suggestion]
    }

    private static func wordTokens(in text: String) -> [String] {
        text.split(omittingEmptySubsequences: true, whereSeparator: \.isWhitespace).map(String.init)
    }

    private static func strippedWordToken(_ token: String) -> String {
        token.trimmingCharacters(in: .punctuationCharacters)
    }

    private static func isPunctuationOnly(_ token: String) -> Bool {
        !token.isEmpty && token.unicodeScalars.allSatisfy { CharacterSet.punctuationCharacters.contains($0) }
    }
}
