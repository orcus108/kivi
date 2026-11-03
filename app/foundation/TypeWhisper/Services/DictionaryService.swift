import Foundation
import SwiftData
import Combine
import os.log
import TypeWhisperPluginSDK

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TypeWhisper", category: "DictionaryService")

enum DictionaryServiceMutationError: LocalizedError {
    case unavailable
    case saveFailed(Error)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Dictionary storage is unavailable"
        case .saveFailed(let error):
            return error.localizedDescription
        }
    }
}

enum DictionaryCorrectionMatchPolicy {
    case exact
    case boundary
    case substring
}

struct DictionaryAliasSuggestion: Equatable {
    let heard: String
    let written: String
}

/// A reviewable result from the same resolver used by final and streaming dictation.
struct DictionaryMatchReview {
    struct Change: Equatable {
        let entryID: UUID
        let correctionID: UUID?
        let heard: String
        let written: String
        let reason: String
    }
    let text: String
    let changes: [Change]
    let conflicts: [String]
    var correctionIDs: Set<UUID> { Set(changes.compactMap(\.correctionID)) }
}

struct LearnedDictionaryCorrection: Identifiable, Equatable, Sendable {
    let id: UUID
    let original: String
    let replacement: String
    var isVocabulary = false
    var savedAt: Date? = nil
}

struct DictionaryCorrectionLearningResult: Equatable, Sendable {
    let learnedCorrections: [LearnedDictionaryCorrection]
    let duplicateCount: Int
    let failed: Bool
}

struct DictionaryTrainingCommitResult: Equatable, Sendable {
    let addedTerm: Bool
    let addedCorrections: [String]
    let duplicateCorrections: [String]
    let conflictingCorrections: [String]
}

@MainActor
final class DictionaryService: ObservableObject {
    private var modelContainer: ModelContainer?
    private var modelContext: ModelContext?
    private var hasDeferredUsageCountChanges = false
    private let dismissedLearningURL: URL
    private var dismissedLearning: Set<String> = []

    @Published private(set) var entries: [DictionaryEntry] = []
    @Published private(set) var terms: [DictionaryEntry] = []
    @Published private(set) var corrections: [DictionaryEntry] = []
    /// Enabled corrections in application order: longer originals first, so a multi-word
    /// correction ("clawed code" → "Claude Code") wins over a shorter prefix correction
    /// ("clawed" → "Claude") that would otherwise consume part of the longer match.
    private(set) var correctionsForApplication: [DictionaryEntry] = []
    @Published private(set) var termsCount: Int = 0
    @Published private(set) var correctionsCount: Int = 0
    @Published private(set) var enabledTermsCount: Int = 0
    @Published private(set) var enabledCorrectionsCount: Int = 0

    #if DEBUG
    private var trainingSaveOverride: (() throws -> Void)?
    var learningSaveOverride: (() throws -> Void)?

    func setTrainingSaveOverrideForTesting(_ override: (() throws -> Void)?) {
        trainingSaveOverride = override
    }
    #endif

    init(appSupportDirectory: URL = AppConstants.appSupportDirectory) {
        dismissedLearningURL = appSupportDirectory.appendingPathComponent("dismissed-correction-learning.json")
        if let data = try? Data(contentsOf: dismissedLearningURL),
           let saved = try? JSONDecoder().decode(Set<String>.self, from: data) {
            dismissedLearning = saved
        }
        setupModelContainer(appSupportDirectory: appSupportDirectory)
    }

    private static func learningKey(original: String, replacement: String, vocabulary: Bool = false) -> String {
        vocabulary ? "term|\(replacement.lowercased())" : "correction|\(original.lowercased())|\(replacement.lowercased())"
    }

    func isLearningDismissed(original: String, replacement: String, vocabulary: Bool = false) -> Bool {
        dismissedLearning.contains(Self.learningKey(original: original, replacement: replacement, vocabulary: vocabulary))
    }

    private func suppressLearning(for entries: [DictionaryEntry]) throws {
        var updated = dismissedLearning
        for entry in entries where entry.source == .autoLearned {
            updated.insert(Self.learningKey(original: entry.original,
                replacement: entry.replacement ?? entry.original, vocabulary: entry.type == .term))
        }
        guard updated != dismissedLearning else { return }
        try JSONEncoder().encode(updated).write(to: dismissedLearningURL, options: .atomic)
        dismissedLearning = updated
    }

    /// Explicitly reviewed teaching is the only way to permit a dismissed lesson again.
    @discardableResult
    func allowLearning(original: String, replacement: String, vocabulary: Bool = false) -> Bool {
        var updated = dismissedLearning
        updated.remove(Self.learningKey(original: original, replacement: replacement, vocabulary: vocabulary))
        guard updated != dismissedLearning else { return true }
        do {
            try JSONEncoder().encode(updated).write(to: dismissedLearningURL, options: .atomic)
            dismissedLearning = updated
            return true
        } catch { return false }
    }

    private func setupModelContainer(appSupportDirectory: URL) {
        guard let (container, context) = try? SwiftDataStoreFactory.create(
            for: [DictionaryEntry.self],
            storeName: "dictionary",
            in: appSupportDirectory
        ) else { return }

        modelContainer = container
        modelContext = context

        loadEntries()
    }

    func loadEntries() {
        guard let context = modelContext else { return }

        do {
            let descriptor = FetchDescriptor<DictionaryEntry>(
                sortBy: [
                    SortDescriptor(\.entryType, order: .forward),
                    SortDescriptor(\.original, order: .forward)
                ]
            )
            entries = try context.fetch(descriptor)

            var newTerms: [DictionaryEntry] = []
            var newCorrections: [DictionaryEntry] = []
            var newTermsCount = 0
            var newCorrectionsCount = 0
            var newEnabledTermsCount = 0
            var newEnabledCorrectionsCount = 0

            for entry in entries {
                if entry.type == .term {
                    newTermsCount += 1
                    if entry.isEnabled {
                        newTerms.append(entry)
                        newEnabledTermsCount += 1
                    }
                } else if entry.type == .correction {
                    newCorrectionsCount += 1
                    if entry.isEnabled {
                        newCorrections.append(entry)
                        newEnabledCorrectionsCount += 1
                    }
                }
            }

            terms = newTerms
            corrections = newCorrections
            correctionsForApplication = Self.orderedForApplication(newCorrections)
            termsCount = newTermsCount
            correctionsCount = newCorrectionsCount
            enabledTermsCount = newEnabledTermsCount
            enabledCorrectionsCount = newEnabledCorrectionsCount
        } catch {
            logger.error("Failed to fetch entries: \(error.localizedDescription)")
        }
    }

    var appImportSnapshot: [AppVocabularyImport.Existing] {
        entries.map {
            AppVocabularyImport.Existing(id: $0.id, entry: AppVocabularyImport.Entry(kind: $0.type == .term ? .term : .correction, original: $0.original, replacement: $0.replacement),
                                         caseSensitive: $0.caseSensitive, isEnabled: $0.isEnabled)
        }
    }

    #if DEBUG
    var appImportSaveOverride: (() throws -> Void)?
    #endif

    /// One reviewed destination is committed in one save. A stale review never writes.
    func importReviewedEntries(
        _ entries: [AppVocabularyImport.Entry],
        baseline: [AppVocabularyImport.Existing]
    ) throws -> Bool {
        guard let context = modelContext else { throw AppVocabularyImportError.storageUnavailable }
        loadEntries()
        guard appImportSnapshot == baseline else { return false }
        guard entries.allSatisfy({ $0.kind != .snippet }) else {
            throw AppVocabularyImportError.invalidFormat
        }
        let review = AppVocabularyImport.review(.init(entries: entries), existing: baseline)
        var inserted: [DictionaryEntry] = []
        for row in review where row.outcome == .add {
            let entry = row.entry
            let item = DictionaryEntry(type: entry.kind == .term ? .term : .correction, original: entry.original, replacement: entry.replacement)
            context.insert(item)
            inserted.append(item)
        }
        do {
            #if DEBUG
            try appImportSaveOverride?()
            #endif
            try context.save()
            loadEntries()
            return true
        } catch {
            // Preserve unrelated pending changes, including deferred dictation counters.
            for item in inserted { context.delete(item) }
            context.processPendingChanges()
            loadEntries()
            throw AppVocabularyImportError.storageUnavailable
        }
    }

