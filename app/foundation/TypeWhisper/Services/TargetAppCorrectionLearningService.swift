import AppKit
import Combine
import Foundation

enum TargetAppCorrectionCommitSignal: String, Codable, Equatable, Sendable {
    case returnKey
    case keypadEnterKey
    case tabKey
    case focusChanged
    case activeApplicationChanged

    var contributionPayloadValue: String {
        switch self {
        case .returnKey:
            "return-key"
        case .keypadEnterKey:
            "keypad-enter-key"
        case .tabKey:
            "tab-key"
        case .focusChanged:
            "focus-changed"
        case .activeApplicationChanged:
            "active-application-changed"
        }
    }
}

struct TargetAppCorrectionObservation: Equatable, Sendable {
    let correctedInsertedText: String
    let commitSignal: TargetAppCorrectionCommitSignal?
}

enum TargetAppCorrectionLearningOutcome: String, Codable, Equatable, Sendable {
    case learned
    case awaitingReview
    case capturedEdit
    case unsupportedTextObservation
    case noEdit
    case ambiguousEdit
    case noCommitBeforeTimeout
    case duplicateCorrection
    case cancelled
    case failed
}

struct TargetAppCorrectionLearningAttemptSnapshot: Codable, Equatable, Sendable {
    let outcome: TargetAppCorrectionLearningOutcome
    let timestamp: Date
    let commitSignal: TargetAppCorrectionCommitSignal?
    let learnedCorrectionCount: Int
}

struct TargetAppCorrectionLearningResult: Equatable, Sendable {
    let snapshot: TargetAppCorrectionLearningAttemptSnapshot
    let learnedCorrections: [LearnedDictionaryCorrection]
    let correctionObservation: TargetAppCorrectionObservation?
}

private func targetAppCorrectionCommitSignal(forKeyCode keyCode: UInt16) -> TargetAppCorrectionCommitSignal? {
    switch keyCode {
    case 0x24:
        return .returnKey
    case 0x4C:
        return .keypadEnterKey
    case 0x30:
        return .tabKey
    default:
        return nil
    }
}

private func installGlobalTargetAppCorrectionKeyMonitor(
    onCommit: @escaping @MainActor (TargetAppCorrectionCommitSignal) -> Void
) -> Any? {
    NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
        guard let signal = targetAppCorrectionCommitSignal(forKeyCode: event.keyCode) else { return }
        Task { @MainActor in
            onCommit(signal)
        }
    }
}

@MainActor
protocol TargetAppCorrectionCommitObserving: AnyObject {
    func start()
    func stop()
}

@MainActor
final class TargetAppCorrectionCommitObserver: TargetAppCorrectionCommitObserving {
    private let onCommit: @MainActor (TargetAppCorrectionCommitSignal) -> Void
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?
    private var appActivationObserver: NSObjectProtocol?

    init(onCommit: @escaping @MainActor (TargetAppCorrectionCommitSignal) -> Void) {
        self.onCommit = onCommit
    }

    func start() {
        stop()

        globalKeyMonitor = installGlobalTargetAppCorrectionKeyMonitor(onCommit: onCommit)
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyEvent(event)
            return event
        }
        appActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.onCommit(.activeApplicationChanged)
            }
        }
    }

    func stop() {
        if let globalKeyMonitor {
            NSEvent.removeMonitor(globalKeyMonitor)
            self.globalKeyMonitor = nil
        }
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
            self.localKeyMonitor = nil
        }
        if let appActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(appActivationObserver)
            self.appActivationObserver = nil
        }
    }

    private func handleKeyEvent(_ event: NSEvent) {
        guard let signal = Self.commitSignal(forKeyCode: event.keyCode) else { return }
        onCommit(signal)
    }

    static func commitSignal(forKeyCode keyCode: UInt16) -> TargetAppCorrectionCommitSignal? {
        targetAppCorrectionCommitSignal(forKeyCode: keyCode)
    }
}

private final class TargetAppCorrectionWakeCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var sleepTask: Task<Void, Never>?
    private var generation = 0

    func wait(for duration: Duration) async {
        guard duration > .seconds(0), !Task.isCancelled else { return }

        await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume()
                    return
                }
                let waitID = self.startWait(continuation)
                let task = Task { [weak self] in
                    try? await Task.sleep(for: duration)
                    self?.resume(waitID: waitID)
                }
                self.storeSleepTask(task, waitID: waitID)
            }
        }, onCancel: {
            resume()
        })
    }

    func wake() {
        resume()
    }

    private func startWait(_ continuation: CheckedContinuation<Void, Never>) -> Int {
        lock.lock()
        generation += 1
        let waitID = generation
        self.continuation = continuation
        let oldTask = sleepTask
        sleepTask = nil
        lock.unlock()
        oldTask?.cancel()
        return waitID
    }

    private func storeSleepTask(_ task: Task<Void, Never>, waitID: Int) {
        lock.lock()
        guard waitID == generation, continuation != nil else {
            lock.unlock()
            task.cancel()
            return
        }
        sleepTask = task
        lock.unlock()
    }

    private func resume(waitID: Int? = nil) {
        lock.lock()
        if let waitID, waitID != generation {
            lock.unlock()
            return
        }
        generation += 1
        let task = sleepTask
        sleepTask = nil
        let continuation = continuation
        self.continuation = nil
        lock.unlock()

        task?.cancel()
        continuation?.resume()
    }
}

@MainActor
final class TargetAppCorrectionLearningService: ObservableObject {
    private static let defaultPollSchedule: [Duration] = (1...30).map { .seconds($0) }

    static let localEnabledKey = "intentCorrectionLearningEnabled"
    static var isPrivateBuild: Bool { ["dev.vedant.intent", "dev.vedant.kivi-combined"].contains(Bundle.main.bundleIdentifier ?? "") }

