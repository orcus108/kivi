import Foundation
import Combine

@MainActor final class KiviTalkConversation: ObservableObject {
    @Published var draft = "" { didSet { saveChat() } }
    @Published private(set) var messages: [KiviTalkMessage] = [] { didSet { saveChat() } }
    @Published private(set) var busy = false
    @Published private(set) var status = ""
    @Published private(set) var error: String?
    @Published private(set) var notice: String?
    @Published private(set) var failedRequest: KiviTalkMessage?
    @Published private(set) var proposal: KiviTalkProposal?
    @Published private(set) var previews: [String: String] = [:]
    @Published private(set) var previewedSample: String?
    @Published var sample = "okay so I think we should launch Friday no sorry Monday and keep it small" { didSet { saveChat() } }
    @Published private(set) var undoReceipt: KiviTalkUndo?
    @Published private(set) var listening = false
    @Published private(set) var transcribing = false
    @Published private(set) var usesGroq: Bool
    @Published private(set) var changes: [KiviTalkChangeRecord] = []
    @Published private(set) var historyError: String?
    @Published private(set) var historyRevision = 0
    @Published private(set) var chats: [KiviTalkChat] = []
    @Published private(set) var chatID = UUID()
    @Published private(set) var archivedPreference: KiviTalkChat.Preference?
    @Published private(set) var chatError: String?
    private var loadingChat = true
    private static let chatKey = "kiviForYouChatsV1"
    private var historyConfiguration: Data?
    private var operation: Task<Void, Never>?
    private var operationID: UUID?
    private var requestingReply = false
    private var captureID: UUID?
    private weak var captureVM: DictationViewModel?
    private let planner: (any KiviTalkPlanning)?
    private let editor: any IntentTextEditing
    private let defaults: UserDefaults
    var configurationChanged: (() -> Void)?
    var protectedTerms: () -> [String] = { [] }

    init(planner: (any KiviTalkPlanning)? = nil, editor: any IntentTextEditing = IntentLocalTextEditor(), defaults: UserDefaults = .standard) {
        self.planner = planner; self.editor = editor; self.defaults = defaults
        usesGroq = defaults.object(forKey: "kiviTalkUsesGroq") as? Bool ?? true
        refreshChanges()
        if let data = defaults.data(forKey: Self.chatKey) {
            do {
                let archive = try JSONDecoder().decode(KiviTalkChat.Archive.self, from: data)
                guard archive.version == 1, Set(archive.chats.map(\.id)).count == archive.chats.count else { throw KiviTalkHistoryError.unreadable }
                chats = archive.chats
                if let chat = chats.first(where: { $0.id == archive.activeID }) {
                    chatID = chat.id; messages = chat.messages; draft = chat.draft
                    sample = chat.sample; archivedPreference = chat.preference
                    if messages.last?.role == "user" { failedRequest = messages.last }
                }
            } catch { chatError = "Chat history couldn’t be opened. Your saved preferences are unchanged." }
        }
        loadingChat = false
    }

    private func saveChat() {
        guard !loadingChat, chatError == nil else { return }
        guard !messages.isEmpty || !draft.isEmpty || chats.contains(where: { $0.id == chatID }) else { return }
        if messages.isEmpty && draft.isEmpty {
            chats.removeAll { $0.id == chatID }
        } else {
        let chat = KiviTalkChat(id: chatID, updatedAt: Date(), messages: messages, draft: draft, sample: sample, preference: archivedPreference)
        if let index = chats.firstIndex(where: { $0.id == chatID }) { chats[index] = chat }
        else { chats.append(chat) }
        }
        do {
            defaults.set(try JSONEncoder().encode(KiviTalkChat.Archive(activeID: chatID, chats: chats)), forKey: Self.chatKey)
        } catch { chatError = "This chat couldn’t be saved. Keep this window open and try again." }
    }

    var canSwitchChat: Bool { !busy && !listening && !transcribing }

    func openChat(_ id: UUID) {
        guard canSwitchChat, id != chatID, let chat = chats.first(where: { $0.id == id }) else { return }
        saveChat(); loadingChat = true
        chatID = chat.id; messages = chat.messages; draft = chat.draft; sample = chat.sample
        archivedPreference = chat.preference
        proposal = nil; previews = [:]; previewedSample = nil; failedRequest = nil
        error = nil; notice = nil; undoReceipt = nil
        if messages.last?.role == "user" { failedRequest = messages.last }
        loadingChat = false; saveChat()
    }

