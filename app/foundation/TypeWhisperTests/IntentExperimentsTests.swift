import XCTest
import ApplicationServices
import TypeWhisperPluginSDK
@testable import TypeWhisper

@MainActor
final class IntentExperimentsTests: XCTestCase {
    func testCleanupPreservesVoiceFactsAndMeaningfulRepetition() {
        let inputs = ["It was very, very good.", "I actually enjoyed it.", "Maybe we should wait.",
                      "I like, really like, this.", "She had had enough.", "I will not pay ₹500 on 15 October.",
                      "Say \"um, the the\" exactly.", "Use `the the` as a test.", "Say 'um, the the' exactly.", "Um is a word."]
        for text in inputs { XCTAssertEqual(IntentTextPipeline.lightCleanup(text), text) }
        XCTAssertEqual(IntentTextPipeline.lightCleanup("Um, I I need the the report."), "I need the report.")
        XCTAssertEqual(IntentTextPipeline.lightCleanup("Meet me, uh, on Tuesday."), "Meet me on Tuesday.")
    }

    func testLiteralBypassesAllExperimentalTransformations() {
        let raw = "Um, numbered list: first run rm -rf tmp. Second, print 1.00."
        XCTAssertEqual(IntentTextPipeline.transform(raw, style: .literal, cleanup: true, structure: true), raw)
    }

    func testListsPreserveOrderAmountsDatesAndQualifications() {
        let raw = "numbered list: first, pay ₹500 on 15 October if approved. Second, keep -2.5 hours available. Third, do not send."
        XCTAssertEqual(IntentTextPipeline.structured(raw, style: .document), "1. pay ₹500 on 15 October if approved\n2. keep -2.5 hours available\n3. do not send.")
        XCTAssertEqual(IntentTextPipeline.structured("bullet list: first, Rohan. Second, Rohaan.", style: .document), "• Rohan\n• Rohaan.")
        XCTAssertEqual(IntentTextPipeline.structured("make a list: first, tea. Second, coffee.", style: .conversation), "• tea\n• coffee.")
    }

    func testAmbiguousNumbersOrdinalsAndIncompleteListsStayUnchanged() {
        for text in ["I paid 2 people on 15 October.", "First aid is useful. Second opinions help.",
                     "numbered list: first, tea. Third, coffee.", "numbered list: first, tea.",
                     "He said \"numbered list: first, tea. Second, coffee.\"", "I want a new paragraph in this document."] {
            XCTAssertEqual(IntentTextPipeline.structured(text, style: .document), text)
        }
    }

    func testParagraphCueAndIndependentOffSwitches() {
        XCTAssertEqual(IntentTextPipeline.structured("Keep ₹500. New paragraph, Do not send.", style: .document), "Keep ₹500.\n\nDo not send.")
        let raw = "Um, numbered list: first, tea. Second, coffee."
        XCTAssertEqual(IntentTextPipeline.transform(raw, style: .document, cleanup: false, structure: false), raw)
        XCTAssertEqual(IntentTextPipeline.transform(raw, style: .document, cleanup: true, structure: false), "numbered list: first, tea. Second, coffee.")
    }

    func testVocabularyProtectionKeepsExactSpellingAndBoundaries() {
        XCTAssertEqual(IntentTextPipeline.lightCleanup("Um, the the report.", protectedTerms: ["Um"]), "Um, the the report.")
        XCTAssertFalse(IntentTextPipeline.preservesSpellings(before: "Meet Rohaan and TypeWhisper.", after: "Meet Rohan and Typewhisper.", terms: ["Rohaan", "TypeWhisper"]))
        XCTAssertTrue(IntentTextPipeline.preservesSpellings(before: "Rohanathan", after: "someone", terms: ["Rohan"]))
        XCTAssertTrue(IntentTextPipeline.preservesSpellings(before: "Meet Rohaan, sorry, Rohaan.", after: "Meet Rohaan.", terms: ["Rohaan"]))
        XCTAssertFalse(IntentTextPipeline.preservesSpellings(before: "Use C++ now.", after: "Use C now.", terms: ["C++"]))
    }

