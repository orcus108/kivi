import SwiftUI

struct InsightsPage: View {
    // Paused for now; keep the presentation available for a later design decision.
    private let showsWritingComparison = false
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @EnvironmentObject private var model: AppModel
    @StateObject private var store: KiviInsightsStore
    @State private var report = KiviInsightReport.make(days: [], period: .all)
    @State private var activityReport = KiviInsightReport.make(days: [], period: .week)
    @FocusState private var keyboardBucket: Date?
    @FocusState private var shareFocused: Bool
    @State private var shareKeyboardInteraction = false
    @State private var hoveredBucket: Date?
    @State private var shareSnapshot: KiviInsightsShareSnapshot?
    @State private var showAllApps = false
    @State private var entranceProgress = 0.0
    @State private var entranceStarted = false
    private var reduceMotion: Bool { systemReduceMotion || model.saved.reduceMotion }
    private var progress: Double { reduceMotion ? 1 : entranceProgress }
    @AppStorage("kiviInsightsTypingWPM") private var storedTypingWPM = 52
    private var typingWPM: Int { (1...300).contains(storedTypingWPM) ? storedTypingWPM : 52 }

    init(history: HistoryService) { _store = StateObject(wrappedValue: KiviInsightsStore(history: history)) }

    var body: some View {
        ScrollView {
            PageContent {
                VStack(alignment: .leading, spacing: 28) {
                    HStack {
                        PageTitle(title: "insights")
                        Spacer()
                        Button { openSharePreview() } label: {
                            Label("share", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(KiviButton())
                        .focusable().focusEffectDisabled()
                        .focused($shareFocused)
                        .onKeyPress(.space, phases: .up) { _ in
                            guard shareFocused else { return .ignored }
                            openSharePreview(keyboard: true)
                            return .handled
                        }
                        .onKeyPress(.tab, phases: .up) { _ in
                            shareKeyboardInteraction = true
                            return .ignored
                        }
                        .overlay {
                            if shareFocused && shareKeyboardInteraction {
                                RoundedRectangle(cornerRadius: 8).stroke(KiviTheme.green.opacity(0.65))
                                    .padding(-3).allowsHitTesting(false)
                            }
                        }
                        .disabled(store.loading || store.error != nil || report.words == 0)
                        .help(report.words == 0 ? "Dictate a few words to create your recap" : "Create a shareable image of your insights")
                    }
                    if let error = store.error {
                        status(title: "Couldn’t load insights", message: error)
                        Button("try again") { store.reload() }.buttonStyle(KiviButton(primary: true))
                    } else if store.loading && store.days.isEmpty {
                        Text("Loading insights…").font(KiviTheme.body(15)).foregroundStyle(KiviTheme.muted).padding(.vertical, 40)
                    } else {
                        totals
                        if report.count > 0 {
                            ViewThatFits(in: .horizontal) {
                                HStack(alignment: .top, spacing: 18) {
                                    activity.frame(minWidth: 330, maxWidth: .infinity)
                                    destinations.frame(minWidth: 280, maxWidth: .infinity)
                                }.fixedSize(horizontal: false, vertical: true)
                                VStack(spacing: 18) { activity; destinations }
                            }
                        } else {
                            emptyState
                        }
                    }
                }
            }
        }
        .sheet(item: $shareSnapshot, onDismiss: restoreShareFocus) { snapshot in KiviInsightsSharePreview(snapshot: snapshot) }
        .onAppear { refreshReport(); store.activate() }
        .onDisappear { hoveredBucket = nil; store.deactivate() }
        .task(id: store.revision > 0) {
            guard store.revision > 0 else { return }
            await animateEntrance()
        }
        .onChange(of: reduceMotion) {
            if reduceMotion { entranceProgress = 1 }
        }
        .onExitCommand { keyboardBucket = nil; hoveredBucket = nil }
        .onChange(of: store.revision) { refreshReport(); keyboardBucket = nil; hoveredBucket = nil }
    }

    private func openSharePreview(keyboard: Bool = false) {
        guard !store.loading, store.error == nil, report.words > 0 else { return }
        shareKeyboardInteraction = keyboard
        shareSnapshot = .init(report: report, typingWPM: typingWPM,
            isDemo: ProcessInfo.processInfo.arguments.contains(KiviInsightDemo.argument))
    }

    private func restoreShareFocus() {
        keyboardBucket = nil
        hoveredBucket = nil
        shareFocused = false
        guard shareKeyboardInteraction else { return }
        Task { @MainActor in
            await Task.yield()
            guard shareSnapshot == nil else { return }
            shareFocused = true
        }
    }

    @MainActor private func animateEntrance() async {
        guard !entranceStarted else { return }
        entranceStarted = true
        guard !reduceMotion else { entranceProgress = 1; return }
        let start = ProcessInfo.processInfo.systemUptime
        while !Task.isCancelled {
            if reduceMotion { entranceProgress = 1; return }
            let elapsed = min(1, (ProcessInfo.processInfo.systemUptime - start) / 0.75)
            // A single eased clock keeps numbers and charts in step, with exact endpoints.
            entranceProgress = elapsed >= 1 ? 1 : 1 - pow(1 - elapsed, 3)
            if elapsed >= 1 { return }
            do { try await Task.sleep(for: .milliseconds(16)) }
            catch { return }
        }
    }

    private func counted(_ value: Int) -> String { Int((Double(value) * progress).rounded(.down)).formatted() }

    private func refreshReport() {
        let now = Date()
        report = .make(days: store.days, period: .all, now: now)
        activityReport = .make(days: store.days, period: .week, now: now)
    }

    private var totals: some View {
        VStack(alignment: .leading, spacing: 26) {
            if KiviTheme.usesIllustratedSummaries {
                VStack(alignment: .leading, spacing: 16) {
                    KiviSummaryBanner(subject: "all-time", value: counted(report.words), caption: "words since you started",
                                      bannerAspectRatio: 3.8, artworkPlacement: .insights)
                    if showsWritingComparison, let comparison = conversationalWordScale {
                        Text(comparison).font(KiviTheme.serif(22)).foregroundStyle(KiviTheme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                            .opacity(progress >= 1 ? 1 : 0)
                            .accessibilityHidden(progress < 1)
                            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: progress >= 1)
                    }
                }
            } else {
            HStack(alignment: .center, spacing: 32) {
                metric(counted(report.words), "total words", finalValue: report.words.formatted(), prominent: true)
                if showsWritingComparison, let description = report.wordScaleDescription {
                    wordScale
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(description)
                        .opacity(progress >= 1 ? 1 : 0)
                        .accessibilityHidden(progress < 1)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: progress >= 1)
                }
            }
            }
            HStack(alignment: .top, spacing: 0) {
                metric(speed(at: progress), "dictation speed", finalValue: speed(at: 1))
                metricDivider
                metric(savedTime(at: progress), "of typing saved", finalValue: savedTime(at: 1))
                metricDivider
                metric(counted(report.activeDays), "active days", finalValue: report.activeDays.formatted())
            }
        }.padding(.top, 4).padding(.bottom, 4)
    }
    private var conversationalWordScale: String? {
        guard report.words > 0 else { return nil }
        let books = report.words / KiviInsightReport.wordsPerShortBook
        if books > 0 {
            return books == 1 ? "Oh, that’s enough words for a whole short book!" : "Oh, that’s enough words for \(books.formatted()) short books!"
        }
        guard report.words >= KiviInsightReport.wordsPerPage else { return "A little more, and you’ll have a whole page of writing." }
        let pages = Int((Double(report.words) / Double(KiviInsightReport.wordsPerPage)).rounded())
        return "Oh, that’s about \(pages.formatted()) \(pages == 1 ? "page" : "pages") of writing!"
    }
    private var wordScale: some View {
        let books = report.words / KiviInsightReport.wordsPerShortBook
        let pages = Int((Double(report.words) / Double(KiviInsightReport.wordsPerPage)).rounded())
        let lessThanPage = report.words < KiviInsightReport.wordsPerPage
        return VStack(alignment: .trailing, spacing: 5) {
            Text(books > 0 ? "Enough words for" : lessThanPage ? "Less than" : "That’s about")
                .font(KiviTheme.body(15)).foregroundStyle(KiviTheme.muted)
            Text(books > 0 ? "\(books.formatted()) \(books == 1 ? "short book" : "short books")" : lessThanPage ? "1 page" : "\(pages.formatted()) \(pages == 1 ? "page" : "pages")")
                .font(KiviTheme.medium(42)).foregroundStyle(KiviTheme.ink)
                .lineLimit(1).minimumScaleFactor(0.65)
            if books == 0 {
                Text("of writing!").font(KiviTheme.body(15)).foregroundStyle(KiviTheme.muted)
            }
        }.multilineTextAlignment(.trailing)
    }
    private var metricDivider: some View { Rectangle().fill(KiviTheme.line).frame(width: 1, height: 52).padding(.horizontal, 24) }
    private func speed(at progress: Double) -> String {
        report.dictationWPM.map { "\(($0 * progress).formatted(.number.precision(.fractionLength(0)))) WPM" } ?? "—"
    }
    private func savedTime(at progress: Double) -> String {
        guard let seconds = report.estimatedSavedSeconds(typingWPM: typingWPM) else { return "—" }
        if seconds == 0 { return "0 min" }
        if seconds < 60 { return "<1 min" }
        let shown = seconds * progress
        if seconds < 3600 { return "\(Int(shown / 60)) min" }
        return "\(Int(shown / 3600))h \(Int(shown.truncatingRemainder(dividingBy: 3600) / 60))m"
    }
    private func metric(_ value: String, _ label: String, finalValue: String, prominent: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(value).font(KiviTheme.medium(prominent ? 64 : 29)).monospacedDigit().foregroundStyle(prominent ? KiviTheme.green : KiviTheme.ink).lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(KiviTheme.body(15)).foregroundStyle(KiviTheme.muted)
        }.frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore).accessibilityLabel("\(label), \(finalValue)")
    }
    private var activity: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("last 7 days").font(KiviTheme.medium(17))
                Spacer()
            }
            Text(bucketCaption).font(KiviTheme.body(13)).foregroundStyle(KiviTheme.muted)
                .frame(height: 32, alignment: .topLeading)
            GeometryReader { geometry in
                HStack(alignment: .bottom, spacing: 6) {
                    ForEach(activityReport.buckets) { bucket in bucketColumn(bucket, height: geometry.size.height) }
                }
            }.frame(minHeight: 126)
                .onHover { inside in if !inside { hoveredBucket = nil } }
        }.frame(maxHeight: .infinity, alignment: .topLeading).padding(20).insightPanel()
    }
    private var focusedBucket: KiviInsightBucket? { activityReport.buckets.first { $0.id == hoveredBucket } }
    private var bucketCaption: String {
        guard let bucket = focusedBucket else { return "\(activityReport.words.formatted()) words" }
        return "\(dateRange(bucket.id, bucket.end)) · \(bucket.words.formatted()) words"
    }
    private func bucketColumn(_ bucket: KiviInsightBucket, height: CGFloat) -> some View {
        let peak = max(1, activityReport.buckets.map(\.words).max() ?? 1)
        let highlighted = hoveredBucket == bucket.id
        return VStack(spacing: 8) {
            Spacer(minLength: 0)
            RoundedRectangle(cornerRadius: 3)
                .fill(KiviTheme.green.opacity(highlighted ? 1 : 0.65))
                .frame(height: bucket.words > 0 ? max(4, (height - 32) * Double(bucket.words) / Double(peak)) * progress : 2)
            Text(bucket.id.formatted(.dateTime.weekday(.abbreviated)))
                .font(KiviTheme.body(11)).foregroundStyle(highlighted ? KiviTheme.ink : KiviTheme.muted)
                .lineLimit(1).minimumScaleFactor(0.8)
        }.frame(maxWidth: .infinity).frame(height: height).contentShape(Rectangle())
            .focusable()
            .focusEffectDisabled()
            .focused($keyboardBucket, equals: bucket.id)
            .overlay {
                if keyboardBucket == bucket.id {
                    RoundedRectangle(cornerRadius: 4).stroke(KiviTheme.green, lineWidth: 1)
                        .allowsHitTesting(false)
                }
            }
            .accessibilityElement(children: .ignore)
            .onHover { hovering in hoveredBucket = hovering ? bucket.id : (hoveredBucket == bucket.id ? nil : hoveredBucket) }
            .accessibilityLabel("\(dateRange(bucket.id, bucket.end)), \(bucket.words) words, \(bucket.count) dictations")
            .help("\(dateRange(bucket.id, bucket.end)): \(bucket.words.formatted()) words")
    }
    private var destinations: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("apps").font(KiviTheme.medium(17))
                Spacer()
                Text("% of dictations").font(KiviTheme.body(13)).foregroundStyle(KiviTheme.muted)
            }
            VStack(spacing: 0) {
                ForEach(showAllApps ? report.apps : Array(report.apps.prefix(3))) { app in
                    InsightAppRow(app: app, total: report.count, progress: progress) {
                        model.history.source = app.name; model.history.kind = "speech"; model.history.period = "all time"
                        model.history.search = ""; model.page = .record
                    }
                }
            }
            if report.apps.count > 3 {
                Button(showAllApps ? "show less" : "show more") { showAllApps.toggle() }
                    .buttonStyle(KiviButton()).accessibilityValue(showAllApps ? "expanded" : "collapsed")
            }
        }.frame(maxHeight: .infinity, alignment: .topLeading).padding(20).insightPanel()
    }
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("No saved dictations").font(KiviTheme.medium(17))
            Text("Dictations saved in History will appear here.")
                .font(KiviTheme.body(15)).foregroundStyle(KiviTheme.muted)
            Button("go to record") { model.page = .record }.buttonStyle(KiviButton())
        }.frame(maxWidth: .infinity, alignment: .leading).padding(24).insightPanel()
    }
    private func status(title: String, message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(KiviTheme.medium(17))
            Text(message).font(KiviTheme.body(15)).foregroundStyle(KiviTheme.muted)
        }.padding(.vertical, 40).frame(maxWidth: .infinity, alignment: .leading)
    }
    private func dateRange(_ start: Date, _ end: Date) -> String {
        let last = Calendar.current.date(byAdding: .day, value: -1, to: end) ?? start
        let format = Date.FormatStyle.dateTime.day().month(.abbreviated).year()
        if Calendar.current.isDate(start, inSameDayAs: last) { return start.formatted(format) }
        return "\(start.formatted(.dateTime.day().month(.abbreviated))) – \(last.formatted(format))"
    }
}

