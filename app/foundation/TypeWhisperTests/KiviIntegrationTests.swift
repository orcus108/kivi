import XCTest
import AppKit
import ApplicationServices
@testable import TypeWhisper

private struct KiviFakeEditor: IntentTextEditing {
    var text: String
    var fails = false
    func rewrite(source: String, instruction: String) async throws -> String {
        if fails { throw IntentEditingError.unavailable }
        return text
    }
}
private struct KiviFakeTalkPlanner: KiviTalkPlanning {
    let value: KiviTalkReply
    var delay: Duration = .zero
    func reply(messages: [KiviTalkMessage], context: String) async throws -> KiviTalkReply {
        if delay != .zero { try? await Task.sleep(for: delay) }
        return value
    }
}
private actor KiviRecoveringTalkPlanner: KiviTalkPlanning {
    var attempts = 0
    func reply(messages: [KiviTalkMessage], context: String) async throws -> KiviTalkReply {
        attempts += 1
        if attempts == 1 { throw URLError(.notConnectedToInternet) }
        return .init(message: "Which Mac apps should this apply to?", ready: false, apps: [], instructions: "", mode: "unchanged")
    }
}
private final class KiviJournalFailDefaults: UserDefaults, @unchecked Sendable {
    override func set(_ value: Any?, forKey key: String) {
        if key != "kiviForYouChangeHistory" { super.set(value, forKey: key) }
    }
}
@MainActor final class KiviIntegrationTests: XCTestCase {
    private struct HistoryFixture: Encodable {
        var version = 1
        var records: [KiviTalkChangeRecord]
    }

    func testRemoveOlderPreferenceKeepsLaterRulesAndTone() throws {
        let defaults = makeDefaults()
        let first = try KiviTalkChanges.apply(KiviTalkChanges.propose(talkReply(apps: ["ChatGPT", "Claude"], instructions: "Keep filler words.", mode: "casual"), defaults: defaults), defaults: defaults)
        let second = try KiviTalkChanges.apply(KiviTalkChanges.propose(talkReply(apps: ["ChatGPT"], instructions: "Use short paragraphs.", mode: "formal"), defaults: defaults), defaults: defaults)
        let group = KiviStyleRouter.load(defaults: defaults).styles
        try KiviTalkChangeHistory.remove(first.changeID!, defaults: defaults)
        var config = KiviStyleRouter.load(defaults: defaults)
        XCTAssertFalse(config.overrides["ChatGPT"]!.rules.contains("Keep filler words."))
        XCTAssertTrue(config.overrides["ChatGPT"]!.rules.contains("Use short paragraphs."))
        XCTAssertEqual(config.overrides["ChatGPT"]!.mode, "formal")
        XCTAssertNil(config.overrides["Claude"])
        XCTAssertEqual(config.styles, group)
        XCTAssertEqual(try KiviTalkChangeHistory.load(defaults: defaults).last?.state, .removed)
        try KiviTalkChangeHistory.remove(second.changeID!, defaults: defaults)
        config = KiviStyleRouter.load(defaults: defaults)
        XCTAssertNil(config.overrides["ChatGPT"])
        XCTAssertFalse(config.enabled.contains("app:ChatGPT"))
    }

    func testRemoveLatestPreferenceDoesNotResurrectRemovedTone() throws {
        let defaults = makeDefaults()
        let first = try KiviTalkChanges.apply(KiviTalkChanges.propose(talkReply(apps: ["ChatGPT"], instructions: "First preference.", mode: "casual"), defaults: defaults), defaults: defaults)
        let second = try KiviTalkChanges.apply(KiviTalkChanges.propose(talkReply(apps: ["ChatGPT"], instructions: "Second preference.", mode: "formal"), defaults: defaults), defaults: defaults)
        try KiviTalkChangeHistory.remove(first.changeID!, defaults: defaults)
        var config = KiviStyleRouter.load(defaults: defaults)
        config.overrides["ChatGPT"]?.rules += "\nManually added rule."
        config.overrides["ChatGPT"]?.mode = "professional"
        let data = try JSONEncoder().encode(config)
        defaults.set(data, forKey: KiviStyleRouter.key)
        try KiviTalkChangeHistory.remove(second.changeID!, defaults: defaults)
        let final = KiviStyleRouter.load(defaults: defaults)
        XCTAssertEqual(final.overrides["ChatGPT"]?.mode, "professional")
        XCTAssertEqual(final.overrides["ChatGPT"]?.rules, "Manually added rule.")
        XCTAssertThrowsError(try KiviTalkChangeHistory.remove(first.changeID!, defaults: defaults))
    }

    func testRemoveChangeRetainsIndependentAppAndSurvivesReload() throws {
        let defaults = makeDefaults()
        let first = try KiviTalkChanges.apply(KiviTalkChanges.propose(talkReply(apps: ["ChatGPT"], instructions: "Keep filler words."), defaults: defaults), defaults: defaults)
        _ = try KiviTalkChanges.apply(KiviTalkChanges.propose(talkReply(apps: ["Slack"], instructions: "Keep messages casual."), defaults: defaults), defaults: defaults)
        let slack = KiviStyleRouter.load(defaults: defaults).overrides["Slack"]
        try KiviTalkChangeHistory.remove(first.changeID!, defaults: defaults)
        XCTAssertEqual(KiviStyleRouter.load(defaults: defaults).overrides["Slack"], slack)
        let record = try XCTUnwrap(KiviTalkChangeHistory.load(defaults: defaults).last)
        XCTAssertEqual(record.state, .removed)
        XCTAssertFalse(KiviTalkChangeHistory.canRemove(record, defaults: defaults))
    }

    func testRemoveInheritedToneAndRecoverPendingRemoval() throws {
        let defaults = makeDefaults()
        let receipt = try KiviTalkChanges.apply(KiviTalkChanges.propose(talkReply(apps: ["ChatGPT"], instructions: "Keep filler words.", mode: "unchanged"), defaults: defaults), defaults: defaults)
        try KiviTalkChangeHistory.remove(receipt.changeID!, defaults: defaults)
        XCTAssertNil(KiviStyleRouter.load(defaults: defaults).overrides["ChatGPT"])
        var records = try KiviTalkChangeHistory.load(defaults: defaults)
        records[0].state = .undoing
        defaults.set(try JSONEncoder().encode(HistoryFixture(records: records)), forKey: KiviTalkChangeHistory.key)
        XCTAssertEqual(try KiviTalkChangeHistory.load(defaults: defaults)[0].state, .removed)
        defaults.set(records[0].undoSource, forKey: KiviStyleRouter.key)
        defaults.set(try JSONEncoder().encode(HistoryFixture(records: records)), forKey: KiviTalkChangeHistory.key)
        XCTAssertEqual(try KiviTalkChangeHistory.load(defaults: defaults)[0].state, .saved)
    }

    func testRemovalFailureDoesNotChangeStyles() throws {
        let defaults = makeDefaults()
        let receipt = try KiviTalkChanges.apply(KiviTalkChanges.propose(talkReply(), defaults: defaults), defaults: defaults)
        // Corrupt history is refused before any style write.
        defaults.set(Data("broken".utf8), forKey: KiviTalkChangeHistory.key)
        let current = defaults.data(forKey: KiviStyleRouter.key)
        XCTAssertThrowsError(try KiviTalkChangeHistory.remove(receipt.changeID!, defaults: defaults))
        XCTAssertEqual(defaults.data(forKey: KiviStyleRouter.key), current)
    }

    func testRemoveLegacyReplacementKeepsLaterInstruction() throws {
        let defaults = makeDefaults()
        var before = KiviStyleConfiguration()
        before.overrides["ChatGPT"] = WritingStyle.defaults[0]
        before.enabled.insert("app:ChatGPT")
        var after = before
        after.overrides["ChatGPT"]?.rules = "Keep original wording."
        let record = KiviTalkChangeRecord(id: UUID(), date: Date(), apps: ["ChatGPT"], instructions: "Keep original wording.", before: try JSONEncoder().encode(before), after: try JSONEncoder().encode(after), state: .saved)
        defaults.set(try JSONEncoder().encode(HistoryFixture(records: [record])), forKey: KiviTalkChangeHistory.key)
        defaults.set(record.after, forKey: KiviStyleRouter.key)
        _ = try KiviTalkChanges.apply(KiviTalkChanges.propose(talkReply(apps: ["ChatGPT"], instructions: "Use short paragraphs."), defaults: defaults), defaults: defaults)
        try KiviTalkChangeHistory.remove(record.id, defaults: defaults)
        let rules = KiviStyleRouter.load(defaults: defaults).overrides["ChatGPT"]!.rules
        XCTAssertTrue(rules.contains(WritingStyle.defaults[0].rules))
        XCTAssertTrue(rules.contains("Use short paragraphs."))
        XCTAssertFalse(rules.contains("Keep original wording."))
    }

    func testRepeatedInstructionRemainsUntilLastOwnerIsRemoved() throws {
        let defaults = makeDefaults()
        let first = try KiviTalkChanges.apply(KiviTalkChanges.propose(talkReply(apps: ["ChatGPT"], instructions: "Keep filler words.", mode: "casual"), defaults: defaults), defaults: defaults)
        let second = try KiviTalkChanges.apply(KiviTalkChanges.propose(talkReply(apps: ["ChatGPT"], instructions: "Keep filler words.", mode: "formal"), defaults: defaults), defaults: defaults)
        try KiviTalkChangeHistory.remove(first.changeID!, defaults: defaults)
        XCTAssertTrue(KiviStyleRouter.load(defaults: defaults).overrides["ChatGPT"]!.rules.contains("Keep filler words."))
        try KiviTalkChangeHistory.remove(second.changeID!, defaults: defaults)
        XCTAssertNil(KiviStyleRouter.load(defaults: defaults).overrides["ChatGPT"])
    }

    func testChangeHistoryStartsEmptyAndDoesNotLogUnappliedProposals() throws {
        let defaults = makeDefaults()
        _ = try KiviTalkChanges.propose(talkReply(), defaults: defaults)
        XCTAssertTrue(try KiviTalkChangeHistory.load(defaults: defaults).isEmpty)
        XCTAssertNil(defaults.data(forKey: KiviTalkChangeHistory.key))
    }

