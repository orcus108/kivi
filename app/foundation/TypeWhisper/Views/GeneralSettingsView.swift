import SwiftUI
import ServiceManagement
import TypeWhisperPluginSDK

private func completeApplicationRelaunch(_ application: NSRunningApplication?, _ error: Error?) {
    guard application != nil, error == nil else { return }
    Task { @MainActor in
        NSApplication.shared.terminate(nil)
    }
}

struct GeneralSettingsView: View {
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var appLanguage: String = {
        if let lang = UserDefaults.standard.string(forKey: UserDefaultsKeys.preferredAppLanguage) {
            return lang
        }
        let preferredLanguage = Locale.preferredLanguages.first
        if preferredLanguage?.hasPrefix("ja") == true {
            return "ja"
        }
        if preferredLanguage?.hasPrefix("zh") == true {
            return "zh-Hans"
        }
        return preferredLanguage?.hasPrefix("de") == true ? "de" : "en"
    }()
    @State private var showRestartAlert = false
    @ObservedObject private var settings = SettingsViewModel.shared

    var body: some View {
        VStack(spacing: 0) {
            SettingsPageHeader(String(localized: "General"))
            Divider()

            Form {
                IntentExperimentSettingsSection()
                SelfCorrectionSettingsSection()
                if TargetAppCorrectionLearningService.isPrivateBuild {
                    LocalCorrectionLearningSettingsSection()
                }
                Section(String(localized: "Spoken Language")) {
                LanguageSelectionEditor(
                    selection: $settings.languageSelection,
                    availableLanguages: settings.availableLanguages,
                    hintBehavior: LanguageSelectionHintBehavior(engine: settings.activeTranscriptionEngine)
                )

                Text(String(localized: "Controls push-to-talk dictation, workflows that inherit the global spoken language, and CLI/API defaults when they use app defaults. Recorder and Recovery have separate language settings."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

                #if canImport(Translation)
                if #available(macOS 15, *) {
                    Section(String(localized: "Translation")) {
                    Toggle(String(localized: "Enable translation"), isOn: $settings.translationEnabled)

                    if settings.translationEnabled {
                        Picker(String(localized: "Target language"), selection: $settings.translationTargetLanguage) {
                            ForEach(TranslationService.availableTargetLanguages, id: \.code) { lang in
                                Text(lang.name).tag(lang.code)
                            }
                        }
                    }

                    Text(String(localized: "Uses Apple Translate (on-device)"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                #endif

                Section(String(localized: "Language")) {
                Picker(String(localized: "App Language"), selection: $appLanguage) {
                    Text(String(localized: "English")).tag("en")
                    Text(String(localized: "Deutsch")).tag("de")
                    Text(String(localized: "日本語")).tag("ja")
                    Text(String(localized: "简体中文")).tag("zh-Hans")
                }
                .onChange(of: appLanguage) {
                    UserDefaults.standard.set(appLanguage, forKey: UserDefaultsKeys.preferredAppLanguage)
                    UserDefaults.standard.set([appLanguage], forKey: "AppleLanguages")
                    showRestartAlert = true
                }
            }

                Section(String(localized: "Startup")) {
                Toggle(String(localized: "Launch at Login"), isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        toggleLaunchAtLogin(newValue)
                    }

                Text(String(localized: "TypeWhisper will start automatically when you log in."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            }
            .formStyle(.grouped)
            .padding(.horizontal, SettingsLayoutMetrics.pagePadding)
            .padding(.bottom, SettingsLayoutMetrics.pagePadding)
        }
        .frame(minWidth: 500, minHeight: 300)
        .alert(String(localized: "Restart Required"), isPresented: $showRestartAlert) {
            Button(String(localized: "Restart Now")) {
                ApplicationRelauncher.relaunch()
            }
            Button(String(localized: "Later"), role: .cancel) {}
        } message: {
            Text(String(localized: "The language change will take effect after restarting TypeWhisper."))
        }
    }

    private func toggleLaunchAtLogin(_ enable: Bool) {
        do {
            if enable {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Revert toggle on failure
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

@MainActor
enum ApplicationRelauncher {
    static func relaunch() {
        let bundleURL = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(
            at: bundleURL,
            configuration: config,
            completionHandler: completeApplicationRelaunch
        )
    }
}

// Private Intent experiment: no entitlement, cloud account, or upload path.
struct LocalCorrectionLearningSettingsSection: View {
    @AppStorage(TargetAppCorrectionLearningService.localEnabledKey) private var enabled = true
    @AppStorage(TargetAppCorrectionLearningService.automaticLearningKey) private var automatic = true
    @ObservedObject private var service = ServiceContainer.shared.targetAppCorrectionLearningService

    var body: some View {
        Section("Learning from corrections") {
            Toggle("Detect edits to dictated text", isOn: $enabled)
                .accessibilityIdentifier("intent.learning.enabled")
                .onChange(of: enabled) { _, value in
                    if !value { service.stopDetection(); service.dismissReview() }
                }
            Toggle("Learn repeated name spellings automatically", isOn: $automatic)
                .disabled(!enabled)
            Text("Edit normally after dictation. After two matching name-spelling corrections in separate takes, Intent saves a local dictionary rule when observation ends. Rewrites, numbers, dates and ambiguous changes remain samples. Remember saves an eligible spelling immediately. Captures expire after 24 hours; learned rules stay until removed in Dictionary. No learning text is uploaded.")
                .font(.caption).foregroundStyle(.secondary)
            Text(service.detectionStatus).font(.caption).accessibilityIdentifier("intent.detection.status")
            Text("Captured edits: \(service.detectedEdits.count)").accessibilityIdentifier("intent.detection.count")
            ForEach(service.detectedEdits.reversed()) { edit in
                VStack(alignment: .leading, spacing: 4) {
                    Text("Original: \(edit.original)").lineLimit(3)
                    Text("Edited: \(edit.edited)").lineLimit(3)
                    Text(service.classification(for: edit)).foregroundStyle(.secondary)
                    HStack {
                        if TargetAppCorrectionLearningService.spellingSuggestion(for: edit) != nil {
                            Button("Remember spelling") { service.rememberDetectedEdit(id: edit.id) }
                        }
                        Button("Discard capture") { service.removeDetectedEdit(id: edit.id) }
                    }
                }.font(.caption)
            }
            if !service.detectedEdits.isEmpty {
                Button("Clear captured edits") { service.clearDetectedEdits() }
            }
            Button("Review learned corrections in Dictionary") {
                SettingsNavigationCoordinator.shared?.navigate(to: .dictionary)
            }
            if service.pendingCorrection != nil || service.reviewMessage != nil {
                CorrectionLearningReviewView(service: service)
            }
        }
    }
}

struct CorrectionLearningReviewView: View {
    @ObservedObject var service: TargetAppCorrectionLearningService

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let pending = service.pendingCorrection {
                Text("Remember this spelling?").font(.headline)
                Text("“\(pending.original)” → “\(pending.replacement)”")
                    .textSelection(.enabled)
                Text("Use this replacement in future dictation across apps.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Remember") { service.rememberCorrection(id: pending.id) }
                        .accessibilityIdentifier("intent.learning.remember")
                    Button("Dismiss") { service.dismissReview() }
                        .accessibilityIdentifier("intent.learning.dismiss")
                }
            } else if let message = service.reviewMessage {
                Text(message)
                HStack {
                    if !service.reviewedCorrections.isEmpty {
                        Button("Undo") { service.undoReviewedCorrections() }
                            .accessibilityIdentifier("intent.learning.undo")
                    }
                    Button("Dictionary") {
                        SettingsNavigationCoordinator.shared?.navigate(to: .dictionary)
                        ManagedAppWindowOpener.shared.open(id: "settings")
                        service.dismissReview()
                    }
                    Button("Dismiss") { service.dismissReview() }
                }
            }
        }
        .padding(16)
    }
}

@MainActor
final class CorrectionLearningPanel: NSPanel {
    init(service: TargetAppCorrectionLearningService) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 420, height: 180),
                   styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        title = "Intent · Spelling correction"
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = NSHostingView(rootView: CorrectionLearningReviewView(service: service))
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func showReview() {
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            setFrameOrigin(NSPoint(x: frame.maxX - self.frame.width - 24, y: frame.minY + 40))
        }
        orderFrontRegardless()
    }
}
