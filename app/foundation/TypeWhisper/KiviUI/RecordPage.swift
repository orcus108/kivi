import SwiftUI

struct RecordPage: View {
    @EnvironmentObject var model: AppModel
    var body: some View { RecordContent(speech: model.speech, history: model.history).environmentObject(model) }
}
private struct RecordContent: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var greetingVisible = false
    @State private var greetingHighlightReveal: CGFloat = 0
    private var feed: KiviHistoryStore { history }
    let speech: SpeechCapture
    @ObservedObject var history: KiviHistoryStore
    init(speech: SpeechCapture, history: KiviHistoryStore) {
        self.speech = speech
        self.history = history
    }
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                PageContent {
                    VStack(alignment: .leading, spacing: 29) {
                        greeting.frame(height: KiviTheme.usesIllustratedSummaries ? 52 : 80, alignment: .center)
                            .opacity(greetingVisible ? 1 : 0)
                            .offset(y: greetingVisible || reduceMotion ? 0 : 6)
                            .task(id: model.greeting) {
                                var reset = Transaction()
                                reset.disablesAnimations = true
                                withTransaction(reset) { greetingHighlightReveal = 0 }
                                await Task.yield()
                                guard !Task.isCancelled else { return }
                                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) { greetingVisible = true }
                                guard !reduceMotion else {
                                    greetingHighlightReveal = 1
                                    return
                                }
                                do { try await Task.sleep(for: .milliseconds(280)) }
                                catch { return }
                                guard !Task.isCancelled else { return }
                                withAnimation(.easeInOut(duration: 0.42)) { greetingHighlightReveal = 1 }
                            }
                        if KiviTheme.usesIllustratedSummaries {
                            KiviSummaryBanner(subject: "words-today", value: history.summary.todayWords.formatted(),
                                              caption: "words today, in \(history.summary.todayCount) \(history.summary.todayCount == 1 ? "take" : "takes")",
                                              bannerAspectRatio: 3.8, artworkPlacement: .home)
                            recentTakes
                        } else {
                        HStack(alignment: .top, spacing: 48) {
                            VStack(alignment: .leading, spacing: 44) {
                                KiviWritingPad(speech: speech, writing: model.writing, history: history)
                                recentTakes
                            }.frame(maxWidth: .infinity, alignment: .topLeading)
                            if geometry.size.width > 850 {
                                BirdPanel(history: history).frame(width: 300, height: max(460, geometry.size.height - 212))
                            }
                        }
                        if geometry.size.width <= 850 { BirdPanel(history: history).frame(height: 280) }
                        }
                    }.padding(.top, 15)
                }
            }
        }
        .onAppear { feed.activate() }
        .onDisappear { feed.deactivate() }
    }
    private var greeting: some View {
        let text = model.currentGreeting
        return ZStack(alignment: .leading) {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(text.0)
            Text(text.1).padding(.horizontal, 2)
                .background { RoundedRectangle(cornerRadius: 2).fill(KiviTheme.green.opacity(0.12)).mask(KiviLeadingReveal(progress: greetingHighlightReveal)) }
                .overlay(alignment: .bottom) {
                    BrushUnderline().fill(KiviTheme.green).frame(height: 2)
                        .mask(KiviLeadingReveal(progress: greetingHighlightReveal)).offset(y: 3)
                }
            Text(text.2)
            IconButton(icon: "arrow.clockwise", label: "another greeting") { model.advanceGreeting() }.scaleEffect(0.7)
        }.font(KiviTheme.greeting(40)).tracking(-1.3).lineLimit(1)
            .id(model.greeting)
            .transition(reduceMotion ? .identity : .opacity)
        }.animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: model.greeting)
    }
    private var reduceMotion: Bool { model.saved.reduceMotion || systemReduceMotion }
    private var recentTakes: some View {
        VStack(alignment: .leading, spacing: 0) {
            KiviHistoryControls(history: feed)
            LazyVStack(alignment: .leading, spacing: 26) {
                if feed.sections.isEmpty && !feed.loading && feed.error == nil {
                    Text(feed.search.isEmpty && feed.source == nil && feed.period == "all time" && feed.kind == "all" ? "your saved takes will appear here." : "no takes match. try another search or clear the filters.")
                        .font(KiviTheme.body(14)).foregroundStyle(KiviTheme.muted).padding(.vertical, 24)
                }
                ForEach(feed.sections) { section in
                    LazyVStack(alignment: .leading, spacing: 8) {
                        Text(dayTitle(section.id)).font(KiviTheme.medium(13)).foregroundStyle(KiviTheme.muted)
                        ForEach(section.takes) { take in
                            HomeTakeRow(take: take, reduceMotion: reduceMotion)
                            Rectangle().fill(KiviTheme.line.opacity(0.7)).frame(height: 1)
                        }
                    }
                }
                if feed.loading {
                    Text("loading takes…").font(KiviTheme.body(13)).foregroundStyle(KiviTheme.muted)
                }
                if let error = feed.error {
                    HStack {
                        Text(error).font(KiviTheme.body(13)).foregroundStyle(KiviTheme.muted)
                        Button("try again") { feed.reload() }.buttonStyle(KiviButton())
                    }
                } else if feed.hasMore && !feed.loading {
                    Button("load older takes") { feed.loadMore() }.buttonStyle(KiviButton())
                        .onAppear { feed.loadMore() }
                }
            }.padding(.top, 22)

        }
    }
    private func dayTitle(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "today" }
        if Calendar.current.isDateInYesterday(date) { return "yesterday" }
        return date.formatted(.dateTime.day().month(.wide).year())
    }

 }
