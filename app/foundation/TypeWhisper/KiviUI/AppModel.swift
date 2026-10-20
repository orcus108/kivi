import SwiftUI
import AppKit
import Combine
import ApplicationServices

struct LexiconEntry: Codable, Identifiable, Equatable { var id = UUID(); var heard: String; var written: String }
struct ExpansionEntry: Codable, Identifiable, Equatable { var id = UUID(); var trigger: String; var expansion: String }
struct Take: Identifiable, Equatable, Sendable { var id: UUID; var date: Date; var raw: String; var text: String; var source: String; var isSpeech: Bool; var wordCount: Int { text.split(whereSeparator: \.isWhitespace).count } }
struct WritingStyle: Identifiable, Codable, Equatable {
    var id: String; var name: String; var subtitle: String; var mode: String; var rules: String; var apps: String
    static let defaults: [Self] = [
        .init(id: "developer", name: "developer", subtitle: "terse, and your code stays code", mode: "clear", rules: "Preserve code identifiers, commands, paths and technical terms.", apps: "Cursor, Xcode, Terminal"),
        .init(id: "work", name: "work messaging", subtitle: "clear, quick, and work-ready", mode: "clear", rules: "Preserve every number and commitment.", apps: "Slack, Teams, Zoom"),
        .init(id: "personal", name: "personal messaging", subtitle: "casual, the way you'd tell a friend", mode: "natural", rules: "Keep my wording and casual tone.", apps: "Messages, WhatsApp, Signal"),
        .init(id: "email", name: "email", subtitle: "a little polish. still all you.", mode: "professional", rules: "Use natural paragraphs. Never invent a sign-off or facts.", apps: "Mail, Outlook"),
        .init(id: "other", name: "other apps", subtitle: "your words, just a little clearer", mode: "balanced", rules: "Preserve the meaning and my voice.", apps: "Safari, Notes, Pages")]
}
struct SavedState: Codable {
    // Service-owned collections are projections, never a second persisted database.
    var takes: [Take] = []; var terms: [LexiconEntry] = []; var shortcuts: [ExpansionEntry] = []
    var termNotes: [String: String] = [:]
    var styles = WritingStyle.defaults
    var appOverrides: [String: WritingStyle] = [:]
    var appearance = "dark"; var reduceMotion = false; var locale = "en"; var model = "llama3.2:latest"; var showOrb = true; var literal = false
    var orbLook = "pill"; var orbTheme = "black"; var hideOrb = true
    enum CodingKeys: String, CodingKey { case styles, termNotes, appOverrides, appearance, reduceMotion, locale, model, showOrb, literal, orbLook, orbTheme, hideOrb }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        styles = try c.decodeIfPresent([WritingStyle].self, forKey: .styles) ?? WritingStyle.defaults
        termNotes = try c.decodeIfPresent([String: String].self, forKey: .termNotes) ?? [:]
        appOverrides = try c.decodeIfPresent([String: WritingStyle].self, forKey: .appOverrides) ?? [:]
        appearance = try c.decodeIfPresent(String.self, forKey: .appearance) ?? "dark"
        reduceMotion = try c.decodeIfPresent(Bool.self, forKey: .reduceMotion) ?? false
        locale = try c.decodeIfPresent(String.self, forKey: .locale) ?? "en"
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? "qwen3:1.7b"
        showOrb = try c.decodeIfPresent(Bool.self, forKey: .showOrb) ?? true
        literal = try c.decodeIfPresent(Bool.self, forKey: .literal) ?? false
        orbLook = try c.decodeIfPresent(String.self, forKey: .orbLook) ?? "pill"
        orbTheme = try c.decodeIfPresent(String.self, forKey: .orbTheme) ?? "black"
        hideOrb = try c.decodeIfPresent(Bool.self, forKey: .hideOrb) ?? true
    }

}
extension Take {
    @MainActor init(_ record: TranscriptionRecord) {
        self.init(id: record.id, date: record.timestamp, raw: record.rawText, text: record.finalText,
                  source: record.appName ?? "writing pad", isSpeech: record.engineUsed != "typed")
    }
}