    func deleteChat(_ id: UUID) {
        guard canSwitchChat, chatError == nil else { return }
        if id == chatID {
            // Save first, then remove the archive, without touching writing preferences.
            newConversation()
        }
        chats.removeAll { $0.id == id }
        do {
            defaults.set(try JSONEncoder().encode(KiviTalkChat.Archive(activeID: chatID, chats: chats)), forKey: Self.chatKey)
        } catch { chatError = "This chat couldn’t be deleted. Try again." }
    }

    func reviewArchivedPreference() {
        guard canSwitchChat, let preference = archivedPreference, preference.state == "not saved" else { return }
        do {
            proposal = try KiviTalkChanges.propose(.init(message: "", ready: true, apps: preference.apps, instructions: preference.instructions, mode: preference.mode), defaults: defaults)
            previews = [:]; previewedSample = nil; error = nil
        } catch { self.error = friendlyError(error) }
    }

    var archivedPreferenceState: String? {
        guard let preference = archivedPreference else { return nil }
        if let id = preference.changeID, let change = changes.first(where: { $0.id == id }) {
            switch change.state {
            case .removed, .undone: return "removed"
            case .saved: return "saved"
            default: return "not saved"
            }
        }
        return preference.state
    }

    func selectGroq(_ value: Bool) {
        guard !busy, !listening, !transcribing else { return }
        usesGroq = value; defaults.set(value, forKey: "kiviTalkUsesGroq"); error = nil
        notice = failedRequest == nil ? nil : "Ready to try again with " + (value ? "Groq." : "the local model.")
    }

    var canApply: Bool {
        guard let proposal else { return false }
        return !busy && !listening && !transcribing && previewedSample == sample && proposal.apps.allSatisfy { previews[$0] != nil }
    }