    func addEntry(
        type: DictionaryEntryType,
        original: String,
        replacement: String? = nil,
        caseSensitive: Bool = false,
        ctcMinSimilarity: Float? = nil,
        source: DictionaryEntrySource = .manual
    ) {
        guard let context = modelContext else { return }

        // Check for duplicate
        if entries.contains(where: { $0.original.lowercased() == original.lowercased() && $0.type == type }) {
            return
        }

        let now = Date()
        let entry = DictionaryEntry(
            type: type,
            original: original,
            replacement: replacement,
            caseSensitive: caseSensitive,
            ctcMinSimilarity: Self.normalizedCtcMinSimilarity(type == .term ? ctcMinSimilarity : nil),
            source: source,
            createdAt: now,
            updatedAt: now
        )

        context.insert(entry)

        do {
            try context.save()
            loadEntries()
        } catch {
            logger.error("Failed to save entry: \(error.localizedDescription)")
        }
    }

    func updateEntry(
        _ entry: DictionaryEntry,
        original: String,
        replacement: String?,
        caseSensitive: Bool,
        ctcMinSimilarity: Float? = nil
    ) {
        guard let context = modelContext else { return }

        if entry.original != original || entry.replacement != replacement {
            do { try suppressLearning(for: [entry]) }
            catch { logger.error("Could not preserve dismissed learning before edit: \(error.localizedDescription)"); return }
        }
        entry.original = original
        entry.replacement = replacement
        entry.caseSensitive = caseSensitive
        entry.ctcMinSimilarity = Self.normalizedCtcMinSimilarity(entry.type == .term ? ctcMinSimilarity : nil)
        entry.updatedAt = Date()

        do {
            try context.save()
            loadEntries()
        } catch {
            logger.error("Failed to update entry: \(error.localizedDescription)")
        }
    }

    func deleteEntry(_ entry: DictionaryEntry) {
        guard let context = modelContext else { return }

        do { try suppressLearning(for: [entry]) }
        catch { logger.error("Could not preserve dismissed learning before delete: \(error.localizedDescription)"); return }
        context.delete(entry)

        do {
            try context.save()
            loadEntries()
        } catch {
            logger.error("Failed to delete entry: \(error.localizedDescription)")
        }
    }

    func toggleEntry(_ entry: DictionaryEntry) {
        guard let context = modelContext else { return }

        entry.isEnabled.toggle()
        entry.updatedAt = Date()

        do {
            try context.save()
            loadEntries()
        } catch {
            logger.error("Failed to toggle entry: \(error.localizedDescription)")
        }
    }

    func setEntryEnabled(_ entry: DictionaryEntry, enabled: Bool) {
        guard let context = modelContext else { return }
        guard entry.isEnabled != enabled else { return }

        let previousEnabled = entry.isEnabled
        let previousUpdatedAt = entry.updatedAt
        entry.isEnabled = enabled
        entry.updatedAt = Date()

        do {
            try context.save()
            loadEntries()
        } catch {
            entry.isEnabled = previousEnabled
            entry.updatedAt = previousUpdatedAt
            logger.error("Failed to set entry enabled state: \(error.localizedDescription)")
        }
    }

    /// Batch add multiple entries with a single save+reload
    func addEntries(_ items: [(type: DictionaryEntryType, original: String, replacement: String?, caseSensitive: Bool)]) {
        addEntries(items.map {
            (type: $0.type, original: $0.original, replacement: $0.replacement,
             caseSensitive: $0.caseSensitive, ctcMinSimilarity: nil as Float?)
        })
    }

    /// Batch add multiple entries with a single save+reload
    func addEntries(_ items: [(type: DictionaryEntryType, original: String, replacement: String?, caseSensitive: Bool, ctcMinSimilarity: Float?)]) {
        addEntries(items.map {
            (type: $0.type, original: $0.original, replacement: $0.replacement,
             caseSensitive: $0.caseSensitive, ctcMinSimilarity: $0.ctcMinSimilarity,
             source: DictionaryEntrySource.manual)
        })
    }

    /// Batch add multiple entries with a single save+reload
    func addEntries(_ items: [(type: DictionaryEntryType, original: String, replacement: String?, caseSensitive: Bool, ctcMinSimilarity: Float?, source: DictionaryEntrySource)]) {
        guard let context = modelContext, !items.isEmpty else { return }

        var existingOriginals = Set(entries.map { "\($0.type.rawValue):\($0.original.lowercased())" })

        for item in items {
            let key = "\(item.type.rawValue):\(item.original.lowercased())"
            guard !existingOriginals.contains(key) else { continue }
            let now = Date()

            let entry = DictionaryEntry(
                type: item.type,
                original: item.original,
                replacement: item.replacement,
                caseSensitive: item.caseSensitive,
                ctcMinSimilarity: Self.normalizedCtcMinSimilarity(item.type == .term ? item.ctcMinSimilarity : nil),
                source: item.source,
                createdAt: now,
                updatedAt: now
            )
            context.insert(entry)
            existingOriginals.insert(key)
        }

        do {
            try context.save()
            loadEntries()
        } catch {
            logger.error("Failed to batch save entries: \(error.localizedDescription)")
        }
    }

    /// Import entries preserving all fields including isEnabled state
    func importEntries(_ items: [(type: DictionaryEntryType, original: String, replacement: String?, caseSensitive: Bool, isEnabled: Bool)]) {
        importEntries(items.map {
            (type: $0.type, original: $0.original, replacement: $0.replacement,
             caseSensitive: $0.caseSensitive, isEnabled: $0.isEnabled, ctcMinSimilarity: nil as Float?)
        })
    }

    /// Import entries preserving all fields including isEnabled state
    func importEntries(_ items: [(type: DictionaryEntryType, original: String, replacement: String?, caseSensitive: Bool, isEnabled: Bool, ctcMinSimilarity: Float?)]) {
        importEntries(items.map {
            (type: $0.type, original: $0.original, replacement: $0.replacement,
             caseSensitive: $0.caseSensitive, isEnabled: $0.isEnabled,
             ctcMinSimilarity: $0.ctcMinSimilarity, source: DictionaryEntrySource.manual)
        })
    }

    /// Import entries preserving all fields including isEnabled state
    func importEntries(_ items: [(type: DictionaryEntryType, original: String, replacement: String?, caseSensitive: Bool, isEnabled: Bool, ctcMinSimilarity: Float?, source: DictionaryEntrySource)]) {
        guard let context = modelContext, !items.isEmpty else { return }

        var existingOriginals = Set(entries.map { "\($0.type.rawValue):\($0.original.lowercased())" })

        for item in items {
            let key = "\(item.type.rawValue):\(item.original.lowercased())"
            guard !existingOriginals.contains(key) else { continue }
            let now = Date()

            let entry = DictionaryEntry(
                type: item.type,
                original: item.original,
                replacement: item.replacement,
                caseSensitive: item.caseSensitive,
                isEnabled: item.isEnabled,
                ctcMinSimilarity: Self.normalizedCtcMinSimilarity(item.type == .term ? item.ctcMinSimilarity : nil),
                source: item.source,
                createdAt: now,
                updatedAt: now
            )
            context.insert(entry)
            existingOriginals.insert(key)
        }

        do {
            try context.save()
            loadEntries()
        } catch {
            logger.error("Failed to import entries: \(error.localizedDescription)")
        }
    }

    /// Batch delete multiple entries
    func deleteEntries(_ entriesToDelete: [DictionaryEntry]) {
        do {
            try deleteEntries(ids: Set(entriesToDelete.map(\.id)))
        } catch {
            logger.error("Failed to batch delete entries: \(error.localizedDescription)")
        }
    }

    /// Batch delete entries by stable IDs and report persistence failures to the caller.
    func deleteEntries(ids: Set<UUID>) throws {
        guard !ids.isEmpty else { return }
        guard let context = modelContext else {
            throw DictionaryServiceMutationError.unavailable
        }

        let entriesToDelete = entries.filter { ids.contains($0.id) }
        guard !entriesToDelete.isEmpty else { return }

        try suppressLearning(for: entriesToDelete)
        for entry in entriesToDelete {
            context.delete(entry)
        }

        do {
            try context.save()
            loadEntries()
        } catch {
            context.rollback()
            loadEntries()
            logger.error("Failed to batch delete entries: \(error.localizedDescription)")
            throw DictionaryServiceMutationError.saveFailed(error)
        }
    }

    /// Get all enabled terms as a comma-separated string for Whisper prompt.
    /// Truncates at 600 characters to stay within the API's 224-token limit.
    func enabledTerms() -> [String] {
        PluginDictionaryTerms.normalizedTerms(from: terms.map(\.original) + learnedRecognitionSpellings())
    }

    func enabledTermHints() -> [PluginDictionaryTermHint] {
        PluginDictionaryTerms.normalizedTermHints(from: terms.map {
            PluginDictionaryTermHint(text: $0.original, ctcMinSimilarity: $0.ctcMinSimilarity)
        } + learnedRecognitionSpellings().map { PluginDictionaryTermHint(text: $0) })
    }