enum Page: String, CaseIterable {
    case record, history, dictionary, shortcuts, styles, settings
    var icon: String { switch self { case .record: "mic"; case .history: "clock"; case .dictionary: "sparkle"; case .shortcuts: "bolt"; case .styles: "line.diagonal"; case .settings: "gearshape" } }
}

@MainActor final class KiviAudioMeter: ObservableObject { @Published var level = 0.0 }

/// Projects the existing dictation state. It never starts a second audio engine.
@MainActor final class SpeechCapture: ObservableObject {
    @Published var isRecording = false; @Published var isBusy = false
    @Published var transcript = ""; let meter = KiviAudioMeter(); @Published var error: String?
    @Published var feedbackMessage: String?
    @Published var feedbackActionTitle: String?
    @Published var isNoSpeechFeedback = false
    private var subscriptions = Set<AnyCancellable>()
    init(_ vm: DictationViewModel) {
        Publishers.CombineLatest4(vm.$state, vm.$actionFeedbackMessage, vm.$actionFeedbackActionTitle, vm.$isNoSpeechFeedback)
            .receive(on: DispatchQueue.main).sink { [weak self] state, feedback, actionTitle, noSpeech in
            self?.isRecording = state == .recording
            let isFeedback = state == .inserting && feedback != nil
            self?.isBusy = state != .idle && state != .recording && !isFeedback
            self?.feedbackMessage = isFeedback ? feedback : nil
            self?.feedbackActionTitle = isFeedback ? actionTitle : nil
            self?.isNoSpeechFeedback = isFeedback && noSpeech
            if case .error(let message) = state { self?.error = message; self?.isBusy = false } else { self?.error = nil }
        }.store(in: &subscriptions)
        vm.$partialText.receive(on: DispatchQueue.main).assign(to: &$transcript)
        vm.$audioLevel.removeDuplicates().receive(on: DispatchQueue.main).map(Double.init).assign(to: &meter.$level)
    }
}
@MainActor final class NativeBridge: ObservableObject {
    @Published var hotkeysEnabled = true
    var hasAccessibility: Bool { AXIsProcessTrusted() }
    func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt" as CFString: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        objectWillChange.send()
    }
    func startHotkey() throws { ServiceContainer.shared.hotkeyService.dictationHotkeysPaused = false; hotkeysEnabled = true }
    func stopHotkey() { ServiceContainer.shared.hotkeyService.dictationHotkeysPaused = true; hotkeysEnabled = false }
}

@MainActor final class KiviDraftStore: ObservableObject { @Published var text = "" }

@MainActor final class AppModel: ObservableObject {
    static let shared = AppModel()
    @Published var saved = SavedState()
    @Published var page: Page = .record {
        didSet {
            if page == .record && oldValue != .record { greeting = (greeting + 1) % 3 }
        }
    }
    @Published var showWelcome = false
    let writing = KiviDraftStore()
    var draft: String { get { writing.text } set { if writing.text != newValue { writing.text = newValue } } }
    @Published var greeting = 0; @Published var toast: String?; @Published var settingsSection = "general"
    @Published var selectedTake: Take?; @Published var selectedStyle: String?
    @Published var modelStatus = "loading your dictation engine…"
    @Published var incognito = false { didSet { updatePrivacy() } }
    let services: ServiceContainer
    let history: KiviHistoryStore
    let speech: SpeechCapture
    let bridge = NativeBridge()
    let dataDirectory: URL
    private var subscriptions = Set<AnyCancellable>()
    private var termBaseline = Set<UUID>(); private var shortcutBaseline = Set<UUID>()
    private var privacyHistory = true; private var privacyLearning = false
    private var toastTask: Task<Void, Never>?
    private var previousLiteral = false
    private var processing: Task<Void, Never>?
    private let presentationWriter = KiviPresentationWriter()
    private var stateURL: URL { dataDirectory.appendingPathComponent("kivi-presentation.json") }