private struct InsightAppRow: View {
    let app: KiviInsightApp
    let total: Int
    let progress: Double
    var action: () -> Void
    @State private var hovering = false
    private var share: Double { total > 0 ? Double(app.count) / Double(total) : 0 }
    private var shareLabel: String { share > 0 && share < 0.01 ? "<1%" : share.formatted(.percent.precision(.fractionLength(0))) }
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                AppGlyph(name: app.name, size: 24)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(app.name).font(KiviTheme.medium(15)).lineLimit(1)
                        Spacer(minLength: 6)
                        Text(progress < 1 ? (share * progress).formatted(.percent.precision(.fractionLength(0))) : shareLabel).monospacedDigit().font(KiviTheme.body(13)).foregroundStyle(KiviTheme.muted)
                    }
                    GeometryReader { geometry in
                        Capsule().fill(KiviTheme.green.opacity(0.09))
                            .overlay(alignment: .leading) { Capsule().fill(KiviTheme.green.opacity(hovering ? 0.95 : 0.55)).frame(width: max(0, geometry.size.width * share * progress)) }
                    }.frame(height: 4)
                }
            }.padding(.vertical, 10).padding(.horizontal, 6)
                .background(hovering ? KiviTheme.green.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 6)).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(app.name == "Unknown app")
            .onHover { hovering = $0 }
            .help("\(app.count) dictations · \(app.words.formatted()) words. Open saved app history.")
            .accessibilityLabel("\(app.name), \(app.count) dictations, \(shareLabel). View app history")
    }
}
private extension View {
    func insightPanel() -> some View {
        background(KiviTheme.panel.opacity(0.65), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(KiviTheme.line))
    }
}