private struct HomeTakeRow: View {
    @EnvironmentObject var model: AppModel
    let take: Take
    let reduceMotion: Bool
    @State private var expanded = false
    @State private var hovered = false
    @State private var fullHeight: CGFloat = 0
    @State private var collapsedHeight: CGFloat = 0
    private var transcript: some View {
        Text(take.text).font(KiviTheme.body(16)).foregroundStyle(KiviTheme.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Button { model.selectedTake = take } label: {
                AppGlyph(name: take.source, size: 20).frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help(take.source)
            .accessibilityLabel("open take from \(take.source)")
            VStack(alignment: .leading, spacing: 10) {
                // The preview owns the collapsed layout; the full text keeps one
                // stable layout throughout the reveal. Animating lineLimit itself
                // can draw the full text outside the row's intermediate bounds.
                Button { model.copy(take.text) } label: {
                    transcript.lineLimit(3).fixedSize(horizontal: false, vertical: true)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { collapsedHeight = $0 }
                        .hidden().accessibilityHidden(true)
                        .frame(height: collapsedHeight > 0 ? (expanded ? max(fullHeight, collapsedHeight) : collapsedHeight) : nil, alignment: .top)
                        .overlay(alignment: .topLeading) {
                            transcript.lineLimit(nil).fixedSize(horizontal: false, vertical: true)
                                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fullHeight = $0 }
                                .allowsHitTesting(false)
                        }
                        .clipped()
                        // Bound hit testing to the visible preview, not the hidden
                        // full-text height. Selectable text remains in take details.
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(take.text)
                .accessibilityHint("copy take")
                if fullHeight > collapsedHeight + 1 {
                    Button(expanded ? "show less" : "show more") {
                        setExpanded(!expanded)
                    }.buttonStyle(.plain).font(KiviTheme.medium(12)).foregroundStyle(KiviTheme.green)
                        .accessibilityValue(expanded ? "expanded" : "collapsed")
                        .onExitCommand { setExpanded(false) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 12) {
                Text(take.date.formatted(date: .omitted, time: .shortened))
                    .font(KiviTheme.body(12)).foregroundStyle(KiviTheme.muted)
                    .monospacedDigit().fixedSize()
                    .onTapGesture { model.copy(take.text) }
                IconButton(icon: "square.on.square", label: "copy take") { model.copy(take.text) }
            }
            .frame(height: 24)
        }
        .padding(.horizontal, 12).padding(.vertical, 18)
        // Put the empty-space action behind the content, so child controls
        // consume their own clicks without also copying the take.
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(hovered ? KiviTheme.green.opacity(0.035) : .clear)
                .contentShape(Rectangle())
                .onTapGesture { model.copy(take.text) }
        }
        .onHover { hovered = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: Text("copy take")) { model.copy(take.text) }
    }
    private func setExpanded(_ value: Bool) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { expanded = value }
    }
}
private struct KiviLeadingReveal: Shape {
    var progress: CGFloat
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }
    func path(in rect: CGRect) -> Path {
        Path(CGRect(x: rect.minX, y: rect.minY, width: rect.width * progress, height: rect.height))
    }
}
private struct KiviWritingPad: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var speech: SpeechCapture
    @ObservedObject var writing: KiviDraftStore
    @ObservedObject var history: KiviHistoryStore
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            writingPad
            if let error = speech.error { Text(error).font(KiviTheme.body(12)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
        }
    }
    private var writingPad: some View {
        VStack(spacing: 0) {
            if speech.isRecording {
                VStack(alignment: .leading, spacing: 15) {
                    HStack { Circle().fill(KiviTheme.green).frame(width: 6, height: 6); Text("listening on your Mac").font(KiviTheme.mono(11)).foregroundStyle(KiviTheme.green); Spacer(); Button("cancel") { model.cancelRecording() }.buttonStyle(.plain).foregroundStyle(KiviTheme.muted) }
                    Text(speech.transcript.isEmpty ? "go on. we're listening." : speech.transcript).font(KiviTheme.body(20)).frame(maxWidth: .infinity, minHeight: 73, alignment: .topLeading)
                }.padding(20).frame(height: 146)
            } else {
                KiviTextEditor(text: $writing.text, fontSize: 20).lineSpacing(10).padding(.horizontal, 20).padding(.vertical, 18).frame(height: 146).accessibilityLabel("Writing area")
            }
            Rectangle().fill(KiviTheme.line).frame(height: 1)
            HStack(spacing: 6) {
                if speech.isRecording { KiviLiveMeter(meter: speech.meter, reduceMotion: model.saved.reduceMotion).frame(width: 80, height: 20) }
                else if let take = history.recent.first {
                    AppGlyph(name: take.source, size: 16)
                    Text(take.source.lowercased()).font(KiviTheme.body(13))
                    Text("·").foregroundStyle(KiviTheme.muted)
                    Text(take.date, format: .dateTime.hour().minute()).font(KiviTheme.body(13)).foregroundStyle(KiviTheme.muted)
                }
                Spacer(minLength: 8)
                Button { model.toggleRecording() } label: {
                    HStack(spacing: 5) {
                        if speech.isRecording { Image(systemName: "stop.fill").font(.system(size: 9)); Text("finish take") }
                        else if speech.isBusy { Text("finishing take…") }
                        else {
                            Text("press")
                            Text(model.services.dictationViewModel.hybridHotkeyLabel.isEmpty ? "set shortcut" : model.services.dictationViewModel.hybridHotkeyLabel).font(KiviTheme.body(11)).padding(.horizontal, 5).padding(.vertical, 2).background(KiviTheme.line, in: RoundedRectangle(cornerRadius: 4))
                            Text("anywhere to talk")
                        }
                    }.font(KiviTheme.body(12)).foregroundStyle(speech.isRecording ? KiviTheme.green : KiviTheme.muted)
                }.buttonStyle(.plain).help("Click to record, or use your configured dictation shortcut.").accessibilityLabel(speech.isRecording ? "stop recording" : "start recording")
            }.padding(.horizontal, 16).frame(height: 45)
            if let message = speech.feedbackMessage {
                Rectangle().fill(KiviTheme.line).frame(height: 1)
                if model.services.dictationViewModel.isInsertionRecoveryFeedback {
                    KiviInsertionRecoveryNotice(shortcut: model.services.dictationViewModel.insertionRecoveryShortcut,
                                                copy: { model.services.dictationViewModel.performActionFeedbackAction() })
                        .padding(18).onHover { model.services.dictationViewModel.setActionFeedbackHovered($0) }
                } else if speech.isNoSpeechFeedback {
                    KiviNoSpeechNotice(state: model.services.dictationViewModel.noSpeechRetryState,
                                      retry: { model.services.dictationViewModel.retryNoSpeechRecording() })
                        .padding(18).onHover { model.services.dictationViewModel.setActionFeedbackHovered($0) }
                } else {
                    HStack(alignment: .top, spacing: 12) {
                    Image(systemName: model.services.dictationViewModel.actionFeedbackIcon ?? "info.circle").foregroundStyle(KiviTheme.green)
                    Text(message).font(KiviTheme.body(14)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    if let title = speech.feedbackActionTitle {
                        Button(title) { model.services.dictationViewModel.performActionFeedbackAction() }.buttonStyle(KiviButton())
                    }
                }.padding(16).onHover { model.services.dictationViewModel.setActionFeedbackHovered($0) }
                }
            }
        }.background(KiviTheme.panel, in: RoundedRectangle(cornerRadius: 9)).overlay(RoundedRectangle(cornerRadius: 9).stroke(KiviTheme.line))
        .contextMenu {
            Button("hey kivi…") { model.openEditor() }
            Button("clean up & save") { model.processDraft() }.disabled(model.draft.isEmpty)
            Button("copy") { model.copy(model.draft) }.disabled(model.draft.isEmpty)
            Toggle("literal text", isOn: $model.saved.literal).onChange(of: model.saved.literal) { model.persist() }
            Button("clear writing pad") { model.draft = "" }
            Button("try a sample") { model.draft = "Um, quick update: the design is ready. Please send the review by Thursday." }
        }
    }
}
private struct KiviLiveMeter: View {
    @ObservedObject var meter: KiviAudioMeter
    var reduceMotion: Bool
    var body: some View { Waveform(level: meter.level, reduceMotion: reduceMotion) }
}