    init(services: ServiceContainer = .shared) {
        self.services = services; history = KiviHistoryStore(service: services.historyService); speech = SpeechCapture(services.dictationViewModel); dataDirectory = AppConstants.appSupportDirectory
        if let data = try? Data(contentsOf: stateURL), let state = try? JSONDecoder().decode(SavedState.self, from: data) { saved = state }
        saved.literal = UserDefaults.standard.string(forKey: IntentTextPipeline.styleKey) == "literal"
        saved.locale = services.settingsViewModel.selectedLanguage ?? "en"
        previousLiteral = saved.literal
        refreshTerms(); refreshShortcuts()
        services.dictionaryService.$entries.dropFirst().debounce(for: .milliseconds(20), scheduler: DispatchQueue.main).sink { [weak self] _ in self?.refreshTerms() }.store(in: &subscriptions)
        services.snippetService.$snippets.dropFirst().debounce(for: .milliseconds(20), scheduler: DispatchQueue.main).sink { [weak self] _ in self?.refreshShortcuts() }.store(in: &subscriptions)
        services.dictationViewModel.$lastTranscribedText.compactMap { $0 }.receive(on: DispatchQueue.main).sink { [weak self] text in self?.draft = text }.store(in: &subscriptions)
        services.modelManagerService.objectWillChange.debounce(for: .milliseconds(150), scheduler: DispatchQueue.main).sink { [weak self] _ in self?.refreshEngineStatus() }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).receive(on: DispatchQueue.main).sink { [weak self] _ in
            guard let self, incognito else { return }
            if UserDefaults.standard.bool(forKey: UserDefaultsKeys.historyEnabled) { UserDefaults.standard.set(false, forKey: UserDefaultsKeys.historyEnabled) }
            if UserDefaults.standard.bool(forKey: TargetAppCorrectionLearningService.localEnabledKey) { UserDefaults.standard.set(false, forKey: TargetAppCorrectionLearningService.localEnabledKey) }
        }.store(in: &subscriptions)
        $saved.map(\.locale).removeDuplicates().dropFirst().receive(on: DispatchQueue.main).sink { [weak self] code in self?.services.settingsViewModel.languageSelection = .exact(code.components(separatedBy: "-")[0]) }.store(in: &subscriptions)
        refreshEngineStatus()
    }
    func refreshEngineStatus() {
        let manager = services.modelManagerService
        let name = manager.activeEngineName ?? "local engine"
        let status = manager.isModelReady ? "ready · \(name)" : manager.canTranscribe ? "\(name) · loads locally when needed" : "choose a speech engine"
        if modelStatus != status { modelStatus = status }
    }
    func refreshTerms() {
        let values = services.dictionaryService.entries.map { LexiconEntry(id: $0.id, heard: $0.original, written: $0.replacement ?? $0.original) }
        if saved.terms != values { saved.terms = values }
        termBaseline = Set(values.map(\.id))
    }
    func refreshShortcuts() {
        let values = services.snippetService.snippets.map { ExpansionEntry(id: $0.id, trigger: $0.trigger, expansion: $0.replacement) }
        if saved.shortcuts != values { saved.shortcuts = values }
        shortcutBaseline = Set(values.map(\.id))
    }
    @discardableResult func persistTerms() -> Bool {
        KiviDictionaryAdapter.reconcile(saved.terms, baseline: termBaseline, service: services.dictionaryService)
        refreshTerms()
        return persist()
    }
    @discardableResult func persistShortcuts() -> Bool {
        let snippets = services.snippetService
        let ids = Set(saved.shortcuts.map(\.id))
        let existing = Dictionary(uniqueKeysWithValues: snippets.snippets.map { ($0.id, $0) })
        for entry in snippets.snippets where shortcutBaseline.contains(entry.id) && !ids.contains(entry.id) { snippets.deleteSnippet(entry) }
        for value in saved.shortcuts {
            if let entry = existing[value.id] {
                if entry.trigger != value.trigger || entry.replacement != value.expansion { snippets.updateSnippet(entry, trigger: value.trigger, replacement: value.expansion, caseSensitive: entry.caseSensitive) }
            } else { snippets.addSnippet(trigger: value.trigger, replacement: value.expansion) }
        }
        refreshShortcuts()
        return true
    }
    func deleteTake(_ id: UUID) { _ = services.historyService.deleteRecord(withID: id) }
    func clearHistory() { services.historyService.clearAll() }

    // Presentation-only save: never scans or mutates service-owned collections.
    @discardableResult func persist() -> Bool {
        if saved.literal != previousLiteral { UserDefaults.standard.set(saved.literal ? "literal" : "automatic", forKey: IntentTextPipeline.styleKey); previousLiteral = saved.literal }
        do {
            let data = try JSONEncoder().encode(saved)
            presentationWriter.write(data, to: stateURL) { [weak self] error in
                if let error { self?.notify("Could not save: \(error.localizedDescription)") }
            }
            return true
        } catch { notify("Could not save: \(error.localizedDescription)"); return false }
    }
    func notify(_ message: String) { toastTask?.cancel(); toast = message; toastTask = Task { try? await Task.sleep(for: .seconds(6)); if !Task.isCancelled { toast = nil } } }
    func copy(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string); notify("copied") }
    func toggleRecording(external: Bool = false, asInstruction: Bool = false) {
        if asInstruction { services.dictationViewModel.startSelectionInstruction(); return }
        services.dictationViewModel.kiviToggleRecording()
    }
    func cancelRecording() { services.dictationViewModel.kiviCancelRecording() }
    func processDraft() {
        guard processing == nil, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let raw = draft, privateTake = incognito
        processing = Task { @MainActor in
            defer { processing = nil }
            do {
                let style = saved.literal ? IntentTextStyle.literal : IntentTextPipeline.style(bundleID: nil, url: nil)
                let processed = try await IntentDictationProcessor.process(raw, style: style, dictionary: services.dictionaryService)
                let result = style == .literal ? raw : services.snippetService.applySnippets(to: processed.text)
                guard draft == raw else { notify("Writing pad changed; the previous result was discarded."); return }
                draft = result
                if !privateTake && !incognito { _ = services.historyService.addRecord(rawText: raw, finalText: result, appName: "writing pad", appBundleIdentifier: Bundle.main.bundleIdentifier, durationSeconds: 0, language: "en", engineUsed: "typed", pipelineSteps: processed.steps) }
                notify(privateTake || incognito ? "cleaned · incognito" : "cleaned and saved")
            } catch { notify(error.localizedDescription) }
        }
    }
    func openEditor(text: String? = nil) { let editor = IntentSelectionEditor.shared; editor.openTyped(); editor.source = text ?? draft }
    func saveStyle(_ style: WritingStyle, app: String?) {
        if let app { saved.appOverrides[app] = style }
        else if let i = saved.styles.firstIndex(where: { $0.id == style.id }) { saved.styles[i] = style }
        KiviStyleRouter.save(style, app: app); _ = persist()
        notify("style saved · applies locally to future dictation")
    }
    func applyStyle(_ style: WritingStyle) { openEditor(); IntentSelectionEditor.shared.instruction = "Rewrite in a \(style.mode) style. \(style.rules) Preserve all facts, names and numbers." }
    func refreshModels() async { refreshEngineStatus() }
    private func updatePrivacy() {
        if incognito { services.dictationViewModel.kiviMarkPrivateSession(); services.targetAppCorrectionLearningService.stopDetection(); privacyHistory = UserDefaults.standard.object(forKey: UserDefaultsKeys.historyEnabled) as? Bool ?? true; privacyLearning = UserDefaults.standard.bool(forKey: TargetAppCorrectionLearningService.localEnabledKey) }
        UserDefaults.standard.set(incognito ? false : privacyHistory, forKey: UserDefaultsKeys.historyEnabled)
        UserDefaults.standard.set(incognito ? false : privacyLearning, forKey: TargetAppCorrectionLearningService.localEnabledKey)
    }
    func importTerms() { openAdvanced("dictionary") }
    func exportHistory() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "kivi-history.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do { try await services.historyService.exportKiviHistory(to: url); notify("history exported") }
            catch { notify("Could not export: \(error.localizedDescription)") }
        }
    }
    func openAdvanced(_ section: String = "general") { KiviAdvancedWindow.shared.show(section) }
}

