import SwiftUI
import AppKit

struct SelfCorrectionSettingsSection: View {
    @AppStorage(SelfCorrectionService.enabledKey) private var liveCleanupEnabled = true
    @AppStorage(SelfCorrectionService.providerKey) private var provider = "groq"
    @State private var keyInput = ""
    @State private var input = "I want to book—sorry, I want to cancel the booking."
    @State private var typedResult: SelfCorrectionResult?
    @State private var task: Task<Void, Never>?
    @State private var runID = UUID()
    @State private var status = ""

    var body: some View {
        Section("Spoken self-correction") {
            Toggle("Enable spoken self-correction", isOn: $liveCleanupEnabled)
            Picker("Cleanup provider", selection: $provider) {
                Text("Groq - GPT-OSS 20B").tag("groq")
                Text("Gemini 3.5 Flash-Lite").tag("gemini")
            }.onChange(of: provider) { _, _ in keyInput = ""; cancel("Provider changed") }
            Text("Groq receives transcript text only when Kivi detects a possible spoken correction. Audio stays on this Mac. If cleanup fails, Kivi keeps the original text. Turn this off to skip API cleanup.")
                .font(.caption).foregroundStyle(.secondary)
            SecureField("API key for selected provider (replace only)", text: $keyInput)
            Button("Save key") {
                do { try SelfCorrectionService.saveGeminiKey(keyInput, useGroq: provider == "groq"); keyInput = ""; status = "Key saved" }
                catch { status = "Could not save key" }
            }.disabled(keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Text("Try a typed transcript")
            TextEditor(text: $input)
                .font(.body).frame(height: 85)
                .accessibilityLabel("Self-correction input")
                .onChange(of: input) { _, _ in cancel("Input changed. Run cleanup again.") }
            HStack {
                Button("Try cleanup") { run() }
                    .disabled(task != nil || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if task != nil { Button("Cancel") { cancel("Cancelled. Original retained.") } }
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            if let typedResult { resultView(typedResult, label: "Typed result") }
            Text("Cleanup can still remove meaningful words. Compare the result with the original; use Copy original to recover it. Typed examples test cleanup only, not speech recognition.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onDisappear { cancel("") }
    }

    private func resultView(_ result: SelfCorrectionResult, label: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.headline)
            Text("Original: \(result.rawText)").textSelection(.enabled)
            Text("Result: \(result.text)").textSelection(.enabled)
                .accessibilityLabel("\(label): \(result.text)")
            Text(String(format: "Cleanup wait: %.2f seconds", result.elapsedSeconds))
                .font(.caption).foregroundStyle(.secondary)
            if let reason = result.fallbackReason {
                Text("Original retained: \(reason)").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Copy original") { copy(result.rawText) }
                Button("Copy result") { copy(result.text) }
            }
        }
    }

    private func run() {
        let id = UUID()
        runID = id
        let raw = input
        typedResult = nil
        status = "Cleaning self-corrections…"
        task = Task { @MainActor in
            do {
                guard let key = SelfCorrectionService.loadKey(useGroq: provider == "groq") else { status = "Save a key for this provider first"; task = nil; return }
                let result = try await SelfCorrectionService(apiKey: key, useGroq: provider == "groq").clean(raw)
                guard !Task.isCancelled, runID == id else { return }
                typedResult = result
                status = result.fallbackReason == nil ? "Finished" : "Original retained"
                task = nil
            } catch {
                guard runID == id else { return }
                status = "Cancelled. Original retained."
                task = nil
            }
        }
    }

    private func cancel(_ message: String) {
        task?.cancel()
        task = nil
        runID = UUID()
        typedResult = nil
        status = message
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