    struct PendingCorrection: Identifiable {
        let id = UUID()
        let original: String
        let replacement: String
    }
    @Published private(set) var pendingCorrection: PendingCorrection?
    @Published private(set) var reviewedCorrections: [LearnedDictionaryCorrection] = []
    @Published private(set) var reviewMessage: String?
    struct DetectedEdit: Identifiable, Codable, Equatable {
        let id: UUID
        let timestamp: Date
        let original: String
        let edited: String
        var usedForLearning: Bool? = nil
        var consumedCandidateKeys: [String]? = nil
        var observationID: UUID? = nil
    }
    static let detectedEditsKey = "intentDetectedEdits"
    static let automaticLearningKey = "intentAutomaticSpellingLearning"
    @Published private(set) var detectedEdits: [DetectedEdit] = []
    @Published private(set) var detectionStatus = "No dictation observed yet"
    private let observeSettledEdits: Bool
    private let settleSeconds: TimeInterval
    private var detectionGeneration: UUID?
    private var currentDetectedID: UUID?
    private var currentBaseline: TextInsertionService.FocusedTextObservation?
    private var latestDetectedValue: String?
    private var ignoredCurrentValue: String?
    private var provisionalMemories: [(key: String, memory: LearnedDictionaryCorrection)] = []
    private var learnedPanel: KiviLearnedWordsPanel?
    private var feedbackExpiry: Task<Void, Never>?
    private var candidateCache: [UUID: (original: String, edited: String, candidates: [CorrectionLearningCandidate])] = [:]

    func clearDetectedEdits() {
        // Clearing evidence is separate from Undoing a saved dictionary memory.
        provisionalMemories = []
        detectedEdits = []
        ignoredCurrentValue = latestDetectedValue
        currentDetectedID = nil
        persistDetectedEdits()
    }

    func removeDetectedEdit(id: UUID) {
        let wasCurrent = currentDetectedID == id
        let ignored = latestDetectedValue
        if wasCurrent { discardCurrentDetectedEdit(userDismissed: true) }
        detectedEdits.removeAll { $0.id == id }
        if wasCurrent { ignoredCurrentValue = ignored; currentDetectedID = nil }
        persistDetectedEdits()
    }

    func stopDetection(hideFeedback: Bool = true) {
        if hideFeedback { hideLearningFeedback() }
        // A new take may begin before another poll. Keep a captured edit only if the
        // same old element still has that exact text, including when it is unfocused.
        if let baseline = currentBaseline, let value = latestDetectedValue,
           textInsertionService.recapturePinnedTextObservation(baseline)?.value != value {
            discardCurrentDetectedEdit()
        }
        // Settled captures learn immediately; stopping must never promote a partial edit.
        provisionalMemories = []
        detectionGeneration = nil
        currentBaseline = nil
        currentDetectedID = nil
        latestDetectedValue = nil
        ignoredCurrentValue = nil
        detectionStatus = "Observation stopped"
    }

