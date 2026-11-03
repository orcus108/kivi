import Foundation

struct KiviTalkChangeRecord: Codable, Identifiable, Equatable {
    enum State: String, Codable { case applying, saved, undoing, undone, removed, notSaved, needsReview }
    let id: UUID
    let date: Date
    let apps: [String]
    let instructions: String
    let before: Data?
    let after: Data
    var state: State
    var undoneAt: Date?
    var undoSource: Data?
    var undoTarget: Data?
    var removing: Bool?
}

enum KiviTalkHistoryError: LocalizedError {
    case unreadable, saveFailed, unavailable
    var errorDescription: String? {
        switch self {
        case .unreadable: "Change history couldn’t be read. Existing records were kept; no new writing settings were saved."
        case .saveFailed: "The change couldn’t be recorded, so writing settings were left unchanged. Try again."
        case .unavailable: "This entry can’t be undone here. Your writing settings may have changed since it was saved."
        }
    }
}

/// Write intent before changing settings. Interrupted writes are reconciled against
/// exact snapshots, never by guessing what a past conversation might have done.
@MainActor enum KiviTalkChangeHistory {
    static let key = "kiviForYouChangeHistory"
    private struct Archive: Codable {
        var version = 1
        var records: [KiviTalkChangeRecord] = []
    }

    private static func read(_ defaults: UserDefaults) throws -> [KiviTalkChangeRecord] {
        guard let data = defaults.data(forKey: key) else { return [] }
        guard let archive = try? JSONDecoder().decode(Archive.self, from: data), archive.version == 1,
              Set(archive.records.map(\.id)).count == archive.records.count else { throw KiviTalkHistoryError.unreadable }
        return archive.records
    }

    private static func write(_ records: [KiviTalkChangeRecord], defaults: UserDefaults) throws {
        let data = try JSONEncoder().encode(Archive(records: records))
        defaults.set(data, forKey: key)
        guard defaults.data(forKey: key) == data else { throw KiviTalkHistoryError.saveFailed }
    }

    static func load(defaults: UserDefaults = .standard) throws -> [KiviTalkChangeRecord] {
        let original = try read(defaults)
        var records = original
        let current = defaults.data(forKey: KiviStyleRouter.key)
        for index in records.indices {
            switch records[index].state {
            case .applying:
                records[index].state = current == records[index].after ? .saved : current == records[index].before ? .notSaved : .needsReview
            case .undoing:
                if current == (records[index].undoSource != nil ? records[index].undoTarget : records[index].before) { records[index].state = records[index].removing == true ? .removed : .undone }
                else if current == (records[index].undoSource ?? records[index].after) { records[index].state = .saved; records[index].undoneAt = nil }
                else { records[index].state = .needsReview }
            default: break
            }
        }
        // An intent record is already present even if its final status can't yet be written.
        if records != original { try? write(records, defaults: defaults) }
        return records
    }

    static func prepare(_ proposal: KiviTalkProposal, after: Data, defaults: UserDefaults) throws -> UUID {
        var records = try load(defaults: defaults)
        let record = KiviTalkChangeRecord(id: UUID(), date: Date(), apps: proposal.apps, instructions: proposal.instructions,
                                         before: proposal.before, after: after, state: .applying)
        records.insert(record, at: 0)
        try write(records, defaults: defaults)
        return record.id
    }