    private func learnedRecognitionSpellings() -> [String] {
        let disabled = Set(entries.filter { !$0.isEnabled }.map { ($0.replacement ?? $0.original).lowercased() })
        return corrections.filter { $0.source == .autoLearned }.compactMap { entry in
            guard let target = entry.replacement, !target.isEmpty, target.count <= 64,
                  !disabled.contains(target.lowercased()) else { return nil }
            return target
        }
    }

    func setTerms(_ rawTerms: [String], replaceExisting: Bool) {
        do {
            try setAPITerms(rawTerms, replaceExisting: replaceExisting)
        } catch {
            logger.error("Failed to set terms: \(error.localizedDescription)")
        }
    }

    func setAPITerms(_ rawTerms: [String], replaceExisting: Bool) throws {
        guard let context = modelContext else {
            throw DictionaryServiceMutationError.unavailable
        }

        let normalized = PluginDictionaryTerms.normalizedTerms(from: rawTerms)
        let normalizedByKey = Dictionary(uniqueKeysWithValues: normalized.map {
            ($0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current), $0)
        })
        let desiredKeys = Set(normalizedByKey.keys)
        let existingTerms = entries.filter { $0.type == .term }

        for entry in existingTerms {
            let key = entry.original.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            if let desiredTerm = normalizedByKey[key] {
                entry.original = desiredTerm
                entry.isEnabled = true
                entry.updatedAt = Date()
            } else if replaceExisting {
                context.delete(entry)
            }
        }

        let existingKeys = Set(existingTerms.map {
            $0.original.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        })

