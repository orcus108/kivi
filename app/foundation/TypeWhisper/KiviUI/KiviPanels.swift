import SwiftUI
import AppKit
import Combine

/// Shared outcome card for the recording pill and the main writing pad.
struct KiviNoSpeechNotice: View {
    let hasRecovery: Bool
    var retry: () -> Void
    var review: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "mic.slash").font(.system(size: 14)).foregroundStyle(KiviTheme.green)
                    .frame(width: 30, height: 30).background(KiviTheme.green.opacity(0.1), in: Circle())
                VStack(alignment: .leading, spacing: 7) {
                    Text("no speech recognised").font(KiviTheme.serif(23)).foregroundStyle(KiviTheme.ink)
                    Text(hasRecovery ? "your recording is saved for review." : "ready for another take when you are.")
                        .font(KiviTheme.body(12)).foregroundStyle(KiviTheme.muted)
                        .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Button(action: retry) { Label("try again", systemImage: "arrow.clockwise") }.buttonStyle(KiviButton(primary: true))
                if hasRecovery { Button("review recording", action: review).buttonStyle(KiviButton()) }
                Spacer(minLength: 0)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

@MainActor final class KiviAdvancedWindow {
    static let shared = KiviAdvancedWindow()
    private var panel: NSWindow?
    func show(_ section: String) {
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
