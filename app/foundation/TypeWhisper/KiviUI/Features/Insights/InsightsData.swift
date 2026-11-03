import Foundation
import Combine

/// Value-only aggregates. Neither transcripts nor recordings leave History's private context.
struct KiviInsightApp: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var count = 0
    var words = 0
}
struct KiviInsightDay: Identifiable, Equatable, Sendable {
    var id: Date
    var words = 0
    var count = 0
    var seconds = 0.0
    var timedCount = 0
    var timedWords = 0
    var timedCharacters = 0
    var apps: [String: KiviInsightApp] = [:]
}
enum KiviInsightPeriod: String, CaseIterable, Identifiable {
    case week, month, all = "all time"
    var id: String { rawValue }
    var days: Int? { switch self { case .week: 7; case .month: 30; case .all: nil } }
}
struct KiviInsightBucket: Identifiable, Equatable {
    var id: Date
    var end: Date
    var words: Int
    var count: Int
}
struct KiviInsightReport {
    var start: Date
    var end: Date
    var words = 0
    var count = 0
    var seconds = 0.0
    var timedCount = 0
    var timedWords = 0
    var timedCharacters = 0
    var activeDays = 0
    var previousWords = 0
    var previousCount = 0
    var apps: [KiviInsightApp] = []
    var buckets: [KiviInsightBucket] = []
    var availableDays: Int
    var averageWords: Int { count > 0 ? Int((Double(words) / Double(count)).rounded()) : 0 }

    // Illustrative reference sizes, not claims about a typical published page or book.
    static let wordsPerPage = 250
    static let wordsPerShortBook = 50_000
    var wordScaleDescription: String? {
        guard words > 0 else { return nil }
        if words >= Self.wordsPerShortBook {
            let books = words / Self.wordsPerShortBook
            return books == 1 ? "Enough words for a short book." : "Enough words for \(books.formatted()) short books."
        }
        guard words >= Self.wordsPerPage else { return "Less than a page of writing." }
        let pages = Int((Double(words) / Double(Self.wordsPerPage)).rounded())
        return "About \(pages.formatted()) \(pages == 1 ? "page" : "pages") of writing."
    }

    /// Recording time includes pauses. Only the words with matching valid timing qualify.
    var dictationWPM: Double? {
        guard timedWords > 0, seconds.isFinite, seconds > 0 else { return nil }
        let value = Double(timedWords) * 60 / seconds
        return value.isFinite ? value : nil
    }
    /// Typing studies use five-character units, not spoken whitespace-separated words.
    /// Aggregate before clamping so slow takes offset fast takes rather than disappearing.
    func estimatedSavedSeconds(typingWPM: Int) -> Double? {
        guard (1...300).contains(typingWPM), timedCharacters > 0,
              seconds.isFinite, seconds > 0 else { return nil }
        return max(0, Double(timedCharacters) / 5 * 60 / Double(typingWPM) - seconds)
    }

    static func make(days: [KiviInsightDay], period: KiviInsightPeriod, now: Date = Date(), calendar: Calendar = .current) -> Self {
        let today = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 1, to: today)!
        let first = days.filter { $0.id < end }.map(\.id).min() ?? today
        let start = period.days.map { calendar.date(byAdding: .day, value: -($0 - 1), to: today)! } ?? min(first, today)
        let dayCount = max(1, calendar.dateComponents([.day], from: start, to: end).day ?? 1)
        let previousStart = calendar.date(byAdding: .day, value: -dayCount, to: start)!
        var result = Self(start: start, end: end, availableDays: dayCount)
        var apps: [String: KiviInsightApp] = [:]
        let selected = days.filter { $0.id >= start && $0.id < end }
        for day in selected {
            result.words += day.words; result.count += day.count
            result.seconds += day.seconds; result.timedCount += day.timedCount
            result.timedWords += day.timedWords; result.timedCharacters += day.timedCharacters
            if day.count > 0 { result.activeDays += 1 }
            for app in day.apps.values {
                var combined = apps[app.id] ?? KiviInsightApp(id: app.id, name: app.name)
                combined.count += app.count; combined.words += app.words
                apps[app.id] = combined
            }
        }
        for day in days where day.id >= previousStart && day.id < start {
            result.previousWords += day.words; result.previousCount += day.count
        }
        result.apps = apps.values.sorted { $0.count == $1.count ? $0.id < $1.id : $0.count > $1.count }
        // At most 15 columns: week is daily, month is paired days; long histories stay legible.
        let stride = period == .week ? 1 : max(1, Int(ceil(Double(dayCount) / 15)))
        var cursor = start
        while cursor < end {
            let next = min(end, calendar.date(byAdding: .day, value: stride, to: cursor)!)
            let contents = selected.filter { $0.id >= cursor && $0.id < next }
            result.buckets.append(.init(id: cursor, end: next, words: contents.reduce(0) { $0 + $1.words }, count: contents.reduce(0) { $0 + $1.count }))
            cursor = next
        }
        return result
    }
}