    func testChangeHistoryPersistsActualAppsInstructionsAndExactSnapshots() throws {
        let defaults = makeDefaults()
        KiviStyleRouter.save(WritingStyle.defaults[3], app: nil, defaults: defaults)
        let before = defaults.data(forKey: KiviStyleRouter.key)
        let proposal = try KiviTalkChanges.propose(talkReply(), defaults: defaults)
        let receipt = try KiviTalkChanges.apply(proposal, defaults: defaults)
        let reloaded = KiviTalkConversation(defaults: defaults)
        let record = try XCTUnwrap(reloaded.changes.first)
        XCTAssertEqual(record.id, receipt.changeID)
        XCTAssertEqual(record.apps, ["ChatGPT", "Claude"])
        XCTAssertEqual(record.instructions, proposal.instructions)
        XCTAssertEqual(record.before, before)
        XCTAssertEqual(record.after, defaults.data(forKey: KiviStyleRouter.key))
        XCTAssertEqual(record.state, .saved)
        XCTAssertTrue(reloaded.canUndoChange(record))
    }

    func testChangeHistoryUndoUpdatesOneEntryAndRestoresExactPreviousState() throws {
        for existing in [false, true] {
            let defaults = makeDefaults()
            if existing { KiviStyleRouter.save(WritingStyle.defaults[3], app: nil, defaults: defaults) }
            let before = defaults.data(forKey: KiviStyleRouter.key)
            let receipt = try KiviTalkChanges.apply(KiviTalkChanges.propose(talkReply(), defaults: defaults), defaults: defaults)
            try KiviTalkChanges.undo(receipt, defaults: defaults)
            let records = try KiviTalkChangeHistory.load(defaults: defaults)
            XCTAssertEqual(records.count, 1)
            XCTAssertEqual(records.first?.state, .undone)
            XCTAssertNotNil(records.first?.undoneAt)
            XCTAssertEqual(defaults.data(forKey: KiviStyleRouter.key), before)
            XCTAssertFalse(KiviTalkChangeHistory.canUndo(records[0], defaults: defaults))
        }
    }

    func testChangeHistoryCanWalkBackSavedChangesWithoutErasingTheLog() throws {
        let defaults = makeDefaults()
        let first = try KiviTalkChanges.apply(KiviTalkChanges.propose(talkReply(), defaults: defaults), defaults: defaults)
        let second = try KiviTalkChanges.apply(KiviTalkChanges.propose(talkReply(apps: ["Slack"], instructions: "Keep messages casual."), defaults: defaults), defaults: defaults)
        var records = try KiviTalkChangeHistory.load(defaults: defaults)
        XCTAssertEqual(records.map(\.id), [second.changeID!, first.changeID!])
        XCTAssertTrue(KiviTalkChangeHistory.canUndo(records[1], defaults: defaults))
        try KiviTalkChangeHistory.undo(second.changeID!, defaults: defaults)
        records = try KiviTalkChangeHistory.load(defaults: defaults)
        XCTAssertTrue(KiviTalkChangeHistory.canUndo(records[1], defaults: defaults))
        try KiviTalkChangeHistory.undo(first.changeID!, defaults: defaults)
        XCTAssertNil(defaults.data(forKey: KiviStyleRouter.key))
        XCTAssertTrue(try KiviTalkChangeHistory.load(defaults: defaults).allSatisfy { $0.state == .undone })
    }

    func testScopedHistoryUndoPreservesUnrelatedAppsAndBlocksSameAppEdits() throws {
        let defaults = makeDefaults()
        let first = try KiviTalkChanges.apply(KiviTalkChanges.propose(talkReply(apps: ["ChatGPT"], instructions: "Keep my wording."), defaults: defaults), defaults: defaults)
        _ = try KiviTalkChanges.apply(KiviTalkChanges.propose(talkReply(apps: ["Slack"], instructions: "Keep messages casual."), defaults: defaults), defaults: defaults)
        let slack = KiviStyleRouter.load(defaults: defaults).overrides["Slack"]
        try KiviTalkChanges.undo(first, defaults: defaults)
        XCTAssertEqual(KiviStyleRouter.load(defaults: defaults).overrides["Slack"], slack)
        XCTAssertNil(KiviStyleRouter.load(defaults: defaults).overrides["ChatGPT"])
        let older = try KiviTalkChanges.apply(KiviTalkChanges.propose(talkReply(apps: ["ChatGPT"], instructions: "Keep my wording."), defaults: defaults), defaults: defaults)
        _ = try KiviTalkChanges.apply(KiviTalkChanges.propose(talkReply(apps: ["ChatGPT"], instructions: "Keep filler words."), defaults: defaults), defaults: defaults)
        let current = defaults.data(forKey: KiviStyleRouter.key)
        XCTAssertThrowsError(try KiviTalkChanges.undo(older, defaults: defaults))
        XCTAssertEqual(defaults.data(forKey: KiviStyleRouter.key), current)
    }

    func testChangeHistoryCannotUndoAfterExternalStylesEdit() throws {
        let defaults = makeDefaults()
        let receipt = try KiviTalkChanges.apply(KiviTalkChanges.propose(talkReply(), defaults: defaults), defaults: defaults)
        KiviStyleRouter.save(WritingStyle.defaults[3], app: "ChatGPT", defaults: defaults)
        let current = defaults.data(forKey: KiviStyleRouter.key)
        XCTAssertThrowsError(try KiviTalkChangeHistory.undo(receipt.changeID!, defaults: defaults))
        XCTAssertEqual(defaults.data(forKey: KiviStyleRouter.key), current)
        XCTAssertEqual(try KiviTalkChangeHistory.load(defaults: defaults).first?.state, .saved)
    }

    func testChangeHistoryFailureBlocksStyleWriteAndPreservesCorruptArchive() throws {
        let failing = KiviJournalFailDefaults(suiteName: "KiviJournalFail.\(UUID())")!
        XCTAssertThrowsError(try KiviTalkChanges.apply(KiviTalkChanges.propose(talkReply(), defaults: failing), defaults: failing))
        XCTAssertNil(failing.data(forKey: KiviStyleRouter.key))
        let defaults = makeDefaults(), corrupt = Data("unreadable history".utf8)
        defaults.set(corrupt, forKey: KiviTalkChangeHistory.key)
        XCTAssertThrowsError(try KiviTalkChanges.apply(KiviTalkChanges.propose(talkReply(), defaults: defaults), defaults: defaults))
        XCTAssertEqual(defaults.data(forKey: KiviTalkChangeHistory.key), corrupt)
        XCTAssertNil(defaults.data(forKey: KiviStyleRouter.key))
        XCTAssertNotNil(KiviTalkConversation(defaults: defaults).historyError)
    }

    func testChangeHistoryRecoversInterruptedApplyWithoutInventingSuccess() throws {
        for outcome in ["saved", "notSaved", "unknown"] {
            let defaults = makeDefaults()
            let proposal = try KiviTalkChanges.propose(talkReply(), defaults: defaults)
            let after = try JSONEncoder().encode(proposal.configuration)
            _ = try KiviTalkChangeHistory.prepare(proposal, after: after, defaults: defaults)
            if outcome == "saved" { defaults.set(after, forKey: KiviStyleRouter.key) }
            if outcome == "unknown" { KiviStyleRouter.save(WritingStyle.defaults[3], app: nil, defaults: defaults) }
            let current = defaults.data(forKey: KiviStyleRouter.key)
            let state = try XCTUnwrap(KiviTalkChangeHistory.load(defaults: defaults).first?.state)
            XCTAssertEqual(state, outcome == "saved" ? .saved : outcome == "notSaved" ? .notSaved : .needsReview)
            XCTAssertEqual(defaults.data(forKey: KiviStyleRouter.key), current)
        }
    }

    func testChangeHistoryRecoversInterruptedUndoAgainstActualSettings() throws {
        for restored in [false, true] {
            let defaults = makeDefaults()
            _ = try KiviTalkChanges.apply(KiviTalkChanges.propose(talkReply(), defaults: defaults), defaults: defaults)
            var records = try KiviTalkChangeHistory.load(defaults: defaults)
            records[0].state = .undoing; records[0].undoneAt = Date()
            defaults.set(try JSONEncoder().encode(HistoryFixture(records: records)), forKey: KiviTalkChangeHistory.key)
            if restored { defaults.removeObject(forKey: KiviStyleRouter.key) }
            XCTAssertEqual(try KiviTalkChangeHistory.load(defaults: defaults).first?.state, restored ? .undone : .saved)
        }
    }

    func testChangeHistoryDoesNotPersistChatMessagesOrExampleTranscripts() async throws {
        let defaults = makeDefaults()
        let conversation = KiviTalkConversation(planner: KiviFakeTalkPlanner(value: talkReply()), editor: KiviFakeEditor(text: "An example."), defaults: defaults)
        conversation.draft = "Unique synthetic chat request, not a saved rule."
        conversation.sample = "Unique synthetic raw example, not a saved rule."
        conversation.send(); try await waitForTalk(conversation)
        conversation.preview(); try await waitForTalk(conversation)
        conversation.apply()
        let archive = String(decoding: try XCTUnwrap(defaults.data(forKey: KiviTalkChangeHistory.key)), as: UTF8.self)
        XCTAssertFalse(archive.contains("Unique synthetic"))
        XCTAssertTrue(archive.contains("Keep my wording"))
        XCTAssertEqual(conversation.changes.count, 1)
    }

