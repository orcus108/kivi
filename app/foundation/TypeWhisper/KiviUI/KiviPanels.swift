import SwiftUI
import AppKit
import Combine

/// Shared outcome card for the recording pill and the main writing pad.
struct KiviNoSpeechNotice: View {
    var state: DictationViewModel.NoSpeechRetryState
    var retry: () -> Void
    var body: some View {
        VStack(spacing: 12) {
            Text(title).font(KiviTheme.medium(20)).foregroundStyle(KiviTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
            if case .ready = state {
                Button(action: retry) { Label("try again", systemImage: "arrow.clockwise") }
                    .buttonStyle(KiviButton(primary: true)).help("Transcribe this saved recording again")
            } else if state == .checking {
                Text("listening to the saved audio").font(KiviTheme.body(13)).foregroundStyle(KiviTheme.muted)
            } else {
                Text("please record again").font(KiviTheme.body(13)).foregroundStyle(KiviTheme.muted)
            }
        }.frame(maxWidth: .infinity)
    }
    private var title: String {
        switch state {
        case .checking: "checking your recording…"
        case .empty: "no speech found"
        case .failed: "couldn’t check recording"
        default: "no speech recognised"
        }
    }
}

struct KiviInsertionRecoveryNotice: View {
    let shortcut: String?
    var copy: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("your text is ready").font(KiviTheme.medium(24)).foregroundStyle(KiviTheme.green)
            if let shortcut {
                (Text("press ").foregroundColor(KiviTheme.muted)
                 + Text(shortcut).foregroundColor(KiviTheme.ink)
                 + Text(" to paste").foregroundColor(KiviTheme.muted))
                    .font(KiviTheme.body(15))
            } else {
                Button("copy your text", action: copy).buttonStyle(KiviButton(primary: true))
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

@MainActor final class KiviAdvancedWindow {
    static let shared = KiviAdvancedWindow()
    private var panel: NSWindow?
    func show(_ section: String) {
        if section == "recovery" { KiviRecoveryWindow.shared.show(); return }
        let mapping: [String: SettingsTab] = ["general": .general, "appearance": .appearance, "dictionary": .dictionary, "shortcuts": .snippets, "models": .integrations, "microphone": .dictation, "hotkeys": .hotkeys, "recovery": .dictationRecovery, "files": .fileTranscription, "recorder": .recorder, "workflows": .workflows, "privacy": .advanced]
        let target = mapping[section] ?? .general
        if panel == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "Kivi · advanced tools"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(initialTab: target).tint(KiviTheme.green))
            window.center(); panel = window
        }
        NSApp.activate(ignoringOtherApps: true); panel?.makeKeyAndOrderFront(nil)
        // Reassert the destination after the opening click/menu event completes.
        DispatchQueue.main.async { SettingsNavigationCoordinator.shared.navigate(to: target) }
    }
}

struct KiviSelectionEditorView: View {
    @ObservedObject var editor: IntentSelectionEditor
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { Image(systemName: "sparkles").foregroundStyle(KiviTheme.green); Text("hey kivi").font(KiviTheme.serif(35)); Spacer(); Text("on your Mac").font(KiviTheme.mono(11)).foregroundStyle(KiviTheme.muted) }
            Text(editor.isCaptured ? "your selection, with the original kept safe." : "a thought into words. or your words, a little differently.").font(KiviTheme.body(14)).foregroundStyle(KiviTheme.muted)
            HStack(alignment: .top, spacing: 18) {
                editorColumn("original", text: $editor.source, locked: editor.isCaptured || editor.busy)
                editorColumn("preview", text: $editor.result, locked: editor.busy)
            }
            Text("tell kivi what to do").font(KiviTheme.mono(11)).foregroundStyle(KiviTheme.muted)
            KiviField(title: "make it shorter. keep the dates and numbers.", text: $editor.instruction).disabled(editor.busy || editor.listening)
            HStack(spacing: 8) {
                ForEach(["make it clearer", "make it concise", "turn into a list"], id: \.self) { request in Button(request) { editor.instruction = request }.buttonStyle(KiviButton()).disabled(editor.busy) }
                Spacer()
                if editor.listening { Button("finish instruction") { DictationViewModel.shared.stopSelectionInstruction() }.buttonStyle(KiviButton(primary: true)) }
            }
            Text(!editor.result.isEmpty && !editor.hasCurrentPreview && !editor.busy ? "Input changed. Rewrite again to create a current preview." : editor.message).font(KiviTheme.body(13)).foregroundStyle(KiviTheme.muted).textSelection(.enabled).frame(minHeight: 38, alignment: .topLeading)
            HStack {
                Button("copy original") { AppModel.shared.copy(editor.originalForCopy) }.buttonStyle(KiviButton())
                Button("undo") { editor.undo() }.buttonStyle(KiviButton()).disabled(!editor.canUndo)
                Spacer()
                if editor.busy { ProgressView().controlSize(.small); Button("cancel") { editor.cancel() }.buttonStyle(KiviButton()) }
                else { Button("rewrite") { editor.rewrite() }.buttonStyle(KiviButton(primary: true)).disabled(editor.source.isEmpty || editor.instruction.isEmpty || editor.listening) }
                Button("copy") { AppModel.shared.copy(editor.result) }.buttonStyle(KiviButton()).disabled(!editor.hasCurrentPreview)
                if editor.isCaptured { Button("apply to selection") { editor.apply() }.buttonStyle(KiviButton(primary: true)).disabled(!editor.canApply) }
                else { Button("use in writing pad") { AppModel.shared.draft = editor.result; AppModel.shared.page = .record }.buttonStyle(KiviButton(primary: true)).disabled(!editor.hasCurrentPreview) }
            }
        }.padding(30).frame(minWidth: 780, minHeight: 510).background(KiviBackground()).foregroundStyle(KiviTheme.ink).preferredColorScheme(AppModel.shared.saved.appearance == "light" ? .light : .dark)
    }
    private func editorColumn(_ title: String, text: Binding<String>, locked: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(KiviTheme.mono(11)).foregroundStyle(title == "preview" ? KiviTheme.green : KiviTheme.muted)
            KiviTextEditor(text: text).padding(12).frame(height: 180).background(KiviTheme.panel, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(title == "preview" ? KiviTheme.green.opacity(0.25) : KiviTheme.line)).disabled(locked)
        }
    }
}
