import SwiftUI

struct RecordPage: View {
    @EnvironmentObject var model: AppModel
    var body: some View { RecordContent(speech: model.speech, history: model.history).environmentObject(model) }
}
private struct RecordContent: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var greetingVisible = false
    let speech: SpeechCapture
    @ObservedObject var history: KiviHistoryStore
    private var greetings: [(String, String, String)] {
        let hour = Calendar.current.component(.hour, from: Date())
        let first = hour >= 22 || hour < 5 ? ("still up? he's", "listening.", "") : ("midday.", "words", "flowing?")
        return [first, ("a little", "less typing.", "more you."), ("your next", "good idea", "starts here.")]
    }
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                PageContent {
                    VStack(alignment: .leading, spacing: 29) {
                        greeting.frame(height: 80, alignment: .center)
                            .opacity(greetingVisible ? 1 : 0)
                            .offset(y: greetingVisible || reduceMotion ? 0 : 6)
                            .task {
                                await Task.yield()
                                guard !Task.isCancelled else { return }
                                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) { greetingVisible = true }
                            }
                        HStack(alignment: .top, spacing: 48) {
                            VStack(alignment: .leading, spacing: 44) {
                                KiviWritingPad(speech: speech, writing: model.writing, history: history)
                                recentTakes
                            }.frame(maxWidth: .infinity, alignment: .topLeading)
                            if geometry.size.width > 850 {
                                BirdPanel(history: history).frame(width: 300, height: max(460, geometry.size.height - 198))
                            }
                        }
                        if geometry.size.width <= 850 { BirdPanel(history: history).frame(height: 280) }
                    }.padding(.top, 15)
                }
            }
        }
    }
    private var greeting: some View {
        let text = greetings[model.greeting % greetings.count]
        return ZStack(alignment: .leading) {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(text.0)
            Text(text.1).padding(.horizontal, 2).background(KiviTheme.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 2))
                .overlay(alignment: .bottom) { BrushUnderline().fill(KiviTheme.green).frame(height: 2).offset(y: 3) }
            Text(text.2)
            IconButton(icon: "arrow.clockwise", label: "another greeting") { model.greeting = (model.greeting + 1) % greetings.count }.scaleEffect(0.7)
        }.font(KiviTheme.greeting(40)).tracking(-1.3).lineLimit(1)
            .id(model.greeting)
            .transition(reduceMotion ? .identity : .opacity)
        }.animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: model.greeting)
    }
    private var reduceMotion: Bool { model.saved.reduceMotion || systemReduceMotion }
    private var recentTakes: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("recent takes").font(KiviTheme.medium(13)).foregroundStyle(Color(red: 0.35, green: 0.45, blue: 0.49))
                Spacer()
                Button("all takes →") { model.page = .history }.buttonStyle(KiviButton())
            }
            Text(history.summary.caption).font(KiviTheme.body(12)).foregroundStyle(KiviTheme.muted).padding(.top, 5).padding(.bottom, 16)
            if history.recent.isEmpty {
                Text("nothing here yet — your next thought starts above.").font(KiviTheme.body(14)).foregroundStyle(KiviTheme.muted).padding(.vertical, 30)
            } else {
                ForEach(Array(history.recent.prefix(4))) { take in
                    HStack(spacing: 12) {
                        AppGlyph(name: take.source, size: 20)
                        Button { model.selectedTake = take } label: { Text(take.text.replacingOccurrences(of: "\n", with: " ")).font(KiviTheme.body(16)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.plain)
                        IconButton(icon: "square.on.square", label: "copy take") { model.copy(take.text) }
                    }.frame(height: 42)
                    Rectangle().fill(KiviTheme.line.opacity(0.7)).frame(height: 1)
                }
            }
        }
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
                if speech.isNoSpeechFeedback {
                    KiviNoSpeechNotice(hasRecovery: speech.feedbackActionTitle != nil,
                                      retry: { model.toggleRecording() },
                                      review: { model.services.dictationViewModel.recoverLastRecording() })
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
                    if let take = history.recent.first { Text("from \(take.source.lowercased())").font(KiviTheme.body(12)).foregroundStyle(KiviTheme.ink.opacity(0.55)).padding(.top, 2) }
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