    func testSuggestionCaretMovesToEndIncludingRepeatedAndUnicodeText() {
        let editor = KiviTalkComposer.ComposerTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 80))
        let text = "Ask ChatGPT 👋"
        let composer = KiviTalkComposer(text: .constant(text), focused: .constant(false), height: .constant(54), caretToEndRequest: UUID(), onSend: {})
        let coordinator = composer.makeCoordinator()
        coordinator.updateText(editor)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: text.utf16.count, length: 0))
        editor.insertText(" extra", replacementRange: editor.selectedRange())
        XCTAssertEqual(editor.string, text + " extra")
        coordinator.parent = KiviTalkComposer(text: .constant(text), focused: .constant(false), height: .constant(54), caretToEndRequest: UUID(), onSend: {})
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        coordinator.updateText(editor)
        XCTAssertEqual(editor.string, text)
        XCTAssertEqual(editor.selectedRange().location, text.utf16.count)
    }

    func testSuggestionCaretRequestDoesNotResetNormalEditingSelection() {
        let editor = KiviTalkComposer.ComposerTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 80))
        let request = UUID()
        let coordinator = KiviTalkComposer(text: .constant("Synthetic request"), focused: .constant(false), height: .constant(54), caretToEndRequest: request, onSend: {}).makeCoordinator()
        coordinator.updateText(editor)
        editor.setSelectedRange(NSRange(location: 4, length: 0))
        coordinator.updateText(editor)
        XCTAssertEqual(editor.selectedRange().location, 4)
        coordinator.parent = KiviTalkComposer(text: .constant("ab"), focused: .constant(false), height: .constant(54), caretToEndRequest: request, onSend: {})
        coordinator.updateText(editor)
        XCTAssertEqual(editor.selectedRange().location, 2)
    }

    private func returnEvent(shift: Bool = false, command: Bool = false, keypad: Bool = false, repeating: Bool = false) -> NSEvent {
        var flags: NSEvent.ModifierFlags = []
        if shift { flags.insert(.shift) }; if command { flags.insert(.command) }
        return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                               windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: repeating, keyCode: keypad ? 76 : 36)!
    }

    func testChatReturnSendsAndShiftReturnAddsLineWithoutSending() {
        let editor = KiviTalkComposer.ComposerTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 80))
        var sends = 0
        editor.onSend = { sends += 1 }
        editor.string = "Synthetic request"
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        editor.keyDown(with: returnEvent())
        XCTAssertEqual(sends, 1)
        XCTAssertEqual(editor.string, "Synthetic request")
        editor.keyDown(with: returnEvent(shift: true))
        XCTAssertEqual(sends, 1)
        XCTAssertEqual(editor.string, "Synthetic request\n")
        editor.keyDown(with: returnEvent(command: true))
        editor.keyDown(with: returnEvent(keypad: true))
        XCTAssertEqual(sends, 3)
        editor.keyDown(with: returnEvent(repeating: true))
        XCTAssertEqual(sends, 3)
    }

    func testChatBlankReturnAndMarkedTextDoNotSend() {
        let editor = KiviTalkComposer.ComposerTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 80))
        var sends = 0
        editor.onSend = { sends += 1 }
        editor.string = " \n"
        editor.keyDown(with: returnEvent())
        XCTAssertEqual(sends, 0)
        editor.string = ""
        editor.setMarkedText("synthetic", selectedRange: NSRange(location: 9, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(editor.hasMarkedText())
        editor.keyDown(with: returnEvent())
        XCTAssertEqual(sends, 0)
    }

    func testChatComposerGrowsForTrailingNewlineCaretAndShrinksWhenCleared() async throws {
        let editor = KiviTalkComposer.ComposerTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 80))
        editor.font = .systemFont(ofSize: 17)
        editor.textContainerInset = NSSize(width: 0, height: 4)
        var height: CGFloat = 0
        editor.onHeightChange = { height = $0 }
        editor.string = "First line\nSecond line\n"
        editor.reportHeight()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertGreaterThan(height, 54, "The empty line containing the caret needs space too")
        editor.string = String(repeating: "Synthetic line\n", count: 20)
        editor.reportHeight()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(height, 140)
        editor.string = ""
        editor.reportHeight()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(height, 54)
    }

    func testChatRetryPreservesNextDraftAndDoesNotDuplicateUserMessage() async throws {
        let defaults = makeDefaults()
        let conversation = KiviTalkConversation(planner: KiviRecoveringTalkPlanner(), defaults: defaults)
        conversation.draft = "My messages sound too formal."
        conversation.send(); try await waitForTalk(conversation)
        XCTAssertTrue(conversation.canRetry)
        XCTAssertEqual(conversation.messages.count, 1)
        conversation.draft = "Unsent next message."
        conversation.retry(); try await waitForTalk(conversation)
        XCTAssertEqual(conversation.messages.filter { $0.role == "user" }.count, 1)
        XCTAssertEqual(conversation.messages.count, 2)
        XCTAssertEqual(conversation.draft, "Unsent next message.")
        XCTAssertFalse(conversation.canRetry)
        XCTAssertNil(conversation.error)
        XCTAssertNil(defaults.data(forKey: KiviStyleRouter.key))
    }

    func testChatStopReportsOutcomeAndKeepsUnsentDraftAndRetry() async throws {
        let conversation = KiviTalkConversation(planner: KiviFakeTalkPlanner(value: talkReply(), delay: .milliseconds(80)), defaults: makeDefaults())
        conversation.draft = "Keep my wording in Claude."
        conversation.send()
        await Task.yield()
        conversation.draft = "Next unsent thought."
        XCTAssertFalse(conversation.canSend)
        conversation.stop()
        XCTAssertEqual(conversation.notice, "Stopped. Nothing was saved.")
        XCTAssertTrue(conversation.canRetry)
        XCTAssertTrue(conversation.canSend)
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(conversation.messages.count, 1)
        XCTAssertEqual(conversation.draft, "Next unsent thought.")
    }

    func testChatImmediateStopNeverStartsThePlanner() async throws {
        let planner = KiviRecoveringTalkPlanner()
        let conversation = KiviTalkConversation(planner: planner, defaults: makeDefaults())
        conversation.draft = "Synthetic request."
        conversation.send()
        conversation.stop()
        try await Task.sleep(for: .milliseconds(20))
        let attempts = await planner.attempts
        XCTAssertEqual(attempts, 0)
        XCTAssertTrue(conversation.canRetry)
        XCTAssertEqual(conversation.messages.count, 1)
    }

    func testChatSendGateRejectsBlankOversizeAndBusyWithoutDroppingDraft() {
        let conversation = KiviTalkConversation(defaults: makeDefaults())
        conversation.draft = " \n"; XCTAssertFalse(conversation.canSend)
        conversation.draft = String(repeating: "x", count: 2001)
        XCTAssertFalse(conversation.canSend)
        conversation.send()
        XCTAssertNotNil(conversation.error)
        XCTAssertEqual(conversation.draft.count, 2001)
        XCTAssertTrue(conversation.messages.isEmpty)
    }

    func testChatHistorySurvivesReloadAndRequiresFreshProposalReview() async throws {
        let defaults = makeDefaults()
        let conversation = KiviTalkConversation(planner: KiviFakeTalkPlanner(value: talkReply()), defaults: defaults)
        conversation.draft = "Keep my wording in Claude."
        conversation.send(); try await waitForTalk(conversation)
        let id = conversation.chatID
        conversation.sample = "Synthetic example."
        conversation.draft = "A follow-up draft."
        let reloaded = KiviTalkConversation(defaults: defaults)
        XCTAssertEqual(reloaded.chatID, id)
        XCTAssertEqual(reloaded.messages, conversation.messages)
        XCTAssertEqual(reloaded.draft, "A follow-up draft.")
        XCTAssertEqual(reloaded.sample, "Synthetic example.")
        XCTAssertNil(reloaded.proposal)
        XCTAssertFalse(reloaded.canApply)
        XCTAssertEqual(reloaded.archivedPreferenceState, "not saved")
        reloaded.reviewArchivedPreference()
        XCTAssertNotNil(reloaded.proposal)
        XCTAssertFalse(reloaded.canApply)
        XCTAssertNil(defaults.data(forKey: KiviStyleRouter.key))
        reloaded.newConversation()
        reloaded.draft = "Another chat draft."
        let secondID = reloaded.chatID
        reloaded.openChat(id)
        XCTAssertEqual(reloaded.draft, "A follow-up draft.")
        reloaded.openChat(secondID)
        XCTAssertEqual(reloaded.draft, "Another chat draft.")
        XCTAssertEqual(reloaded.chats.count, 2)
    }

    func testDeletingChatDoesNotChangeSavedPreferencesOrOtherDrafts() {
        let defaults = makeDefaults()
        let original = Data("synthetic style data".utf8)
        defaults.set(original, forKey: KiviStyleRouter.key)
        let conversation = KiviTalkConversation(defaults: defaults)
        conversation.draft = "First draft"
        let first = conversation.chatID
        conversation.newConversation(); conversation.draft = "Second draft"
        conversation.deleteChat(first)
        XCTAssertEqual(conversation.draft, "Second draft")
        XCTAssertEqual(conversation.chats.count, 1)
        conversation.deleteChat(conversation.chatID)
        XCTAssertTrue(conversation.chats.isEmpty)
        XCTAssertTrue(conversation.draft.isEmpty)
        XCTAssertEqual(defaults.data(forKey: KiviStyleRouter.key), original)
        XCTAssertTrue(KiviTalkConversation(defaults: defaults).chats.isEmpty)
    }

    func testCorruptChatHistoryIsNotOverwritten() {
        let defaults = makeDefaults()
        let key = "kiviForYouChatsV1"
        let original = Data("invalid synthetic archive".utf8)
        defaults.set(original, forKey: key)
        let conversation = KiviTalkConversation(defaults: defaults)
        XCTAssertNotNil(conversation.chatError)
        conversation.draft = "A new draft."
        conversation.newConversation()
        XCTAssertEqual(defaults.data(forKey: key), original)
        XCTAssertNil(defaults.data(forKey: KiviStyleRouter.key))
    }

    private func waitForTalk(_ conversation: KiviTalkConversation) async throws {
        for _ in 0..<200 {
            if !conversation.busy { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Synthetic conversation did not finish")
    }

    func testTalkCompleteTypedFlowRequiresFreshPreviewAndCanUndo() async throws {
        let defaults = makeDefaults()
        let conversation = KiviTalkConversation(planner: KiviFakeTalkPlanner(value: talkReply()), editor: KiviFakeEditor(text: "Launch Monday."), defaults: defaults)
        conversation.draft = "Keep my wording in the ChatGPT and Claude Mac apps."
        conversation.send(); try await waitForTalk(conversation)
        XCTAssertNotNil(conversation.proposal)
        XCTAssertFalse(conversation.canApply)
        XCTAssertNil(defaults.data(forKey: KiviStyleRouter.key))
        conversation.preview(); try await waitForTalk(conversation)
        XCTAssertTrue(conversation.canApply)
        conversation.sample = "A different example."
        XCTAssertFalse(conversation.canApply)
        conversation.preview(); try await waitForTalk(conversation)
        conversation.apply()
        XCTAssertNotNil(conversation.undoReceipt)
        XCTAssertNotNil(KiviStyleRouter.load(defaults: defaults).overrides["Claude"])
        conversation.undo()
        XCTAssertNil(defaults.data(forKey: KiviStyleRouter.key))
    }

    func testTalkLateModelReplyCannotReviveCancelledProposal() async throws {
        let defaults = makeDefaults()
        let conversation = KiviTalkConversation(planner: KiviFakeTalkPlanner(value: talkReply(), delay: .milliseconds(80)), defaults: defaults)
        conversation.draft = "Keep my wording in Claude."
        conversation.send()
        await Task.yield()
        conversation.stop()
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertFalse(conversation.busy)
        XCTAssertNil(conversation.proposal)
        XCTAssertEqual(conversation.messages.count, 1)
        XCTAssertNil(defaults.data(forKey: KiviStyleRouter.key))
    }

    func testTalkModelResponseBasedOnOutdatedSettingsCannotBecomeProposal() async throws {
        let defaults = makeDefaults()
        let conversation = KiviTalkConversation(planner: KiviFakeTalkPlanner(value: talkReply(), delay: .milliseconds(80)), defaults: defaults)
        conversation.draft = "Keep my wording in Claude."
        conversation.send()
        try await Task.sleep(for: .milliseconds(20))
        KiviGlobalRules.save([.init(text: "Preserve names.")], defaults: defaults)
        try await waitForTalk(conversation)
        XCTAssertNil(conversation.proposal)
        XCTAssertNotNil(conversation.error)
        XCTAssertNil(defaults.data(forKey: KiviStyleRouter.key))
    }

    func testTalkFailedPreviewNeverEnablesApply() async throws {
        let defaults = makeDefaults()
        let conversation = KiviTalkConversation(planner: KiviFakeTalkPlanner(value: talkReply()), editor: KiviFakeEditor(text: "", fails: true), defaults: defaults)
        conversation.draft = "Keep my wording in Claude."
        conversation.send(); try await waitForTalk(conversation)
        conversation.preview(); try await waitForTalk(conversation)
        XCTAssertNotNil(conversation.error)
        XCTAssertFalse(conversation.canApply)
        XCTAssertNil(defaults.data(forKey: KiviStyleRouter.key))
    }

    private func talkReply(apps: [String] = ["ChatGPT", "Claude"], instructions: String = "Keep my wording. Fix punctuation only.", mode: String = "natural") -> KiviTalkReply {
        .init(message: "I can preserve your wording in these apps.", ready: true, apps: apps, instructions: instructions, mode: mode)
    }

    func testTalkProposalDoesNotWriteAndOnlyChangesNamedAppExceptions() throws {
        let defaults = makeDefaults()
        var initial = KiviStyleConfiguration()
        var mail = WritingStyle.defaults[3]; mail.rules = "Keep my sign-off."
        initial.overrides["Mail"] = mail; initial.enabled.insert("app:Mail")
        let data = try JSONEncoder().encode(initial); defaults.set(data, forKey: KiviStyleRouter.key)
        let proposal = try KiviTalkChanges.propose(talkReply(), defaults: defaults)
        XCTAssertEqual(defaults.data(forKey: KiviStyleRouter.key), data)
        XCTAssertEqual(proposal.configuration.styles, initial.styles)
        XCTAssertEqual(proposal.configuration.overrides["Mail"], mail)
        XCTAssertEqual(proposal.configuration.overrides["Claude"]?.mode, "natural")
        XCTAssertTrue(proposal.configuration.enabled.contains("app:ChatGPT"))
        XCTAssertEqual(proposal.apps, ["ChatGPT", "Claude"])
    }

    func testTalkApplyReloadAndUndoRestoreExactAbsentOrExistingConfiguration() throws {
        for existing in [false, true] {
            let defaults = makeDefaults()
            if existing { KiviStyleRouter.save(WritingStyle.defaults[3], app: nil, defaults: defaults) }
            let before = defaults.data(forKey: KiviStyleRouter.key)
            let proposal = try KiviTalkChanges.propose(talkReply(), defaults: defaults)
            let receipt = try KiviTalkChanges.apply(proposal, defaults: defaults)
            XCTAssertEqual(KiviStyleRouter.resolved(appName: "Claude", bundleID: nil, defaults: defaults)?.mode, "natural")
            XCTAssertNil(KiviStyleRouter.resolved(appName: "Slack", bundleID: nil, defaults: defaults))
            try KiviTalkChanges.undo(receipt, defaults: defaults)
            XCTAssertEqual(defaults.data(forKey: KiviStyleRouter.key), before)
        }
    }

    func testTalkRejectsChangedStyleAndGlobalRulesBeforeApply() throws {
        for changeGlobal in [false, true] {
            let defaults = makeDefaults()
            let proposal = try KiviTalkChanges.propose(talkReply(), defaults: defaults)
            if changeGlobal { KiviGlobalRules.save([.init(text: "Keep dates.")], defaults: defaults) }
            else { KiviStyleRouter.save(WritingStyle.defaults[3], app: nil, defaults: defaults) }
            XCTAssertThrowsError(try KiviTalkChanges.apply(proposal, defaults: defaults))
            XCTAssertNil(KiviStyleRouter.load(defaults: defaults).overrides["Claude"])
        }
    }

    func testTalkUndoNeverOverwritesLaterStyleEdits() throws {
        let defaults = makeDefaults()
        let receipt = try KiviTalkChanges.apply(KiviTalkChanges.propose(talkReply(), defaults: defaults), defaults: defaults)
        KiviStyleRouter.save(WritingStyle.defaults[3], app: "ChatGPT", defaults: defaults)
        let edited = defaults.data(forKey: KiviStyleRouter.key)
        XCTAssertThrowsError(try KiviTalkChanges.undo(receipt, defaults: defaults))
        XCTAssertEqual(defaults.data(forKey: KiviStyleRouter.key), edited)
    }

    func testTalkRejectsUnknownDuplicateEmptyAndOversizedProposals() {
        for reply in [talkReply(apps: ["invented destination"]), talkReply(apps: ["Claude", "Claude"]), talkReply(apps: []), talkReply(instructions: " "), talkReply(instructions: String(repeating: "x", count: 401))] {
            let defaults = makeDefaults()
            XCTAssertThrowsError(try KiviTalkChanges.propose(reply, defaults: defaults))
            XCTAssertNil(defaults.data(forKey: KiviStyleRouter.key))
        }
    }

    func testTalkPreservesExistingAppRulesAndDoesNotAccumulateIdenticalPreference() throws {
        let defaults = makeDefaults()
        var style = WritingStyle.defaults[4]; style.rules = "Preserve code identifiers."
        KiviStyleRouter.save(style, app: "Claude", defaults: defaults)
        let reply = talkReply(apps: ["Claude"])
        let proposal = try KiviTalkChanges.propose(reply, defaults: defaults)
        XCTAssertTrue(proposal.configuration.overrides["Claude"]!.rules.contains(style.rules))
        _ = try KiviTalkChanges.apply(proposal, defaults: defaults)
        XCTAssertThrowsError(try KiviTalkChanges.propose(reply, defaults: defaults))
    }

    func testTalkCanRefineSavedPreferencesAlongsideExistingGlobalRules() throws {
        let defaults = makeDefaults()
        KiviGlobalRules.save([.init(text: String(repeating: "Preserve dates. ", count: 20))], defaults: defaults)
        let first = try KiviTalkChanges.propose(talkReply(), defaults: defaults)
        _ = try KiviTalkChanges.apply(first, defaults: defaults)
        let refinement = try KiviTalkChanges.propose(talkReply(instructions: "Keep proper capitalization too."), defaults: defaults)
        XCTAssertTrue(refinement.configuration.overrides["Claude"]!.rules.contains(first.instructions))
        XCTAssertTrue(refinement.configuration.overrides["Claude"]!.rules.contains("Keep proper capitalization too."))
    }

    func testLocalEditorRejectsOversizedComposedInstructionsBeforeNetworkRequest() async {
        do {
            _ = try await IntentLocalTextEditor().rewrite(source: "Synthetic example.", instruction: String(repeating: "x", count: 4001))
            XCTFail("Oversized instruction was accepted")
        } catch {
            guard let failure = error as? IntentEditingError, case .invalidInput = failure else {
                XCTFail("Expected input validation, got \(error)"); return
            }
        }
    }

    func testTalkRefusesCorruptSettingsInsteadOfReplacingThem() {
        let defaults = makeDefaults(), corrupt = Data("invalid configuration".utf8)
        defaults.set(corrupt, forKey: KiviStyleRouter.key)
        XCTAssertThrowsError(try KiviTalkChanges.propose(talkReply(), defaults: defaults))
        XCTAssertEqual(defaults.data(forKey: KiviStyleRouter.key), corrupt)
    }

    func testTalkModelReplyRejectsTruncationAndMalformedOutput() throws {
        let reply = talkReply()
        let content = String(decoding: try JSONEncoder().encode(reply), as: UTF8.self)
        for (done, reason) in [(false, "stop"), (true, "length")] {
            let data = try JSONSerialization.data(withJSONObject: ["message": ["content": content], "done": done, "done_reason": reason])
            XCTAssertThrowsError(try KiviTalkLocalPlanner.decode(data))
        }
        let valid = try JSONSerialization.data(withJSONObject: ["message": ["content": content], "done": true])
        XCTAssertEqual(try KiviTalkLocalPlanner.decode(valid), reply)
        XCTAssertThrowsError(try KiviTalkLocalPlanner.decode(Data("{}".utf8)))
    }

    func testTalkGroqDecoderRequiresOneCompleteStructuredResponse() throws {
        let reply = talkReply()
        let content = String(decoding: try JSONEncoder().encode(reply), as: UTF8.self)
        func data(_ finish: String, _ content: String?) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": finish, "message": ["content": content as Any? ?? NSNull()]]]])
        }
        XCTAssertEqual(try KiviTalkGroqPlanner.decode(data("stop", content)), reply)
        XCTAssertThrowsError(try KiviTalkGroqPlanner.decode(data("length", content)))
        XCTAssertThrowsError(try KiviTalkGroqPlanner.decode(data("stop", nil)))
        XCTAssertThrowsError(try KiviTalkGroqPlanner.decode(data("stop", "not JSON")))
        XCTAssertThrowsError(try KiviTalkGroqPlanner.decode(Data("{\"choices\":[]}".utf8)))
    }

    func testTalkProviderSelectionPersistsWithoutChangingWritingRules() {
        let defaults = makeDefaults()
        let conversation = KiviTalkConversation(defaults: defaults)
        conversation.selectGroq(false)
        XCTAssertFalse(KiviTalkConversation(defaults: defaults).usesGroq)
        conversation.selectGroq(true)
        XCTAssertTrue(KiviTalkConversation(defaults: defaults).usesGroq)
        XCTAssertNil(defaults.data(forKey: KiviStyleRouter.key))
    }

    func testTalkPreviewUsesProposedRulesWithoutSavingAndProtectsSpellings() async throws {
        let defaults = makeDefaults()
        let proposal = try KiviTalkChanges.propose(talkReply(), defaults: defaults)
        let output = try await KiviStyleRouter.preview("Ask Rohaan on Monday.", app: "Claude", configuration: proposal.configuration, rules: [], protectedTerms: ["Rohaan"], client: KiviFakeEditor(text: "Ask Rohaan on Monday."))
        XCTAssertEqual(output, "Ask Rohaan on Monday.")
        XCTAssertNil(defaults.data(forKey: KiviStyleRouter.key))
        do {
            _ = try await KiviStyleRouter.preview("Ask Rohaan.", app: "Claude", configuration: proposal.configuration, rules: [], protectedTerms: ["Rohaan"], client: KiviFakeEditor(text: "Ask Rohan."))
            XCTFail("Changed protected spelling was accepted")
        } catch { }
    }

    func testTalkConversationRequiresPreviewAndArchivesDraftWhenStartingNewChat() {
        let defaults = makeDefaults()
        let conversation = KiviTalkConversation(defaults: defaults)
        conversation.draft = "Unsent synthetic message."
        XCTAssertFalse(conversation.canApply)
        conversation.apply()
        XCTAssertNotNil(conversation.error)
        XCTAssertNil(defaults.data(forKey: KiviStyleRouter.key))
        let id = conversation.chatID
        conversation.newConversation()
        XCTAssertTrue(conversation.draft.isEmpty)
        conversation.openChat(id)
        XCTAssertEqual(conversation.draft, "Unsent synthetic message.")
    }
    func testSettingsDestinationsRetainExistingLinksWithPlainLanguageTitles() {
        for (destination, expected) in [("shortcuts", KiviSettingsSection.keyboardShortcuts),
            ("keyboard shortcuts", .keyboardShortcuts), ("the orb", .recordingIndicator),
            ("recording indicator", .recordingIndicator), ("microphone", .recording),
            ("recording", .recording), ("permissions", .permissions), ("writing", .writing),
            ("advanced tools", .advanced), ("unknown destination", .general)] {
            XCTAssertEqual(KiviSettingsSection.resolve(destination), expected)
        }
        XCTAssertEqual(KiviSettingsSection.resolve("  KEYBOARD SHORTCUTS  "), .keyboardShortcuts)
    }

    func testSettingsSearchFindsMovedControlsAndHandlesEmptyQueries() {
        XCTAssertTrue(KiviSettingsSection.writing.matches(" light cleanup "))
        XCTAssertTrue(KiviSettingsSection.recording.matches("microphone"))
        XCTAssertTrue(KiviSettingsSection.recordingIndicator.matches("pill"))
        XCTAssertTrue(KiviSettingsSection.advanced.matches("provider key"))
        XCTAssertFalse(KiviSettingsSection.general.matches("cleanup"))
        XCTAssertTrue(KiviSettingsSection.allCases.allSatisfy { $0.matches("  ") })
        XCTAssertFalse(KiviSettingsSection.allCases.contains { $0.matches("no-such-setting-fixture") })
    }


    func testPendingRecoveryKeepsExactTextAcrossLaterTakesAndResolvesIndependently() {
        var queue = KiviPendingRecovery()
        let first = UUID(), second = UUID()
        queue.add(id: first, text: "First synthetic take.")
        queue.add(id: second, text: "Second synthetic take.")
        queue.add(id: first, text: "A later retry must not replace the original.")
        XCTAssertEqual(queue.items.map(\.text), ["First synthetic take.", "Second synthetic take."])
        queue.resolve(second)
        XCTAssertEqual(queue.items.map(\.id), [first])
        queue.resolve(first)
        XCTAssertTrue(queue.items.isEmpty)
    }

    func testPendingRecoveryIgnoresEmptyTakesAndUnknownResolution() {
        var queue = KiviPendingRecovery()
        queue.add(id: UUID(), text: " \n")
        queue.resolve(UUID())
        XCTAssertTrue(queue.items.isEmpty)
    }

    func testPasteTargetAssessmentUsesEditabilityAcrossAppSurfaces() {
        let cases: [(String?, Bool?, Bool, Bool, Bool, TextInsertionService.PasteTargetAssessment)] = [
            ("AXWebArea", nil, false, false, true, .nonEditable), // Page background, even with selectable text.
            ("AXWebArea", true, false, false, true, .editable), // contenteditable document.
            ("AXWebArea", nil, false, true, true, .editable),
            ("AXTextArea", nil, false, false, true, .editable), // Opaque editor still accepts paste.
            ("AXTextField", nil, false, false, true, .editable),
            ("AXSearchField", nil, false, false, true, .editable),
            ("AXSecureTextField", nil, false, false, true, .editable),
            ("AXTextArea", false, false, false, true, .editable), // Direct AX mutation may be read-only; keyboard paste still works.
            ("AXGroup", nil, true, false, false, .editable), // Custom native/web editor.
            ("AXGroup", nil, false, true, false, .editable),
            ("AXGroup", nil, false, false, true, .unknown),
            ("AXGroup", nil, false, false, false, .unknown), // Incomplete AX tree.
            ("AXButton", nil, false, true, true, .nonEditable), // A writable control value isn't text.
            ("AXScrollArea", nil, false, false, true, .unknown),
            ("AXStaticText", nil, false, false, true, .nonEditable),
            ("AXUnknown", nil, false, false, true, .unknown),
            (nil, nil, false, false, true, .unknown)
        ]
        for (role, editable, textWritable, valueWritable, checked, expected) in cases {
            XCTAssertEqual(TextInsertionService.assessPasteTarget(role: role, editable: editable,
                selectedTextSettable: textWritable, valueSettable: valueWritable, descendantsChecked: checked), expected,
                "role=\(role ?? "missing") editable=\(String(describing: editable))")
        }
    }

    func testNegativeAXAssessmentStillAttemptsPasteBeforeOfferingRecovery() async throws {
        for autoEnter in [false, true] {
            let service = TextInsertionService()
            let pasteboard = NSPasteboard.withUniqueName()
            pasteboard.setString("original clipboard", forType: .string)
            service.accessibilityGrantedOverride = true
            service.pasteTargetAssessmentOverride = { .nonEditable }
            service.pasteCommandAvailabilityOverride = { .disabled }
            service.captureActiveAppOverride = { ("Fixture", "synthetic.fixture", nil) }
            service.pasteVerificationAttempts = 0
            service.pasteboardProvider = { pasteboard }
            var pastes = 0
            var returns = 0
            service.pasteSimulatorOverride = { pastes += 1 }
            service.returnSimulatorOverride = { returns += 1 }
            let result = try await service.insertText("synthetic transcript", preserveClipboard: true,
                                                      autoEnter: autoEnter, awaitPasteVerification: true)
            XCTAssertEqual(result, .notInsertedNoEditableTarget)
            XCTAssertEqual(pastes, 1)
            XCTAssertEqual(returns, 0)
            service.flushPendingClipboardRestore()
            XCTAssertEqual(pasteboard.string(forType: .string), "original clipboard")
        }
    }

    func testEnabledOrUnknownPasteCommandNeverProducesFalseRecoveryFromNegativeAX() async throws {
        for capability in [TextInsertionService.PasteCommandAvailability.enabled, .unknown] {
            let service = TextInsertionService()
            let pasteboard = NSPasteboard.withUniqueName()
            service.accessibilityGrantedOverride = true
            service.pasteboardProvider = { pasteboard }
            service.pasteTargetAssessmentOverride = { .nonEditable }
            service.pasteCommandAvailabilityOverride = { capability }
            service.captureActiveAppOverride = { ("Fixture", "synthetic.fixture", nil) }
            service.pasteVerificationAttempts = 0
            var pastes = 0
            service.pasteSimulatorOverride = { pastes += 1 }
            let result = try await service.insertText("accepted by an opaque editor", awaitPasteVerification: true)
            XCTAssertEqual(result, .pasted(verification: .unverified(.focusedTextStateUnavailable)))
            XCTAssertEqual(pastes, 1)
        }
    }

    func testRecoveryRequiresIndependentDisabledPasteEvidenceInTheSameApp() {
        func decision(_ verification: TextInsertionService.PasteVerification = .unverified(.focusedTextStateUnavailable),
                      _ initial: TextInsertionService.PasteTargetAssessment = .nonEditable,
                      _ final: TextInsertionService.PasteTargetAssessment = .nonEditable,
                      _ before: TextInsertionService.PasteCommandAvailability = .disabled,
                      _ after: TextInsertionService.PasteCommandAvailability = .disabled,
                      _ sameApp: Bool = true) -> Bool {
            TextInsertionService.shouldRecoverAfterPaste(verification: verification, initialTarget: initial,
                finalTarget: final, commandBefore: before, commandAfter: after, sameApplication: sameApp)
        }
        XCTAssertTrue(decision())
        XCTAssertFalse(decision(.verified))
        XCTAssertFalse(decision(.unverified(.focusedTextStateUnavailable), .editable))
        XCTAssertFalse(decision(.unverified(.focusedTextStateUnavailable), .nonEditable, .editable))
        XCTAssertFalse(decision(.unverified(.focusedTextStateUnavailable), .nonEditable, .nonEditable, .enabled))
        XCTAssertFalse(decision(.unverified(.focusedTextStateUnavailable), .nonEditable, .nonEditable, .disabled, .enabled))
        XCTAssertFalse(decision(.unverified(.focusedTextStateUnavailable), .nonEditable, .nonEditable, .unknown))
        XCTAssertFalse(decision(.unverified(.focusedTextStateUnavailable), .nonEditable, .nonEditable, .disabled, .unknown))
        XCTAssertFalse(decision(.unverified(.focusedTextStateUnavailable), .nonEditable, .nonEditable, .disabled, .disabled, false))
    }

    func testPasteMenuMatchingUsesCommandMetadataInsteadOfLocalizedTitles() {
        XCTAssertTrue(TextInsertionService.isPlainPasteCommand(character: "v", modifiers: 0))
        XCTAssertTrue(TextInsertionService.isPlainPasteCommand(character: "V", modifiers: 0))
        XCTAssertFalse(TextInsertionService.isPlainPasteCommand(character: "v", modifiers: 1))
        XCTAssertFalse(TextInsertionService.isPlainPasteCommand(character: "v", modifiers: 8))
        XCTAssertFalse(TextInsertionService.isPlainPasteCommand(character: nil, modifiers: 0))
        XCTAssertFalse(TextInsertionService.isPlainPasteCommand(character: "v", modifiers: nil))
    }

    func testPasteCanSucceedEvenWhenInitialAXTargetLooksNonEditable() async throws {
        let service = TextInsertionService()
        service.accessibilityGrantedOverride = true
        service.pasteboardProvider = { NSPasteboard.withUniqueName() }
        service.pasteVerificationAttempts = 0
        var pastes = 0
        service.pasteTargetAssessmentOverride = { pastes == 0 ? .nonEditable : .editable }
        service.focusedTextElementOverride = { AXUIElementCreateSystemWide() }
        service.focusedTextStateOverride = { _ in nil }
        service.pasteSimulatorOverride = { pastes += 1 }
        let result = try await service.insertText("synthetic transcript", awaitPasteVerification: true)
        XCTAssertEqual(pastes, 1)
        XCTAssertEqual(result, .pasted(verification: .unverified(.focusedTextStateUnavailable)))
    }

    func testFloatingNoticesUseSeventyFivePercentWithNarrowerNoSpeechCard() {
        let recovery = IndicatorFeedbackPanelLayout.feedbackBody(for: .minimal, message: nil, kiviInsertionRecovery: true)
        let noSpeech = IndicatorFeedbackPanelLayout.feedbackBody(for: .minimal, message: nil, kiviNoSpeech: true)
        XCTAssertEqual(recovery.width, 225); XCTAssertEqual(recovery.height, 75)
        XCTAssertEqual(noSpeech.width, 225); XCTAssertEqual(noSpeech.height, 82.5)
    }

    func testEditableOpaqueFieldPastesOnceWithoutRequestingRecovery() async throws {
        let service = TextInsertionService()
        let pasteboard = NSPasteboard.withUniqueName()
        service.accessibilityGrantedOverride = true
        service.pasteTargetAssessmentOverride = { .editable }
        service.focusedTextElementOverride = { AXUIElementCreateSystemWide() }
        service.focusedTextStateOverride = { _ in nil }
        service.pasteboardProvider = { pasteboard }
        service.pasteVerificationAttempts = 0
        var pastes = 0
        service.pasteSimulatorOverride = { pastes += 1 }
        let result = try await service.insertText("synthetic transcript", awaitPasteVerification: true)
        XCTAssertEqual(result, .pasted(verification: .unverified(.focusedTextStateUnavailable)))
        XCTAssertFalse(TextInsertionService.shouldOfferPasteRecovery(.unverified(.focusedTextStateUnavailable)))
        XCTAssertEqual(pastes, 1)
    }

    func testReplacementFieldVerificationRequiresExactExpectedInsertion() {
        XCTAssertTrue(TextInsertionService.matchesExpectedPaste(before: "A 🥭 B", range: NSRange(location: 2, length: 2), inserted: "mango", after: "A mango B"))
        XCTAssertFalse(TextInsertionService.matchesExpectedPaste(before: "hello", range: NSRange(location: 5, length: 0), inserted: " world", after: "hello"))
        XCTAssertFalse(TextInsertionService.matchesExpectedPaste(before: "hello", range: NSRange(location: 5, length: 0), inserted: " world", after: "hello other edit"))
        XCTAssertFalse(TextInsertionService.matchesExpectedPaste(before: "hello", range: NSRange(location: 99, length: 0), inserted: " world", after: "hello world"))
    }

    func testUncertainPasteNeverPromptsDuplicateInsertion() {
        XCTAssertFalse(TextInsertionService.shouldOfferPasteRecovery(.verified))
        XCTAssertFalse(TextInsertionService.shouldOfferPasteRecovery(.notAwaited))
        XCTAssertFalse(TextInsertionService.shouldOfferPasteRecovery(.unverified(.focusedTextStateUnavailable)))
        XCTAssertTrue(TextInsertionService.shouldOfferPasteRecovery(.unverified(.noEditableTarget)))
        XCTAssertFalse(TextInsertionService.shouldOfferPasteRecovery(.unverified(.focusedTextUnchanged)))
    }

    func testPasteLastDefaultPreservesAssignmentsConflictsAndLaterRemoval() {
        for (assigned, conflict) in [(true, false), (false, true), (false, false)] {
            let defaults = makeDefaults()
            XCTAssertEqual(HotkeyService.shouldInstallPasteLastDefault(defaults: defaults,
                hasAssignment: assigned, hasConflict: conflict), !assigned && !conflict)
            XCTAssertFalse(HotkeyService.shouldInstallPasteLastDefault(defaults: defaults,
                hasAssignment: false, hasConflict: false), "Must not reassign after removal or override a previous conflict decision")
        }
    }

    func testGreetingAlternatesBetweenOneStablePairUntilExpiry() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var cycle = KiviGreetingCycle(now: now)
        let first = [cycle.current.0, cycle.current.1, cycle.current.2]
        cycle.advance(now: now.addingTimeInterval(1))
        let second = [cycle.current.0, cycle.current.1, cycle.current.2]
        XCTAssertNotEqual(first, second)
        cycle.advance(now: now.addingTimeInterval(3599))
        XCTAssertEqual([cycle.current.0, cycle.current.1, cycle.current.2], first)
        cycle.advance(now: now.addingTimeInterval(3599))
        XCTAssertEqual([cycle.current.0, cycle.current.1, cycle.current.2], second)
        let expiry = now.addingTimeInterval(3600)
        cycle.advance(now: expiry)
        let renewed = KiviGreetingCycle(now: expiry)
        XCTAssertEqual([cycle.current.0, cycle.current.1, cycle.current.2], [renewed.current.0, renewed.current.1, renewed.current.2])
    }

    func testGreetingPairFreezesItsTimeWordingAndRecoversFromClockRollback() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 22, hour: 21, minute: 50))!
        var cycle = KiviGreetingCycle(now: now, calendar: calendar)
        let first = [cycle.current.0, cycle.current.1, cycle.current.2]
        cycle.advance(now: now.addingTimeInterval(1200), calendar: calendar)
        cycle.advance(now: now.addingTimeInterval(1201), calendar: calendar)
        XCTAssertEqual([cycle.current.0, cycle.current.1, cycle.current.2], first)
        cycle.advance(now: now.addingTimeInterval(-1), calendar: calendar)
        let reset = KiviGreetingCycle(now: now.addingTimeInterval(-1), calendar: calendar)
        XCTAssertEqual([cycle.current.0, cycle.current.1, cycle.current.2], [reset.current.0, reset.current.1, reset.current.2])
    }

    private func makeDefaults() -> UserDefaults { UserDefaults(suiteName: "KiviIntegrationTests.\(UUID())")! }
    func testUnconfiguredStyleDoesNotChangeFoundationBehavior() async {
        let defaults = makeDefaults()
        let result = await KiviStyleRouter.process("Keep ₹500 and Tuesday.", appName: "Mail", bundleID: "com.apple.mail", protectedTerms: [], defaults: defaults, client: KiviFakeEditor(text: "must not run"))
        XCTAssertEqual(result.text, "Keep ₹500 and Tuesday."); XCTAssertNil(result.step)
    }
    func testGlobalRulesPersistWithoutChangingStyleConfiguration() {
        let defaults = makeDefaults()
        KiviStyleRouter.save(WritingStyle.defaults[3], app: nil, defaults: defaults)
        let rules = [KiviGlobalRule(text: "Use short sentences")]
        KiviGlobalRules.save(rules, defaults: defaults)
        XCTAssertEqual(KiviGlobalRules.load(defaults: defaults), rules)
        XCTAssertEqual(KiviStyleRouter.resolved(appName: "Mail", bundleID: nil, defaults: defaults)?.mode, "professional")
        KiviGlobalRules.save([], defaults: defaults)
        XCTAssertTrue(KiviGlobalRules.load(defaults: defaults).isEmpty)
        XCTAssertNotNil(KiviStyleRouter.resolved(appName: "Mail", bundleID: nil, defaults: defaults))
    }
    func testRuleDialogCancellationAndInvalidSavePreserveStoredRules() {
        let defaults = makeDefaults()
        let rules = [KiviGlobalRule(text: "Use short sentences")]
        KiviGlobalRules.save(rules, defaults: defaults)
        let editor = KiviGlobalRulesEditor(defaults: defaults)
        editor.begin(rules[0]); XCTAssertFalse(editor.changed)
        editor.draft = "Unsaved change"; editor.cancel()
        XCTAssertEqual(editor.rules, rules)
        XCTAssertEqual(KiviGlobalRules.load(defaults: defaults), rules)
        XCTAssertFalse(editor.editing)
        editor.begin(nil); editor.draft = "use SHORT sentences"; editor.save()
        XCTAssertTrue(editor.editing)
        XCTAssertEqual(KiviGlobalRules.load(defaults: defaults), rules)
    }
    func testRuleDialogEditRemoveUndoRetainsIdentityAndOrder() {
        let defaults = makeDefaults()
        let rules = [KiviGlobalRule(text: "Use short sentences"), KiviGlobalRule(text: "Write numbers as digits")]
        KiviGlobalRules.save(rules, defaults: defaults)
        let editor = KiviGlobalRulesEditor(defaults: defaults)
        editor.begin(rules[0]); editor.draft = "  Keep sentences short  "; editor.save()
        XCTAssertEqual(editor.rules[0].id, rules[0].id)
        XCTAssertEqual(editor.rules[0].text, "Keep sentences short")
        XCTAssertEqual(KiviGlobalRules.load(defaults: defaults), editor.rules)
        let edited = editor.rules
        editor.begin(editor.rules[0]); editor.remove()
        XCTAssertFalse(editor.editing)
        XCTAssertEqual(KiviGlobalRules.load(defaults: defaults), [rules[1]])
        editor.undo()
        XCTAssertEqual(KiviGlobalRules.load(defaults: defaults), edited)
        XCTAssertNil(editor.removed)
    }
    func testGlobalRulesWorkWithoutAnEnabledCategory() async {
        let defaults = makeDefaults()
        KiviGlobalRules.save([.init(text: "Fix grammar")], defaults: defaults)
        let result = await KiviStyleRouter.process("I is ready.", appName: "Unknown", bundleID: nil, protectedTerms: [], defaults: defaults, client: KiviFakeEditor(text: "I am ready."))
        XCTAssertEqual(result.text, "I am ready.")
        XCTAssertEqual(result.step, "Global writing rules")
        XCTAssertNil(KiviStyleRouter.resolved(appName: "Unknown", bundleID: nil, defaults: defaults))
    }
    func testGlobalAndAppInstructionsComposeWithExplicitPrecedence() {
        let rule = KiviGlobalRule(text: "Use short sentences")
        let instruction = KiviStyleRouter.instruction(style: WritingStyle.defaults[3], rules: [rule])!
        XCTAssertTrue(instruction.contains(rule.text))
        XCTAssertTrue(instruction.contains(WritingStyle.defaults[3].rules))
        XCTAssertTrue(instruction.contains("take priority over conflicting global and group preferences"))
        XCTAssertTrue(instruction.contains("Preserve all facts, names, numbers and commitments"))
        XCTAssertNil(KiviStyleRouter.instruction(style: nil, rules: []))
    }
    func testGlobalRulesRetainOriginalOnFailureEmptyOutputAndSpellingDrift() async {
        let defaults = makeDefaults()
        KiviGlobalRules.save([.init(text: "Fix grammar")], defaults: defaults)
        for client in [KiviFakeEditor(text: "", fails: true), KiviFakeEditor(text: "  "), KiviFakeEditor(text: "Ask Rohan.")] {
            let result = await KiviStyleRouter.process("Ask Rohaan.", appName: nil, bundleID: nil, protectedTerms: ["Rohaan"], defaults: defaults, client: client)
            XCTAssertEqual(result.text, "Ask Rohaan.")
        }
    }
    func testRuleValidationHandlesEmptyDuplicateAndEdit() {
        let rule = KiviGlobalRule(text: "Use short sentences")
        XCTAssertNotNil(KiviGlobalRules.validation(" ", editing: nil, rules: []))
        XCTAssertNotNil(KiviGlobalRules.validation(" use SHORT sentences ", editing: nil, rules: [rule]))
        XCTAssertNil(KiviGlobalRules.validation(rule.text, editing: rule.id, rules: [rule]))
        XCTAssertNotNil(KiviGlobalRules.validation(String(repeating: "a", count: 501), editing: nil, rules: []))
    }
    func testSavedCategoryIsResolvedAfterReload() {
        let defaults = makeDefaults()
        var style = WritingStyle.defaults[3]; style.mode = "formal"
        KiviStyleRouter.save(style, app: nil, defaults: defaults)
        XCTAssertEqual(KiviStyleRouter.resolved(appName: "Mail", bundleID: nil, defaults: defaults)?.mode, "formal")
        XCTAssertNil(KiviStyleRouter.resolved(appName: "Messages", bundleID: nil, defaults: defaults))
    }
    func testCustomGroupsPersistWithUniqueMembershipAndDeletionFallback() throws {
        var config = KiviStyleConfiguration()
        let group = WritingStyle(id: "custom", name: "Client work", subtitle: "", mode: "clear", rules: "Keep paragraphs short.", apps: "Mail, Notes")
        config.upsert(group); config.enabled.insert(group.id)
        XCTAssertEqual(config.group(for: "Mail")?.id, "custom")
        XCTAssertFalse(config.styles.first { $0.id == "email" }!.appNames.contains("Mail"))
        var exception = group; exception.rules = "Avoid bullets."
        config.overrides["Mail"] = exception; config.enabled.insert("app:Mail")
        config = try JSONDecoder().decode(KiviStyleConfiguration.self, from: JSONEncoder().encode(config))
        config.assign("Mail", to: "work")
        XCTAssertEqual(config.group(for: "Mail")?.id, "work")
        XCTAssertEqual(config.overrides["Mail"]?.rules, "Avoid bullets.")
        config.deleteGroup("work")
        XCTAssertEqual(config.group(for: "Mail")?.id, "other")
        XCTAssertEqual(config.overrides["Mail"]?.id, "other")
        XCTAssertEqual(config.overrides["Mail"]?.rules, "Avoid bullets.")
        config.reset("Mail")
        XCTAssertNil(config.overrides["Mail"])
        XCTAssertFalse(config.enabled.contains("app:Mail"))
        config.deleteGroup("other")
        XCTAssertNotNil(config.styles.first { $0.id == "other" })
    }
    func testAppInstructionsIncludeCurrentGroupRulesWithSpecificPrecedence() {
        let defaults = makeDefaults()
        var group = WritingStyle.defaults[3]
        group.rules = "Keep paragraphs short."
        KiviStyleRouter.save(group, app: nil, defaults: defaults)
        var app = group; app.rules = "Avoid bullets."
        KiviStyleRouter.save(app, app: "Mail", defaults: defaults)
        group.rules = "Use British spelling."
        KiviStyleRouter.save(group, app: nil, defaults: defaults)
        let config = KiviStyleRouter.load(defaults: defaults)
        let instruction = KiviStyleRouter.instruction(style: config.overrides["Mail"], rules: [], group: config.group(for: "Mail"))!
        XCTAssertTrue(instruction.contains("Use British spelling."))
        XCTAssertTrue(instruction.contains("Avoid bullets."))
        XCTAssertTrue(instruction.contains("conflicting global and group preferences"))
        XCTAssertFalse(instruction.contains("Keep paragraphs short."))
        var reset = config; reset.reset("Mail")
        XCTAssertEqual(reset.group(for: "Mail")?.rules, "Use British spelling.")
    }
    func testAppRulesInheritFutureGroupToneAndKeepLegacyExplicitTone() {
        let defaults = makeDefaults()
        var group = WritingStyle.defaults[3]
        var app = group; app.rules = "No bullets."; app.usesGroupTone = true
        KiviStyleRouter.save(app, app: "Mail", defaults: defaults)
        group.mode = "friendly"
        KiviStyleRouter.save(group, app: nil, defaults: defaults)
        XCTAssertEqual(KiviStyleRouter.resolved(appName: "Mail", bundleID: nil, defaults: defaults)?.mode, "friendly")
        app.usesGroupTone = nil
        KiviStyleRouter.save(app, app: "Mail", defaults: defaults)
        XCTAssertEqual(KiviStyleRouter.resolved(appName: "Mail", bundleID: nil, defaults: defaults)?.mode, "professional")
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
    func testGroupedMishearingsMergeEditReloadAndRejectConflicts() throws {
        let directory = try TestSupport.makeTemporaryDirectory(); defer { TestSupport.remove(directory) }
        let service = DictionaryService(appSupportDirectory: directory)
        try KiviDictionaryAdapter.saveGroupedWord(written: "Kivi", misspellings: " Kiwi, KV, kiwi ", editing: nil, service: service)
        try KiviDictionaryAdapter.saveGroupedWord(written: "Kivi", misspellings: "Kivy, KV", editing: nil, service: service)
        let reloaded = DictionaryService(appSupportDirectory: directory)
        func rows() -> [LexiconEntry] {
            KiviDictionaryAdapter.grouped(reloaded.entries.map { .init(id: $0.id, heard: $0.original, written: $0.replacement ?? $0.original) })
        }
        XCTAssertEqual(rows().count, 1)
        XCTAssertEqual(reloaded.entries.count, 3)
        XCTAssertEqual(reloaded.previewCorrections(to: "Kiwi KV Kivy"), "Kivi Kivi Kivi")
        reloaded.addEntry(type: .correction, original: "reserved", replacement: "Other")
        XCTAssertThrowsError(try KiviDictionaryAdapter.saveGroupedWord(written: "Kivi", misspellings: "new alias, reserved", editing: nil, service: reloaded))
        XCTAssertFalse(reloaded.entries.contains { $0.original == "new alias" })
        XCTAssertThrowsError(try KiviDictionaryAdapter.saveGroupedWord(written: "Kivi", misspellings: "KV, , Kiwi", editing: nil, service: reloaded))
        let group = try XCTUnwrap(rows().first { $0.written == "Kivi" })
        try KiviDictionaryAdapter.saveGroupedWord(written: "Kivi", misspellings: "KV, Kivee", editing: group.id, service: reloaded)
        XCTAssertEqual(reloaded.previewCorrections(to: "Kiwi KV Kivy Kivee"), "Kiwi Kivi Kivy Kivi")
        XCTAssertEqual(rows().filter { $0.written == "Kivi" }.count, 1)
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
        // Home starts unfiltered, paginates independently, and cannot cancel History's query.
        let home = store.makeIndependentFeed()
        home.activate()
        try await waitForHistory(home)
        XCTAssertEqual(home.sections.flatMap(\.takes).count, 100)
        XCTAssertTrue(home.hasMore)
        XCTAssertEqual(store.sections.flatMap(\.takes).map(\.text), ["fixture 124"])
        home.loadMore(); try await waitForHistory(home)
        XCTAssertEqual(home.sections.flatMap(\.takes).count, 125)
        home.deactivate()
        XCTAssertEqual(store.search, "raw 124")
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

extension KiviIntegrationTests {
    func testInsightsWordScaleUsesPagesThenWholeShortBooks() {
        var report = KiviInsightReport.make(days: [], period: .all)
        let cases: [(Int, String?)] = [
            (-1, nil), (0, nil),
            (1, "Less than a page of writing."),
            (249, "Less than a page of writing."),
            (250, "About 1 page of writing."),
            (1_000, "About 4 pages of writing."),
            (15_000, "About 60 pages of writing."),
            (49_999, "About 200 pages of writing."),
            (50_000, "Enough words for a short book."),
            (99_999, "Enough words for a short book."),
            (100_000, "Enough words for 2 short books."),
            (149_999, "Enough words for 2 short books."),
            (150_000, "Enough words for 3 short books.")
        ]
        for (words, expected) in cases {
            report.words = words
            XCTAssertEqual(report.wordScaleDescription, expected, "Word total: \(words)")
        }
    }

    private func insightsCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }
    func testInsightsCalendarWindowsAndZeroDaysAcrossDaylightSaving() {
        let calendar = insightsCalendar()
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 12))!
        let today = calendar.startOfDay(for: now)
        let old = calendar.date(byAdding: .day, value: -7, to: today)!
        let future = calendar.date(byAdding: .day, value: 1, to: today)!
        let report = KiviInsightReport.make(days: [.init(id: old, words: 40, count: 1), .init(id: today, words: 100, count: 2), .init(id: future, words: 999, count: 1)], period: .week, now: now, calendar: calendar)
        XCTAssertEqual(report.words, 100)
        XCTAssertEqual(report.previousWords, 40)
        XCTAssertEqual(report.count, 2)
        XCTAssertEqual(report.activeDays, 1)
        XCTAssertEqual(report.buckets.count, 7)
        XCTAssertEqual(report.buckets.reduce(0) { $0 + $1.words }, 100)
        XCTAssertEqual(report.buckets.filter { $0.count == 0 }.count, 6)
        XCTAssertEqual(calendar.dateComponents([.day], from: report.start, to: report.end).day, 7)
    }
    func testInsightsLongHistoryIsBoundedAndAppSharesUseTakeCounts() {
        let calendar = insightsCalendar()
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 22))!
        let today = calendar.startOfDay(for: now)
        let old = calendar.date(byAdding: .year, value: -8, to: today)!
        let appA = KiviInsightApp(id: "a", name: "Notes", count: 1, words: 300)
        let appB = KiviInsightApp(id: "b", name: "Messages", count: 3, words: 30)
        let report = KiviInsightReport.make(days: [.init(id: old, words: 300, count: 1, apps: ["a": appA]), .init(id: today, words: 30, count: 3, apps: ["b": appB])], period: .all, now: now, calendar: calendar)
        XCTAssertLessThanOrEqual(report.buckets.count, 15)
        XCTAssertEqual(report.words, 330)
        XCTAssertEqual(report.buckets.reduce(0) { $0 + $1.words }, 330)
        XCTAssertEqual(report.apps.first?.name, "Messages")
        XCTAssertEqual(report.averageWords, 83)
    }
    func testInsightsMonthAndEmptyReports() {
        let calendar = insightsCalendar()
        let now = Date()
        let report = KiviInsightReport.make(days: [], period: .month, now: now, calendar: calendar)
        XCTAssertEqual(report.availableDays, 30)
        XCTAssertEqual(report.buckets.count, 15)
        XCTAssertEqual(report.words, 0)
        XCTAssertEqual(report.averageWords, 0)
        let all = KiviInsightReport.make(days: [], period: .all, now: now, calendar: calendar)
        XCTAssertEqual(all.availableDays, 1)
        XCTAssertEqual(all.buckets.count, 1)
    }
    func testInsightsReadsAllHistoryExcludesTypedAndCountsBeforeExpansion() async throws {
        let directory = try TestSupport.makeTemporaryDirectory(prefix: "KiviInsights")
        defer { TestSupport.remove(directory) }
        let history = HistoryService(appSupportDirectory: directory)
        for index in 0..<205 {
            XCTAssertTrue(history.addRecord(rawText: "two words", finalText: "an expanded snippet with many more words", appName: "Notes", appBundleIdentifier: "com.apple.Notes", durationSeconds: 2, language: "en", engineUsed: index == 0 ? "typed" : "test"))
        }
        let days = try await history.kiviInsightDays()
        XCTAssertEqual(days.reduce(0) { $0 + $1.words }, 408)
        XCTAssertEqual(days.reduce(0) { $0 + $1.count }, 204)
        XCTAssertEqual(days.reduce(0) { $0 + $1.seconds }, 408)
        XCTAssertEqual(days.reduce(0) { $0 + $1.timedWords }, 408)
        XCTAssertEqual(days.reduce(0) { $0 + $1.timedCharacters }, 1836)
        history.clearAll()
        let cleared = try await history.kiviInsightDays()
        XCTAssertTrue(cleared.isEmpty)
    }
}