    var canSend: Bool {
        !busy && !listening && !transcribing && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draft.count <= 2000
    }
    var canRetry: Bool {
        !busy && !listening && !transcribing && failedRequest != nil && messages.last?.id == failedRequest?.id
    }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy, !listening, !transcribing else { return }
        guard draft.count <= 2000 else { error = "Keep your request under 2,000 characters."; return }
        messages.append(.init(role: "user", text: text)); draft = ""
        requestReply()
    }

    func retry() {
        guard canRetry else { return }
        requestReply()
    }

    private func requestReply() {
        error = nil; notice = nil; failedRequest = nil
        proposal = nil; archivedPreference = nil; saveChat(); previews = [:]; previewedSample = nil
        requestingReply = true
        let requestMessages = messages
        let id = UUID(); operationID = id; busy = true; status = usesGroq ? "thinking…" : "thinking on your Mac…"
        let activePlanner: any KiviTalkPlanning = planner ?? (usesGroq ? KiviTalkGroqPlanner() as any KiviTalkPlanning : KiviTalkLocalPlanner() as any KiviTalkPlanning)
        operation = Task { [weak self] in
            guard let self else { return }
            defer { if operationID == id { busy = false; operation = nil; status = ""; requestingReply = false } }
            do {
                try Task.checkCancellation()
                guard operationID == id else { return }
                let baseline = defaults.data(forKey: KiviStyleRouter.key)
                let globalBaseline = defaults.data(forKey: KiviGlobalRules.key)
                let context = try KiviTalkChanges.context(defaults: defaults)
                // Preserve complete conversational context; don't silently drop the original scope.
                guard requestMessages.map(\.text).joined().count <= 14000 else { throw KiviTalkError.tooLong }
                let reply = try await activePlanner.reply(messages: requestMessages, context: context)
                try Task.checkCancellation()
                guard operationID == id else { return }
                guard defaults.data(forKey: KiviStyleRouter.key) == baseline,
                      defaults.data(forKey: KiviGlobalRules.key) == globalBaseline else { throw KiviTalkError.changed }
                if reply.ready {
                    proposal = try KiviTalkChanges.propose(reply, defaults: defaults)
                    archivedPreference = .init(apps: reply.apps, instructions: reply.instructions, mode: reply.mode, state: "not saved")
                    messages.append(.init(role: "assistant", text: "I can update writing preferences for \(reply.apps.joined(separator: " and ")). Try the proposal with an example before saving it."))
                } else { messages.append(.init(role: "assistant", text: reply.message)) }
            } catch is CancellationError { }
            catch { if operationID == id { self.error = friendlyError(error); failedRequest = requestMessages.last { $0.role == "user" } } }
        }
    }

    func preview() {
        guard let proposal, !busy, !listening, !transcribing else { return }
        let source = sample.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty, source.count <= 2000 else { error = "Use an example of 1–2,000 characters."; return }
        error = nil; notice = nil; previews = [:]; previewedSample = nil
        requestingReply = false
        let exactSample = sample, terms = protectedTerms()
        let id = UUID(); operationID = id; busy = true; status = "trying your example locally…"
        operation = Task { [weak self] in
            guard let self else { return }
            defer { if operationID == id { busy = false; operation = nil; status = ""; requestingReply = false } }
            do {
                try Task.checkCancellation()
                guard operationID == id else { return }
                try KiviTalkChanges.check(proposal, defaults: defaults)
                var results: [String: String] = [:]
                for app in proposal.apps {
                    results[app] = try await KiviStyleRouter.preview(source, app: app, configuration: proposal.configuration, rules: proposal.rules, protectedTerms: terms, client: editor)
                    try Task.checkCancellation()
                }
                guard operationID == id else { return }
                try KiviTalkChanges.check(proposal, defaults: defaults)
                guard sample == exactSample else { error = "The example changed. Preview it again before applying."; return }
                previews = results; previewedSample = exactSample
            } catch is CancellationError { }
            catch { if operationID == id { self.error = friendlyError(error, localPreview: true) } }
        }
    }

    func apply() {
        guard canApply, let proposal else { error = KiviTalkError.noPreview.localizedDescription; return }
        do {
            undoReceipt = try KiviTalkChanges.apply(proposal, defaults: defaults)
            refreshChanges()
            archivedPreference?.state = "saved"; archivedPreference?.changeID = undoReceipt?.changeID
            messages.append(.init(role: "assistant", text: "Saved for \(proposal.apps.joined(separator: " and "))."))
            self.proposal = nil; previews = [:]; previewedSample = nil; error = nil; notice = nil
            configurationChanged?()
        } catch { self.error = friendlyError(error) }
    }

    func undo() {
        guard let undoReceipt, !busy, !listening, !transcribing else { return }
        do {
            try KiviTalkChanges.undo(undoReceipt, defaults: defaults)
            refreshChanges()
            self.undoReceipt = nil; proposal = nil; previews = [:]; previewedSample = nil; error = nil; notice = nil
            messages.append(.init(role: "assistant", text: "Undone. Your previous writing preferences are back."))
            configurationChanged?()
        } catch { self.error = friendlyError(error) }
    }

    func discardProposal() { guard !busy else { return }; archivedPreference?.state = "discarded"; saveChat(); proposal = nil; previews = [:]; previewedSample = nil; error = nil; notice = nil }

    func refreshChanges() {
        do {
            let records = try KiviTalkChangeHistory.load(defaults: defaults)
            if changes != records { changes = records }
            historyError = nil
        } catch { historyError = error.localizedDescription }
        let current = defaults.data(forKey: KiviStyleRouter.key)
        if current != historyConfiguration { historyConfiguration = current; historyRevision &+= 1 }
    }

    func canRemoveChange(_ record: KiviTalkChangeRecord) -> Bool {
        !busy && !listening && !transcribing && KiviTalkChangeHistory.canRemove(record, defaults: defaults)
    }

    func removeChange(_ id: UUID) {
        guard !busy, !listening, !transcribing else { return }
        do {
            try KiviTalkChangeHistory.remove(id, defaults: defaults)
            undoReceipt = nil; proposal = nil; previews = [:]; previewedSample = nil
            historyError = nil; configurationChanged?(); refreshChanges()
        } catch { historyError = error.localizedDescription; refreshHistoryAfterFailure() }
    }

    func canUndoChange(_ record: KiviTalkChangeRecord) -> Bool {
        !busy && !listening && !transcribing && KiviTalkChangeHistory.canUndo(record, defaults: defaults)
    }

    func undoChange(_ id: UUID) {
        guard !busy, !listening, !transcribing else { return }
        do {
            try KiviTalkChangeHistory.undo(id, defaults: defaults)
            undoReceipt = nil; proposal = nil; previews = [:]; previewedSample = nil
            error = nil; notice = nil; historyError = nil
            messages.append(.init(role: "assistant", text: "Undone. The writing settings from before that change are restored."))
            configurationChanged?()
            refreshChanges()
        } catch { historyError = error.localizedDescription; refreshHistoryAfterFailure() }
    }

    private func refreshHistoryAfterFailure() {
        // Keep the actionable failure visible while refreshing current eligibility.
        let failure = historyError
        refreshChanges()
        if let failure { historyError = failure }
    }
    func stop() {
        guard busy else { return }
        if requestingReply { failedRequest = messages.last { $0.role == "user" } }
        operationID = nil; operation?.cancel(); operation = nil; busy = false; status = ""; requestingReply = false
        error = nil; notice = "Stopped. Nothing was saved."
    }
    func newConversation() {
        guard canSwitchChat else { return }
        saveChat(); loadingChat = true
        chatID = UUID(); messages = []; draft = ""; archivedPreference = nil
        sample = "okay so I think we should launch Friday no sorry Monday and keep it small"
        proposal = nil; previews = [:]; previewedSample = nil; error = nil; notice = nil; failedRequest = nil; undoReceipt = nil
        loadingChat = false
        // Persist the empty active selection without adding an empty history row.
        if chatError == nil, let data = try? JSONEncoder().encode(KiviTalkChat.Archive(activeID: chatID, chats: chats)) { defaults.set(data, forKey: Self.chatKey) }
    }

    func toggleVoice(_ vm: DictationViewModel) {
        guard !busy, !transcribing else { return }
        if listening { listening = false; transcribing = true; vm.kiviStopTalkCapture(); return }
        error = nil
        let id = UUID(), draftBefore = draft
        captureID = id; captureVM = vm; listening = true
        let started = vm.kiviStartTalkCapture(id: id) { [weak self] result in
            guard let self, captureID == id else { return }
            captureID = nil; captureVM = nil; listening = false; transcribing = false
            switch result {
            case .success(let text):
                guard draft == draftBefore else { error = "Your draft changed while recording. Copy the spoken text below if you want to keep it."; messages.append(.init(role: "assistant", text: "Unsent spoken text: " + text)); return }
                draft = draftBefore.isEmpty ? text : draftBefore + " " + text
            case .failure(let failure):
                if !(failure is CancellationError) { error = failure.localizedDescription }
            }
        }
        if !started { captureID = nil; captureVM = nil; listening = false; error = "Finish the current dictation before recording a message here." }
    }

    func cancelVoice() {
        guard let id = captureID else { return }
        captureID = nil; listening = false; transcribing = false
        captureVM?.kiviCancelTalkCapture(id: id); captureVM = nil
    }

    private func friendlyError(_ error: Error, localPreview: Bool = false) -> String {
        if let failure = error as? KiviTalkError { return failure.localizedDescription }
        if let failure = error as? IntentEditingError {
            switch failure {
            case .invalidInput: return KiviTalkError.tooLong.localizedDescription
            case .missingModel: return "The local writing model (\(IntentLocalTextEditor.modelName)) isn’t installed. Your request is still here; no settings changed."
            case .unavailable: return "The local writing model couldn’t respond. Try again in a moment. Nothing was saved."
            default: break
            }
        }
        if error is URLError { return usesGroq && !localPreview ? KiviTalkError.groqUnavailable.localizedDescription : "The local writing model couldn’t respond. Try again in a moment. Your request is still here; no settings changed." }
        return error.localizedDescription
    }
}

/// Conversation content is local history, never a replayable settings transaction.
struct KiviTalkChat: Codable, Identifiable, Equatable {
    struct Preference: Codable, Equatable {
        var apps: [String]
        var instructions: String
        var mode: String
        var state: String
        var changeID: UUID? = nil
    }
    struct Archive: Codable {
        var version = 1
        var activeID: UUID
        var chats: [KiviTalkChat]
    }
    var id: UUID
    var updatedAt: Date
    var messages: [KiviTalkMessage]
    var draft: String
    var sample: String
    var preference: Preference?
    var title: String { String((messages.first(where: { $0.role == "user" })?.text ?? draft).prefix(75)) }
}
