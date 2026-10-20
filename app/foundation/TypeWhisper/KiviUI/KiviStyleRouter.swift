import Foundation
import AppKit

struct KiviStyleConfiguration: Codable {
    var styles: [WritingStyle] = WritingStyle.defaults
    var overrides: [String: WritingStyle] = [:]
    var enabled: Set<String> = []
}
/// Explicitly saved style choices use the existing local editor. Unconfigured
/// categories keep the foundation's processing path and latency unchanged.
@MainActor enum KiviStyleRouter {
    static let key = "kiviCombinedWritingStyles"
    static func load(defaults: UserDefaults = .standard) -> KiviStyleConfiguration {
        guard let data = defaults.data(forKey: key), let config = try? JSONDecoder().decode(KiviStyleConfiguration.self, from: data) else { return .init() }
        return config
    }
    static func save(_ style: WritingStyle, app: String?, defaults: UserDefaults = .standard) {
        var config = load(defaults: defaults)
        if let app { config.overrides[app] = style; config.enabled.insert("app:" + app) }
        else { if let i = config.styles.firstIndex(where: { $0.id == style.id }) { config.styles[i] = style }; config.enabled.insert(style.id) }
        if let data = try? JSONEncoder().encode(config) { defaults.set(data, forKey: key) }
    }
    static func resolved(appName: String?, bundleID: String?, defaults: UserDefaults = .standard) -> WritingStyle? {
        let config = load(defaults: defaults)
        let name = appName ?? bundleID.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)?.deletingPathExtension().lastPathComponent }
        if let name, config.enabled.contains("app:" + name), let style = config.overrides[name] { return style }
        let style = config.styles.first { style in style.apps.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.contains(name ?? "") } ?? config.styles.first { $0.id == "other" }
        return style.flatMap { config.enabled.contains($0.id) ? $0 : nil }
    }
    static func process(_ text: String, appName: String?, bundleID: String?, protectedTerms: [String], defaults: UserDefaults = .standard, client: any IntentTextEditing = IntentLocalTextEditor()) async -> (text: String, step: String?) {
        guard let style = resolved(appName: appName, bundleID: bundleID, defaults: defaults) else { return (text, nil) }
        do {
            let result = try await client.rewrite(source: text, instruction: "Rewrite in a \(style.mode) style. \(style.rules) Preserve all facts, names, numbers and commitments. Return only the rewritten text.")
            guard IntentTextPipeline.preservesSpellings(before: text, after: result, terms: protectedTerms) else { return (text, "Style retained original: protected spelling changed") }
            return (result, "Style: \(style.name) · \(style.mode)")
        } catch {
            if !AppConstants.isRunningTests { AppModel.shared.notify("Style unavailable; your original wording was kept. \(error.localizedDescription)") }
            return (text, "Style unavailable: original retained")
        }
    }
}