extension KiviIntegrationTests {
    func testInsightsExcludesImportedAndFailedRecordsAndHandlesMissingTiming() async throws {
        let directory = try TestSupport.makeTemporaryDirectory(prefix: "KiviInsightEligibility")
        defer { TestSupport.remove(directory) }
        let history = HistoryService(appSupportDirectory: directory, eventEmitter: { _ in })
        var ids: [UUID] = []
        for _ in 0..<4 {
            let id = UUID(); ids.append(id)
            XCTAssertTrue(history.addRecord(id: id, rawText: "two words", finalText: "two words", appName: "Notes", appBundleIdentifier: "com.apple.Notes", durationSeconds: 1, language: "en", engineUsed: "test"))
        }
        let imported = try XCTUnwrap(history.record(withID: ids[0]))
        imported.source = .importedFile
        history.updateRecord(imported, finalText: imported.finalText)
        let failed = try XCTUnwrap(history.record(withID: ids[1]))
        failed.processingState = .failed
        history.updateRecord(failed, finalText: failed.finalText)
        let untimed = try XCTUnwrap(history.record(withID: ids[2]))
        untimed.durationSeconds = .nan
        history.updateRecord(untimed, finalText: untimed.finalText)
        let fallback = try XCTUnwrap(history.record(withID: ids[3]))
        fallback.rawText = ""
        history.updateRecord(fallback, finalText: "three fallback words")
        let days = try await history.kiviInsightDays()
        XCTAssertEqual(days.reduce(0) { $0 + $1.count }, 2)
        XCTAssertEqual(days.reduce(0) { $0 + $1.words }, 5)
        XCTAssertEqual(days.reduce(0) { $0 + $1.timedCount }, 1)
        XCTAssertEqual(days.reduce(0) { $0 + $1.seconds }, 1)
        XCTAssertEqual(days.reduce(0) { $0 + $1.timedWords }, 3)
        XCTAssertEqual(days.reduce(0) { $0 + $1.timedCharacters }, 20)
    }
}