struct KiviRootHost: View {
    @StateObject private var model = AppModel.shared
    var body: some View {
        RootView().environmentObject(model)
            .preferredColorScheme(model.showWelcome ? .light : (model.saved.appearance == "system" ? nil : model.saved.appearance == "light" ? .light : .dark))
            .background(WindowConfigurator())
            .task { await KiviLocalEditorRuntime.shared.ensureRunning() }
    }
}

/// Preserve native entry identity, enabled state and learning provenance while
/// translating Kivi's preferred-spelling form into vocabulary and alias entries.
@MainActor enum KiviDictionaryAdapter {
    enum WordError: LocalizedError {
        case empty, sameSpelling, duplicate, saveFailed
        var errorDescription: String? {
            switch self {
            case .empty: return "enter a word and, when correcting, its misspelling."
            case .sameSpelling: return "the misspelling and correct spelling must be different."
            case .duplicate: return "this word or misspelling is already in your dictionary. edit the existing entry instead."
            case .saveFailed: return "the word couldn’t be saved. please try again."
            }
        }
    }

    static func saveWord(written: String, misspelling: String?, editing id: UUID?, service: DictionaryService) throws {
        let spelling = written.trimmingCharacters(in: .whitespacesAndNewlines)
        let heard = misspelling?.trimmingCharacters(in: .whitespacesAndNewlines) ?? spelling
        guard !spelling.isEmpty, !heard.isEmpty else { throw WordError.empty }
        guard misspelling == nil || heard != spelling else { throw WordError.sameSpelling }
        let type: DictionaryEntryType = misspelling == nil ? .term : .correction
        guard !service.entries.contains(where: { $0.id != id && $0.type == type && $0.original.caseInsensitiveCompare(heard) == .orderedSame }) else {
            throw WordError.duplicate
        }
        let replacement = type == .term ? nil : spelling
        if let id {
            guard let entry = service.entries.first(where: { $0.id == id }) else { throw WordError.saveFailed }
            entry.type = type
            service.updateEntry(entry, original: heard, replacement: replacement, caseSensitive: entry.caseSensitive,
                                ctcMinSimilarity: entry.ctcMinSimilarity)
        } else {
            service.addEntry(type: type, original: heard, replacement: replacement)
        }
        guard service.entries.contains(where: { $0.type == type && $0.original == heard && $0.replacement == replacement }) else {
            throw WordError.saveFailed
        }
    }