    /// Conservative name-spelling heuristic, not a semantic classifier. Require
    /// exact surrounding text, including numbers and punctuation.
    static func spellingSuggestion(for edit: DetectedEdit) -> CorrectionSuggestion? {
        guard edit.original.count <= 2_000, edit.edited.count <= 2_000,
              !edit.original.contains("`"), !edit.original.contains("_"),
              let regex = try? NSRegularExpression(pattern: #"[\p{L}]+(?:['’-][\p{L}]+)*"#) else { return nil }
        let old = regex.matches(in: edit.original, range: NSRange(edit.original.startIndex..., in: edit.original))
        let new = regex.matches(in: edit.edited, range: NSRange(edit.edited.startIndex..., in: edit.edited))
        guard old.count == new.count else { return nil }
        var candidate: CorrectionSuggestion?
        for (left, right) in zip(old, new) {
            let a = (edit.original as NSString).substring(with: left.range)
            let b = (edit.edited as NSString).substring(with: right.range)
            guard a != b else { continue }
            guard candidate == nil, a.lowercased() != b.lowercased(), a.count >= 3, b.count >= 3,
                  max(a.count, b.count) <= 64 else { return nil }
            let forbidden: Set<String> = ["not", "now", "can", "cant", "can't", "cannot", "could", "would", "should", "will", "wont", "won't", "may", "might", "yes", "no", "true", "false", "before", "after", "more", "less", "then", "than", "and", "but", "the", "this", "that", "here", "there", "today", "tomorrow", "yesterday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "january", "february", "march", "april", "june", "july", "august", "september", "october", "november", "december"]
            guard !forbidden.contains(a.lowercased()), !forbidden.contains(b.lowercased()),
                  a.first?.isUppercase == true || b.first?.isUppercase == true else { return nil }
            let lhs = Array(a.lowercased()), rhs = Array(b.lowercased())
            var row = Array(0...rhs.count)
            for (i, char) in lhs.enumerated() {
                var next = [i + 1] + Array(repeating: 0, count: rhs.count)
                for (j, other) in rhs.enumerated() { next[j + 1] = min(row[j + 1] + 1, next[j] + 1, row[j] + (char == other ? 0 : 1)) }
                row = next
            }
            guard row[rhs.count] <= 2, Double(row[rhs.count]) / Double(max(lhs.count, rhs.count)) <= 0.34,
                  (edit.original as NSString).replacingCharacters(in: left.range, with: b) == edit.edited else { return nil }
            candidate = CorrectionSuggestion(original: a, replacement: b)
        }
        return candidate
    }

    static func learningCandidates(for edit: DetectedEdit) -> [CorrectionLearningCandidate] {
        CorrectionLearningAnalysis.candidates(original: edit.original, edited: edit.edited)
    }

    func cachedCandidates(for edit: DetectedEdit) -> [CorrectionLearningCandidate] {
        if let cached = candidateCache[edit.id], cached.original == edit.original, cached.edited == edit.edited { return cached.candidates }
        let result = Self.learningCandidates(for: edit)
        candidateCache[edit.id] = (edit.original, edit.edited, result)
        return result
    }

    private func evidenceCount(for candidate: CorrectionLearningCandidate) -> Int {
        Set(detectedEdits.filter { edit in
            edit.usedForLearning != true && now().timeIntervalSince(edit.timestamp) >= 0 &&
            now().timeIntervalSince(edit.timestamp) < 86_400 &&
            !(edit.consumedCandidateKeys ?? []).contains(candidate.key) &&
            cachedCandidates(for: edit).contains(where: { $0.key == candidate.key })
        }.map { $0.observationID ?? $0.id }).count
    }

    func classification(for edit: DetectedEdit) -> String {
        let candidates = cachedCandidates(for: edit)
        guard !candidates.isEmpty else { return "No reusable spelling found · no rule saved" }
        return candidates.map { candidate in
            if dictionaryService.isLearningDismissed(original: candidate.original, replacement: candidate.replacement, vocabulary: candidate.kind == .vocabulary) {
                return "\(candidate.replacement) · dismissed; automatic learning blocked"
            }
            if edit.usedForLearning == true || (edit.consumedCandidateKeys ?? []).contains(candidate.key) {
                return "\(candidate.replacement) · evidence used; review in Dictionary"
            }
            let kind = candidate.kind == .vocabulary ? "vocabulary only" : "spelling"
            return "\(candidate.original) → \(candidate.replacement) · \(kind) · \(evidenceCount(for: candidate))/2 takes"
        }.joined(separator: "\n")
    }

    func rememberDetectedEdit(id: UUID) {
        guard defaults.bool(forKey: Self.localEnabledKey),
              let edit = detectedEdits.first(where: { $0.id == id }),
              now().timeIntervalSince(edit.timestamp) >= 0,
              now().timeIntervalSince(edit.timestamp) < 86_400 else { return }
        if currentDetectedID == id {
            guard let baseline = currentBaseline,
                  textInsertionService.recapturePinnedTextObservation(baseline)?.value == latestDetectedValue else {
                discardCurrentDetectedEdit(); return
            }
        }
        for candidate in cachedCandidates(for: edit) {
            // A deliberate Remember action may teach a previously dismissed lesson.
            guard dictionaryService.allowLearning(original: candidate.original, replacement: candidate.replacement, vocabulary: candidate.kind == .vocabulary) else {
                reviewMessage = "Could not update learning preferences. Try again in Dictionary."
                continue
            }
            saveDetectedCandidate(candidate, provisional: currentDetectedID == id)
        }
    }

    private func learnRepeatedSpellings(id: UUID) {
        guard defaults.bool(forKey: Self.localEnabledKey),
              defaults.object(forKey: Self.automaticLearningKey) as? Bool ?? true,
              let edit = detectedEdits.first(where: { $0.id == id }) else { return }
        for candidate in cachedCandidates(for: edit) {
            guard evidenceCount(for: candidate) >= 2 else { continue }
            // Contradictory fresh teaching for one source needs human review.
            let conflicting = detectedEdits.contains { other in
                now().timeIntervalSince(other.timestamp) < 86_400 && other.usedForLearning != true &&
                cachedCandidates(for: other).contains {
                    $0.original.lowercased() == candidate.original.lowercased() && $0.replacement.lowercased() != candidate.replacement.lowercased()
                }
            }
            guard !conflicting else { continue }
            saveDetectedCandidate(candidate, provisional: true)
        }
    }

    private func saveDetectedCandidate(_ candidate: CorrectionLearningCandidate, provisional: Bool) {
        let result = candidate.kind == .vocabulary
            ? dictionaryService.learnVocabularyWithResult(candidate.replacement)
            : learnCorrections([CorrectionSuggestion(original: candidate.original, replacement: candidate.replacement)])
        guard !result.failed else {
            reviewMessage = "Could not save this word. Try again in Dictionary."
            return
        }
        guard !result.learnedCorrections.isEmpty else { return }
        for index in detectedEdits.indices where cachedCandidates(for: detectedEdits[index]).contains(where: { $0.key == candidate.key }) {
            var consumed = Set(detectedEdits[index].consumedCandidateKeys ?? [])
            consumed.insert(candidate.key)
            detectedEdits[index].consumedCandidateKeys = consumed.sorted()
        }
        persistDetectedEdits()
        reviewedCorrections.append(contentsOf: result.learnedCorrections)
        if provisional {
            provisionalMemories.append(contentsOf: result.learnedCorrections.map { (candidate.key, $0) })
        }
        reviewMessage = candidate.kind == .vocabulary
            ? "Learned \(candidate.replacement) as vocabulary. Other words stay unchanged."
            : "Learned \(candidate.original) → \(candidate.replacement)."
        showLearnedFeedback()
    }

    private func showLearnedFeedback() {
        guard !AppConstants.isRunningTests else { return }
        if learnedPanel == nil { learnedPanel = KiviLearnedWordsPanel(service: self) }
        learnedPanel?.showFeedback()
        setLearningFeedbackHovered(false)
    }

    func setLearningFeedbackHovered(_ hovered: Bool) {
        feedbackExpiry?.cancel()
        if hovered { return }
        feedbackExpiry = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            self?.learnedPanel?.orderOut(nil)
        }
    }

    func hideLearningFeedback() {
        feedbackExpiry?.cancel()
        learnedPanel?.orderOut(nil)
    }

    private func persistDetectedEdits() {
        detectedEdits = Array(detectedEdits.filter { now().timeIntervalSince($0.timestamp) >= 0 && now().timeIntervalSince($0.timestamp) < 86_400 }.suffix(50))
        let ids = Set(detectedEdits.map(\.id))
        candidateCache = candidateCache.filter { ids.contains($0.key) }
        if let data = try? JSONEncoder().encode(detectedEdits) { defaults.set(data, forKey: Self.detectedEditsKey) }
    }

    private func discardCurrentDetectedEdit(userDismissed: Bool = false) {
        // Continued typing or Undo invalidates only memories created by this active
        // observation. Never delete an independently learned or subsequently edited rule.
        if !provisionalMemories.isEmpty {
            let memories = provisionalMemories.map(\.memory)
            guard dictionaryService.undoLearnedCorrections(memories, suppressRelearning: userDismissed) else {
                reviewMessage = "Could not withdraw the learned word. Review it in Dictionary."
                showLearnedFeedback()
                return
            }
            let ids = Set(memories.map(\.id))
            reviewedCorrections.removeAll { ids.contains($0.id) }
            let keys = Set(provisionalMemories.map(\.key))
            for index in detectedEdits.indices {
                detectedEdits[index].consumedCandidateKeys?.removeAll { keys.contains($0) }
            }
            provisionalMemories = []
            reviewMessage = "Edit changed; the unconfirmed learning was withdrawn."
            hideLearningFeedback()
        }
        if let id = currentDetectedID { detectedEdits.removeAll { $0.id == id }; persistDetectedEdits() }
        currentDetectedID = nil
        latestDetectedValue = nil
    }

    private let reviewTimeout: Duration
    private let reviewBeforeSaving: Bool
    private let dictionaryService: DictionaryService
    private var reviewExpiry: Task<Void, Never>?
    private var reviewPanel: CorrectionLearningPanel?

    func dismissReview() {
        reviewExpiry?.cancel()
        reviewExpiry = nil
        pendingCorrection = nil
        reviewedCorrections = []
        reviewMessage = nil
        reviewPanel?.orderOut(nil)
        hideLearningFeedback()
    }

    func rememberCorrection(id: UUID) {
        guard let pending = pendingCorrection, pending.id == id,
              defaults.bool(forKey: Self.localEnabledKey) else { return }
        let result = learnCorrections([CorrectionSuggestion(original: pending.original, replacement: pending.replacement)])
        pendingCorrection = nil
        reviewedCorrections = result.learnedCorrections
        latestAttempt = TargetAppCorrectionLearningAttemptSnapshot(
            outcome: result.failed ? .failed : result.learnedCorrections.isEmpty ? .duplicateCorrection : .learned,
            timestamp: now(), commitSignal: latestAttempt?.commitSignal,
            learnedCorrectionCount: result.learnedCorrections.count
        )
        if let latestAttempt { persistLatestAttempt(latestAttempt) }
        reviewMessage = result.failed ? "Could not save correction. Try again in Dictionary."
            : result.learnedCorrections.isEmpty ? "An existing rule was kept. Review it in Dictionary."
            : "Saved locally. Applies to future dictation in all apps."
    }

    func undoReviewedCorrections() {
        guard dictionaryService.undoLearnedCorrections(reviewedCorrections) else {
            reviewMessage = "Could not undo learning. Your words are still in Dictionary; try again."
            showLearnedFeedback()
            return
        }
        provisionalMemories = []
        hideLearningFeedback()
        reviewedCorrections = []
        reviewMessage = "Unchanged learned rules removed. Edited rules are kept. Your document was not changed."
    }

    private func offerReview(_ suggestion: CorrectionSuggestion) {
        dismissReview()
        pendingCorrection = PendingCorrection(original: suggestion.original, replacement: suggestion.replacement)
        if !AppConstants.isRunningTests {
            if reviewPanel == nil { reviewPanel = CorrectionLearningPanel(service: self) }
            reviewPanel?.showReview()
        }
        let id = pendingCorrection?.id
        reviewExpiry = Task { @MainActor [weak self] in
            try? await Task.sleep(for: self?.reviewTimeout ?? .seconds(30))
            guard !Task.isCancelled, self?.pendingCorrection?.id == id else { return }
            self?.dismissReview()
        }
    }

    // Prove the exact insertion against the pre-insertion selection, not a substring hit.
    static func verifiedInsertionObservation(insertedText: String, before: TextInsertionService.FocusedTextObservation?, after: TextInsertionService.FocusedTextObservation?) -> TextInsertionService.FocusedTextObservation? {
        guard let before, var after, before.element == after.element,
              let selection = before.selectedRange,
              let range = Range(selection, in: before.value), !insertedText.isEmpty else { return nil }
        var expected = before.value
        expected.replaceSubrange(range, with: insertedText)
        guard expected == after.value else { return nil }
        after.ownedInsertionRange = NSRange(location: selection.location, length: insertedText.utf16.count)
        return after
    }

    static func verifiedInsertion(insertedText: String, before: TextInsertionService.FocusedTextObservation?, after: TextInsertionService.FocusedTextObservation?) -> Bool {
        verifiedInsertionObservation(insertedText: insertedText, before: before, after: after) != nil
    }

    // Isolate only the inserted region using its unchanged document prefix/suffix.
    // Repeated identical phrases elsewhere cannot redirect the observation.
    static func editedPassage(insertedText: String, baseline: TextInsertionService.FocusedTextObservation, editedValue: String) -> String? {
        guard let owned = baseline.ownedInsertionRange,
              let range = Range(owned, in: baseline.value),
              String(baseline.value[range]) == insertedText else { return nil }
        let prefix = String(baseline.value[..<range.lowerBound])
        let suffix = String(baseline.value[range.upperBound...])
        guard editedValue.hasPrefix(prefix), editedValue.hasSuffix(suffix),
              editedValue.utf16.count >= prefix.utf16.count + suffix.utf16.count,
              let editedRange = Range(NSRange(location: prefix.utf16.count,
                length: editedValue.utf16.count - prefix.utf16.count - suffix.utf16.count), in: editedValue) else { return nil }
        return String(editedValue[editedRange])
    }

    private func trackSettledInsertion(insertedText: String, baseline: TextInsertionService.FocusedTextObservation?) async -> TargetAppCorrectionLearningResult {
        stopDetection()
        dismissReview()
        let id = UUID()
        activeAttemptID = id
        detectionGeneration = id
        currentBaseline = baseline
        guard let baseline, baseline.ownedInsertionRange != nil,
              insertedText.count <= 2_000, baseline.value.utf16.count <= 100_000 else {
            detectionStatus = "Insertion could not be verified; no edits captured"
            return completeAttempt(id: id, outcome: .unsupportedTextObservation, commitSignal: nil)
        }
        detectionStatus = "Watching the inserted passage for edits"
        var previousValue = baseline.value
        var stableSince = now()
        var unavailableCount = 0
        var elapsed: Duration = .zero
        var outcome: TargetAppCorrectionLearningOutcome = .noEdit
        defer {
            if detectionGeneration == id {
                let finalStatus = detectionStatus
                stopDetection(hideFeedback: false)
                detectionStatus = finalStatus
            }
        }
        for offset in pollSchedule {
            await sleep(max(.zero, offset - elapsed))
            elapsed = offset
            guard !Task.isCancelled, detectionGeneration == id,
                  defaults.bool(forKey: Self.localEnabledKey) else {
                return completeAttempt(id: id, outcome: .cancelled, commitSignal: nil)
            }
            guard let observation = textInsertionService.recaptureFocusedTextObservation(matching: baseline) else {
                if textInsertionService.focusedTextElementMatch(baseline) == .different {
                    // Leaving the field is a natural end of editing. Read the pinned
                    // old field itself, not a cached partial edit or the new field.
                    if let final = textInsertionService.recapturePinnedTextObservation(baseline),
                       let edited = Self.editedPassage(insertedText: insertedText, baseline: baseline, editedValue: final.value),
                       edited != insertedText, final.selectedRange?.length == 0,
                       final.value != ignoredCurrentValue,
                       insertedText.count <= 2_000, edited.count <= 2_000 {
                        if final.value != latestDetectedValue { discardCurrentDetectedEdit() }
                        if currentDetectedID == nil {
                            let candidate = DetectedEdit(id: UUID(), timestamp: now(), original: insertedText, edited: edited, observationID: id)
                            detectedEdits.append(candidate)
                            currentDetectedID = candidate.id
                            latestDetectedValue = final.value
                            persistDetectedEdits()
                            learnRepeatedSpellings(id: candidate.id)
                        }
                        outcome = .capturedEdit
                    }
                    detectionStatus = "Focus changed; observation finished"
                    return completeAttempt(id: id, outcome: outcome, commitSignal: nil)
                }
                unavailableCount += 1
                if unavailableCount >= 3 {
                    detectionStatus = "Field is unreadable; no new edits captured"
                    return completeAttempt(id: id, outcome: .unsupportedTextObservation, commitSignal: nil)
                }
                stableSince = now()
                continue
            }
            unavailableCount = 0
            guard let edited = Self.editedPassage(insertedText: insertedText, baseline: baseline, editedValue: observation.value) else {
                discardCurrentDetectedEdit()
                detectionStatus = "Document changed outside the inserted passage; observation stopped"
                return completeAttempt(id: id, outcome: .ambiguousEdit, commitSignal: nil)
            }
            if observation.value != previousValue {
                previousValue = observation.value
                stableSince = now()
                // Withdraw older captures while editing continues, including an Undo.
                discardCurrentDetectedEdit()
                outcome = .ambiguousEdit
            }
            if edited == insertedText {
                detectionStatus = "Watching the inserted passage for edits"
                outcome = .noEdit
                continue
            }
            detectionStatus = "Edit noticed; waiting for typing to settle"
            guard now().timeIntervalSince(stableSince) >= settleSeconds,
                  observation.value != ignoredCurrentValue,
                  observation.selectedRange?.length == 0 else { continue }
            guard insertedText.count <= 2_000, edited.count <= 2_000 else {
                detectionStatus = "Edit exceeds the capture limit; no text stored"
                continue
            }
            if currentDetectedID == nil {
                let candidate = DetectedEdit(id: UUID(), timestamp: now(), original: insertedText, edited: edited, observationID: id)
                detectedEdits.append(candidate)
                currentDetectedID = candidate.id
                latestDetectedValue = observation.value
                persistDetectedEdits()
                learnRepeatedSpellings(id: candidate.id)
            }
            outcome = .capturedEdit
            detectionStatus = "Edit captured locally; reusable words checked for learning"
        }
        return completeAttempt(id: id, outcome: outcome, commitSignal: nil)
    }

    private let textInsertionService: TextInsertionService
    private let textDiffService: TextDiffService
    private let learnCorrections: @MainActor ([CorrectionSuggestion]) -> DictionaryCorrectionLearningResult
    private let pollSchedule: [Duration]
    private let sleep: @MainActor (Duration) async -> Void
    private let makeCommitObserver: (@escaping @MainActor (TargetAppCorrectionCommitSignal) -> Void) -> TargetAppCorrectionCommitObserving
    private let defaults: UserDefaults
    private let shouldPersistLatestAttempt: Bool
    private let now: @MainActor () -> Date
    private var activeAttemptID: UUID?

    @Published private(set) var latestAttempt: TargetAppCorrectionLearningAttemptSnapshot?

    init(
        textInsertionService: TextInsertionService,
        textDiffService: TextDiffService,
        dictionaryService: DictionaryService,
        pollSchedule: [Duration]? = nil,
        sleep: @escaping @MainActor (Duration) async -> Void = { duration in
            try? await Task.sleep(for: duration)
        },
        makeCommitObserver: @escaping (@escaping @MainActor (TargetAppCorrectionCommitSignal) -> Void) -> TargetAppCorrectionCommitObserving = {
            TargetAppCorrectionCommitObserver(onCommit: $0)
        },
        learnCorrections: (@MainActor ([CorrectionSuggestion]) -> DictionaryCorrectionLearningResult)? = nil,
        defaults: UserDefaults = .standard,
        persistLatestAttempt: Bool = !AppConstants.isRunningTests,
        reviewBeforeSaving: Bool = TargetAppCorrectionLearningService.isPrivateBuild,
        reviewTimeout: Duration = .seconds(30),
        observeSettledEdits: Bool = TargetAppCorrectionLearningService.isPrivateBuild,
        settleSeconds: TimeInterval = 3,
        now: @escaping @MainActor () -> Date = Date.init
    ) {
        self.observeSettledEdits = observeSettledEdits
        self.settleSeconds = settleSeconds
        self.reviewTimeout = reviewTimeout
        self.reviewBeforeSaving = reviewBeforeSaving
        self.dictionaryService = dictionaryService
        self.textInsertionService = textInsertionService
        self.textDiffService = textDiffService
        self.learnCorrections = learnCorrections ?? { suggestions in
            dictionaryService.learnCorrectionsWithResult(suggestions)
        }
        self.pollSchedule = pollSchedule ?? (observeSettledEdits ? (1...240).map { .milliseconds($0 * 500) } : Self.defaultPollSchedule)
        self.sleep = sleep
        self.makeCommitObserver = makeCommitObserver
        self.defaults = defaults
        self.shouldPersistLatestAttempt = persistLatestAttempt
        self.now = now
        self.latestAttempt = Self.loadLatestAttempt(from: defaults)
        self.detectedEdits = defaults.data(forKey: Self.detectedEditsKey)
            .flatMap { try? JSONDecoder().decode([DetectedEdit].self, from: $0) } ?? []
        if observeSettledEdits { persistDetectedEdits() }
    }

    #if DEBUG
    func prepareScreenshotFixture(hasPremiumAccess: Bool) {
        activeAttemptID = nil
        latestAttempt = hasPremiumAccess
            ? TargetAppCorrectionLearningAttemptSnapshot(
                outcome: .learned,
                timestamp: AppConstants.screenshotFixtureReferenceDate,
                commitSignal: .returnKey,
                learnedCorrectionCount: 1
            )
            : nil
    }
    #endif

    func trackInsertion(
        insertedText: String,
        baseline: TextInsertionService.FocusedTextObservation?
    ) async -> TargetAppCorrectionLearningResult {
        if observeSettledEdits { return await trackSettledInsertion(insertedText: insertedText, baseline: baseline) }
        if reviewBeforeSaving { dismissReview() }
        let attemptID = UUID()
        activeAttemptID = attemptID
        let insertedText = insertedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !insertedText.isEmpty else {
            return completeAttempt(
                id: attemptID,
                outcome: .unsupportedTextObservation,
                commitSignal: nil
            )
        }
        guard let baseline else {
            return completeAttempt(
                id: attemptID,
                outcome: .unsupportedTextObservation,
                commitSignal: nil
            )
        }
        guard !pollSchedule.isEmpty else {
            return completeAttempt(
                id: attemptID,
                outcome: .noCommitBeforeTimeout,
                commitSignal: nil
            )
        }

        var commitSignal: TargetAppCorrectionCommitSignal?
        let wakeCoordinator = TargetAppCorrectionWakeCoordinator()
        let commitObserver = makeCommitObserver { signal in
            commitSignal = signal
            wakeCoordinator.wake()
        }
        commitObserver.start()
        defer { commitObserver.stop() }

        var latestSuggestions: [CorrectionSuggestion] = []
        var latestNonConfidentOutcome: TargetAppCorrectionLearningOutcome = .unsupportedTextObservation
        var latestObservation: TargetAppCorrectionObservation?
        var elapsed: Duration = .seconds(0)
        for pollOffset in pollSchedule {
            let waitDuration: Duration
            if pollOffset > elapsed {
                waitDuration = pollOffset - elapsed
                elapsed = pollOffset
            } else {
                waitDuration = .seconds(0)
            }
            if commitSignal == nil {
                if waitDuration > .seconds(0) {
                    await wakeCoordinator.wait(for: waitDuration)
                } else {
                    await sleep(.seconds(0))
                }
            }
            guard !Task.isCancelled else {
                return completeAttempt(
                    id: attemptID,
                    outcome: .cancelled,
                    commitSignal: commitSignal
                )
            }

            guard let observation = textInsertionService.recaptureFocusedTextObservation(matching: baseline) else {
                if reviewBeforeSaving {
                    return completeAttempt(id: attemptID, outcome: .unsupportedTextObservation, commitSignal: commitSignal)
                }
                switch textInsertionService.focusedTextElementMatch(baseline) {
                case .same, .unavailable:
                    if let commitSignal {
                        return completeCommittedAttempt(
                            id: attemptID,
                            suggestions: latestSuggestions,
                            fallbackOutcome: latestNonConfidentOutcome,
                            commitSignal: commitSignal,
                            correctionObservation: committedObservation(
                                latestObservation,
                                commitSignal: commitSignal
                            )
                        )
                    }
                    continue
                case .different:
                    let resolvedCommitSignal = commitSignal ?? .focusChanged
                    return completeCommittedAttempt(
                        id: attemptID,
                        suggestions: latestSuggestions,
                        fallbackOutcome: latestNonConfidentOutcome,
                        commitSignal: resolvedCommitSignal,
                        correctionObservation: committedObservation(
                            latestObservation,
                            commitSignal: resolvedCommitSignal
                        )
                    )
                }
            }

            latestObservation = correctionObservation(
                insertedText: insertedText,
                baselineText: baseline.value,
                editedText: observation.value,
                commitSignal: commitSignal
            )

            let suggestions = reviewCorrectionSuggestions(
                insertedText: insertedText,
                baselineText: baseline.value,
                observation: observation,
                commitSignal: commitSignal
            )
            if !suggestions.isEmpty {
                latestSuggestions = suggestions
            } else {
                latestSuggestions = []
                latestNonConfidentOutcome = observation.value == baseline.value ? .noEdit : .ambiguousEdit
            }

            if let commitSignal {
                return completeCommittedAttempt(
                    id: attemptID,
                    suggestions: latestSuggestions,
                    fallbackOutcome: latestNonConfidentOutcome,
                    commitSignal: commitSignal,
                    correctionObservation: latestObservation
                )
            }
        }

        if Task.isCancelled {
            return completeAttempt(
                id: attemptID,
                outcome: .cancelled,
                commitSignal: commitSignal
            )
        }
        return completeAttempt(
            id: attemptID,
            outcome: .noCommitBeforeTimeout,
            commitSignal: nil
        )
    }

    func trackInsertionResult(
        insertedText: String,
        baseline: TextInsertionService.FocusedTextObservation?
    ) async -> TargetAppCorrectionLearningResult {
        await trackInsertion(insertedText: insertedText, baseline: baseline)
    }

    private func completeCommittedAttempt(
        id: UUID,
        suggestions: [CorrectionSuggestion],
        fallbackOutcome: TargetAppCorrectionLearningOutcome,
        commitSignal: TargetAppCorrectionCommitSignal,
        correctionObservation: TargetAppCorrectionObservation?
    ) -> TargetAppCorrectionLearningResult {
        guard !suggestions.isEmpty else {
            return completeAttempt(
                id: id,
                outcome: fallbackOutcome,
                commitSignal: commitSignal,
                correctionObservation: correctionObservation
            )
        }

        if reviewBeforeSaving {
            guard activeAttemptID == id, !Task.isCancelled, suggestions.count == 1,
                  defaults.bool(forKey: Self.localEnabledKey) else {
                return completeAttempt(id: id, outcome: .cancelled, commitSignal: commitSignal)
            }
            offerReview(suggestions[0])
            return completeAttempt(id: id, outcome: .awaitingReview, commitSignal: commitSignal)
        }
        let dictionaryResult = learnCorrections(suggestions)
        let outcome: TargetAppCorrectionLearningOutcome
        if dictionaryResult.failed {
            outcome = .failed
        } else if !dictionaryResult.learnedCorrections.isEmpty {
            outcome = .learned
        } else if dictionaryResult.duplicateCount > 0 {
            outcome = .duplicateCorrection
        } else {
            outcome = .failed
        }
        return completeAttempt(
            id: id,
            outcome: outcome,
            commitSignal: commitSignal,
            learnedCorrections: dictionaryResult.learnedCorrections,
            correctionObservation: correctionObservation
        )
    }

    private func completeAttempt(
        id: UUID,
        outcome: TargetAppCorrectionLearningOutcome,
        commitSignal: TargetAppCorrectionCommitSignal?,
        learnedCorrections: [LearnedDictionaryCorrection] = [],
        correctionObservation: TargetAppCorrectionObservation? = nil
    ) -> TargetAppCorrectionLearningResult {
        let snapshot = TargetAppCorrectionLearningAttemptSnapshot(
            outcome: outcome,
            timestamp: now(),
            commitSignal: commitSignal,
            learnedCorrectionCount: learnedCorrections.count
        )
        if activeAttemptID == id {
            activeAttemptID = nil
            latestAttempt = snapshot
            persistLatestAttempt(snapshot)
        }
        return TargetAppCorrectionLearningResult(
            snapshot: snapshot,
            learnedCorrections: learnedCorrections,
            correctionObservation: correctionObservation
        )
    }

    private func persistLatestAttempt(_ snapshot: TargetAppCorrectionLearningAttemptSnapshot) {
        guard shouldPersistLatestAttempt else { return }
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: UserDefaultsKeys.targetAppCorrectionLearningLatestAttempt)
    }

