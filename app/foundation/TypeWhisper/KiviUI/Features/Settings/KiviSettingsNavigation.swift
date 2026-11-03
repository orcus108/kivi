import Foundation

/// Keep existing internal destinations working while presenting plain-language labels.
enum KiviSettingsSection: String, CaseIterable, Identifiable {
    case general, writing
    case keyboardShortcuts = "shortcuts"
    case recording = "microphone"
    case recordingIndicator = "the orb"
    case permissions
    case privacy = "privacy & data"
    case advanced = "advanced tools"
    case billing = "plan & billing"
    case account, about

    var id: String { rawValue }
    var title: String {
        switch self {
        case .keyboardShortcuts: "keyboard shortcuts"
        case .recording: "recording"
        case .recordingIndicator: "recording indicator"
        default: rawValue
        }
    }
    var icon: String {
        switch self {
        case .general: "gearshape"
        case .writing: "text.alignleft"
        case .keyboardShortcuts: "keyboard"
        case .recording: "mic"
        case .recordingIndicator: "waveform"
        case .permissions: "checkmark.shield"
        case .privacy: "lock"
        case .advanced: "slider.horizontal.3"
        case .billing: "creditcard"
        case .account: "person.crop.circle"
        case .about: "info.circle"
        }
    }
    private var keywords: String {
        switch self {
        case .general: "appearance light dark system animation motion login startup welcome demo"
        case .writing: "light cleanup hesitations repeats automatic structure format spoken lists paragraphs literal mode text dictionary shortcuts styles rules learning corrections Groq Gemini provider for you conversation model local"
        case .keyboardShortcuts: "hotkey key hold tap toggle paste copy undo workflow keyboard"
        case .recording: "microphone input device audio test level cancel Escape live typing recovery interrupted"
        case .recordingIndicator: "orb pill visibility position top bottom preview screen captures sharing sounds spoken feedback"
        case .permissions: "access microphone accessibility access recognition"
        case .privacy: "history saved takes incognito exports retention backups storage data"
        case .advanced: "engine model provider key cloud self corrections workflows file transcription audio recorder selection editing rewrite tools"
        case .billing: "plan subscription billing local"
        case .account: "workspace personal account setup"
        case .about: "version updates privacy policy kivi"
        }
    }
    func matches(_ query: String) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace)
        let searchable = title + " " + keywords
        return words.allSatisfy { searchable.localizedCaseInsensitiveContains(String($0)) }
    }
    static func resolve(_ destination: String) -> Self {
        let normalized = destination.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return allCases.first { $0.rawValue == normalized || $0.title == normalized } ?? .general
    }
}