struct BirdPanel: View {
    @ObservedObject var history: KiviHistoryStore
    @Environment(\.colorScheme) private var colorScheme
    private var artworkName: String {
        let hour = Calendar.current.component(.hour, from: Date())
        if colorScheme == .light { return hour < 10 ? "bird-panel-L1-dawn-terraces" : "bird-panel-L4-golden-hour-savanna" }
        return hour >= 18 || hour < 5 ? "bird-panel-D6-night-hanami" : "bird-panel-D4-golden-hour-savanna"
    }
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                if let artwork = KiviTheme.image(artworkName) {
                    Image(nsImage: artwork).resizable().interpolation(.none).scaledToFill().frame(width: geometry.size.width, height: geometry.size.height).clipped()
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text("\(history.summary.todayWords)").font(KiviTheme.mono(22)).foregroundStyle(KiviTheme.ink.opacity(0.75))
                    Text("words took flight today").font(KiviTheme.medium(14)).foregroundStyle(KiviTheme.ink.opacity(0.84))
                }.padding(18)
            }.clipShape(RoundedRectangle(cornerRadius: 9)).overlay(RoundedRectangle(cornerRadius: 9).stroke(KiviTheme.line))
        }
    }
}
struct Waveform: View {
    var level: Double
    var reduceMotion = false
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.10, paused: reduceMotion || systemReduceMotion)) { timeline in
            HStack(spacing: 3) {
                ForEach(0..<16, id: \.self) { i in
                    let phase = timeline.date.timeIntervalSinceReferenceDate * 6 + Double(i) * 0.8
                    Capsule().fill(KiviTheme.green).frame(width: 3, height: max(3, CGFloat((sin(phase) * 0.5 + 0.5) * max(0.12, level) * 22)))
                }
            }.frame(height: 24)
        }
    }
}

