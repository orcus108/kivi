import Foundation

// Override Bundle.main's localization to support in-app language switching.
// This must happen before TypeWhisperApp.main() so that all String(localized:)
// calls resolve using the user's preferred language, not the system language.

private class OverrideBundle: Bundle, @unchecked Sendable {
    override func localizedString(forKey key: String, value: String?, table tableName: String?) -> String {
        guard let lang = UserDefaults.standard.string(forKey: UserDefaultsKeys.preferredAppLanguage) else {
            return super.localizedString(forKey: key, value: value, table: tableName)
        }

        // Try language-specific .lproj first, then fall back to Base.lproj
        // (English is the source language and may live in Base.lproj or directly in Resources)
        let candidates = [lang, "Base"]
        for candidate in candidates {
            if let path = Bundle.main.path(forResource: candidate, ofType: "lproj"),
               let bundle = Bundle(path: path) {
                let result = bundle.localizedString(forKey: key, value: value, table: tableName)
                // If the bundle returned the key itself, the string wasn't found — try next
                if result != key { return result }
            }
        }

        // If the preferred language is the source language (English), return the key
        // as-is since it IS the English string for String(localized:).
        if lang == "en" {
            return value ?? key
        }

        return super.localizedString(forKey: key, value: value, table: tableName)
    }
}

// Import only the sanitized, one-time preference snapshot into this app's domain.
if !UserDefaults.standard.bool(forKey: "kiviCombinedBootstrapped"),
   let path = Bundle.main.object(forInfoDictionaryKey: "KiviCombinedPreferences") as? String,
   let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
   let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
    for (key, value) in values { UserDefaults.standard.set(value, forKey: key) }
    UserDefaults.standard.set(false, forKey: SelfCorrectionService.enabledKey)
    UserDefaults.standard.set(true, forKey: UserDefaultsKeys.setupWizardCompleted)
    UserDefaults.standard.set(true, forKey: "kiviCombinedBootstrapped")
}
// Apply the requested Kivi sound set once, preserving the sound on/off switch.
if Bundle.main.bundleIdentifier == "dev.vedant.kivi-combined",
   !UserDefaults.standard.bool(forKey: "kiviOriginalSoundsV1") {
    UserDefaults.standard.set("bundled:kivi_start", forKey: UserDefaultsKeys.soundRecordingStarted)
    UserDefaults.standard.set("bundled:kivi_complete", forKey: UserDefaultsKeys.soundTranscriptionSuccess)
    UserDefaults.standard.set("bundled:kivi_error", forKey: UserDefaultsKeys.soundError)
    UserDefaults.standard.set(true, forKey: "kiviOriginalSoundsV1")
}
object_setClass(Bundle.main, OverrideBundle.self)

if #available(macOS 15.0, *) {
    TypeWhisperApp<SuppressedManagedAppWindowSceneConfiguration>.main()
} else {
    TypeWhisperApp<LegacyManagedAppWindowSceneConfiguration>.main()
}