        for term in normalized where !existingKeys.contains(term.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)) {
            let now = Date()
            context.insert(DictionaryEntry(type: .term, original: term, replacement: nil, caseSensitive: false, isEnabled: true, createdAt: now, updatedAt: now))
        }

        if replaceExisting || !desiredKeys.isEmpty {
            do {
                try context.save()
                loadEntries()
            } catch {
                logger.error("Failed to set terms: \(error.localizedDescription)")
                throw DictionaryServiceMutationError.saveFailed(error)
            }
        }
    }

    func setAPITermEntries(_ rawTerms: [(term: String, ctcMinSimilarity: Float?)], replaceExisting: Bool) throws {
        guard let context = modelContext else {
            throw DictionaryServiceMutationError.unavailable
        }

        let normalized = PluginDictionaryTerms.normalizedTermHints(from: rawTerms.map {
            PluginDictionaryTermHint(
                text: $0.term,
                ctcMinSimilarity: Self.normalizedCtcMinSimilarity($0.ctcMinSimilarity)
            )
        })
        let normalizedByKey = Dictionary(uniqueKeysWithValues: normalized.map {
            ($0.text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current), $0)
        })
        let desiredKeys = Set(normalizedByKey.keys)
        let existingTerms = entries.filter { $0.type == .term }

        for entry in existingTerms {
            let key = entry.original.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            if let desiredTerm = normalizedByKey[key] {
                entry.original = desiredTerm.text
                entry.isEnabled = true
                entry.ctcMinSimilarity = desiredTerm.ctcMinSimilarity
                entry.updatedAt = Date()
            } else if replaceExisting {
                context.delete(entry)
            }
        }

        let existingKeys = Set(existingTerms.map {
            $0.original.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        })

        for term in normalized where !existingKeys.contains(term.text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)) {
            let now = Date()
            context.insert(DictionaryEntry(
                type: .term,
                original: term.text,
                replacement: nil,
                caseSensitive: false,
                isEnabled: true,
                ctcMinSimilarity: term.ctcMinSimilarity,
                createdAt: now,
                updatedAt: now
            ))
        }

        if replaceExisting || !desiredKeys.isEmpty {
            do {
                try context.save()
                loadEntries()
            } catch {
                logger.error("Failed to set term entries: \(error.localizedDescription)")
                throw DictionaryServiceMutationError.saveFailed(error)
            }
        }
    }

    func deleteAPITerm(_ rawTerm: String) throws -> Bool {
        guard let context = modelContext else {
            throw DictionaryServiceMutationError.unavailable
        }

        guard let normalizedTerm = PluginDictionaryTerms.normalizedTerms(from: [rawTerm]).first else {
            return false
        }

        let desiredKey = normalizedTerm.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        guard let entry = entries.first(where: {
            $0.type == .term &&
            $0.original.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) == desiredKey
        }) else {
            return false
        }

        context.delete(entry)

        do {
            try context.save()
            loadEntries()
            return true
        } catch {
            logger.error("Failed to delete term: \(error.localizedDescription)")
            throw DictionaryServiceMutationError.saveFailed(error)
        }
    }

    func removeAllTerms() {
        guard let context = modelContext else { return }

        for entry in entries where entry.type == .term {
            context.delete(entry)
        }

        do {
            try context.save()
            loadEntries()
        } catch {
            logger.error("Failed to remove all terms: \(error.localizedDescription)")
        }
    }

    func getTermsForPrompt(providerId: String?) -> String? {
        let terms = enabledTerms()
        guard !terms.isEmpty else { return nil }

        guard let providerId,
              let plugin = PluginManager.shared?.transcriptionEngine(for: providerId) else {
            return PluginDictionaryTerms.prompt(from: terms)
        }

        // Terms stay out of the prompt until the plugin setting enables them, so a
        // caller-supplied prompt can still reach the plugin on its own.
        switch (plugin as? any DictionaryTermsCapabilityProviding)?.dictionaryTermsSupport {
        case .unsupported, .requiresPluginSetting:
            return nil
        case .supported, nil:
            break
        }

        guard let budget = (plugin as? any DictionaryTermsBudgetProviding)?.dictionaryTermsBudget else {
            return PluginDictionaryTerms.prompt(from: terms)
        }

        return PluginDictionaryTerms.prompt(from: terms, budget: budget)
    }

    func getTermHints(providerId: String?) -> [PluginDictionaryTermHint] {
        let hints = enabledTermHints()
        guard !hints.isEmpty else { return [] }

        guard let providerId,
              let plugin = PluginManager.shared?.transcriptionEngine(for: providerId),
              let budget = (plugin as? any DictionaryTermsBudgetProviding)?.dictionaryTermsBudget else {
            return PluginDictionaryTerms.clippedTermHints(
                from: hints,
                budget: DictionaryTermsBudget(maxTotalChars: 600)
            )
        }

        return PluginDictionaryTerms.clippedTermHints(from: hints, budget: budget)
    }

    /// Apply all enabled corrections to the given text.
    ///
    /// With `deferUsageCountSave`, usage counters stay unsaved until `saveDeferredUsageCounts()`
    /// so the dictation pipeline does not block insertion on a SwiftData save.
    func applyCorrections(to text: String, deferUsageCountSave: Bool = false) -> String {
        applyCorrections(to: [text], deferUsageCountSave: deferUsageCountSave).first ?? text
    }

    /// Applies all enabled corrections, counting a correction's usage only if its id is not
    /// already in `countedCorrectionIDs`. The post-processing pipeline shares one set across
    /// its pre- and post-LLM passes so a dictation counts each correction at most once.
    func applyCorrections(
        to text: String,
        deferUsageCountSave: Bool,
        countedCorrectionIDs: inout Set<UUID>
    ) -> String {
        applyCorrections(
            to: [text],
            deferUsageCountSave: deferUsageCountSave,
            countedCorrectionIDs: &countedCorrectionIDs
        ).first ?? text
    }

    /// Orders corrections for application: longest original first, ties keep the
    /// caller's (alphabetical) order so results stay deterministic.
    static func orderedForApplication(_ entries: [DictionaryEntry]) -> [DictionaryEntry] {
        entries.enumerated()
            .sorted { lhs, rhs in
                let lhsLength = lhs.element.original.trimmingCharacters(in: .whitespacesAndNewlines).count
                let rhsLength = rhs.element.original.trimmingCharacters(in: .whitespacesAndNewlines).count
                if lhsLength != rhsLength {
                    return lhsLength > rhsLength
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    /// Spellings that LLM post-processing must preserve: enabled terms plus the target
    /// spellings of enabled corrections, de-duplicated case- and diacritic-insensitively
    /// (terms win ties) and sorted for a stable prompt.
    func vocabularyForPrompt(limit: Int = 400) -> [String] {
        var seenKeys = Set<String>()
        var result: [String] = []
        let candidates = terms.map(\.original) + corrections.compactMap(\.replacement)
        for candidate in candidates {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            guard seenKeys.insert(key).inserted else { continue }
            result.append(trimmed)
        }
        return Array(
            result
                .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
                .prefix(limit)
        )
    }

    /// Apply all enabled corrections to related text fields while counting each correction once.
    func applyCorrections(to texts: [String], deferUsageCountSave: Bool = false) -> [String] {
        var countedCorrectionIDs = Set<UUID>()
        return applyCorrections(
            to: texts,
            deferUsageCountSave: deferUsageCountSave,
            countedCorrectionIDs: &countedCorrectionIDs
        )
    }

    private func applyCorrections(
        to texts: [String],
        deferUsageCountSave: Bool,
        countedCorrectionIDs: inout Set<UUID>
    ) -> [String] {
        let reviews = texts.map { reviewMatches(in: $0) }
        let usedIDs = reviews.reduce(into: Set<UUID>()) { $0.formUnion($1.correctionIDs) }
        let newlyCounted = usedIDs.subtracting(countedCorrectionIDs)
        countedCorrectionIDs.formUnion(usedIDs)
        recordUsage(ofCorrectionIDs: newlyCounted, deferUsageCountSave: deferUsageCountSave)
        return reviews.map(\.text)
    }

    /// Applies all enabled corrections without touching usage counters, for text that is
    /// prepared repeatedly while recording and will be corrected again when dictation stops.
    func previewCorrections(to text: String) -> String {
        var appliedCorrectionIDs = Set<UUID>()
        return previewCorrections(to: text, appliedCorrectionIDs: &appliedCorrectionIDs)
    }

    /// Like `previewCorrections(to:)`, and adds the id of every correction that changed the
    /// text to `appliedCorrectionIDs`, so a caller can count their usage later with
    /// `recordUsage(ofCorrectionIDs:deferUsageCountSave:)` once the result is actually used.
    func previewCorrections(to text: String, appliedCorrectionIDs: inout Set<UUID>) -> String {
        let review = reviewMatches(in: text)
        appliedCorrectionIDs.formUnion(review.correctionIDs)
        return review.text
    }

    /// Counts one use for each enabled correction whose id is in `correctionIDs`.
    func recordUsage(ofCorrectionIDs correctionIDs: Set<UUID>, deferUsageCountSave: Bool) {
        guard !correctionIDs.isEmpty else { return }
        var needsSave = false
        for correction in corrections where correctionIDs.contains(correction.id) {
            correction.usageCount += 1
            needsSave = true
        }
        guard needsSave else { return }
        if deferUsageCountSave {
            hasDeferredUsageCountChanges = true
        } else {
            saveUsageCounts()
        }
    }

    /// Saves usage counters left unsaved by `applyCorrections(to:deferUsageCountSave:)`.
    func saveDeferredUsageCounts() {
        guard hasDeferredUsageCountChanges else { return }
        saveUsageCounts()
    }

    private func saveUsageCounts() {
        hasDeferredUsageCountChanges = false
        do {
            try modelContext?.save()
        } catch {
            logger.error("Failed to update usage count: \(error.localizedDescription)")
        }
    }

    private struct MatchCandidate {
        let matchRange: Range<String.Index>
        let isDeletion: Bool
        let range: Range<String.Index>
        let replacement: String
        let entryID: UUID
        let priority: Int
        let reason: String
    }

    /// Resolve against the input once. Preferred spellings are terminal, explicit aliases
    /// beat inferred formatting, and equally strong conflicting matches leave text alone.
    func reviewMatches(in text: String) -> DictionaryMatchReview {
        guard !text.isEmpty else { return .init(text: text, changes: [], conflicts: []) }
        var candidates: [MatchCandidate] = []
        var conflicts = Set<String>()
        let preferred = terms.map { ($0, $0.original) } + corrections.compactMap { entry in
            entry.replacement.map { (entry, $0) }
        }
        // Protect complete preferred outputs across passes, including aliases that point
        // into another rule. This also prevents a shorter alias corrupting a saved name.
        var terminalRanges: [Range<String.Index>] = []
        for (_, spelling) in preferred where !spelling.isEmpty {
            var start = text.startIndex
            while start < text.endIndex,
                  let range = text.range(of: spelling, range: start..<text.endIndex) {
                if isBoundaryMatch(range, in: text, original: spelling) { terminalRanges.append(range) }
                start = range.upperBound
            }
        }
        func append(_ range: Range<String.Index>, _ replacement: String,
                    entry: DictionaryEntry, priority: Int, reason: String) {
            guard text[range] != replacement,
                  !self.isStructuredTokenFragment(range, in: text) else { return }
            if terminalRanges.contains(where: { $0.lowerBound <= range.lowerBound && range.upperBound <= $0.upperBound }) {
                // Self-expansion is handled by the legacy matcher; report cross-rule
                // collisions only when the source itself is a complete preferred output.
                if terminalRanges.contains(range) {
                    conflicts.insert("“\(text[range])” is already a preferred spelling; its competing rule was skipped.")
                }
                return
            }
            let isDeletion = entry.type == .correction && entry.replacement?.isEmpty == true
            let matchRange = isDeletion ? self.boundaryEvaluationRange(for: range, in: text) : range
            candidates.append(.init(matchRange: matchRange, isDeletion: isDeletion,
                                    range: range, replacement: replacement, entryID: entry.id,
                                    priority: priority, reason: reason))
        }
        for correction in correctionsForApplication {
            guard let replacement = correction.replacement else { continue }
            _ = applyCorrection(correction, to: text, replacement: replacement) { range, output in
                let comparisonRange = replacement.isEmpty ? self.boundaryEvaluationRange(for: range, in: text) : range
                let source = replacement.isEmpty ? correction.original.trimmingCharacters(in: .whitespacesAndNewlines) : correction.original
                let literal = self.textMatches(String(text[comparisonRange]), source, caseSensitive: correction.caseSensitive)
                append(range, output, entry: correction, priority: literal ? 3 : 2,
                       reason: literal ? "saved alias" : "alias formatting variant")
            }
        }
        // Plain vocabulary remains an engine hint: it is not authority to rewrite common
        // words (for example, Linear / linear). Only distinctive compound spellings have
        // enough structure for deterministic formatting without guessing their meaning.
        for (entry, spelling) in preferred where Self.hasDistinctiveWordStructure(spelling) {
            _ = replacingBoundaryMatches(of: spelling, in: text, with: spelling,
                                         caseSensitive: entry.caseSensitive) { range, output in
                append(range, output, entry: entry, priority: 1, reason: "preferred spelling")
            }
        }
        // Longest matched span wins; within the same span, a literal alias wins over
        // formatting inference. Stable identifiers affect ordering, never conflict outcomes.
        candidates.sort {
            let left = text.distance(from: $0.matchRange.lowerBound, to: $0.matchRange.upperBound)
            let right = text.distance(from: $1.matchRange.lowerBound, to: $1.matchRange.upperBound)
            if left != right { return left > right }
            if $0.priority != $1.priority { return $0.priority > $1.priority }
            if $0.range.lowerBound != $1.range.lowerBound { return $0.range.lowerBound < $1.range.lowerBound }
            return $0.entryID.uuidString < $1.entryID.uuidString
        }
        var occupied: [Range<String.Index>] = []
        var selected: [MatchCandidate] = []
        for candidate in candidates {
            guard !occupied.contains(where: { $0.overlaps(candidate.matchRange) }) else { continue }
            let peers = candidates.filter { $0.matchRange == candidate.matchRange && $0.priority == candidate.priority }
            occupied.append(candidate.matchRange)
            guard Set(peers.map(\.replacement)).count == 1 else {
                conflicts.insert("“\(text[candidate.range])” matches different preferred spellings; no replacement was made.")
                continue
            }
            selected.append(candidate)
        }
        selected.sort { $0.matchRange.lowerBound < $1.matchRange.lowerBound }
        var edits: [(range: Range<String.Index>, replacement: String, isDeletion: Bool)] = []
        var changes: [DictionaryMatchReview.Change] = []
        for candidate in selected {
            changes.append(.init(entryID: candidate.entryID, correctionID: candidate.priority > 1 ? candidate.entryID : nil,
                                 heard: String(text[candidate.matchRange]),
                                 written: candidate.isDeletion ? "" : candidate.replacement, reason: candidate.reason))
            // Adjacent deletions can share whitespace padding. Merge their removal spans
            // before rendering so one deletion cannot hide another or leave a stray space.
            if candidate.isDeletion, let last = edits.last, last.isDeletion,
               last.range.upperBound >= candidate.range.lowerBound {
                let union = min(last.range.lowerBound, candidate.range.lowerBound)..<max(last.range.upperBound, candidate.range.upperBound)
                let merged = boundaryReplacement(for: union, in: text, replacement: "", lowerLimit: text.startIndex)
                edits[edits.count - 1] = (merged.range, merged.text, true)
            } else {
                edits.append((candidate.range, candidate.replacement, candidate.isDeletion))
            }
        }
        var output = ""
        var cursor = text.startIndex
        for edit in edits {
            let lower = max(cursor, edit.range.lowerBound)
            output += text[cursor..<lower]
            output += edit.replacement
            cursor = max(cursor, edit.range.upperBound)
        }
        output += text[cursor...]
        return .init(text: output, changes: changes, conflicts: conflicts.sorted())
    }

    /// A word rule must not silently rewrite part of an address, URL, filename or
    /// code token. A saved rule covering the entire token still has explicit authority.
    private func isStructuredTokenFragment(_ range: Range<String.Index>, in text: String) -> Bool {
        var lower = range.lowerBound
        var upper = range.upperBound
        while lower > text.startIndex {
            let previous = text.index(before: lower)
            guard !text[previous].isWhitespace, !"()[]{}<>,;\"".contains(text[previous]) else { break }
            lower = previous
        }
        while upper < text.endIndex, !text[upper].isWhitespace,
              !"()[]{}<>,;\"".contains(text[upper]) { upper = text.index(after: upper) }
        while upper > range.upperBound {
            let previous = text.index(before: upper)
            guard ".!?:".contains(text[previous]) else { break }
            upper = previous
        }
        guard lower != range.lowerBound || upper != range.upperBound else { return false }
        let token = String(text[lower..<upper])
        return token.contains("@") || token.contains("://") || token.contains("`") ||
            token.hasPrefix("/") || token.hasPrefix("~/") || token.hasPrefix("./") ||
            token.range(of: #"[\p{L}\p{N}]\.[\p{L}]"#, options: .regularExpression) != nil
    }

    /// Suggestions are deliberately separate from dictation matching. A nearby spelling
    /// is evidence to review, never authority to change the transcript or learn a rule.
    func suggestedAliases(in text: String) -> [DictionaryAliasSuggestion] {
        guard !text.isEmpty, text.count <= 2_000,
              let tokenizer = try? NSRegularExpression(pattern: #"[\p{L}\p{N}]+(?:[-'’][\p{L}\p{N}]+)*"#) else { return [] }
        let ranges = tokenizer.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap { Range($0.range, in: text) }
        let preferred = terms.map(\.original) + corrections.compactMap(\.replacement)
        let mappings = preferred.map { ($0, $0) } + corrections.compactMap { entry in
            entry.replacement.map { (entry.original, $0) }
        }
        let targets = mappings.map { (key: Self.suggestionKey($0.0), written: $0.1) }
            .filter { $0.key.count >= 6 && $0.key.count <= 64 && !$0.written.isEmpty && $0.written.count <= 64 }
        let knownKeys = Set(targets.map(\.key))
        var suggestions: [DictionaryAliasSuggestion] = []
        for index in ranges.indices {
            for count in 1...min(4, ranges.count - index) {
                let last = index + count - 1
                if count > 1 {
                    let gap = text[ranges[last - 1].upperBound..<ranges[last].lowerBound]
                    // An n-gram may cross horizontal spaces, never punctuation or lines.
                    guard !gap.isEmpty, gap.allSatisfy({ $0.isWhitespace && !$0.isNewline }) else { break }
                }
                let range = ranges[index].lowerBound..<ranges[last].upperBound
                guard !isStructuredTokenFragment(range, in: text) else { continue }
                let source = String(text[range])
                let key = Self.suggestionKey(source)
                guard key.count >= 6, key.count <= 64, !knownKeys.contains(key) else { continue }
                let nearby = Set(targets.filter { Self.isOneEditApart(key, $0.key) }.map(\.written)).sorted()
                guard !nearby.isEmpty, previewCorrections(to: source) == source else { continue }
                for target in nearby {
                    let suggestion = DictionaryAliasSuggestion(heard: source, written: target)
                    if !suggestions.contains(suggestion) { suggestions.append(suggestion) }
                    if suggestions.count == 3 { return suggestions }
                }
            }
        }
        return suggestions
    }

    private static func suggestionKey(_ text: String) -> String {
        String(text.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    private static func isOneEditApart(_ lhs: String, _ rhs: String) -> Bool {
        guard lhs != rhs else { return false }
        let a = Array(lhs), b = Array(rhs)
        guard abs(a.count - b.count) <= 1 else { return false }
        if a.count == b.count {
            let differences = a.indices.filter { a[$0] != b[$0] }
            if differences.count == 1 { return true }
            return differences.count == 2 && differences[1] == differences[0] + 1 &&
                a[differences[0]] == b[differences[1]] && a[differences[1]] == b[differences[0]]
        }
        let shorter = a.count < b.count ? a : b
        let longer = a.count < b.count ? b : a
        var shortIndex = 0, longIndex = 0, skipped = false
        while shortIndex < shorter.count && longIndex < longer.count {
            if shorter[shortIndex] == longer[longIndex] {
                shortIndex += 1
                longIndex += 1
            } else {
                guard !skipped else { return false }
                skipped = true
                longIndex += 1
            }
        }
        return true
    }

    private static func hasDistinctiveWordStructure(_ spelling: String) -> Bool {
        let characters = Array(spelling)
        guard characters.count >= 4 else { return false }
        return characters.indices.dropFirst().contains { index in
            characters[index].isUppercase && characters[index - 1].isLetter &&
                (characters[index - 1].isLowercase ||
                 (index + 1 < characters.count && characters[index + 1].isLowercase))
        }
    }

    private func applyCorrection(_ correction: DictionaryEntry, to text: String, replacement: String,
                                 onMatch: ((Range<String.Index>, String) -> Void)? = nil) -> String {
        switch matchPolicy(for: correction) {
        case .exact:
            guard textMatches(text, correction.original, caseSensitive: correction.caseSensitive) else { return text }
            onMatch?(text.startIndex..<text.endIndex, replacement)
            return replacement
        case .boundary:
            return replacingBoundaryMatches(
                of: correction.original,
                in: text,
                with: replacement,
                caseSensitive: correction.caseSensitive,
                onMatch: onMatch
            )
        case .substring:
            let options: String.CompareOptions = correction.caseSensitive ? [] : [.caseInsensitive]
            let contexts = Self.reexpansionContexts(of: correction.original, in: replacement, options: options, locale: nil)
            var result = ""
            var searchStart = text.startIndex
            while let range = text.range(of: correction.original, options: options, range: searchStart..<text.endIndex),
                  range.lowerBound < range.upperBound {
                result += text[searchStart..<range.lowerBound]
                let alreadyCorrected = Self.isWithinExistingReplacement(
                    range,
                    in: text,
                    contexts: contexts,
                    options: options,
                    locale: nil
                )
                if !alreadyCorrected { onMatch?(range, replacement) }
                result += alreadyCorrected ? String(text[range]) : replacement
                searchStart = range.upperBound
            }
            result += text[searchStart..<text.endIndex]
            return result
        }
    }

    /// Where the original re-matches inside its own replacement: the replacement text before
    /// and after each such match. Found with the correction's own matching semantics, so a
    /// case-folded match counts too (`Strasse` matches inside `Straße.`). A match that spans
    /// the whole replacement is skipped: re-applying it reproduces the replacement, which is
    /// why case-only corrections (`rake` -> `RAKE`) need no protection. Empty when a
    /// repeated pass cannot expand the text.
    private struct ReexpansionContext {
        let prefix: String
        let suffix: String
    }

    private static func reexpansionContexts(
        of original: String,
        in replacement: String,
        options: String.CompareOptions,
        locale: Locale?,
        flexibleSpacing: Bool = false
    ) -> [ReexpansionContext] {
        guard !original.isEmpty, !replacement.isEmpty else { return [] }
        let wholeReplacement = replacement.startIndex..<replacement.endIndex
        var contexts: [ReexpansionContext] = []
        var searchStart = replacement.startIndex
        while searchStart < replacement.endIndex,
              let range = nextSpellingRange(of: original, in: replacement, options: options,
                                            range: searchStart..<replacement.endIndex, locale: locale,
                                            flexibleSpacing: flexibleSpacing) {
            if range != wholeReplacement {
                contexts.append(ReexpansionContext(
                    prefix: String(replacement[..<range.lowerBound]),
                    suffix: String(replacement[range.upperBound...])
                ))
            }
            searchStart = replacement.index(after: range.lowerBound)
        }
        return contexts
    }

    /// Whether the match of the original at `range` already sits inside the replacement: for
    /// one of the places the original re-matches inside the replacement, the text before and
    /// after the match equals the replacement text before and after it. Replacing such a match
    /// again would expand text that is already corrected (`GitHub.com.com`, `Straße..`, or a
    /// run of hyphens that grows on every pass, including where two corrected runs meet). Text
    /// that already reads as the replacement is treated as corrected even when it was
    /// dictated that way.
    private static func isWithinExistingReplacement(
        _ range: Range<String.Index>,
        in text: String,
        contexts: [ReexpansionContext],
        options: String.CompareOptions,
        locale: Locale?
    ) -> Bool {
        // Anchored searches rather than Character offsets: under case folding the text can
        // spell a context with a different number of Characters (`ss` for `ß`).
        for context in contexts {
            let prefixMatches = context.prefix.isEmpty || text.range(
                of: context.prefix,
                options: options.union([.anchored, .backwards]),
                range: text.startIndex..<range.lowerBound,
                locale: locale
            ) != nil
            guard prefixMatches else { continue }
            let suffixMatches = context.suffix.isEmpty || text.range(
                of: context.suffix,
                options: options.union(.anchored),
                range: range.upperBound..<text.endIndex,
                locale: locale
            ) != nil
            if suffixMatches {
                return true
            }
        }
        return false
    }

    private func matchPolicy(for correction: DictionaryEntry) -> DictionaryCorrectionMatchPolicy {
        let original = correction.original.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !original.isEmpty else { return .exact }
        return original.containsWordLikeCharacter ? .boundary : .substring
    }

    private func textMatches(_ text: String, _ original: String, caseSensitive: Bool) -> Bool {
        if caseSensitive {
            return text == original
        }
        return text.compare(original, options: [.caseInsensitive], locale: .current) == .orderedSame
    }

    /// Retain Foundation's existing Unicode comparison semantics for literal matches;
    /// regex normalization supplements it rather than replacing it.
    private static func nextSpellingRange(of original: String, in text: String,
                                          options: String.CompareOptions, range: Range<String.Index>,
                                          locale: Locale?, flexibleSpacing: Bool) -> Range<String.Index>? {
        let literal = text.range(of: original, options: options, range: range, locale: locale)
        guard flexibleSpacing, let pattern = boundarySearchPattern(original),
              let normalized = text.range(of: pattern, options: options.union(.regularExpression), range: range, locale: locale) else {
            return literal
        }
        guard let literal else { return normalized }
        if literal.lowerBound != normalized.lowerBound {
            return literal.lowerBound < normalized.lowerBound ? literal : normalized
        }
        return literal.upperBound >= normalized.upperBound ? literal : normalized
    }

    /// Normalize only boundaries that the saved spelling actually supplies. Preserve
    /// significant punctuation, digits, diacritics, underscores and line boundaries.
    private static func boundarySearchPattern(_ original: String) -> String? {
        guard original == original.trimmingCharacters(in: .whitespacesAndNewlines),
              !original.contains(where: { $0.isNewline }) else { return nil }
        let characters = Array(original)
        var pattern = ""
        var changed = false
        var previousWasSeparator = false
        let separator = "[\\p{Zs}\\t]*[-‐‑]?[\\p{Zs}\\t]*"
        for index in characters.indices {
            let character = characters[index]
            let before = index > 0 ? characters[index - 1] : nil
            let after = index + 1 < characters.count ? characters[index + 1] : nil
            let isSeparator = character.isWhitespace || "-‐‑".contains(character)
            if isSeparator {
                // Relax only internal word separators, not punctuation operators or
                // leading/trailing whitespace used by explicit deletion rules.
                if !previousWasSeparator { pattern += separator }
                previousWasSeparator = true
                changed = true
                continue
            }
            if !previousWasSeparator, character.isUppercase, let before, before.isLetter,
               before.isLowercase || (before.isUppercase && after?.isLowercase == true) {
                pattern += separator
                changed = true
            }
            if "'’".contains(character), before?.isLetter == true, after?.isLetter == true {
                pattern += "['’]"
                changed = true
            } else {
                pattern += NSRegularExpression.escapedPattern(for: String(character))
            }
            previousWasSeparator = false
        }
        // Operators and punctuation-only sources keep the original literal semantics.
        guard changed, characters.first?.isLetter == true, characters.last?.isLetter == true else { return nil }
        return pattern
    }

    private func replacingBoundaryMatches(
        of original: String,
        in text: String,
        with replacement: String,
        caseSensitive: Bool,
        onMatch: ((Range<String.Index>, String) -> Void)? = nil
    ) -> String {
        let boundaryOriginal = original.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !original.isEmpty, !boundaryOriginal.isEmpty else { return text }

        var result = ""
        var searchStart = text.startIndex
        let options: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        let contexts = Self.reexpansionContexts(of: original, in: replacement, options: options, locale: .current, flexibleSpacing: true)

        while let range = Self.nextSpellingRange(of: original, in: text, options: options,
                                                range: searchStart..<text.endIndex, locale: .current,
                                                flexibleSpacing: true) {
            guard range.lowerBound < range.upperBound else { break }
            let boundaryRange = boundaryEvaluationRange(for: range, in: text)

            if boundaryRange.lowerBound < boundaryRange.upperBound,
               !Self.isWithinExistingReplacement(range, in: text, contexts: contexts, options: options, locale: .current),
               isBoundaryMatch(boundaryRange, in: text, original: boundaryOriginal) {
                let resolvedReplacement = boundaryReplacement(
                    for: range,
                    in: text,
                    replacement: replacement,
                    lowerLimit: searchStart
                )
                onMatch?(resolvedReplacement.range, resolvedReplacement.text)
                result += text[searchStart..<resolvedReplacement.range.lowerBound]
                result += resolvedReplacement.text
                searchStart = resolvedReplacement.range.upperBound
            } else {
                result += text[searchStart..<range.upperBound]
                searchStart = range.upperBound
            }
        }

        result += text[searchStart..<text.endIndex]
        return result
    }

    private func boundaryReplacement(
        for range: Range<String.Index>,
        in text: String,
        replacement: String,
        lowerLimit: String.Index
    ) -> (range: Range<String.Index>, text: String) {
        guard replacement.isEmpty else { return (range, replacement) }

        let deletionRange = emptyBoundaryReplacementRange(for: range, in: text, lowerLimit: lowerLimit)
        return (deletionRange, separatorAfterDeleting(deletionRange, in: text))
    }

    private func emptyBoundaryReplacementRange(
        for range: Range<String.Index>,
        in text: String,
        lowerLimit: String.Index
    ) -> Range<String.Index> {
        var lowerBound = range.lowerBound
        var upperBound = range.upperBound

        if upperBound < text.endIndex, text[upperBound].isWhitespace {
            while upperBound < text.endIndex, text[upperBound].isWhitespace {
                upperBound = text.index(after: upperBound)
            }
        } else if shouldConsumeLeadingWhitespace(for: range, in: text) {
            while lowerBound > lowerLimit {
                let previous = text.index(before: lowerBound)
                guard text[previous].isWhitespace else { break }
                lowerBound = previous
            }
        }

        return lowerBound..<upperBound
    }

    private func shouldConsumeLeadingWhitespace(for range: Range<String.Index>, in text: String) -> Bool {
        guard range.lowerBound < range.upperBound else { return false }
        let lastMatchedIndex = text.index(before: range.upperBound)
        return !text[lastMatchedIndex].isWhitespace || range.upperBound == text.endIndex
    }

    private func separatorAfterDeleting(_ range: Range<String.Index>, in text: String) -> String {
        let previous = range.lowerBound > text.startIndex ? text[text.index(before: range.lowerBound)] : nil
        let next = range.upperBound < text.endIndex ? text[range.upperBound] : nil

        if previous?.isLatinOrNumber == true && next?.isLatinOrNumber == true {
            return " "
        }

        if previous?.keepsFollowingWordSeparatedAfterDeletion == true && next?.isLatinOrNumber == true {
            return " "
        }

        return ""
    }

    private func boundaryEvaluationRange(for range: Range<String.Index>, in text: String) -> Range<String.Index> {
        var lowerBound = range.lowerBound
        var upperBound = range.upperBound

        while lowerBound < upperBound, text[lowerBound].isWhitespace {
            lowerBound = text.index(after: lowerBound)
        }

        while lowerBound < upperBound {
            let previous = text.index(before: upperBound)
            guard text[previous].isWhitespace else { break }
            upperBound = previous
        }

        return lowerBound..<upperBound
    }

    private func isBoundaryMatch(_ range: Range<String.Index>, in text: String, original: String) -> Bool {
        let previous = range.lowerBound > text.startIndex ? text[text.index(before: range.lowerBound)] : nil
        let next = range.upperBound < text.endIndex ? text[range.upperBound] : nil

        if original.isAllKatakana {
            return previous?.isKatakana != true && next?.isKatakana != true
        }

        if original.isAllLatinOrNumber {
            return previous?.isLatinOrNumber != true && next?.isLatinOrNumber != true && previous != "_" && next != "_"
        }

        let startsAtBoundary = previous != "_" && (previous?.isWordLike != true || previous?.isJapaneseParticleBoundary == true)
        let endsAtBoundary = next != "_" && (next?.isWordLike != true ||
            next?.isJapaneseParticleBoundary == true ||
            (original.count > 1 && String(text[range.upperBound...]).startsWithJapaneseParticleBoundary))
        return startsAtBoundary && endsAtBoundary
    }

    /// Add a correction learned from history edits
    func learnCorrection(original: String, replacement: String) {
        _ = learnCorrections([CorrectionSuggestion(original: original, replacement: replacement)])
    }

    /// Batch add corrections learned from user edits. Existing corrections are never overwritten.
    @discardableResult
    func learnCorrections(_ suggestions: [CorrectionSuggestion]) -> [LearnedDictionaryCorrection] {
        learnCorrectionsWithResult(suggestions).learnedCorrections
    }

    /// Typed variant used by automatic learning to distinguish duplicates from storage failures.
    func learnCorrectionsWithResult(_ suggestions: [CorrectionSuggestion]) -> DictionaryCorrectionLearningResult {
        guard !suggestions.isEmpty else {
            return DictionaryCorrectionLearningResult(learnedCorrections: [], duplicateCount: 0, failed: false)
        }
        guard let context = modelContext else {
            return DictionaryCorrectionLearningResult(learnedCorrections: [], duplicateCount: 0, failed: true)
        }

        var existingOriginals = Set(
            entries
                .filter { $0.type == .correction }
                .map { $0.original.lowercased() }
        )
        let now = Date()
        var learned: [LearnedDictionaryCorrection] = []
        var insertedEntries: [DictionaryEntry] = []
        var duplicateCount = 0

        for suggestion in suggestions {
            let original = suggestion.original.trimmingCharacters(in: .whitespacesAndNewlines)
            let replacement = suggestion.replacement.trimmingCharacters(in: .whitespacesAndNewlines)
            let originalKey = original.lowercased()

            guard !original.isEmpty,
                  originalKey != replacement.lowercased() else {
                continue
            }
            guard !isLearningDismissed(original: original, replacement: replacement),
                  !entries.contains(where: { !$0.isEnabled && ($0.original.lowercased() == originalKey || ($0.replacement ?? $0.original).lowercased() == replacement.lowercased()) }),
                  !(entries + insertedEntries).contains(where: { $0.type == .correction &&
                      ($0.original.lowercased() == replacement.lowercased() || $0.replacement?.lowercased() == originalKey) }) else {
                duplicateCount += 1
                continue
            }
            guard !existingOriginals.contains(originalKey) else {
                duplicateCount += 1
                continue
            }

            let entry = DictionaryEntry(
                type: .correction,
                original: original,
                replacement: replacement,
                caseSensitive: false,
                source: .autoLearned,
                createdAt: now,
                updatedAt: now
            )
            context.insert(entry)
            insertedEntries.append(entry)
            existingOriginals.insert(originalKey)
            learned.append(LearnedDictionaryCorrection(
                id: entry.id,
                original: original,
                replacement: replacement,
                savedAt: now
            ))
        }

        guard !learned.isEmpty else {
            return DictionaryCorrectionLearningResult(
                learnedCorrections: [],
                duplicateCount: duplicateCount,
                failed: false
            )
        }

        do {
            #if DEBUG
            try learningSaveOverride?()
            #endif
            try context.save()
            loadEntries()
            return DictionaryCorrectionLearningResult(
                learnedCorrections: learned,
                duplicateCount: duplicateCount,
                failed: false
            )
        } catch {
            // A learning failure must not roll back deferred usage or other edits.
            for entry in insertedEntries { context.delete(entry) }
            context.processPendingChanges()
            loadEntries()
            logger.error("Failed to learn corrections: \(error.localizedDescription)")
            return DictionaryCorrectionLearningResult(
                learnedCorrections: [],
                duplicateCount: duplicateCount,
                failed: true
            )
        }
    }

    /// Vocabulary-only memory cannot rewrite a legitimate common word. It uses the
    /// same dictionary store, visibility, disabling, and deletion as manual terms.
    func learnVocabularyWithResult(_ word: String) -> DictionaryCorrectionLearningResult {
        let word = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let context = modelContext else {
            return .init(learnedCorrections: [], duplicateCount: 0, failed: true)
        }
        guard !word.isEmpty, word.count <= 64,
              !isLearningDismissed(original: word, replacement: word, vocabulary: true),
              !entries.contains(where: { !$0.isEnabled && ($0.replacement ?? $0.original).lowercased() == word.lowercased() }),
              !entries.contains(where: { $0.type == .term && $0.original.lowercased() == word.lowercased() }) else {
            return .init(learnedCorrections: [], duplicateCount: 1, failed: false)
        }
        let date = Date()
        let entry = DictionaryEntry(type: .term, original: word, source: .autoLearned, createdAt: date, updatedAt: date)
        context.insert(entry)
        do {
            #if DEBUG
            try learningSaveOverride?()
            #endif
            try context.save()
            loadEntries()
            return .init(learnedCorrections: [.init(id: entry.id, original: word, replacement: word, isVocabulary: true, savedAt: date)], duplicateCount: 0, failed: false)
        } catch {
            context.delete(entry)
            context.processPendingChanges()
            loadEntries()
            return .init(learnedCorrections: [], duplicateCount: 0, failed: true)
        }
    }

    /// Atomically adds a reviewed training term and its flat manual corrections.
    /// Existing corrections are re-checked immediately before saving and are never overwritten.
    func applyDictionaryTraining(
        canonicalWord rawCanonicalWord: String,
        approvedCandidates rawCandidates: [String]
    ) throws -> DictionaryTrainingCommitResult {
        guard let context = modelContext else {
            throw DictionaryServiceMutationError.unavailable
        }

        let canonicalWord = rawCanonicalWord.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !canonicalWord.isEmpty else {
            return DictionaryTrainingCommitResult(
                addedTerm: false,
                addedCorrections: [],
                duplicateCorrections: [],
                conflictingCorrections: []
            )
        }

        let canonicalKey = canonicalWord.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
        let termExists = entries.contains {
            $0.type == .term &&
                $0.original.folding(
                    options: [.caseInsensitive, .diacriticInsensitive],
                    locale: .current
                ) == canonicalKey
        }
        let addedTerm = !termExists
        let now = Date()

        if addedTerm {
            context.insert(DictionaryEntry(
                type: .term,
                original: canonicalWord,
                source: .manual,
                createdAt: now,
                updatedAt: now
            ))
        }

        let existingCorrections = entries.filter { $0.type == .correction }
        var seenCandidateKeys = Set<String>()
        var addedCorrections: [String] = []
        var duplicateCorrections: [String] = []
        var conflictingCorrections: [String] = []

        for rawCandidate in rawCandidates {
            let candidate = rawCandidate.trimmingCharacters(in: .whitespacesAndNewlines)
            let candidateKey = candidate.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            )
            guard !candidate.isEmpty,
                  candidateKey != canonicalKey,
                  seenCandidateKeys.insert(candidateKey).inserted else {
                continue
            }

            if let existing = existingCorrections.first(where: {
                $0.original.folding(
                    options: [.caseInsensitive, .diacriticInsensitive],
                    locale: .current
                ) == candidateKey
            }) {
                let existingReplacementKey = (existing.replacement ?? "").folding(
                    options: [.caseInsensitive, .diacriticInsensitive],
                    locale: .current
                )
                if existingReplacementKey == canonicalKey {
                    duplicateCorrections.append(candidate)
                } else {
                    conflictingCorrections.append(candidate)
                }
                continue
            }

            context.insert(DictionaryEntry(
                type: .correction,
                original: candidate,
                replacement: canonicalWord,
                caseSensitive: false,
                source: .manual,
                createdAt: now,
                updatedAt: now
            ))
            addedCorrections.append(candidate)
        }

        guard addedTerm || !addedCorrections.isEmpty else {
            return DictionaryTrainingCommitResult(
                addedTerm: false,
                addedCorrections: [],
                duplicateCorrections: duplicateCorrections,
                conflictingCorrections: conflictingCorrections
            )
        }

        do {
            #if DEBUG
            try trainingSaveOverride?()
            #endif
            try context.save()
            loadEntries()
            return DictionaryTrainingCommitResult(
                addedTerm: addedTerm,
                addedCorrections: addedCorrections,
                duplicateCorrections: duplicateCorrections,
                conflictingCorrections: conflictingCorrections
            )
        } catch {
            context.rollback()
            loadEntries()
            logger.error("Failed to apply dictionary training: \(error.localizedDescription)")
            throw DictionaryServiceMutationError.saveFailed(error)
        }
    }

    @discardableResult
    func undoLearnedCorrections(_ learned: [LearnedDictionaryCorrection], suppressRelearning: Bool = true) -> Bool {
        guard !learned.isEmpty else { return true }
        guard let context = modelContext else { return false }

        let learnedByID = Dictionary(uniqueKeysWithValues: learned.map { ($0.id, $0) })
        let entriesToDelete = entries.filter { entry in
            guard entry.source == .autoLearned,
                  let learned = learnedByID[entry.id],
                  entry.type == (learned.isVocabulary ? .term : .correction),
                  learned.savedAt == nil || entry.effectiveUpdatedAt == learned.savedAt else {
                return false
            }

            return entry.original == learned.original &&
                (learned.isVocabulary ? entry.original : entry.replacement ?? "") == learned.replacement
        }

        guard !entriesToDelete.isEmpty else { return true }

        do {
            if suppressRelearning { try suppressLearning(for: entriesToDelete) }
        } catch {
            logger.error("Could not persist dismissed learning: \(error.localizedDescription)")
            return false
        }

        for entry in entriesToDelete {
            context.delete(entry)
        }

        do {
            try context.save()
            loadEntries()
            return true
        } catch {
            logger.error("Failed to undo learned corrections: \(error.localizedDescription)")
            return false
        }
    }

    func upsertAPICorrection(original: String, replacement: String, caseSensitive: Bool) throws {
        guard let context = modelContext else {
            throw DictionaryServiceMutationError.unavailable
        }

        if let entry = entries.first(where: {
            $0.type == .correction &&
            $0.original.caseInsensitiveCompare(original) == .orderedSame
        }) {
            entry.original = original
            entry.replacement = replacement
            entry.caseSensitive = caseSensitive
            entry.isEnabled = true
            entry.source = .manual
            entry.updatedAt = Date()
        } else {
            let now = Date()
            let entry = DictionaryEntry(
                type: .correction,
                original: original,
                replacement: replacement,
                caseSensitive: caseSensitive,
                isEnabled: true,
                source: .manual,
                createdAt: now,
                updatedAt: now
            )
            context.insert(entry)
        }

        do {
            try context.save()
            loadEntries()
        } catch {
            logger.error("Failed to upsert correction: \(error.localizedDescription)")
            throw DictionaryServiceMutationError.saveFailed(error)
        }
    }

    func deleteAPICorrection(original: String) throws -> Bool {
        guard let context = modelContext else {
            throw DictionaryServiceMutationError.unavailable
        }

        guard let entry = entries.first(where: {
            $0.type == .correction &&
            $0.original.caseInsensitiveCompare(original) == .orderedSame
        }) else {
            return false
        }

        context.delete(entry)

        do {
            try context.save()
            loadEntries()
            return true
        } catch {
            logger.error("Failed to delete correction: \(error.localizedDescription)")
            throw DictionaryServiceMutationError.saveFailed(error)
        }
    }

    func userDataSyncEntries(
        excludingTermItemIDs: Set<String> = [],
        excludingCorrectionItemIDs: Set<String> = [],
        keepLearnedCorrectionsLocal: Bool = TargetAppCorrectionLearningService.isPrivateBuild
    ) -> [UserDataSyncDictionaryEntry] {
        entries.compactMap { entry in
            if keepLearnedCorrectionsLocal, entry.source == .autoLearned { return nil }
            let itemID = UserDataSyncIdentity.dictionaryItemID(entryType: entry.type, original: entry.original)
            if entry.type == .term, excludingTermItemIDs.contains(itemID) {
                return nil
            }
            if entry.type == .correction, excludingCorrectionItemIDs.contains(itemID) {
                return nil
            }

            return UserDataSyncDictionaryEntry(
                entryType: UserDataSyncDictionaryEntryType(entry.type),
                original: entry.original,
                replacement: entry.type == .correction ? (entry.replacement ?? "") : nil,
                caseSensitive: entry.caseSensitive,
                isEnabled: entry.isEnabled,
                source: entry.source == .manual ? nil : entry.source,
                ctcMinSimilarity: entry.type == .term
                    ? entry.ctcMinSimilarity
                    : nil,
                createdAt: entry.createdAt,
                updatedAt: entry.effectiveUpdatedAt
            )
        }
    }

    func applyUserDataSyncMutations(_ mutations: [UserDataSyncMutation]) throws {
        guard let context = modelContext else {
            throw DictionaryServiceMutationError.unavailable
        }
        guard !mutations.isEmpty else { return }

        for mutation in mutations {
            switch mutation {
            case .upsertDictionary(let synced):
                upsertSyncedDictionaryEntry(synced, context: context)
            case .deleteDictionary(let itemID):
                deleteSyncedDictionaryEntry(itemID: itemID, context: context)
            case .upsertSnippet,
                 .deleteSnippet,
                 .upsertHistoryContent,
                 .upsertHistoryInbox,
                 .upsertHistoryAudio,
                 .deleteHistory:
                continue
            }
        }

        do {
            try context.save()
            loadEntries()
        } catch {
            logger.error("Failed to apply dictionary sync mutations: \(error.localizedDescription)")
            throw DictionaryServiceMutationError.saveFailed(error)
        }
    }

    private func upsertSyncedDictionaryEntry(_ synced: UserDataSyncDictionaryEntry, context: ModelContext) {
        let targetType = DictionaryEntryType(synced.entryType)
        let targetID = UserDataSyncIdentity.dictionaryItemID(entryType: synced.entryType, original: synced.original)
        let replacement = targetType == .correction ? (synced.replacement ?? "") : nil

        if let entry = entries.first(where: {
            $0.type == targetType &&
            UserDataSyncIdentity.dictionaryItemID(entryType: $0.type, original: $0.original) == targetID
        }) {
            entry.original = synced.original
            entry.replacement = replacement
            entry.caseSensitive = synced.caseSensitive
            entry.isEnabled = synced.isEnabled
            entry.source = synced.source ?? .manual
            if targetType == .correction {
                entry.ctcMinSimilarity = nil
            } else if synced.ctcMinSimilarityFieldPresent {
                entry.ctcMinSimilarity = synced.ctcMinSimilarity
            }
            entry.updatedAt = synced.updatedAt
            return
        }

        context.insert(DictionaryEntry(
            type: targetType,
            original: synced.original,
            replacement: replacement,
            caseSensitive: synced.caseSensitive,
            isEnabled: synced.isEnabled,
            ctcMinSimilarity: targetType == .term
                ? synced.ctcMinSimilarity
                : nil,
            source: synced.source ?? .manual,
            createdAt: synced.createdAt,
            updatedAt: synced.updatedAt
        ))
    }

    private func deleteSyncedDictionaryEntry(itemID: String, context: ModelContext) {
        guard let entry = entries.first(where: {
            UserDataSyncIdentity.dictionaryItemID(entryType: $0.type, original: $0.original) == itemID
        }) else {
            return
        }
        context.delete(entry)
    }

    private static func normalizedCtcMinSimilarity(_ value: Float?) -> Float? {
        guard let value, value.isFinite else { return nil }
        return Swift.min(Swift.max(value, 0), 1)
    }

}

private extension Character {
    var isKatakana: Bool {
        unicodeScalars.allSatisfy { scalar in
            (0x30A0...0x30FF).contains(Int(scalar.value)) ||
            (0x31F0...0x31FF).contains(Int(scalar.value)) ||
            (0xFF66...0xFF9D).contains(Int(scalar.value))
        }
    }

    var isLatinOrNumber: Bool {
        unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.value < 0x3000 }
    }

    var isWordLike: Bool {
        unicodeScalars.contains { scalar in
            CharacterSet.alphanumerics.contains(scalar) ||
            (0x3040...0x30FF).contains(Int(scalar.value)) ||
            (0x3400...0x9FFF).contains(Int(scalar.value)) ||
            (0xF900...0xFAFF).contains(Int(scalar.value)) ||
            (0x20000...0x323AF).contains(Int(scalar.value)) ||
            (0xFF66...0xFF9D).contains(Int(scalar.value))
        }
    }

    var keepsFollowingWordSeparatedAfterDeletion: Bool {
        switch self {
        case ",", ".", "!", "?", ";", ":":
            return true
        default:
            return false
        }
    }

    var isJapaneseParticleBoundary: Bool {
        guard unicodeScalars.count == 1, let scalar = unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x3067, // で
             0x306B, // に
             0x306E, // の
             0x306F, // は
             0x3092, // を
             0x304C, // が
             0x3082, // も
             0x3068, // と
             0x3078, // へ
             0x3088: // よ
            return true
        default:
            return false
        }
    }
}

private extension String {
    var startsWithJapaneseParticleBoundary: Bool {
        [
            "から",
            "まで",
            "より",
            "には",
            "では",
            "にも",
            "でも",
            "とは",
            "との",
            "へは",
            "への",
            "だけ",
            "など",
        ].contains { hasPrefix($0) }
    }

    var containsWordLikeCharacter: Bool {
        contains { $0.isWordLike }
    }

    var isAllKatakana: Bool {
        !isEmpty && allSatisfy { character in
            character.isKatakana || character.unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) }
        }
    }

    var isAllLatinOrNumber: Bool {
        !isEmpty && allSatisfy { character in
            character.isLatinOrNumber || character.unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) }
        }
    }
}
