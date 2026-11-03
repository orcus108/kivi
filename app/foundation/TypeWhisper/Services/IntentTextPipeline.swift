import Foundation

enum IntentTextStyle: String, Codable, CaseIterable, Identifiable {
    case automatic, standard, conversation, document, literal
    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: "By destination"
        case .standard: "Keep my wording"
        case .conversation: "Conversation"
        case .document: "Document"
        case .literal: "Literal"
        }
    }
}

struct IntentDestinationRule: Codable, Equatable, Identifiable {
    var id = UUID()
    var bundleID: String
    var host: String
    var style: IntentTextStyle

    func matches(bundleID: String?, url: String?) -> Bool {
        guard self.bundleID.isEmpty || self.bundleID == bundleID else { return false }
        if host.isEmpty { return !self.bundleID.isEmpty }
        guard let actual = url.flatMap({ URL(string: $0)?.host })?.lowercased() else { return false }
        let domain = host.lowercased()
        return actual == domain || actual.hasSuffix("." + domain)
    }
}

/// Shared by typed preview and ordinary dictation. No inference or external actions.
enum IntentTextPipeline {
    static let styleKey = "intentTextStyle"
    static let cleanupKey = "intentLightCleanup"
    static let structureKey = "intentAutomaticStructure"
    static let rulesKey = "intentDestinationRules"

    static var defaultRules: [IntentDestinationRule] {
        [
            .init(bundleID: "com.apple.Terminal", host: "", style: .literal),
            .init(bundleID: "com.googlecode.iterm2", host: "", style: .literal),
            .init(bundleID: "com.microsoft.VSCode", host: "", style: .literal),
            .init(bundleID: "com.todesktop.230313mzl4w4u92", host: "", style: .literal),
            .init(bundleID: "com.apple.dt.Xcode", host: "", style: .literal),
            .init(bundleID: "", host: "docs.google.com", style: .document),
            .init(bundleID: "", host: "web.whatsapp.com", style: .conversation),
            .init(bundleID: "", host: "chatgpt.com", style: .conversation),
            .init(bundleID: "com.apple.iChat", host: "", style: .conversation),
            .init(bundleID: "net.whatsapp.WhatsApp", host: "", style: .conversation),
            .init(bundleID: "com.apple.TextEdit", host: "", style: .document),
            .init(bundleID: "com.apple.iWork.Pages", host: "", style: .document)
        ]
    }

    static func rules(defaults: UserDefaults = .standard) -> [IntentDestinationRule] {
        guard let data = defaults.data(forKey: rulesKey),
              let rules = try? JSONDecoder().decode([IntentDestinationRule].self, from: data) else { return defaultRules }
        return rules
    }

    static func style(bundleID: String?, url: String?, defaults: UserDefaults = .standard) -> IntentTextStyle {
        let manual = IntentTextStyle(rawValue: defaults.string(forKey: styleKey) ?? "automatic") ?? .automatic
        if manual != .automatic { return manual }
        return rules(defaults: defaults).first { $0.matches(bundleID: bundleID, url: url) && $0.style != .automatic }?.style ?? .standard
    }

    static func enabled(_ key: String, defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }

    static func transform(_ text: String, style: IntentTextStyle, cleanup: Bool, structure: Bool, protectedTerms: [String] = []) -> String {
        guard style != .literal else { return text }
        var result = text
        if cleanup { result = lightCleanup(result, protectedTerms: protectedTerms) }
        if structure { result = structured(result, style: style) }
        return preservesSpellings(before: text, after: result, terms: protectedTerms) ? result : text
    }

    // Exact preferred spellings already present must survive every cleanup pass.
    static func preservesSpellings(before: String, after: String, terms: [String]) -> Bool {
        terms.allSatisfy { term in
            guard !term.isEmpty else { return true }
            let pattern = #"(?<![\p{L}\p{N}_])"# + NSRegularExpression.escapedPattern(for: term) + #"(?![\p{L}\p{N}_])"#
            guard let expression = try? NSRegularExpression(pattern: pattern) else { return true }
            let original = expression.numberOfMatches(in: before, range: NSRange(before.startIndex..., in: before))
            let remaining = expression.numberOfMatches(in: after, range: NSRange(after.startIndex..., in: after))
            return original == 0 || remaining > 0
        }
    }

