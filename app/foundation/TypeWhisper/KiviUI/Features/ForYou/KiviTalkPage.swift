import SwiftUI
import AppKit

struct KiviTalkPage: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @ObservedObject var conversation: KiviTalkConversation
    @State private var composerFocused = false
    @State private var composerCaretRequest: UUID?
    @State private var showSavedInstructions = false
    @State private var showHistory = false
    @State private var showChats = false
    @State private var deletingChat: UUID?
    @State private var composerHeight: CGFloat = 54
    @State private var followingLatest = true
    @State private var scrollRequest = UUID()

    private var reduceMotion: Bool { systemReduceMotion || model.saved.reduceMotion }
    private var previewRunning: Bool { conversation.busy && conversation.proposal != nil }

    private var isEmpty: Bool { conversation.messages.isEmpty }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button { showChats.toggle(); showHistory = false; composerFocused = !showChats } label: {
                        Image(systemName: showChats ? "xmark" : "bubble.left.and.bubble.right").frame(width: 32, height: 32)
                    }.buttonStyle(KiviTalkIconStyle()).help(showChats ? "back to conversation" : "chats")
                        .accessibilityLabel(showChats ? "close chats" : "chats")
                        .disabled(!conversation.canSwitchChat)
                    Button { showHistory.toggle(); showChats = false; composerFocused = !showHistory } label: {
                        Image(systemName: showHistory ? "xmark" : "clock.arrow.circlepath").frame(width: 32, height: 32)
                    }.buttonStyle(KiviTalkIconStyle()).help(showHistory ? "back to conversation" : "change history")
                        .accessibilityLabel(showHistory ? "close change history" : "change history")
                        .disabled(conversation.busy || conversation.listening || conversation.transcribing)
                    if (!isEmpty || showChats) && !showHistory {
                        Button { conversation.newConversation(); showChats = false; composerFocused = true } label: {
                            Image(systemName: "square.and.pencil").frame(width: 32, height: 32)
                        }.buttonStyle(KiviTalkIconStyle()).help("new conversation").accessibilityLabel("new conversation")
                            .disabled(conversation.busy || conversation.listening || conversation.transcribing)
                    }
                }.padding(.horizontal, 30).padding(.top, 22).padding(.bottom, 12)

                if showChats {
                    chatHistory
                } else if showHistory {
                    KiviTalkHistoryView(conversation: conversation)
                } else if isEmpty {
                    Spacer(minLength: 20)
                    VStack(spacing: 28) {
                        Text("what would you like to change?")
                            .font(KiviTheme.greeting(geometry.size.width < 780 ? 36 : 43)).tracking(-1)
                            .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                        composer
                        VStack(spacing: 10) {
                            suggestion("keep my wording in ChatGPT and Claude", request: "In the ChatGPT and Claude Mac apps, preserve my wording and casual tone. Only fix punctuation and remove clear false starts.")
                            suggestion("make my Slack messages less formal", request: "Make my Slack messages more casual. Keep my wording, numbers and commitments.")
                        }
                    }.frame(maxWidth: 690).padding(.horizontal, 36)
                    Spacer(minLength: 30)
                    feedback.frame(maxWidth: 690).padding(.horizontal, 36).padding(.bottom, 24)
                } else {
                    thread
                    composer.frame(maxWidth: 690).padding(.horizontal, 36).padding(.top, 12).padding(.bottom, 24)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(KiviTalkEscapeCapture(enabled: showChats || showHistory || conversation.busy || conversation.listening || conversation.transcribing) { handleEscape() })
        .onAppear { composerFocused = true }
        .onDisappear { conversation.cancelVoice() }
        .onExitCommand(perform: handleEscape)
        .onChange(of: conversation.messages.last?.id) {
            if let message = conversation.messages.last, message.role == "assistant" { announce(message.text) }
        }
        .onChange(of: conversation.error) { if let error = conversation.error { announce(error) } }
        .onChange(of: conversation.notice) { if let notice = conversation.notice { announce(notice) } }
        .onChange(of: conversation.busy) { if conversation.busy { announce(conversation.status) } }
    }

    private var chatHistory: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("chats").font(KiviTheme.greeting(34)).foregroundStyle(KiviTheme.ink)
                if let error = conversation.chatError {
                    Text(error).font(KiviTheme.body(14)).foregroundStyle(KiviTheme.muted)
                }
                if conversation.chats.isEmpty && conversation.chatError == nil {
                    Text("No chats yet").font(KiviTheme.body(15)).foregroundStyle(KiviTheme.muted)
                    Button("start a chat") { showChats = false; composerFocused = true }.buttonStyle(KiviTalkButton())
                }
                ForEach(conversation.chats.sorted { $0.updatedAt > $1.updatedAt }) { chat in
                    VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 12) {
                    Button {
                        conversation.openChat(chat.id); showChats = false; followingLatest = true
                        scrollRequest = UUID(); composerCaretRequest = UUID(); composerFocused = true
                    } label: {
                        HStack(alignment: .top, spacing: 14) {
                            VStack(alignment: .leading, spacing: 7) {
                                Text(chat.title).font(KiviTheme.body(15)).foregroundStyle(KiviTheme.ink)
                                    .lineLimit(2).multilineTextAlignment(.leading)
                                HStack(spacing: 8) {
                                    Text(chat.updatedAt, style: .date)
                                    if !chat.draft.isEmpty { Text("draft") }
                                }.font(KiviTheme.body(12)).foregroundStyle(KiviTheme.muted)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: chat.id == conversation.chatID ? "checkmark" : "chevron.right")
                                .font(.system(size: 12)).foregroundStyle(KiviTheme.muted)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 10).contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(!conversation.canSwitchChat)
                        .accessibilityAddTraits(chat.id == conversation.chatID ? .isSelected : [])
                    Button { deletingChat = chat.id } label: {
                        Image(systemName: "trash").frame(width: 30, height: 36)
                    }.buttonStyle(KiviTalkIconStyle()).accessibilityLabel("delete chat: " + chat.title)
                        .disabled(!conversation.canSwitchChat || conversation.chatError != nil)
                    }
                    if deletingChat == chat.id {
                        Text("Delete this chat? Saved preferences will stay.").font(KiviTheme.body(13)).foregroundStyle(KiviTheme.muted)
                        HStack(spacing: 18) {
                            Button("cancel") { deletingChat = nil }.buttonStyle(KiviTalkTextStyle())
                            Button("delete chat") { conversation.deleteChat(chat.id); deletingChat = nil }.buttonStyle(KiviTalkTextStyle(destructive: true))
                        }.disabled(!conversation.canSwitchChat)
                    }
                    }
                }
            }.frame(maxWidth: 690, alignment: .leading).padding(.horizontal, 36).padding(.vertical, 25).frame(maxWidth: .infinity)
        }
    }

    private var thread: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ZStack(alignment: .bottom) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 30) {
                            ForEach(conversation.messages) { message in messageView(message) }
                            if let proposal = conversation.proposal { proposalView(proposal, availableWidth: max(0, min(690, viewport.size.width - 72) - 17)) }
                            if conversation.proposal == nil, let preference = conversation.archivedPreference {
                                VStack(alignment: .leading, spacing: 12) {
                                    HStack(spacing: 8) {
                                        Text(preference.apps.joined(separator: " · ")).foregroundStyle(KiviTheme.ink)
                                        Text(conversation.archivedPreferenceState ?? "not saved").foregroundStyle(KiviTheme.muted)
                                    }.font(KiviTheme.body(12))
                                    Text(preference.instructions).font(KiviTheme.body(15)).foregroundStyle(KiviTheme.ink)
                                    if conversation.archivedPreferenceState == "not saved" {
                                        Button("review preference") { conversation.reviewArchivedPreference() }
                                            .buttonStyle(KiviTalkButton()).disabled(!conversation.canSwitchChat)
                                    }
                                }
                            }
                            if conversation.busy && !previewRunning {
                                HStack(spacing: 9) {
                                    ProgressView().controlSize(.small).tint(KiviTheme.ink)
                                    Text(conversation.status).font(KiviTheme.body(14)).foregroundStyle(KiviTheme.muted)
                                }.accessibilityLabel(conversation.status)
                            }
                            if conversation.undoReceipt != nil {
                                Button("view saved changes") { showHistory = true }
                                    .buttonStyle(KiviTalkTextStyle())
                                    .disabled(conversation.busy || conversation.listening || conversation.transcribing)
                            }
                            feedback
                            Color.clear.frame(height: 1).id("talk-bottom")
                                .background {
                                    GeometryReader { marker in
                                        Color.clear.preference(key: KiviTalkBottomKey.self, value: marker.frame(in: .named("kivi-talk-thread")).maxY)
                                    }
                                }
                        }.frame(maxWidth: 690, alignment: .leading).padding(.horizontal, 36).padding(.top, 25).padding(.bottom, 22)
                            .frame(maxWidth: .infinity)
                    }
                    .coordinateSpace(name: "kivi-talk-thread")
                    .accessibilityElement(children: .contain).accessibilityLabel("conversation")
                    .onPreferenceChange(KiviTalkBottomKey.self) { bottom in
                        followingLatest = bottom <= viewport.size.height + 80
                    }
                    .onAppear { proxy.scrollTo("talk-bottom", anchor: .bottom) }
                    .onChange(of: scrollRequest) { proxy.scrollTo("talk-bottom", anchor: .bottom) }
                    .onChange(of: conversation.messages.count) { if followingLatest { proxy.scrollTo("talk-bottom", anchor: .bottom) } }
                    .onChange(of: conversation.proposal?.id) { if followingLatest { proxy.scrollTo("talk-bottom", anchor: .bottom) } }
                    .onChange(of: conversation.previewedSample) { if followingLatest { proxy.scrollTo("talk-bottom", anchor: .bottom) } }
                    .onChange(of: conversation.error) { if followingLatest { proxy.scrollTo("talk-bottom", anchor: .bottom) } }
                    .onChange(of: conversation.notice) { if followingLatest { proxy.scrollTo("talk-bottom", anchor: .bottom) } }
                    if !followingLatest {
                        Button { followingLatest = true; proxy.scrollTo("talk-bottom", anchor: .bottom) } label: {
                            Label("latest message", systemImage: "arrow.down")
                        }.buttonStyle(KiviTalkButton()).padding(.bottom, 12)
                    }
                }
            }
        }
    }

    private func sendMessage() {
        guard conversation.canSend else { return }
        followingLatest = true; scrollRequest = UUID()
        conversation.send(); composerFocused = true
    }

    private func handleEscape() {
        if deletingChat != nil { deletingChat = nil }
        else if showChats { showChats = false; composerFocused = true }
        else if showHistory { showHistory = false; composerFocused = true }
        else if conversation.listening || conversation.transcribing { conversation.cancelVoice() }
        else if conversation.busy { conversation.stop() }
        else { composerFocused = false }
    }

    private func announce(_ text: String) {
        guard !text.isEmpty else { return }
        NSAccessibility.post(element: NSApp.mainWindow as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            KiviTalkComposer(text: $conversation.draft, focused: Binding(get: { composerFocused }, set: { composerFocused = $0 }), height: $composerHeight, caretToEndRequest: composerCaretRequest, onSend: sendMessage)
                .frame(height: composerHeight)
                .accessibilityLabel("message to Kivi")
                .disabled(conversation.listening || conversation.transcribing)
            HStack(spacing: 12) {
                if conversation.listening || conversation.transcribing {
                    Text(conversation.listening ? "listening…" : "transcribing locally…")
                        .font(KiviTheme.body(13)).foregroundStyle(KiviTheme.muted)
                    Button("cancel") { conversation.cancelVoice() }.buttonStyle(KiviTalkTextStyle())
                }
                Spacer(minLength: 0)
                if conversation.draft.count > 1800 {
                    Text("\(conversation.draft.count)/2000").font(KiviTheme.body(12))
                        .foregroundStyle(conversation.draft.count > 2000 ? Color.red : KiviTheme.muted)
                        .accessibilityLabel("\(conversation.draft.count) of 2000 characters")
                }
                if conversation.busy {
                    Button { conversation.stop() } label: { Image(systemName: "stop.fill").frame(width: 34, height: 34) }
                        .buttonStyle(KiviTalkIconStyle()).help("stop response").accessibilityLabel("stop response")
                } else {
                    Button { conversation.toggleVoice(model.services.dictationViewModel) } label: {
                        Image(systemName: conversation.listening ? "stop.fill" : "mic").font(.system(size: 17)).frame(width: 34, height: 34)
                    }.buttonStyle(KiviTalkIconStyle()).disabled(conversation.transcribing)
                        .help(conversation.listening ? "finish recording" : "dictate a message")
                        .accessibilityLabel(conversation.listening ? "finish recording" : "dictate a message")
                    Button(action: sendMessage) {
                        Image(systemName: "arrow.up").font(.system(size: 16, weight: .medium)).frame(width: 12, height: 20)
                    }.buttonStyle(KiviButton(primary: true)).keyboardShortcut(.return, modifiers: .command)
                        .disabled(!conversation.canSend)
                        .help("send message · Return").accessibilityLabel("send message")
                }
            }
        }.padding(14)
            .background(KiviTheme.panel, in: RoundedRectangle(cornerRadius: 19))
            .overlay(RoundedRectangle(cornerRadius: 19).stroke(KiviTheme.line))
    }

    @ViewBuilder private var feedback: some View {
        if conversation.error != nil || conversation.notice != nil || conversation.canRetry || conversation.chatError != nil {
            VStack(alignment: .leading, spacing: 9) {
                if let error = conversation.chatError { Text(error).font(KiviTheme.body(14)).foregroundStyle(KiviTheme.muted) }
                if let error = conversation.error {
                    Text(error).font(KiviTheme.body(14)).foregroundStyle(KiviTheme.ink)
                        .fixedSize(horizontal: false, vertical: true).accessibilityLabel("Error: " + error)
                }
                if let notice = conversation.notice {
                    Text(notice).font(KiviTheme.body(14)).foregroundStyle(KiviTheme.muted)
                }
                if conversation.canRetry {
                    HStack(spacing: 18) {
                        Button("try again") { followingLatest = true; conversation.retry(); composerFocused = true }
                            .buttonStyle(KiviTalkTextStyle())
                        if conversation.draft.isEmpty {
                            Button("edit request") {
                                conversation.draft = conversation.failedRequest?.text ?? ""
                                composerFocused = true
                            }.buttonStyle(KiviTalkTextStyle())
                        }
                    }
                }
            }.padding(.vertical, 8)
        }
    }

    private func suggestion(_ text: String, request: String) -> some View {
        Button { conversation.draft = request; composerCaretRequest = UUID(); composerFocused = true } label: {
            HStack(spacing: 9) { Text(text); Image(systemName: "arrow.up.left").font(.system(size: 11)) }
                .font(KiviTheme.body(14)).multilineTextAlignment(.center)
        }.buttonStyle(KiviTalkTextStyle(suggestion: true))
    }

    private func messageView(_ message: KiviTalkMessage) -> some View {
        HStack(alignment: .top) {
            if message.role == "user" { Spacer(minLength: 35) }
            Text(message.text).font(KiviTheme.body(16)).lineSpacing(5).textSelection(.enabled)
                    .padding(.horizontal, message.role == "user" ? 17 : 0)
                    .padding(.vertical, message.role == "user" ? 13 : 0)
                    .background(message.role == "user" ? KiviTheme.panel : .clear, in: RoundedRectangle(cornerRadius: 16))
                    .accessibilityLabel((message.role == "user" ? "You: " : "Kivi: ") + message.text)
            if message.role != "user" { Spacer(minLength: 0) }
        }
    }

    private func proposalView(_ proposal: KiviTalkProposal, availableWidth: CGFloat) -> some View {
        let wide = availableWidth >= 560
        let comparisonLayout = wide
            ? AnyLayout(HStackLayout(alignment: .top, spacing: 18))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: 16))
        return VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 8) {
                ForEach(proposal.apps, id: \.self) { app in
                    HStack(spacing: 6) { AppGlyph(name: app, size: 17); Text(app).font(KiviTheme.body(13)) }
                }
            }.accessibilityLabel("Applies only to " + proposal.apps.joined(separator: ", "))
            VStack(alignment: .leading, spacing: 8) {
                Text(proposal.instructions).font(KiviTheme.body(16)).lineSpacing(4).textSelection(.enabled)
                Button(showSavedInstructions ? "hide existing rules" : "see existing rules") { showSavedInstructions.toggle() }
                    .buttonStyle(KiviTalkTextStyle())
                if showSavedInstructions {
                    let before = proposal.before.flatMap { try? JSONDecoder().decode(KiviStyleConfiguration.self, from: $0) } ?? KiviStyleConfiguration()
                    ForEach(proposal.apps, id: \.self) { app in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(app).font(KiviTheme.medium(13))
                            Text(existingRules(app: app, config: before, rules: proposal.rules))
                                .font(KiviTheme.body(13)).foregroundStyle(KiviTheme.muted).textSelection(.enabled)
                        }
                    }
                }
            }
            Rectangle().fill(KiviTheme.line).frame(height: 1)
            comparisonLayout {
                previewBefore.frame(maxWidth: .infinity)
                previewArrow(vertical: !wide).frame(width: wide ? 24 : nil, height: wide ? 164 : 24)
                previewAfter(proposal).frame(maxWidth: .infinity)
            }.frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 17) {
                if conversation.canApply {
                    Button("save preference") { conversation.apply() }.buttonStyle(KiviTalkButton(primary: true))
                }
                Button("discard") { conversation.discardProposal() }.buttonStyle(KiviTalkTextStyle(destructive: true)).disabled(conversation.busy)
            }
        }.padding(.leading, 17).overlay(alignment: .leading) { Rectangle().fill(KiviTheme.line).frame(width: 2) }
    }

    private var previewBefore: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("before").font(KiviTheme.medium(13)).foregroundStyle(KiviTheme.muted)
            KiviTextEditor(text: $conversation.sample, prompt: "paste something you might dictate", fontSize: 15)
                .frame(height: 120).padding(9)
                .background(KiviTheme.panel, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(KiviTheme.line))
                .accessibilityLabel("before: example dictation")
                .disabled(conversation.busy)
        }
    }

    private func previewAfter(_ proposal: KiviTalkProposal) -> some View {
        let results = previewGroups(proposal)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Circle().fill(KiviTheme.green).frame(width: 6, height: 6).accessibilityHidden(true)
                Text("after").font(KiviTheme.medium(13)).foregroundStyle(KiviTheme.ink)
            }
            VStack(alignment: .leading, spacing: 14) {
                if results.isEmpty {
                    if previewRunning {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small).tint(KiviTheme.green)
                            Text("previewing…").font(KiviTheme.body(13)).foregroundStyle(KiviTheme.ink)
                        }.accessibilityLabel("Previewing your example")
                    } else {
                        Button("preview change") { conversation.preview() }
                            .buttonStyle(KiviButton(primary: true))
                            .disabled(conversation.busy || conversation.listening || conversation.transcribing || conversation.sample.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                ForEach(results, id: \.text) { result in
                    VStack(alignment: .leading, spacing: 6) {
                        if results.count > 1 {
                            Text(result.apps.joined(separator: " · ")).font(KiviTheme.medium(12)).foregroundStyle(KiviTheme.muted)
                        }
                        Text(result.text).font(KiviTheme.body(15)).lineSpacing(4).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }.transition(reduceMotion ? .identity : .opacity.combined(with: .offset(x: -10)))
                }
            }.padding(9).frame(maxWidth: .infinity, minHeight: 138, alignment: results.isEmpty ? .center : .topLeading)
                .background {
                    RoundedRectangle(cornerRadius: 9).fill(KiviTheme.panel)
                        .overlay(RoundedRectangle(cornerRadius: 9).fill(KiviTheme.green.opacity(0.07)))
                }
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(KiviTheme.green.opacity(0.3)))
                .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: results.isEmpty)
        }
    }

    private func previewArrow(vertical: Bool) -> some View {
        Image(systemName: vertical ? "arrow.down" : "arrow.right")
            .foregroundStyle(KiviTheme.green.opacity(previewRunning ? 1 : 0.5))
            .phaseAnimator(previewRunning && !reduceMotion ? [0.0, 1.0] : [0.0]) { arrow, phase in
                arrow.offset(x: vertical ? 0 : phase * 7, y: vertical ? phase * 7 : 0)
            } animation: { _ in .easeInOut(duration: 0.7) }
            .accessibilityHidden(true)
    }

    private struct PreviewResult {
        var apps: [String]
        let text: String
    }

    private func previewGroups(_ proposal: KiviTalkProposal) -> [PreviewResult] {
        guard conversation.previewedSample == conversation.sample else { return [] }
        var results: [PreviewResult] = []
        for app in proposal.apps {
            guard let text = conversation.previews[app] else { continue }
            if let index = results.firstIndex(where: { $0.text == text }) { results[index].apps.append(app) }
            else { results.append(.init(apps: [app], text: text)) }
        }
        return results
    }

    private func existingRules(app: String, config: KiviStyleConfiguration, rules: [KiviGlobalRule]) -> String {
        var parts = rules.map { "Global: " + $0.text }
        if let group = config.group(for: app), config.enabled.contains(group.id) || config.enabled.contains("app:" + app) {
            parts.append("Group (\(group.mode)): " + group.rules)
        }
        if let style = config.overrides[app], config.enabled.contains("app:" + app) { parts.append("App (\(style.mode)): " + style.rules) }
        return parts.isEmpty ? "No saved writing preferences are active for this app." : parts.joined(separator: "\n")
    }
}

