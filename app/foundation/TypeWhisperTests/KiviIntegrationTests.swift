import XCTest
@testable import TypeWhisper

private struct KiviFakeEditor: IntentTextEditing {
    var text: String
    var fails = false
    func rewrite(source: String, instruction: String) async throws -> String {
        if fails { throw IntentEditingError.unavailable }
        return text
    }
}
@MainActor final class KiviIntegrationTests: XCTestCase {
    private func makeDefaults() -> UserDefaults { UserDefaults(suiteName: "KiviIntegrationTests.\(UUID())")! }
    func testUnconfiguredStyleDoesNotChangeFoundationBehavior() async {
        let defaults = makeDefaults()
        let result = await KiviStyleRouter.process("Keep ₹500 and Tuesday.", appName: "Mail", bundleID: "com.apple.mail", protectedTerms: [], defaults: defaults, client: KiviFakeEditor(text: "must not run"))
        XCTAssertEqual(result.text, "Keep ₹500 and Tuesday."); XCTAssertNil(result.step)
    }
    func testSavedCategoryIsResolvedAfterReload() {
        let defaults = makeDefaults()
        var style = WritingStyle.defaults[3]; style.mode = "formal"
        KiviStyleRouter.save(style, app: nil, defaults: defaults)
        XCTAssertEqual(KiviStyleRouter.resolved(appName: "Mail", bundleID: nil, defaults: defaults)?.mode, "formal")
        XCTAssertNil(KiviStyleRouter.resolved(appName: "Messages", bundleID: nil, defaults: defaults))
    }
    func testAppOverrideWinsWithoutChangingSharedStyle() {
        let defaults = makeDefaults()
        let shared = WritingStyle.defaults[3]; var specific = shared; specific.mode = "friendly"
        KiviStyleRouter.save(shared, app: nil, defaults: defaults); KiviStyleRouter.save(specific, app: "Mail", defaults: defaults)
        XCTAssertEqual(KiviStyleRouter.resolved(appName: "Mail", bundleID: nil, defaults: defaults)?.mode, "friendly")
        XCTAssertEqual(KiviStyleRouter.resolved(appName: "Outlook", bundleID: nil, defaults: defaults)?.mode, "professional")
    }
    func testOfflineStylingRetainsProcessedDictation() async {
        let defaults = makeDefaults()
        KiviStyleRouter.save(WritingStyle.defaults[3], app: nil, defaults: defaults)
        let text = "Send Rohaan ₹500 on Tuesday."
        let result = await KiviStyleRouter.process(text, appName: "Mail", bundleID: nil, protectedTerms: ["Rohaan"], defaults: defaults, client: KiviFakeEditor(text: "", fails: true))
        XCTAssertEqual(result.text, text); XCTAssertEqual(result.step, "Style unavailable: original retained")
    }
    func testStyleCannotRemovePreferredSpelling() async {
        let defaults = makeDefaults()
        KiviStyleRouter.save(WritingStyle.defaults[3], app: nil, defaults: defaults)
        let result = await KiviStyleRouter.process("Send Rohaan ₹500.", appName: "Mail", bundleID: nil, protectedTerms: ["Rohaan"], defaults: defaults, client: KiviFakeEditor(text: "Send Rohan ₹500."))
        XCTAssertEqual(result.text, "Send Rohaan ₹500.")
    }
    func testSavedPresentationCannotDuplicatePrivateTextStores() throws {
        let defaults = makeDefaults()
        var state = SavedState()
        state.takes = [Take(id: UUID(), date: Date(), raw: "private original", text: "private result", source: "sample", isSpeech: false)]
        state.terms = [.init(heard: "private alias", written: "private spelling")]
        state.shortcuts = [.init(trigger: "private trigger", expansion: "private expansion")]
        let data = try JSONEncoder().encode(state)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["takes"]); XCTAssertNil(object["terms"]); XCTAssertNil(object["shortcuts"])
        XCTAssertFalse(json.contains("private original")); XCTAssertFalse(json.contains("private trigger")); XCTAssertFalse(json.contains("private alias"))
        let reloaded = try JSONDecoder().decode(SavedState.self, from: data)
        XCTAssertTrue(reloaded.takes.isEmpty); XCTAssertEqual(reloaded.styles, state.styles)
    }
    func testVocabularyRenameUpdatesNativeHintAndCreatesSpellingAlias() throws {
        let directory = try TestSupport.makeTemporaryDirectory(); defer { TestSupport.remove(directory) }
        let service = DictionaryService(appSupportDirectory: directory)
        service.addEntry(type: .term, original: "Kivistone", caseSensitive: true)
        let id = try XCTUnwrap(service.entries.first?.id)
        KiviDictionaryAdapter.reconcile([.init(id: id, heard: "Kivistone", written: "KiviStoneLabs")], baseline: [id], service: service)
        XCTAssertEqual(service.terms.first?.original, "KiviStoneLabs")
        XCTAssertEqual(service.previewCorrections(to: "Use Kivistone."), "Use KiviStoneLabs.")
        XCTAssertEqual(service.terms.first?.id, id); XCTAssertEqual(service.terms.first?.caseSensitive, true)
    }
    func testWordDialogSavesHintAndOptionalCorrectionAcrossReload() throws {
        let directory = try TestSupport.makeTemporaryDirectory(); defer { TestSupport.remove(directory) }
        let service = DictionaryService(appSupportDirectory: directory)
        try KiviDictionaryAdapter.saveWord(written: "  KiviStone  ", misspelling: nil, editing: nil, service: service)
        try KiviDictionaryAdapter.saveWord(written: "KiviStone", misspelling: " kiwi stone ", editing: nil, service: service)
        let reloaded = DictionaryService(appSupportDirectory: directory)
        XCTAssertEqual(reloaded.enabledTerms(), ["KiviStone"])
        XCTAssertEqual(reloaded.previewCorrections(to: "Use kiwi stone."), "Use KiviStone.")
        XCTAssertThrowsError(try KiviDictionaryAdapter.saveWord(written: "Other", misspelling: "KIWI STONE", editing: nil, service: reloaded))
        XCTAssertThrowsError(try KiviDictionaryAdapter.saveWord(written: " ", misspelling: nil, editing: nil, service: reloaded))
        XCTAssertThrowsError(try KiviDictionaryAdapter.saveWord(written: "KiviStone", misspelling: " ", editing: nil, service: reloaded))
    }
    func testWordDialogCanSwitchModesWithoutDeletingOtherAliases() throws {
        let directory = try TestSupport.makeTemporaryDirectory(); defer { TestSupport.remove(directory) }
        let service = DictionaryService(appSupportDirectory: directory)
        service.addEntry(type: .correction, original: "kiwi stone", replacement: "KiviStone")
        service.addEntry(type: .correction, original: "kivy stone", replacement: "KiviStone")
        let id = try XCTUnwrap(service.entries.first(where: { $0.original == "kiwi stone" })?.id)
        try KiviDictionaryAdapter.saveWord(written: "KiviStone", misspelling: nil, editing: id, service: service)
        XCTAssertEqual(service.entries.first(where: { $0.id == id })?.type, .term)
        XCTAssertEqual(service.previewCorrections(to: "kiwi stone and kivy stone"), "kiwi stone and KiviStone")
        try KiviDictionaryAdapter.saveWord(written: "KiviStone", misspelling: "kiwi stone", editing: id, service: service)
        XCTAssertEqual(service.entries.first(where: { $0.id == id })?.type, .correction)
        XCTAssertEqual(service.entries.count, 2)
        XCTAssertEqual(service.previewCorrections(to: "kiwi stone and kivy stone"), "KiviStone and KiviStone")
    }
    func testEditingLearnedRulePreservesIdentityProvenanceAndDisabledState() throws {
        let directory = try TestSupport.makeTemporaryDirectory(); defer { TestSupport.remove(directory) }
        let service = DictionaryService(appSupportDirectory: directory)
        service.addEntry(type: .correction, original: "Rohan", replacement: "Rohaan", source: .autoLearned)
        let entry = try XCTUnwrap(service.entries.first); let id = entry.id
        service.setEntryEnabled(entry, enabled: false)
        KiviDictionaryAdapter.reconcile([.init(id: id, heard: "Rohan", written: "Rohann")], baseline: [id], service: service)
        let updated = try XCTUnwrap(service.entries.first)
        XCTAssertEqual(updated.id, id); XCTAssertEqual(updated.source, .autoLearned); XCTAssertFalse(updated.isEnabled)
        XCTAssertEqual(updated.replacement, "Rohann")
    }
    func testStaleDictionaryProjectionCannotDeleteNewlyLearnedRule() throws {
        let directory = try TestSupport.makeTemporaryDirectory(); defer { TestSupport.remove(directory) }
        let service = DictionaryService(appSupportDirectory: directory)
        service.addEntry(type: .term, original: "OldTerm")
        let oldID = try XCTUnwrap(service.entries.first?.id)
        service.addEntry(type: .correction, original: "NewAlias", replacement: "NewTerm", source: .autoLearned)
        KiviDictionaryAdapter.reconcile([], baseline: [oldID], service: service)
        XCTAssertEqual(service.entries.count, 1); XCTAssertEqual(service.entries.first?.replacement, "NewTerm")
    }

    func testTypedPreviewBecomesUnusableWhenInputsChange() async {
        let editor = IntentSelectionEditor(client: KiviFakeEditor(text: "Design is ready. Send review Thursday."))
        editor.openTyped(); editor.source = "The design is ready. Please send review by Thursday."; editor.instruction = "Make it concise."
        editor.rewrite()
        for _ in 0..<100 { if !editor.busy { break }; await Task.yield() }
        XCTAssertTrue(editor.hasCurrentPreview)
        editor.instruction = "Make a list."
        XCTAssertFalse(editor.hasCurrentPreview); XCTAssertFalse(editor.canApply)
    }

    func testPresentationWritesStayOrderedAndDoNotPersistCollections() async throws {
        let directory = try TestSupport.makeTemporaryDirectory(); defer { TestSupport.remove(directory) }
        let url = directory.appendingPathComponent("presentation.json")
        let writer = KiviPresentationWriter()
        let completed = expectation(description: "writes completed"); completed.expectedFulfillmentCount = 40
        for index in 0..<40 {
            var state = SavedState(); state.appearance = "mode-\(index)"
            state.takes = [.init(id: UUID(), date: Date(), raw: "secret", text: "secret", source: "test", isSpeech: false)]
            writer.write(try JSONEncoder().encode(state), to: url) { error in
                XCTAssertNil(error); completed.fulfill()
            }
        }
        await fulfillment(of: [completed], timeout: 10)
        let data = try Data(contentsOf: url)
        XCTAssertEqual(try JSONDecoder().decode(SavedState.self, from: data).appearance, "mode-39")
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("secret"))
    }

    func testPagedHistorySearchSummaryAndExportIncludeUnloadedRecords() async throws {
        let directory = try TestSupport.makeTemporaryDirectory(); defer { TestSupport.remove(directory) }
        let service = HistoryService(appSupportDirectory: directory, eventEmitter: { _ in })
        let now = Date()
        for index in 0..<125 {
            service.addRecord(timestamp: now.addingTimeInterval(Double(-index)), rawText: "raw \(index)",
                              finalText: "fixture \(index)", appName: index == 124 ? nil : "Test App",
                              appBundleIdentifier: nil, durationSeconds: 0, language: "en", engineUsed: index == 124 ? "typed" : "test")
        }
        let store = KiviHistoryStore(service: service)
        store.activate()
        try await waitForHistory(store)
        XCTAssertEqual(store.sections.flatMap(\.takes).count, 100)
        XCTAssertTrue(store.hasMore); XCTAssertEqual(store.recent.count, 4)
        store.loadMore(); try await waitForHistory(store)
        XCTAssertEqual(store.sections.flatMap(\.takes).count, 125); XCTAssertFalse(store.hasMore)
        XCTAssertEqual(Set(store.sections.flatMap(\.takes).map(\.id)).count, 125)
        store.search = "raw 124"; try await waitForHistory(store)
        XCTAssertEqual(store.sections.flatMap(\.takes).map(\.text), ["fixture 124"])
        store.search = "writing pad"; store.kind = "typed"; try await waitForHistory(store)
        XCTAssertEqual(store.sections.flatMap(\.takes).count, 1)
        store.source = "TEST APP"; try await waitForHistory(store)
        XCTAssertTrue(store.sections.isEmpty)
        // A superseded debounced search cannot replace the current result.
        store.source = nil; store.kind = "all"; store.search = "raw 12"; store.search = "raw 124"
        try await waitForHistory(store)
        XCTAssertEqual(store.sections.flatMap(\.takes).map(\.text), ["fixture 124"])
        let summary = try await service.kiviSummary(now: now)
        XCTAssertEqual(summary.sources, ["Test App", "writing pad"])
        let destination = directory.appendingPathComponent("export.txt")
        try await service.exportKiviHistory(to: destination)
        let exported = try String(contentsOf: destination, encoding: .utf8)
        XCTAssertTrue(exported.contains("fixture 0")); XCTAssertTrue(exported.contains("fixture 124"))
        XCTAssertEqual(exported.components(separatedBy: "\n\n").count, 125)
        store.deactivate()
    }

    func testKiviDateRangeAndSearchSemantics() throws {
        let record = TranscriptionRecord(rawText: "hello  world", finalText: "Café", appName: nil,
                                         appBundleIdentifier: nil, durationSeconds: 0, language: "en", engineUsed: "typed")
        var query = HistoryQuery(); query.kiviSearch = true
        query.searchText = "  "
        XCTAssertTrue(query.requiresPostFiltering)
        XCTAssertTrue(HistoryPostFilter(query: query).matches(record))
        query.searchText = "writing pad"; query.kiviIsSpeech = false
        XCTAssertTrue(HistoryPostFilter(query: query).matches(record))
        query.kiviIsSpeech = true
        XCTAssertFalse(HistoryPostFilter(query: query).matches(record))
        query.kiviIsSpeech = nil; query.searchText = ""; query.endDate = record.timestamp
        XCTAssertFalse(HistoryPostFilter(query: query).matches(record))
    }

    func testOnePassHistoryGroupingMatchesPreviousGroupingAtScale() {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        for count in [0, 100, 1_000, 10_000] {
            let takes = (0..<count).map { index in
                Take(id: UUID(), date: now.addingTimeInterval(Double(-index * 3600)), raw: "raw", text: "synthetic fixture", source: "Test", isSpeech: true)
            }
            let start = ContinuousClock.now
            let days = Array(Set(takes.map { calendar.startOfDay(for: $0.date) })).sorted(by: >)
            let old = days.map { day in KiviTakeSection(id: day, takes: takes.filter { calendar.startOfDay(for: $0.date) == day }) }
            let oldTime = start.duration(to: .now)
            let optimizedStart = ContinuousClock.now
            let optimized = KiviTakeSection.group(takes, calendar: calendar)
            let newTime = optimizedStart.duration(to: .now)
            XCTAssertEqual(old, optimized)
            print("KIVI_GROUP_BENCH records=\(count) old=\(oldTime) new=\(newTime)")
        }
    }

    private func waitForHistory(_ store: KiviHistoryStore) async throws {
        for _ in 0..<500 {
            if !store.loading { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("History query did not finish")
    }

}