    private static func loadLatestAttempt(from defaults: UserDefaults) -> TargetAppCorrectionLearningAttemptSnapshot? {
        guard let data = defaults.data(forKey: UserDefaultsKeys.targetAppCorrectionLearningLatestAttempt) else {
            return nil
        }
        return try? JSONDecoder().decode(TargetAppCorrectionLearningAttemptSnapshot.self, from: data)
    }

    func correctedInsertedText(
        insertedText: String,
        baselineText: String,
        editedText: String
    ) -> String? {
        guard let changedRanges = Self.changedRanges(from: baselineText, to: editedText),
              let baselineInsertedRange = Self.insertedRange(
                containing: changedRanges.baseline,
                insertedText: insertedText,
                in: baselineText
              ),
              Self.range(changedRanges.baseline, isContainedIn: baselineInsertedRange) else {
            return nil
        }

        let beforeCorrection = baselineText[baselineInsertedRange.lowerBound..<changedRanges.baseline.lowerBound]
        let correction = editedText[changedRanges.edited]
        let afterCorrection = baselineText[changedRanges.baseline.upperBound..<baselineInsertedRange.upperBound]
        let corrected = (String(beforeCorrection) + String(correction) + String(afterCorrection))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return corrected.isEmpty || corrected == insertedText ? nil : corrected
    }

