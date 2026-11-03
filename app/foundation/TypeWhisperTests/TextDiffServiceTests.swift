import XCTest
@testable import TypeWhisper

final class TextDiffServiceTests: XCTestCase {
    func testLearningExtractsIndependentNamesDespitePunctuationAndFactEdits() {
        let result = CorrectionLearningAnalysis.candidates(
            original: "Meet Rohan, then Vedan on Tuesday for 500.",
            edited: "Meet Rohaan; then Vedant on Wednesday for 600!")
        XCTAssertEqual(result.map(\.original), ["Rohan", "Vedan"])
        XCTAssertEqual(result.map(\.replacement), ["Rohaan", "Vedant"])
        XCTAssertTrue(result.allSatisfy { $0.kind == .spelling })
    }

    func testLearningHandlesSplitMergedAndRepeatedTerms() {
        XCTAssertEqual(CorrectionLearningAnalysis.candidates(original: "Talk to Sar vam today.", edited: "Talk to Sarvam today.").first?.replacement, "Sarvam")
        let result = CorrectionLearningAnalysis.candidates(original: "Rohan will ask Rohan.", edited: "Rohaan will ask Rohaan.")
        XCTAssertEqual(result.count, 1, "Repeated names within one paragraph are one piece of evidence")
    }

    func testLearningCommonWordConfusionIsVocabularyOnly() {
        let result = CorrectionLearningAnalysis.candidates(original: "Try kiwi today.", edited: "Try Kivi today.")
        XCTAssertEqual(result.first?.kind, .vocabulary)
        XCTAssertEqual(result.first?.replacement, "Kivi")
        XCTAssertEqual(CorrectionLearningAnalysis.candidates(original: "Try KIVI today.", edited: "Try Kivi today.").first?.kind, .vocabulary)
    }

    func testLearningRejectsFactsNegationOrdinarySpellingAndCode() {
        for (old, new) in [("Tuesday works", "Wednesday works"), ("Pay 500", "Pay 5000"),
                           ("We can go", "We cannot go"), ("Send it", "Sent it"),
                           ("Color the box", "Colour the box"), ("Meet Rohan", "Meet Rohit"),
                           ("Use `Rohan`", "Use `Rohaan`"), ("Meet Rohan_id", "Meet Rohaan_id"),
                           ("Meet Rohan at x.com", "Meet Rohan at y.com")] {
            XCTAssertTrue(CorrectionLearningAnalysis.candidates(original: old, edited: new).isEmpty, "\(old) → \(new)")
        }
        XCTAssertTrue(CorrectionLearningAnalysis.candidates(original: String(repeating: "x", count: 2_001), edited: "Rohaan").isEmpty)
    }

    func testLearningDoesNotMineAddressesOrPathsButKeepsIndependentNameEdit() {
        for (old, new) in [("Email Rohan@example.com", "Email Rohaan@example.com"),
                           ("Open https://Rohan.com", "Open https://Rohaan.com"),
                           ("Open /Users/Rohan/file", "Open /Users/Rohaan/file")] {
            XCTAssertTrue(CorrectionLearningAnalysis.candidates(original: old, edited: new).isEmpty)
        }
        let result = CorrectionLearningAnalysis.candidates(original: "Ask Rohan at Rohan@example.com.", edited: "Ask Rohaan at Rohaan@example.com.")
        XCTAssertEqual(result.map(\.replacement), ["Rohaan"])
    }

    func testWordDiffPreservesRepeatedWordTieBreaking() {
        let service = TextDiffService()
        XCTAssertEqual(service.computeWordDiff(original: "a b", processed: "b a"), [
            .removed("a"), .unchanged("b"), .added("a"),
        ])
        XCTAssertEqual(service.computeWordDiff(original: "a a", processed: "a"), [
            .removed("a"), .unchanged("a"),
        ])
        XCTAssertEqual(service.computeWordDiff(original: "a", processed: "a a"), [
            .added("a"), .unchanged("a"),
        ])
    }

    func testWordDiffHandlesEmptyInputsUnicodeAndAnUnchangedSuffix() {
        let service = TextDiffService()
        XCTAssertEqual(service.computeWordDiff(original: "", processed: ""), [])
        XCTAssertEqual(service.computeWordDiff(original: "", processed: "🌍 世界"), [.added("🌍"), .added("世界")])
        XCTAssertEqual(service.computeWordDiff(original: "🌍", processed: ""), [.removed("🌍")])
        XCTAssertEqual(service.computeWordDiff(original: "old\t🌍\n世界", processed: "new 🌍 世界"), [
            .removed("old"), .added("new"), .unchanged("🌍"), .unchanged("世界"),
        ])
        let text = Array(repeating: "word", count: 10_000).joined(separator: " ")
        XCTAssertEqual(service.computeWordDiff(original: text, processed: text), Array(repeating: .unchanged("word"), count: 10_000))
    }

