import SwiftUI
import AppKit
import AVFoundation

@MainActor final class KiviRecoveryWindow {
    static let shared = KiviRecoveryWindow()
    private var window: NSWindow?
    func show() {
        if window == nil {
            let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 620), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            panel.title = "Kivi · recording recovery"
            panel.isReleasedWhenClosed = false
            panel.contentView = NSHostingView(rootView: KiviRecoveryView())
            panel.minSize = NSSize(width: 620, height: 480)
            panel.center()
            window = panel
        }
        DictationRecoveryViewModel.shared.refreshRecoveries()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct KiviRecoveryView: View {
    @ObservedObject private var workspace = AppModel.shared
    @ObservedObject private var recovery = DictationRecoveryViewModel.shared
    @State private var player: AVAudioPlayer?
    @State private var playbackError: String?
    @State private var pendingDiscard: DictationRecoveryViewModel.RecoveryItem?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("pick up where you left off").font(KiviTheme.serif(30))
                Text("listen to a saved take, then try its transcription again. recovered words appear here for you to copy. history follows your existing settings.")
                    .font(KiviTheme.body(14)).foregroundStyle(KiviTheme.muted)
                if recovery.recoveries.isEmpty {
                    Label(recovery.isRecoveryStorageDisabled ? "recording recovery is turned off" : "no recordings to recover", systemImage: "waveform")
                        .font(KiviTheme.body(17)).padding(.vertical, 24)
                } else {
                    Picker("recording", selection: $recovery.selectedRecoveryID) {
                        ForEach(recovery.recoveries) { take in Text(take.fileName).tag(take.id as String?) }
                    }.disabled(recovery.isProcessing)
                    HStack(spacing: 10) {
                        Button("listen") { play() }.buttonStyle(KiviButton())
                        Button("stop playback") { player?.stop() }.buttonStyle(KiviButton())
                        Spacer()
                        Button("discard…") { pendingDiscard = recovery.selectedRecovery }.buttonStyle(KiviButton())
                    }.disabled(recovery.isProcessing)
                    Picker("speech engine", selection: $recovery.selectedEngine) {
                        Text("use my current engine").tag(nil as String?)
                        ForEach(recovery.availableEngines, id: \.providerId) { engine in
                            Text(engine.providerDisplayName).tag(engine.providerId as String?).disabled(!recovery.canUseForTranscription(engine))
                        }
                    }.disabled(recovery.isProcessing)
                    if let engine = recovery.resolvedEngine, engine.transcriptionModels.count > 1 {
                        Picker("model", selection: $recovery.selectedModel) {
                            Text("default model").tag(nil as String?)
                            ForEach(engine.transcriptionModels, id: \.id) { model in Text(model.displayName).tag(model.id as String?) }
                        }.disabled(recovery.isProcessing)
                    }
                    Text("uses your selected engine and existing language settings. a cloud engine sends this recording to its provider.")
                        .font(KiviTheme.body(12)).foregroundStyle(KiviTheme.muted)
                    if !recovery.canTranscribe && !recovery.isProcessing {
                        Text("this engine is not ready. choose a configured engine above, or prepare it in Settings → speech engine.")
                            .font(KiviTheme.body(13)).foregroundStyle(KiviTheme.muted)
                    }
                    HStack {
                        if recovery.isProcessing { ProgressView().controlSize(.small); Text("recovering your words…").font(KiviTheme.body(14)) }
                        Spacer()
                        Button("try transcription again") { player?.stop(); recovery.transcribe() }
                            .buttonStyle(KiviButton(primary: true)).disabled(!recovery.canTranscribe)
                    }
                }
                if let error = recovery.errorMessage ?? playbackError {
                    Text(error).font(KiviTheme.body(14)).foregroundStyle(.red).textSelection(.enabled)
                }
                if let text = recovery.recoveredText {
                    Divider()
                    Text("recovered words").font(KiviTheme.serif(23))
                    if let name = recovery.lastSavedRecoveryFileName { Text(name).font(KiviTheme.body(12)).foregroundStyle(KiviTheme.muted) }
                    Text(text).font(KiviTheme.body(16)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    HStack {
                        Button("copy") { AppModel.shared.copy(text) }.buttonStyle(KiviButton(primary: true))
                        Button("open takes") {
                            AppModel.shared.history.search = ""
                            AppModel.shared.history.source = nil
                            AppModel.shared.history.period = "all time"
                            AppModel.shared.history.kind = "all"
                            AppModel.shared.page = .record
                            ManagedAppWindowOpener.shared.open(id: "settings")
                        }.buttonStyle(KiviButton())
                    }
                }
            }.padding(30).frame(maxWidth: .infinity, alignment: .leading)
        }.foregroundStyle(KiviTheme.ink).background(KiviTheme.background)
            .preferredColorScheme(workspace.saved.appearance == "system" ? nil : workspace.saved.appearance == "light" ? .light : .dark)
            .onAppear { recovery.refreshRecoveries() }
            .onDisappear { player?.stop() }
            .onChange(of: recovery.selectedRecoveryID) { _, _ in player?.stop(); playbackError = nil }
            .sheet(item: $pendingDiscard) { take in
                VStack(alignment: .leading, spacing: 20) {
                    Text("discard this recording?").font(KiviTheme.serif(27))
                    Text(take.fileName).font(KiviTheme.body(14)).textSelection(.enabled)
                    Text("this removes the saved audio from recovery. it cannot be undone.").font(KiviTheme.body(14)).foregroundStyle(KiviTheme.muted)
                    HStack {
                        Button("cancel") { pendingDiscard = nil }.buttonStyle(KiviButton()).keyboardShortcut(.cancelAction)
                        Spacer()
                        Button("discard recording", role: .destructive) { player?.stop(); recovery.discardRecovery(take); pendingDiscard = nil }.buttonStyle(KiviButton())
                    }
                }.padding(30).frame(width: 450).foregroundStyle(KiviTheme.ink).background(KiviTheme.panel)
            }
    }
    private func play() {
        guard let url = recovery.recoveryURL else { return }
        do { player?.stop(); player = try AVAudioPlayer(contentsOf: url); player?.play(); playbackError = nil }
        catch { playbackError = "could not play this recording: \(error.localizedDescription)" }
    }
}