/// A stable pair for one elapsed hour; navigation and the refresh button share it.
struct KiviGreetingCycle {
    private var pair: [(String, String, String)]
    private var position = 0
    private var startedAt: Date
    var current: (String, String, String) { pair[position] }

    init(now: Date = Date(), calendar: Calendar = .current) {
        startedAt = now
        let hour = calendar.component(.hour, from: now)
        let timeGreeting = hour >= 22 || hour < 5
            ? ("still up? he's", "listening.", "")
            : ("midday.", "words", "flowing?")
        let pool = [
            timeGreeting,
            ("a little", "less typing.", "more you."),
            ("your next", "good idea", "starts here."),
            ("a thought worth keeping.", "say it.", ""),
            ("less time", "typing.", "more time doing."),
            ("a little room to", "think out loud.", ""),
            ("start anywhere.", "say what’s", "on your mind.")
        ]
        let first = Int(floor(now.timeIntervalSince1970 / 3600)).quotientAndRemainder(dividingBy: pool.count).remainder
        let index = (first + pool.count) % pool.count
        pair = [pool[index], pool[(index + 1) % pool.count]]
    }

    mutating func advance(now: Date = Date(), calendar: Calendar = .current) {
        if now.timeIntervalSince(startedAt) >= 3600 || now < startedAt {
            self = KiviGreetingCycle(now: now, calendar: calendar)
        } else {
            position = 1 - position
        }
    }
}