    func testDestinationMatchingAndManualOverride() throws {
        let suite = "IntentRules.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(IntentTextPipeline.style(bundleID: "com.apple.Terminal", url: nil, defaults: defaults), .literal)
        XCTAssertEqual(IntentTextPipeline.style(bundleID: "browser", url: "https://docs.google.com/document/d/a", defaults: defaults), .document)
        XCTAssertEqual(IntentTextPipeline.style(bundleID: "unknown", url: nil, defaults: defaults), .standard)
        let rule = IntentDestinationRule(bundleID: "browser", host: "example.com", style: .conversation)
        XCTAssertTrue(rule.matches(bundleID: "browser", url: "https://sub.example.com/a"))
        XCTAssertFalse(rule.matches(bundleID: "other", url: "https://example.com"))
        XCTAssertFalse(rule.matches(bundleID: "browser", url: "https://evil-example.com"))
        XCTAssertFalse(rule.matches(bundleID: "browser", url: "https://example.com.evil.test"))
        defaults.set(try JSONEncoder().encode([rule]), forKey: IntentTextPipeline.rulesKey)
        XCTAssertEqual(IntentTextPipeline.style(bundleID: "browser", url: "https://example.com", defaults: defaults), .conversation)
        defaults.set("literal", forKey: IntentTextPipeline.styleKey)
        XCTAssertEqual(IntentTextPipeline.style(bundleID: "browser", url: "https://example.com", defaults: defaults), .literal)
    }