extension KiviIntegrationTests {
    func testInsightsSpeedUsesPairedTimingAndWeightsByDuration() throws {
        let calendar = insightsCalendar()
        let now = Date()
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let days: [KiviInsightDay] = [
            .init(id: yesterday, words: 1000, count: 2, seconds: 30, timedCount: 1, timedWords: 100, timedCharacters: 600),
            .init(id: today, words: 100, count: 1, seconds: 90, timedCount: 1, timedWords: 100, timedCharacters: 600)
        ]
        let report = KiviInsightReport.make(days: days, period: .all, now: now, calendar: calendar)
        XCTAssertEqual(report.words, 1100) // Untimed words still belong in the lifetime total.
        XCTAssertEqual(try XCTUnwrap(report.dictationWPM), 100, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(report.estimatedSavedSeconds(typingWPM: 60)), 120, accuracy: 0.0001)
        XCTAssertEqual(report.estimatedSavedSeconds(typingWPM: 120), 0)
        XCTAssertEqual(report.estimatedSavedSeconds(typingWPM: 300), 0)
        XCTAssertNil(report.estimatedSavedSeconds(typingWPM: 0))
        XCTAssertNil(report.estimatedSavedSeconds(typingWPM: 301))
    }
    func testInsightsSpeedNeedsUsableTimingAndDoesNotHideSlowTakes() {
        var report = KiviInsightReport.make(days: [], period: .all)
        XCTAssertNil(report.dictationWPM)
        XCTAssertNil(report.estimatedSavedSeconds(typingWPM: 52))
        report.timedWords = 100; report.timedCharacters = 600; report.seconds = .nan
        XCTAssertNil(report.dictationWPM)
        XCTAssertNil(report.estimatedSavedSeconds(typingWPM: 52))
        report.seconds = 1000
        XCTAssertEqual(report.estimatedSavedSeconds(typingWPM: 60), 0)
        report.seconds = 0
        XCTAssertNil(report.dictationWPM)
        XCTAssertNil(report.estimatedSavedSeconds(typingWPM: 52))
    }
}