    private func correctionObservation(
        insertedText: String,
        baselineText: String,
        editedText: String,
        commitSignal: TargetAppCorrectionCommitSignal?
    ) -> TargetAppCorrectionObservation? {
        correctedInsertedText(
            insertedText: insertedText,
            baselineText: baselineText,
            editedText: editedText
        ).map {
            TargetAppCorrectionObservation(
                correctedInsertedText: $0,
                commitSignal: commitSignal
            )
        }
    }

    private func committedObservation(
        _ observation: TargetAppCorrectionObservation?,
        commitSignal: TargetAppCorrectionCommitSignal
    ) -> TargetAppCorrectionObservation? {
        observation.map {
            TargetAppCorrectionObservation(
                correctedInsertedText: $0.correctedInsertedText,
                commitSignal: commitSignal
            )
        }
    }

    func reviewCorrectionSuggestions(
        insertedText: String,
        baselineText: String,
        observation: TextInsertionService.FocusedTextObservation,
        commitSignal: TargetAppCorrectionCommitSignal?
    ) -> [CorrectionSuggestion] {
        let direct = highConfidenceCorrectionSuggestions(
            insertedText: insertedText, baselineText: baselineText, editedText: observation.value
        )
        guard direct.isEmpty, reviewBeforeSaving,
              commitSignal == .returnKey || commitSignal == .keypadEnterKey,
              let caret = observation.selectedRange, caret.length == 0, caret.location > 0,
              let newline = Range(NSRange(location: caret.location - 1, length: 1), in: observation.value),
              observation.value[newline] == "\n" else { return direct }
        // Return itself can add a line break outside the dictated span. Ignore exactly
        // that one character at the current caret, never arbitrary document changes.
        var beforeReturn = observation.value
        beforeReturn.removeSubrange(newline)
        return highConfidenceCorrectionSuggestions(
            insertedText: insertedText, baselineText: baselineText, editedText: beforeReturn
        )
    }