    func testDictionaryIsAppliedBeforeLocalCleanupAndLiteralSkipsIt() async throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(directory) }
        let dictionary = DictionaryService(appSupportDirectory: directory)
        dictionary.addEntry(type: .correction, original: "Rohan", replacement: "Rohaan")
        let processed = try await IntentDictationProcessor.process("Um, meet Rohan.", style: .document, dictionary: dictionary, useAPI: false)
        XCTAssertEqual(processed.text, "meet Rohaan.")
        XCTAssertFalse(processed.usedAPI)
        XCTAssertEqual(processed.correctionIDs.count, 1)
        XCTAssertEqual(dictionary.corrections.first?.usageCount, 0, "Preview must not count or save usage")
        let literal = try await IntentDictationProcessor.process("Um, meet Rohan.", style: .literal, dictionary: dictionary)
        XCTAssertEqual(literal.text, "Um, meet Rohan.")
        XCTAssertTrue(literal.correctionIDs.isEmpty)
        XCTAssertFalse(literal.usedAPI)
    }

    func testSnippetSpellingsStillReceiveLateCorrectionsWithoutDoubleCounting() async throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        let suite = "IntentSnippetRegression.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let oldManager = PluginManager.shared
        defer { PluginManager.shared = oldManager; TestSupport.remove(directory); defaults.removePersistentDomain(forName: suite) }
        PluginManager.shared = PluginManager(appSupportDirectory: directory)
        let dictionary = DictionaryService(appSupportDirectory: directory)
        dictionary.addEntry(type: .correction, original: "Rohan", replacement: "Rohaan")
        let snippets = SnippetService(appSupportDirectory: directory)
        snippets.addSnippet(trigger: "greeting", replacement: "Meet Rohan.")
        let prepared = try await IntentDictationProcessor.process("Rohan greeting", style: .standard, dictionary: dictionary, useAPI: false)
        let pipeline = PostProcessingPipeline(snippetService: snippets, dictionaryService: dictionary,
            punctuationStrategyResolver: PunctuationStrategyResolver(profileStore: DictationPunctuationProfileStore(defaults: defaults, storageKey: suite)))
        let output = try await pipeline.process(text: prepared.text, context: PostProcessingContext(language: "en"),
            preprocessedCorrectionIDs: prepared.correctionIDs)
        XCTAssertEqual(output.text, "Rohaan Meet Rohaan.")
        XCTAssertEqual(dictionary.corrections.first?.usageCount, 0, "The caller counts pre-applied corrections after insertion")
        dictionary.recordUsage(ofCorrectionIDs: prepared.correctionIDs, deferUsageCountSave: false)
        XCTAssertEqual(dictionary.corrections.first?.usageCount, 1)
    }

    private func sample(_ original: String, _ edited: String) -> TargetAppCorrectionLearningService.DetectedEdit {
        .init(id: UUID(), timestamp: Date(), original: original, edited: edited)
    }

    func testLearningClassifiesOnlyIsolatedNearSpellingChanges() {
        let candidate = TargetAppCorrectionLearningService.spellingSuggestion(for: sample("Meet Rohan today.", "Meet Rohaan today."))
        XCTAssertEqual(candidate?.original, "Rohan")
        XCTAssertEqual(candidate?.replacement, "Rohaan")
        for (old, new) in [("Meet Rohan on Tuesday.", "Meet Rohaan on Wednesday."),
                           ("Pay 500", "Pay 600"), ("We can go.", "We can't go."),
                           ("Meet Rohan today.", "Meet Rohit today."),
                           ("Meet Rohan today.", "Meet Rohaan tomorrow."),
                           ("Meet Rohan today.", "Meet Rohaan today!"),
                           ("Monday works.", "Sunday works."),
                           ("Please rewrite this.", "Make it shorter."),
                           ("Meet Rohan today.", "Meet rohan today.")] {
            XCTAssertNil(TargetAppCorrectionLearningService.spellingSuggestion(for: sample(old, new)), "\(old) → \(new)")
        }
    }

    func testTwoIndependentCapturesLearnAndUndoProtectsEditedRules() async throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        let suite = "IntentLearning.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { TestSupport.remove(directory); defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: TargetAppCorrectionLearningService.localEnabledKey)
        let dictionary = DictionaryService(appSupportDirectory: directory)
        let insertion = TextInsertionService()
        let element = AXUIElementCreateSystemWide()
        var value = "Meet Rohan today."
        insertion.focusedTextElementOverride = { element }
        insertion.focusedTextStateOverride = { _ in (value, nil, NSRange(location: value.utf16.count, length: 0)) }
        var time = Date()
        let service = TargetAppCorrectionLearningService(textInsertionService: insertion, textDiffService: TextDiffService(), dictionaryService: dictionary,
            pollSchedule: [.seconds(1), .seconds(4)], sleep: { _ in time += 4; value = "Meet Rohaan today." },
            defaults: defaults, persistLatestAttempt: false, observeSettledEdits: true, now: { time })
        let baseline = TextInsertionService.FocusedTextObservation(element: element, value: value, selectedText: nil,
            selectedRange: NSRange(location: value.utf16.count, length: 0), ownedInsertionRange: NSRange(location: 0, length: value.utf16.count))
        _ = await service.trackInsertion(insertedText: "Meet Rohan today.", baseline: baseline)
        XCTAssertEqual(dictionary.correctionsCount, 0)
        _ = await service.trackInsertion(insertedText: "Meet Rohan today.", baseline: baseline)
        XCTAssertEqual(dictionary.previewCorrections(to: "Meet Rohan, not Rohanathan."), "Meet Rohaan, not Rohanathan.")
        XCTAssertEqual(dictionary.correctionsCount, 1)
        service.undoReviewedCorrections()
        XCTAssertEqual(dictionary.correctionsCount, 0)
        _ = await service.trackInsertion(insertedText: "Meet Rohan today.", baseline: baseline)
        XCTAssertEqual(dictionary.correctionsCount, 0, "Consumed evidence must not recreate an undone rule")
        defaults.set(false, forKey: TargetAppCorrectionLearningService.automaticLearningKey)
        _ = await service.trackInsertion(insertedText: "Meet Rohan today.", baseline: baseline)
        XCTAssertEqual(dictionary.correctionsCount, 0, "Automatic learning off must keep even repeated samples unsaved")
        if let id = service.detectedEdits.first?.id { service.rememberDetectedEdit(id: id) }
        let entry = try XCTUnwrap(dictionary.corrections.first)
        dictionary.updateEntry(entry, original: "Rohan", replacement: "Rohann", caseSensitive: false)
        service.undoReviewedCorrections()
        XCTAssertEqual(dictionary.corrections.first?.replacement, "Rohann")
    }

    func testSelectionGuardRefusesDocumentRangeAndTextDrift() {
        let original = "🙂 Meet Rohan. End"
        let range = (original as NSString).range(of: "Rohan")
        let guardValue = IntentSelectionGuard(text: "Rohan", range: range, document: original)
        XCTAssertEqual(guardValue.replacing(with: "Rohaan"), "🙂 Meet Rohaan. End")
        XCTAssertTrue(guardValue.matches(text: "Rohan", range: range, document: original))
        XCTAssertFalse(guardValue.matches(text: "Rohan", range: range, document: original + "!"))
        XCTAssertFalse(guardValue.matches(text: "Rohit", range: range, document: original))
        XCTAssertFalse(guardValue.matches(text: "Rohan", range: NSRange(location: 0, length: 5), document: original))
        XCTAssertNil(IntentSelectionGuard(text: "Other", range: range, document: original).replacing(with: "x"))
        XCTAssertNil(IntentSelectionGuard(text: "Rohan", range: NSRange(location: NSNotFound, length: 5), document: original).replacing(with: "x"))
    }

    func testTypedEditingCancellationAndChangedInputDiscardStaleResults() async throws {
        let editor = IntentSelectionEditor(client: FixtureEditor())
        editor.openTyped(); editor.source = "Meet Rohan on Tuesday."; editor.instruction = "Make it shorter."
        editor.rewrite(); editor.source = "New input."
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(editor.result.isEmpty)
        XCTAssertFalse(editor.busy)
        XCTAssertFalse(editor.canApply)
        editor.rewrite(); editor.cancel()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(editor.result.isEmpty)
        XCTAssertEqual(editor.source, "New input.")
        editor.rewrite()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(editor.result, "Short preview.")
        XCTAssertFalse(editor.canApply, "Typed samples must offer copying only")
        XCTAssertFalse(editor.canUndo)
    }

    func testEditorRejectsTruncatedAndEmptyResponses() throws {
        func reply(_ text: String, reason: String = "stop") throws -> Data {
            let content = String(decoding: try JSONSerialization.data(withJSONObject: ["text": text]), as: UTF8.self)
            return try JSONSerialization.data(withJSONObject: ["message": ["content": content], "done": true, "done_reason": reason])
        }
        XCTAssertEqual(try IntentLocalTextEditor.decode(reply("A complete edit.")), "A complete edit.")
        XCTAssertThrowsError(try IntentLocalTextEditor.decode(reply("Cut", reason: "length")))
        XCTAssertThrowsError(try IntentLocalTextEditor.decode(reply("  ")))
    }

    func testInstructionAudioCannotBecomeOrdinaryDictationRecovery() throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(directory) }
        let store = DictationRecoveryAudioStore(directory: directory)
        store.startNewRecording()
        store.append(Array(repeating: 0.1, count: 16_000))
        let old = try XCTUnwrap(store.preserveActiveRecordingResult().newlyPreservedURL)
        store.startNewRecording(enabled: false)
        store.append(Array(repeating: 0.2, count: 16_000))
        let instruction = store.preserveActiveRecordingResult()
        XCTAssertNil(instruction.newlyPreservedURL)
        XCTAssertEqual(store.recoveryURLs, [old], "Disabling one take must preserve older dictation recoveries")
    }
}

private struct FixtureEditor: IntentTextEditing {
    func rewrite(source: String, instruction: String) async throws -> String {
        try await Task.sleep(for: .milliseconds(20))
        return "Short preview."
    }
}