/// NSTextView handles cancelOperation before SwiftUI's ancestor onExitCommand.
/// Consume plain Escape only for this page’s active history/response/capture.
private struct KiviTalkEscapeCapture: NSViewRepresentable {
    var enabled: Bool
    var onEscape: () -> Void
    func makeNSView(context: Context) -> CaptureView { CaptureView() }
    func updateNSView(_ view: CaptureView, context: Context) { view.enabled = enabled; view.onEscape = onEscape }
    static func dismantleNSView(_ view: CaptureView, coordinator: ()) { view.removeMonitor() }

    final class CaptureView: NSView {
        var enabled = false
        var onEscape: (() -> Void)?
        private var monitor: Any?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.enabled, event.keyCode == 53, event.window === self.window,
                      event.modifierFlags.intersection([.shift, .option, .command, .control]).isEmpty else { return event }
                if let editor = self.window?.firstResponder as? NSTextView, editor.hasMarkedText() { return event }
                self.onEscape?()
                return nil
            }
        }
        func removeMonitor() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
    }
}

private struct KiviTalkIconStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.foregroundStyle(enabled ? KiviTheme.ink : KiviTheme.muted)
            .background(configuration.isPressed ? KiviTheme.line : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
    }
}

private struct KiviTalkTextStyle: ButtonStyle {
    var suggestion = false
    var destructive = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.kiviReduceMotion) private var appReduceMotion
    @State private var hovered = false

    private var red: Color {
        scheme == .dark ? Color(red: 1, green: 0.44, blue: 0.40) : Color(red: 0.70, green: 0.14, blue: 0.12)
    }

    func makeBody(configuration: Configuration) -> some View {
        let active = enabled && (hovered || configuration.isPressed)
        return configuration.label.font(KiviTheme.body(13))
            .foregroundStyle(!enabled ? KiviTheme.muted : destructive ? red : active ? (suggestion ? KiviTheme.ink.opacity(0.72) : KiviTheme.ink) : KiviTheme.muted)
            .padding(.horizontal, suggestion ? 10 : 0).padding(.vertical, suggestion ? 7 : 3)
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .onHover { hovered = $0 }
            .animation(systemReduceMotion || appReduceMotion ? nil : .easeOut(duration: 0.14), value: active)
    }
}