    private static func replacing(_ text: String, _ pattern: String, _ template: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return text }
        return expression.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    static func lightCleanup(_ text: String, protectedTerms: [String] = []) -> String {
        // Quoted speech and code are literal, including ambiguous unmatched quotes.
        guard !text.contains("\""), !text.contains("“"), !text.contains("`"), !text.contains("‘"),
              text.range(of: #"(?<![\p{L}])'[^']+'(?![\p{L}])"#, options: .regularExpression) == nil else { return text }
        var result = text
        // Only unambiguous hesitation sounds, with comma/space boundaries. Never
        // remove like, actually, well, maybe, or emphatic very/so/really repetitions.
        var previous: String
        repeat {
            previous = result
            result = replacing(result, #"(?i)(^|[.!?]\s+)(?:um|uh|erm),\s*"#, "$1")
            result = replacing(result, #"(?i),\s*(?:um|uh|erm),\s*"#, " ")
            result = replacing(result, #"(?i)\b(I|the|a|an|to)\s+\1\b"#, "$1")
        } while result != previous
        return preservesSpellings(before: text, after: result, terms: protectedTerms) ? result : text
    }

    static func structured(_ text: String, style: IntentTextStyle) -> String {
        guard !text.contains("\""), !text.contains("“"), !text.contains("`") else { return text }
        var result = replacing(text, #"(?i)([.!?])\s+new paragraph[,.]?\s+"#, "$1\n\n")
        guard let prefix = result.range(of: #"(?i)^(?:numbered list|bullet list|list items|make a list)\s*[:.]\s*"#, options: .regularExpression) else { return result }
        let heading = String(result[prefix]).lowercased()
        let body = String(result[prefix.upperBound...])
        let ordinals = ["first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth"]
        let pattern = #"(?i)(?:^|[;.!?]\s+)(first|second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth)[,:]?\s+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return result }
        let matches = regex.matches(in: body, range: NSRange(body.startIndex..., in: body))
        guard matches.count >= 2, matches.count <= 10, matches.first?.range.location == 0 else { return result }
        var items: [String] = []
        for (index, match) in matches.enumerated() {
            guard let marker = Range(match.range(at: 1), in: body), body[marker].lowercased() == ordinals[index] else { return result }
            let end = index + 1 < matches.count ? matches[index + 1].range.location : body.utf16.count
            let start = NSMaxRange(match.range)
            guard end > start, let itemRange = Range(NSRange(location: start, length: end - start), in: body) else { return result }
            let item = String(body[itemRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !item.isEmpty else { return result }
            items.append(item)
        }
        let numbered = heading.hasPrefix("numbered") || (!heading.hasPrefix("bullet") && style == .document)
        result = items.enumerated().map { numbered ? "\($0.offset + 1). \($0.element)" : "• \($0.element)" }.joined(separator: "\n")
        return result
    }
}

struct IntentProcessedText {
    let text: String
    let steps: [String]
    let usedAPI: Bool
    let correctionIDs: Set<UUID>
}

@MainActor
enum IntentDictationProcessor {
    static func process(_ raw: String, style: IntentTextStyle, dictionary: DictionaryService,
                        useAPI: Bool = true, defaults: UserDefaults = .standard) async throws -> IntentProcessedText {
        try Task.checkCancellation()
        guard style != .literal else { return .init(text: raw, steps: ["Literal"], usedAPI: false, correctionIDs: []) }
        var ids = Set<UUID>()
        var text = dictionary.previewCorrections(to: raw, appliedCorrectionIDs: &ids)
        var steps = text == raw ? [] : ["Preferred spellings"]
        let terms = dictionary.vocabularyForPrompt(limit: .max)
        var usedAPI = false
        if useAPI, defaults.object(forKey: SelfCorrectionService.enabledKey) as? Bool ?? true,
           SelfCorrectionService.hasRepairCue(text), let key = SelfCorrectionService.selectedKey {
            usedAPI = true
            let cleaned = try await SelfCorrectionService(apiKey: key, useGroq: SelfCorrectionService.groqSelected).clean(text)
            try Task.checkCancellation()
            if cleaned.fallbackReason == nil, IntentTextPipeline.preservesSpellings(before: text, after: cleaned.text, terms: terms) {
                text = cleaned.text
                steps.append("Spoken self-correction")
            } else { steps.append("Self-correction: original retained") }
        }
        let cleaned = IntentTextPipeline.transform(text, style: style,
            cleanup: IntentTextPipeline.enabled(IntentTextPipeline.cleanupKey, defaults: defaults),
            structure: IntentTextPipeline.enabled(IntentTextPipeline.structureKey, defaults: defaults), protectedTerms: terms)
        if cleaned != text { steps.append("Local cleanup / structure") }
        return .init(text: cleaned, steps: steps, usedAPI: usedAPI, correctionIDs: ids)
    }
}