    func highConfidenceCorrectionSuggestions(
        insertedText: String,
        baselineText: String,
        editedText: String
    ) -> [CorrectionSuggestion] {
        guard let changedRanges = Self.changedRanges(from: baselineText, to: editedText),
              (reviewBeforeSaving || !changedRanges.baseline.isEmpty),
              (reviewBeforeSaving || !changedRanges.edited.isEmpty),
              let baselineInsertedRange = Self.insertedRange(
                containing: changedRanges.baseline,
                insertedText: insertedText,
                in: baselineText
              ) else {
            return []
        }

        let expandedBaselineRange = Self.expandedTokenRange(in: baselineText, around: changedRanges.baseline)
        guard Self.range(expandedBaselineRange, isContainedIn: baselineInsertedRange) else {
            return []
        }

        let expandedEditedRange = Self.expandedTokenRange(in: editedText, around: changedRanges.edited)
        let original = String(baselineText[expandedBaselineRange])
        let edited = String(editedText[expandedEditedRange])

        let suggestions = textDiffService.extractHighConfidenceCorrections(original: original, edited: edited)
        if reviewBeforeSaving {
            // Numbers, code-like tokens and case-only changes are not spelling candidates.
            return suggestions.filter { suggestion in
                [suggestion.original, suggestion.replacement].allSatisfy { token in
                    token.unicodeScalars.contains { CharacterSet.letters.contains($0) }
                        && token.unicodeScalars.allSatisfy { CharacterSet.letters.contains($0) || "'-".unicodeScalars.contains($0) }
                }
            }
        }
        return suggestions
    }