/// Monochrome actions belong only to this conversation surface.
private struct KiviTalkButton: ButtonStyle {
    var primary = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.kiviReduceMotion) private var appReduceMotion
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        let fill = scheme == .dark ? Color(white: 0.91) : Color(white: 0.04)
        let label = scheme == .dark ? Color(white: 0.04) : Color.white
        let transition: Animation? = systemReduceMotion || appReduceMotion ? nil : .easeOut(duration: configuration.isPressed ? 0.055 : 0.12)
        return configuration.label
            .font(KiviTheme.body(14)).padding(.horizontal, 14).padding(.vertical, 7)
            .foregroundStyle(primary && enabled ? label : (enabled ? KiviTheme.ink : KiviTheme.muted))
            .background {
                if primary {
                    RoundedRectangle(cornerRadius: 8).fill(enabled ? fill : KiviTheme.panel)
                        .overlay {
                            RoundedRectangle(cornerRadius: 8)
                                .fill((scheme == .dark ? Color.black : Color.white).opacity(enabled ? (configuration.isPressed ? 0.10 : hovered ? 0.05 : 0) : 0))
                        }
                } else {
                    KiviButtonSurface(primary: false, hovered: hovered, pressed: configuration.isPressed, enabled: enabled)
                }
            }
            .onHover { hovered = $0 }
            .onChange(of: enabled) { if !enabled { hovered = false } }
            .animation(transition, value: hovered)
            .animation(transition, value: configuration.isPressed)
    }
}

private struct KiviTalkBottomKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