extension KiviIntegrationTests {
    func testDemoInsightsFillsEntireWeekAboveMinimumWithoutMutatingInput() {
        let calendar = Calendar(identifier: .gregorian)
        let today = calendar.startOfDay(for: Date())
        let old = calendar.date(byAdding: .day, value: -7, to: today)!
        let reference = KiviInsightDay(id: old, words: 1000, count: 10, seconds: 500,
                                      timedCount: 10, timedWords: 1000, timedCharacters: 5000)
        let actual = KiviInsightDay(id: today, words: 2000, count: 20)
        let input = [reference, actual]
        let result = KiviInsightDemo.applying(to: input, now: today, calendar: calendar)
        XCTAssertEqual(input, [reference, actual])
        XCTAssertEqual(result.count, 8)
        XCTAssertEqual(result.first, reference)
        XCTAssertEqual(result.last, actual)
        XCTAssertEqual(result, KiviInsightDemo.applying(to: input, now: today, calendar: calendar))
        XCTAssertGreaterThan(Set(result.dropFirst().dropLast().map(\.words)).count, 1)
        XCTAssertTrue(result.dropFirst().allSatisfy { $0.words >= 1300 })
        let generated = result[1]
        XCTAssertEqual(Double(generated.timedWords) * 60 / generated.seconds, 120, accuracy: 0.01)
    }

    func testDemoInsightsDoesNotInventBaselineWithoutOlderActivity() {
        XCTAssertTrue(KiviInsightDemo.applying(to: []).isEmpty)
    }
}