    static func finish(_ id: UUID, state: KiviTalkChangeRecord.State, defaults: UserDefaults) {
        guard var records = try? read(defaults), let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].state = state
        try? write(records, defaults: defaults)
    }

    /// Restore only app overrides and enablement; group configuration is never replaced.
    private static func restored(_ record: KiviTalkChangeRecord, current: Data?) throws -> Data? {
        let decoder = JSONDecoder()
        let before = try record.before.map { try decoder.decode(KiviStyleConfiguration.self, from: $0) } ?? .init()
        let after = try decoder.decode(KiviStyleConfiguration.self, from: record.after)
        var result = try current.map { try decoder.decode(KiviStyleConfiguration.self, from: $0) } ?? .init()
        guard before.styles == after.styles else { throw KiviTalkHistoryError.unavailable }
        for app in record.apps {
            let key = "app:" + app
            guard result.overrides[app] == after.overrides[app],
                  result.enabled.contains(key) == after.enabled.contains(key),
                  result.group(for: app) == after.group(for: app),
                  result.group(for: app).map({ result.enabled.contains($0.id) }) == after.group(for: app).map({ after.enabled.contains($0.id) }) else { throw KiviTalkHistoryError.unavailable }
            result.overrides[app] = before.overrides[app]
            if before.enabled.contains(key) { result.enabled.insert(key) } else { result.enabled.remove(key) }
        }
        if result == before { return record.before }
        return try JSONEncoder().encode(result)
    }

    /// Remove this entry's additive instruction, preserving later instructions and manual edits.
    /// Tone is rebuilt from surviving recorded tone choices, only if it is still history-owned.
    private static func removing(_ id: UUID, records: [KiviTalkChangeRecord], current: Data?) throws -> Data? {
        guard let index = records.firstIndex(where: { $0.id == id }), records[index].state == .saved else { throw KiviTalkHistoryError.unavailable }
        let record = records[index]
        let decode: (Data?) throws -> KiviStyleConfiguration = { data in
            try data.map { try JSONDecoder().decode(KiviStyleConfiguration.self, from: $0) } ?? .init()
        }
        let before = try decode(record.before)
        let after = try decode(record.after)
        var result = try decode(current)
        guard before.styles == after.styles else { throw KiviTalkHistoryError.unavailable }
        for app in record.apps {
            guard let saved = after.overrides[app] else { throw KiviTalkHistoryError.unreadable }
            let priorRules = before.overrides[app]?.rules ?? ""
            var added: String
            var replacementRules = ""
            if priorRules.isEmpty { added = saved.rules }
            else if saved.rules.hasPrefix(priorRules + "\n") { added = String(saved.rules.dropFirst(priorRules.count + 1)) }
            else if saved.rules == priorRules { added = "" }
            else { added = saved.rules; replacementRules = priorRules } // Legacy records replaced rules rather than appending.
            let otherOwner = records.contains { $0.id != id && $0.state == .saved && $0.apps.contains(app) && $0.instructions == record.instructions }
            if otherOwner { added = ""; replacementRules = "" }
            else if added.isEmpty && records.contains(where: { $0.state == .removed && $0.apps.contains(app) && $0.instructions == record.instructions }) {
                added = "Latest preference (wins conflicts with older app instructions): " + record.instructions
            }
            guard var style = result.overrides[app] else { continue } // Already replaced manually.
            if added.isEmpty && !replacementRules.isEmpty {
                style.rules = [replacementRules, style.rules].filter { !$0.isEmpty }.joined(separator: "\n")
            }
            if !added.isEmpty {
                // Match complete stored instruction lines, not arbitrary substrings of user rules.
                var lines = style.rules.components(separatedBy: "\n")
                let target = added.components(separatedBy: "\n")
                if lines.count >= target.count, let start = (0...(lines.count - target.count)).first(where: {
                    Array(lines[$0..<($0 + target.count)]) == target
                }) {
                    lines.replaceSubrange(start..<(start + target.count), with: replacementRules.isEmpty ? [] : replacementRules.components(separatedBy: "\n"))
                }
                style.rules = lines.joined(separator: "\n")
            }
            let timeline = records.reversed().filter { $0.apps.contains(app) && ($0.state == .saved || $0.state == .removed || $0.state == .undone) }
            if let first = timeline.first {
                let base = try decode(first.before)
                var expected = base.overrides[app] ?? base.group(for: app) ?? saved
                if base.overrides[app] == nil { expected.usesGroupTone = true }
                var replacement = expected
                for entry in timeline where entry.state == .saved {
                    let old = try decode(entry.before)
                    let new = try decode(entry.after)
                    guard let value = new.overrides[app] else { throw KiviTalkHistoryError.unreadable }
                    let previous = old.overrides[app]
                    // Creating an override without a tone request inherits its group tone.
                    let toneChanged = previous.map { $0.mode != value.mode || $0.usesGroupTone != value.usesGroupTone } ?? (value.usesGroupTone != true)
                    if toneChanged {
                        expected.mode = value.mode; expected.usesGroupTone = value.usesGroupTone
                        if entry.id != id { replacement.mode = value.mode; replacement.usesGroupTone = value.usesGroupTone }
                    }
                }
                if style.mode == expected.mode && style.usesGroupTone == expected.usesGroupTone {
                    style.mode = replacement.mode; style.usesGroupTone = replacement.usesGroupTone
                }
                let survivors = timeline.filter { $0.state == .saved && $0.id != id }
                if survivors.isEmpty && style.rules == (base.overrides[app]?.rules ?? "") &&
                    style.mode == replacement.mode && style.usesGroupTone == replacement.usesGroupTone &&
                    result.group(for: app) == after.group(for: app) &&
                    result.enabled.contains("app:" + app) == after.enabled.contains("app:" + app) {
                    result.overrides[app] = base.overrides[app]
                    if base.enabled.contains("app:" + app) { result.enabled.insert("app:" + app) }
                    else { result.enabled.remove("app:" + app) }
                    continue
                }
            }
            result.overrides[app] = style
        }
        if result == (try decode(current)) { return current }
        if result == before { return record.before }
        return try JSONEncoder().encode(result)
    }

    static func canRemove(_ record: KiviTalkChangeRecord, defaults: UserDefaults = .standard) -> Bool {
        guard let records = try? load(defaults: defaults) else { return false }
        do { _ = try removing(record.id, records: records, current: defaults.data(forKey: KiviStyleRouter.key)); return true }
        catch { return false }
    }

    static func remove(_ id: UUID, defaults: UserDefaults = .standard) throws {
        var records = try load(defaults: defaults)
        guard let index = records.firstIndex(where: { $0.id == id }) else { throw KiviTalkHistoryError.unavailable }
        let source = defaults.data(forKey: KiviStyleRouter.key)
        let target = try removing(id, records: records, current: source)
        records[index].state = .undoing; records[index].removing = true
        records[index].undoSource = source; records[index].undoTarget = target
        records[index].undoneAt = Date()
        try write(records, defaults: defaults)
        guard defaults.data(forKey: KiviStyleRouter.key) == source else { throw KiviTalkError.changed }
        if let target { defaults.set(target, forKey: KiviStyleRouter.key) }
        else { defaults.removeObject(forKey: KiviStyleRouter.key) }
        guard defaults.data(forKey: KiviStyleRouter.key) == target else { throw CocoaError(.fileWriteUnknown) }
        finish(id, state: .removed, defaults: defaults)
    }

    static func canUndo(_ record: KiviTalkChangeRecord, defaults: UserDefaults = .standard) -> Bool {
        guard record.state == .saved else { return false }
        do { _ = try restored(record, current: defaults.data(forKey: KiviStyleRouter.key)); return true }
        catch { return false }
    }

    static func undo(_ id: UUID, defaults: UserDefaults = .standard) throws {
        var records = try load(defaults: defaults)
        guard let index = records.firstIndex(where: { $0.id == id }), records[index].state == .saved else { throw KiviTalkHistoryError.unavailable }
        let source = defaults.data(forKey: KiviStyleRouter.key)
        let target = try restored(records[index], current: source)
        records[index].state = .undoing
        records[index].removing = false
        records[index].undoneAt = Date()
        records[index].undoSource = source
        records[index].undoTarget = target
        try write(records, defaults: defaults)
        guard defaults.data(forKey: KiviStyleRouter.key) == source else {
            finish(id, state: .saved, defaults: defaults)
            throw KiviTalkError.changed
        }
        if let target { defaults.set(target, forKey: KiviStyleRouter.key) }
        else { defaults.removeObject(forKey: KiviStyleRouter.key) }
        guard defaults.data(forKey: KiviStyleRouter.key) == target else { throw CocoaError(.fileWriteUnknown) }
        finish(id, state: .undone, defaults: defaults)
    }
}