    private static func insertedRange(
        containing changedRange: Range<String.Index>,
        insertedText: String,
        in baselineText: String
    ) -> Range<String.Index>? {
        guard !insertedText.isEmpty else { return nil }

        guard let first = baselineText.range(of: insertedText),
              baselineText.range(of: insertedText, range: baselineText.index(after: first.lowerBound)..<baselineText.endIndex) == nil else { return nil }
        var searchStart = baselineText.startIndex
        while searchStart <= baselineText.endIndex,
              let range = baselineText.range(of: insertedText, range: searchStart..<baselineText.endIndex) {
            if Self.range(changedRange, isContainedIn: range) {
                return range
            }
            searchStart = range.upperBound
            if searchStart == baselineText.endIndex { break }
        }

        return nil
    }

    private static func changedRanges(
        from baselineText: String,
        to editedText: String
    ) -> (baseline: Range<String.Index>, edited: Range<String.Index>)? {
        guard baselineText != editedText else { return nil }

        var baselinePrefix = baselineText.startIndex
        var editedPrefix = editedText.startIndex
        while baselinePrefix < baselineText.endIndex,
              editedPrefix < editedText.endIndex,
              baselineText[baselinePrefix] == editedText[editedPrefix] {
            baselineText.formIndex(after: &baselinePrefix)
            editedText.formIndex(after: &editedPrefix)
        }

        var baselineSuffix = baselineText.endIndex
        var editedSuffix = editedText.endIndex
        while baselineSuffix > baselinePrefix,
              editedSuffix > editedPrefix {
            let previousBaseline = baselineText.index(before: baselineSuffix)
            let previousEdited = editedText.index(before: editedSuffix)
            guard baselineText[previousBaseline] == editedText[previousEdited] else {
                break
            }
            baselineSuffix = previousBaseline
            editedSuffix = previousEdited
        }

        return (baselinePrefix..<baselineSuffix, editedPrefix..<editedSuffix)
    }

    private static func expandedTokenRange(
        in text: String,
        around range: Range<String.Index>
    ) -> Range<String.Index> {
        var lowerBound = range.lowerBound
        while lowerBound > text.startIndex {
            let previous = text.index(before: lowerBound)
            guard !Self.isWhitespace(text[previous]) else { break }
            lowerBound = previous
        }

        var upperBound = range.upperBound
        while upperBound < text.endIndex, !Self.isWhitespace(text[upperBound]) {
            text.formIndex(after: &upperBound)
        }

        return lowerBound..<upperBound
    }

    private static func range(
        _ inner: Range<String.Index>,
        isContainedIn outer: Range<String.Index>
    ) -> Bool {
        inner.lowerBound >= outer.lowerBound && inner.upperBound <= outer.upperBound
    }

    private static func isWhitespace(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy {
            CharacterSet.whitespacesAndNewlines.contains($0)
        }
    }
}