    static func reconcile(_ values: [LexiconEntry], baseline: Set<UUID>, service: DictionaryService) {
        let ids = Set(values.map(\.id))
        let existing = Dictionary(uniqueKeysWithValues: service.entries.map { ($0.id, $0) })
        service.deleteEntries(service.entries.filter { baseline.contains($0.id) && !ids.contains($0.id) })
        for value in values {
            if let entry = existing[value.id] {
                if entry.type == .term {
                    if entry.original != value.written || entry.replacement != nil { service.updateEntry(entry, original: value.written, replacement: nil, caseSensitive: entry.caseSensitive) }
                    if value.heard != value.written {
                        if let alias = service.corrections.first(where: { $0.original.caseInsensitiveCompare(value.heard) == .orderedSame }) {
                            if alias.replacement != value.written { service.updateEntry(alias, original: alias.original, replacement: value.written, caseSensitive: alias.caseSensitive) }
                        } else { service.addEntry(type: .correction, original: value.heard, replacement: value.written) }
                    }
                } else if entry.original != value.heard || entry.replacement != value.written {
                    service.updateEntry(entry, original: value.heard, replacement: value.written, caseSensitive: entry.caseSensitive)
                }
            } else { service.addEntry(type: value.heard == value.written ? .term : .correction, original: value.heard, replacement: value.heard == value.written ? nil : value.written) }
        }
    }
}