/// Recording-only, in-memory overlay. Never writes synthetic activity to History.
/// A normal relaunch restores the actual aggregates without a data restore operation.
enum KiviInsightDemo {
    static let argument = "--kivi-demo-insights"

    static func applying(to days: [KiviInsightDay], now: Date = Date(), calendar: Calendar = .current) -> [KiviInsightDay] {
        let today = calendar.startOfDay(for: now)
        let cutoff = calendar.date(byAdding: .day, value: -6, to: today)!
        let references = days.filter { $0.id < cutoff && $0.words > 0 }
            .sorted { $0.id > $1.id }.prefix(3)
        guard !references.isEmpty else { return days }
        let samples = Array(references)
        let baseline = Double(samples.reduce(0) { $0 + $1.words }) / Double(samples.count)
        let spread = max(600, Int(baseline * 1.55) - 1301)
        var result = days
        for offset in 0..<7 {
            let date = calendar.date(byAdding: .day, value: -offset, to: today)!
            var sample = samples[offset % samples.count]
            // Date-seeded variation stays stable across refreshes without cycling the reference days.
            var seed = UInt64(calendar.ordinality(of: .day, in: .era, for: date) ?? 0)
            seed &+= 0x9E3779B97F4A7C15
            seed = (seed ^ (seed >> 30)) &* 0xBF58476D1CE4E5B9
            seed = (seed ^ (seed >> 27)) &* 0x94D049BB133111EB
            seed ^= seed >> 31
            let targetWords = 1301 + Int(seed % UInt64(spread))
            let factor = Double(targetWords) / Double(sample.words)
            sample.id = date
            sample.words = targetWords
            sample.count = max(1, Int((Double(sample.count) * factor).rounded()))
            sample.seconds *= factor
            sample.timedCount = Int((Double(sample.timedCount) * factor).rounded())
            sample.timedWords = Int((Double(sample.timedWords) * factor).rounded())
            sample.timedCharacters = Int((Double(sample.timedCharacters) * factor).rounded())
            sample.apps = sample.apps.mapValues { app in
                var value = app
                value.words = Int((Double(app.words) * factor).rounded())
                value.count = Int((Double(app.count) * factor).rounded())
                return value
            }
            if let index = result.firstIndex(where: { calendar.isDate($0.id, inSameDayAs: date) }) {
                if result[index].words < sample.words { result[index] = sample }
            } else {
                result.append(sample)
            }
        }
        return result.sorted { $0.id < $1.id }
    }
}

@MainActor final class KiviInsightsStore: ObservableObject {
    @Published private(set) var days: [KiviInsightDay] = []
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published private(set) var revision = 0
    private let history: HistoryService
    private var subscriptions = Set<AnyCancellable>()
    private var task: Task<Void, Never>?
    private var visible = false
    private var dirty = true
    private var generation = 0

    init(history: HistoryService) {
        self.history = history
        history.$recentRecords.dropFirst().debounce(for: .milliseconds(120), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.invalidate() }.store(in: &subscriptions)
        for name in [NSNotification.Name.NSCalendarDayChanged, NSNotification.Name.NSSystemTimeZoneDidChange, NSNotification.Name.NSSystemClockDidChange] {
            NotificationCenter.default.publisher(for: name).receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.invalidate() }.store(in: &subscriptions)
        }
    }
    func activate() { visible = true; if dirty { reload() } }
    func deactivate() { visible = false; task?.cancel(); generation += 1; if loading { dirty = true }; loading = false }
    private func invalidate() { dirty = true; if visible { reload() } }
    func reload() {
        task?.cancel(); generation += 1
        let version = generation
        loading = true; error = nil
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let value = try await history.kiviInsightDays()
                guard !Task.isCancelled, generation == version else { return }
                days = ProcessInfo.processInfo.arguments.contains(KiviInsightDemo.argument)
                    ? KiviInsightDemo.applying(to: value) : value
                loading = false; dirty = false; revision += 1
            } catch {
                guard !Task.isCancelled, generation == version else { return }
                self.error = "Your saved activity couldn’t be read. Try again in a moment."
                loading = false
            }
        }
    }
}
