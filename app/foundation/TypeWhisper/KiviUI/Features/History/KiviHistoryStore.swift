import Foundation
import Combine

struct KiviHistorySummary: Sendable, Equatable {
    var todayWords = 0
    var todayCount = 0
    var topSource: String?
    var sources: [String] = []
    var caption: String { "\(todayCount) today" + (topSource.map { " · mostly \($0.lowercased())" } ?? "") }
}

struct KiviTakeSection: Identifiable, Equatable {
    let id: Date
    var takes: [Take]
    static func group(_ takes: [Take], calendar: Calendar = .current) -> [Self] {
        var sections: [Self] = []
        // Pages are sorted newest first, so grouping is a single pass.
        for take in takes {
            let day = calendar.startOfDay(for: take.date)
            if sections.last?.id == day { sections[sections.count - 1].takes.append(take) }
            else { sections.append(Self(id: day, takes: [take])) }
        }
        return sections
    }
}

@MainActor final class KiviHistoryStore: ObservableObject {
    @Published private(set) var recent: [Take] = []
    @Published private(set) var summary = KiviHistorySummary()
    @Published private(set) var sections: [KiviTakeSection] = []
    @Published private(set) var loading = false
    @Published private(set) var hasMore = false
    @Published private(set) var error: String?
    @Published var search = "" { didSet { if search != oldValue { reload(debounce: true) } } }
    @Published var source: String? { didSet { if source != oldValue { reload() } } }
    @Published var period = "all time" { didSet { if period != oldValue { reload() } } }
    @Published var kind = "all" { didSet { if kind != oldValue { reload() } } }
    private let service: HistoryService
    private var subscriptions = Set<AnyCancellable>()
    private var queryTask: Task<Void, Never>?
    private var summaryTask: Task<Void, Never>?
    private var generation = 0
    private var loaded: [Take] = []
    private var visible = false
    private var dirty = true
    private(set) var pageSize = 100

    init(service: HistoryService) {
        self.service = service
        refreshRecent()
        service.$recentRecords.dropFirst().debounce(for: .milliseconds(60), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.recordsChanged() }.store(in: &subscriptions)
        for name in [NSNotification.Name.NSCalendarDayChanged, NSNotification.Name.NSSystemTimeZoneDidChange, NSNotification.Name.NSSystemClockDidChange] {
            NotificationCenter.default.publisher(for: name).receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.recordsChanged() }.store(in: &subscriptions)
        }
        updateSummary()
    }
    func delete(_ take: Take) throws {
        try service.moveKiviTakeToTrash(id: take.id)
        loaded.removeAll { $0.id == take.id }
        sections = KiviTakeSection.group(loaded)
        recordsChanged()
    }

    func restore(_ take: Take) throws {
        try service.restoreKiviTake(id: take.id)
        recordsChanged()
    }

    func recentlyDeleted() throws -> [Take] { try service.recentlyDeletedKiviTakes() }

    func makeIndependentFeed() -> KiviHistoryStore { KiviHistoryStore(service: service) }
    func activate() { visible = true; if dirty { reload() } }
    func deactivate() { visible = false; queryTask?.cancel(); generation += 1; if loading { dirty = true }; loading = false }
    func recordsChanged() { refreshRecent(); updateSummary(); dirty = true; if visible { reload() } }
    private func refreshRecent() {
        let values = service.recentRecords.prefix(4).map(Take.init)
        if recent != values { recent = values }
    }
    private func updateSummary() {
        summaryTask?.cancel()
        summaryTask = Task { [weak self] in
            guard let self else { return }
            do {
                let value = try await service.kiviSummary()
                guard !Task.isCancelled else { return }
                if summary != value { summary = value }
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
    func query(now: Date = Date(), calendar: Calendar = .current) -> HistoryQuery {
        var query = HistoryQuery()
        query.kiviSearch = true; query.searchText = search; query.kiviAppName = source
        query.kiviIsSpeech = kind == "all" ? nil : kind == "speech"
        let component: Calendar.Component? = period == "today" ? .day : period == "this week" ? .weekOfYear : period == "this month" ? .month : nil
        if let component, let interval = calendar.dateInterval(of: component, for: now) {
            query.cutoffDate = interval.start; query.endDate = interval.end
        }
        return query
    }
    func reload(debounce: Bool = false) {
        dirty = true
        queryTask?.cancel(); generation += 1
        guard visible else { return }
        loading = true; error = nil
        let version = generation, query = query()
        queryTask = Task { [weak self] in
            guard let self else { return }
            if debounce { try? await Task.sleep(for: .milliseconds(120)) }
            guard !Task.isCancelled else { return }
            await fetch(query: query, offset: 0, version: version)
        }
    }
    func loadMore() {
        guard visible, hasMore, !loading, !dirty else { return }
        loading = true
        let version = generation, offset = loaded.count, query = query()
        queryTask = Task { [weak self] in await self?.fetch(query: query, offset: offset, version: version) }
    }
    private func fetch(query: HistoryQuery, offset: Int, version: Int) async {
        let page = await service.fetchPageInBackground(query: query, offset: offset, limit: pageSize)
        guard !Task.isCancelled, generation == version else { return }
        guard let page else {
            loading = false
            error = "couldn’t load your takes. try again."
            return
        }
        error = nil
        let values = page.records.map(Take.init)
        if offset == 0 { loaded = values } else { loaded.append(contentsOf: values) }
        sections = KiviTakeSection.group(loaded)
        hasMore = page.hasMore; loading = false; dirty = false
    }
}