    func testBoundedWordDiffMatchesUnboundedDiffAndRejectsOversizedTables() {
        let service = TextDiffService()
        XCTAssertEqual(
            TextDiffService.wordDiff(
                original: "the quick brown fox",
                processed: "the slow brown fox jumps",
                maxComparisonCells: 20
            ),
            service.computeWordDiff(original: "the quick brown fox", processed: "the slow brown fox jumps")
        )
        // The shared suffix is excluded before the bound is checked.
        XCTAssertEqual(
            TextDiffService.wordDiff(original: "a b c", processed: "x b c", maxComparisonCells: 1),
            [.removed("a"), .added("x"), .unchanged("b"), .unchanged("c")]
        )
        XCTAssertNil(TextDiffService.wordDiff(original: "a b c", processed: "x y z", maxComparisonCells: 8))
        XCTAssertNotNil(TextDiffService.wordDiff(original: "a b c", processed: "x y z", maxComparisonCells: 9))
        XCTAssertEqual(TextDiffService.wordDiff(original: "", processed: "new", maxComparisonCells: 0), [.added("new")])
    }

    func testBoundedWordDiffChecksCancellationPeriodicallyAndStopsWhenCancelled() {
        let wordCount = 1_000
        let original = (0..<wordCount).map { "a\($0)" }.joined(separator: " ")
        let processed = (0..<wordCount).map { "b\($0)" }.joined(separator: " ")
        let cellCount = wordCount * wordCount

        var checks = 0
        let segments = TextDiffService.wordDiff(
            original: original,
            processed: processed,
            maxComparisonCells: .max,
            checkCancellation: { checks += 1 }
        )
        XCTAssertEqual(segments?.count, 2 * wordCount)
        XCTAssertGreaterThanOrEqual(checks, cellCount / TextDiffService.cancellationCheckInterval)

        checks = 0
        XCTAssertThrowsError(
            try TextDiffService.wordDiff(
                original: original,
                processed: processed,
                maxComparisonCells: .max,
                checkCancellation: {
                    checks += 1
                    if checks == 3 { throw CancellationError() }
                }
            )
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(checks, 3, "The comparison must stop at the first failed check")
    }

    func testBoundedWordDiffChecksCancellationWithinWideRow() {
        // One word against many forms a single table row, which must not run unchecked.
        let wordCount = 300_000
        let processed = (0..<wordCount).map { "b\($0)" }.joined(separator: " ")

        var checks = 0
        let segments = TextDiffService.wordDiff(
            original: "a",
            processed: processed,
            maxComparisonCells: .max,
            checkCancellation: { checks += 1 }
        )
        XCTAssertEqual(segments?.count, wordCount + 1)
        XCTAssertEqual(checks, 1 + wordCount / TextDiffService.cancellationCheckInterval)

        checks = 0
        XCTAssertThrowsError(
            try TextDiffService.wordDiff(
                original: "a",
                processed: processed,
                maxComparisonCells: .max,
                checkCancellation: {
                    checks += 1
                    if checks == 3 { throw CancellationError() }
                }
            )
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(checks, 3)
    }

    func testExtractCorrectionsFindsLocalizedWordReplacement() {
        let service = TextDiffService()

        let suggestions = service.extractCorrections(
            original: "teh quick brown fox",
            edited: "the quick brown fox"
        )

        XCTAssertEqual(suggestions.count, 1)
        XCTAssertEqual(suggestions.first?.original, "teh")
        XCTAssertEqual(suggestions.first?.replacement, "the")
    }

    func testExtractCorrectionsSkipsLargeRewrites() {
        let service = TextDiffService()

        let suggestions = service.extractCorrections(
            original: "one two three",
            edited: "completely different rewrite here"
        )

        XCTAssertTrue(suggestions.isEmpty)
    }

    func testHighConfidenceExtractionFindsSingleLocalTokenReplacement() {
        let service = TextDiffService()

        let suggestions = service.extractHighConfidenceCorrections(
            original: "please use teh word",
            edited: "please use the word"
        )

        XCTAssertEqual(suggestions.count, 1)
        XCTAssertEqual(suggestions.first?.original, "teh")
        XCTAssertEqual(suggestions.first?.replacement, "the")
    }

    func testHighConfidenceExtractionSkipsAmbiguousAndLowSignalEdits() {
        let service = TextDiffService()

        XCTAssertTrue(service.extractHighConfidenceCorrections(
            original: "teh langauge",
            edited: "the language"
        ).isEmpty)

        XCTAssertTrue(service.extractHighConfidenceCorrections(
            original: "remove this sentence",
            edited: "write new copy"
        ).isEmpty)

        XCTAssertTrue(service.extractHighConfidenceCorrections(
            original: "remove this sentence",
            edited: ""
        ).isEmpty)

        XCTAssertTrue(service.extractHighConfidenceCorrections(
            original: "teh quick fox",
            edited: "the very quick fox"
        ).isEmpty)

        XCTAssertTrue(service.extractHighConfidenceCorrections(
            original: "TypeWhisper",
            edited: "typewhisper"
        ).isEmpty)

        XCTAssertTrue(service.extractHighConfidenceCorrections(
            original: "hello.",
            edited: "hello!"
        ).isEmpty)

        XCTAssertTrue(service.extractHighConfidenceCorrections(
            original: "teh teh",
            edited: "the them"
        ).isEmpty)

        XCTAssertTrue(service.extractHighConfidenceCorrections(
            original: "one two three four",
            edited: "1 2 3 4"
        ).isEmpty)
    }
}
