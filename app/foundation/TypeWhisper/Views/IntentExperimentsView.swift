import SwiftUI

struct IntentExperimentSettingsSection: View {
    @AppStorage(IntentTextPipeline.styleKey) private var style = IntentTextStyle.automatic.rawValue
    @AppStorage(IntentTextPipeline.cleanupKey) private var cleanup = true
    @AppStorage(IntentTextPipeline.structureKey) private var structure = true
    @State private var rules = IntentTextPipeline.rules()
    @State private var input = "Um, numbered list: first, meet Rohaan on Tuesday. Second, keep the budget at ₹500."
    @State private var result = ""
    @State private var explanation = ""
    @State private var bundle = "com.apple.TextEdit"
    @State private var url = ""
    @State private var includeAPI = false
    @State private var previewTask: Task<Void, Never>?
    @State private var previewID: UUID?

    var body: some View {
        Section("Text experiments") {
            Picker("Writing mode", selection: $style) {
                ForEach(IntentTextStyle.allCases) { Text($0.title).tag($0.rawValue) }
            }
            Toggle("Light cleanup", isOn: $cleanup)
            Toggle("Format explicit lists and paragraph breaks", isOn: $structure)
            Text("Cleanup removes clear um/uh hesitations and a few accidental word repeats. Emphasis, uncertainty, and quoted speech stay. Start lists with “numbered list:” or “bullet list:” and say “first … second …”. Say “new paragraph” after a sentence. Literal mode bypasses experimental and ordinary text post-processing for plain dictation.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Open local selection editor") { IntentSelectionEditor.shared.openTyped() }
        }
        Section("Rules by destination") {
            Text("The first matching rule wins in By destination mode. A rule may match an app, a website, or both. An empty website matches the whole app. Unknown destinations keep your wording. Workflow, translation, and formatted-output routes keep their own existing settings.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach($rules) { $rule in
                HStack {
                    TextField("App bundle ID (optional)", text: $rule.bundleID)
                    TextField("Website host (optional)", text: $rule.host)
                    Picker("Style", selection: $rule.style) {
                        ForEach(IntentTextStyle.allCases.filter { $0 != .automatic }) { Text($0.title).tag($0) }
                    }.labelsHidden().frame(width: 150)
                    Button(role: .destructive) {
                        let id = rule.id
                        rules.removeAll { $0.id == id }
                    } label: { Image(systemName: "minus.circle") }
                }
            }
            Button("Add destination rule") { rules.insert(.init(bundleID: "", host: "", style: .standard), at: 0) }
        }
        .onChange(of: rules) { _, value in
            if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: IntentTextPipeline.rulesKey) }
        }
        Section("Try a typed transcript") {
            Text("Uses the same spelling, cleanup, structure, and destination rules as ordinary dictation. This is a typed preview; it does not test speech recognition or insertion.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("App bundle ID", text: $bundle)
                TextField("Website URL", text: $url)
            }
            TextEditor(text: $input).font(.body.monospaced()).frame(minHeight: 90)
                .accessibilityIdentifier("intent.experiments.input")
            Toggle("Include enabled API self-correction in this preview", isOn: $includeAPI)
            HStack {
                Button("Preview") { preview() }.disabled(previewTask != nil || input.isEmpty)
                Button("Cancel") { cancel() }.disabled(previewTask == nil)
                Button("Copy result") { copyIntentText(result) }.disabled(result.isEmpty)
                Button("Copy original") { copyIntentText(input) }.disabled(input.isEmpty)
            }
            if !explanation.isEmpty { Text(explanation).font(.caption).foregroundStyle(.secondary) }
            if !result.isEmpty { Text(result).textSelection(.enabled).accessibilityIdentifier("intent.experiments.result") }
        }
        .onDisappear { cancel() }
    }

    private func cancel() {
        previewID = nil
        previewTask?.cancel(); previewTask = nil
        result = ""; explanation = "Preview cancelled"
    }

    private func preview() {
        let id = UUID(); previewID = id
        let raw = input
        let mode = IntentTextPipeline.style(bundleID: bundle, url: url)
        let api = includeAPI
        result = ""; explanation = "Processing typed text…"
        previewTask = Task { @MainActor in
            let started = ContinuousClock.now
            do {
                let processed = try await IntentDictationProcessor.process(raw, style: mode,
                    dictionary: ServiceContainer.shared.dictionaryService, useAPI: api)
                guard !Task.isCancelled, previewID == id else { return }
                result = processed.text
                explanation = "Typed preview · \(mode.title) · \(started.duration(to: .now)) · \(processed.steps.joined(separator: ", "))"
            } catch {
                guard previewID == id else { return }
                explanation = error.localizedDescription
            }
            if previewID == id { previewTask = nil }
        }
    }
}

@MainActor
func copyIntentText(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

struct IntentSelectionEditorView: View {
    @ObservedObject var editor: IntentSelectionEditor

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Edit selected text").font(.title2.bold())
                Spacer()
                Button("Check local editor") { editor.checkEditor() }.disabled(editor.busy)
            }
            Text("Ollama · llama3.2:latest · text stays on this Mac")
                .font(.caption).foregroundStyle(.secondary)
            Text(editor.isCaptured ? "Original selection" : "Sample text").font(.headline)
            TextEditor(text: $editor.source).font(.body).frame(minHeight: 105)
                .disabled(editor.isCaptured || editor.busy)
                .accessibilityIdentifier("intent.editor.source")
            Text("Instruction").font(.headline)
            TextEditor(text: $editor.instruction).frame(minHeight: 55, maxHeight: 90)
                .disabled(editor.busy || editor.listening)
                .accessibilityIdentifier("intent.editor.instruction")
            HStack {
                Button("Rewrite") { editor.rewrite() }.disabled(editor.busy || editor.listening)
                    .accessibilityIdentifier("intent.editor.rewrite")
                Button("Cancel") { editor.cancel() }.disabled(editor.isMutating)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Copy original") { copyIntentText(editor.originalForCopy) }.disabled(editor.originalForCopy.isEmpty)
            }
            Text("Preview · review before applying").font(.headline)
            TextEditor(text: $editor.result).frame(minHeight: 130)
                .disabled(editor.busy || editor.applied)
                .accessibilityIdentifier("intent.editor.result")
            Text(editor.message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("intent.editor.status")
            HStack {
                Button("Apply to captured selection") { editor.apply() }.disabled(!editor.canApply)
                    .accessibilityIdentifier("intent.editor.apply")
                Button("Undo applied edit") { editor.undo() }.disabled(!editor.canUndo)
                    .accessibilityIdentifier("intent.editor.undo")
                Spacer()
                Button("Copy result") { copyIntentText(editor.result) }.disabled(editor.result.isEmpty)
            }
        }
        .padding(22).frame(minWidth: 560, minHeight: 540)
        .onDisappear { if !editor.isMutating { editor.cancel() } }
    }
}
