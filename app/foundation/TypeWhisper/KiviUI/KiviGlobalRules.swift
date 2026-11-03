import SwiftUI

struct KiviGlobalRule: Codable, Identifiable, Equatable {
    var id = UUID()
    var text: String
}

@MainActor enum KiviGlobalRules {
    static let key = "kiviGlobalWritingRules"
    static let suggestions = [
        "Remove em dashes from my writing",
        "Fix my grammar without changing my meaning",
        "Use British English spelling",
        "Write numbers as digits",
        "Use short sentences",
        "Format dates and times like 10 October 2026, 8:00 PM. Never invent missing dates or times."
    ]
    static func load(defaults: UserDefaults = .standard) -> [KiviGlobalRule] {
        guard let data = defaults.data(forKey: key), let rules = try? JSONDecoder().decode([KiviGlobalRule].self, from: data) else { return [] }
        return rules
    }
    static func save(_ rules: [KiviGlobalRule], defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(rules) else { return }
        defaults.set(data, forKey: key)
    }
    static func validation(_ text: String, editing: UUID?, rules: [KiviGlobalRule]) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Write a rule first." }
        if trimmed.count > 500 { return "Keep each rule under 500 characters." }
        if rules.contains(where: { $0.id != editing && $0.text.caseInsensitiveCompare(trimmed) == .orderedSame }) { return "This rule is already added." }
        return nil
    }
}

@MainActor final class KiviGlobalRulesEditor: ObservableObject {
    @Published var rules: [KiviGlobalRule]
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults; rules = KiviGlobalRules.load(defaults: defaults)
    }
    @Published var editing = false
    @Published var editingID: UUID?
    @Published var draft = ""
    @Published var removed: (rule: KiviGlobalRule, index: Int)?
    var validation: String? { KiviGlobalRules.validation(draft, editing: editingID, rules: rules) }
    var changed: Bool { editingID.flatMap { id in rules.first { $0.id == id }?.text } != draft.trimmingCharacters(in: .whitespacesAndNewlines) }
    func begin(_ rule: KiviGlobalRule?) { editingID = rule?.id; draft = rule?.text ?? ""; editing = true }
    func cancel() { editing = false }
    func save() {
        guard validation == nil else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = editingID, let index = rules.firstIndex(where: { $0.id == id }) { rules[index].text = text }
        else { rules.append(.init(text: text)) }
        KiviGlobalRules.save(rules, defaults: defaults); cancel()
    }
    func remove() {
        guard let id = editingID, let index = rules.firstIndex(where: { $0.id == id }) else { return }
        removed = (rules[index], index); rules.remove(at: index); KiviGlobalRules.save(rules, defaults: defaults); cancel()
    }
    func undo() {
        guard let removed else { return }
        rules.insert(removed.rule, at: min(removed.index, rules.count)); KiviGlobalRules.save(rules, defaults: defaults); self.removed = nil
    }
}

struct KiviGlobalRulesView: View {
    @ObservedObject var editor: KiviGlobalRulesEditor
    @State private var showDetails = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Text("global rules").font(KiviTheme.medium(18))
                Button { showDetails.toggle() } label: {
                    Image(systemName: "info.circle").font(.system(size: 13)).foregroundStyle(KiviTheme.muted)
                        .frame(width: 24, height: 28).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("how global rules work")
                    .accessibilityValue(showDetails ? "expanded" : "collapsed")
                    .popover(isPresented: $showDetails, arrowEdge: .top) {
                        Text("Applied across apps. App instructions take priority. Literal dictation stays untouched.")
                            .font(KiviTheme.body(13)).foregroundStyle(KiviTheme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(16).frame(width: 270, alignment: .leading).background(KiviTheme.panel)
                            .onExitCommand { showDetails = false }
                    }
                Spacer()
                Button { editor.begin(nil) } label: { Label("add a rule", systemImage: "plus") }
                    .buttonStyle(KiviRuleActionStyle()).disabled(editor.editing)
            }
            if editor.rules.isEmpty {
                Text("No rules yet. Add your own, or start with a suggestion.")
                    .font(KiviTheme.body(14)).foregroundStyle(KiviTheme.muted).padding(.vertical, 6)
            } else {
                VStack(spacing: 0) {
                    ForEach(editor.rules) { rule in
                        KiviSavedRuleRow(editor: editor, rule: rule)
                        if rule.id != editor.rules.last?.id {
                            Rectangle().fill(KiviTheme.line).frame(height: 1)
                        }
                    }
                }
            }
            if editor.removed != nil {
                HStack {
                    Text("rule removed").font(KiviTheme.body(13)).foregroundStyle(KiviTheme.muted)
                    Button("undo", action: editor.undo).buttonStyle(KiviRuleActionStyle())
                }
            }
        }.foregroundStyle(KiviTheme.ink)
    }
}

private struct KiviSavedRuleRow: View {
    @ObservedObject var editor: KiviGlobalRulesEditor
    let rule: KiviGlobalRule
    @FocusState private var rowFocused: Bool
    @FocusState private var fieldFocused: Bool
    private var isEditing: Bool { editor.editing && editor.editingID == rule.id }
    var body: some View {
        KiviHoverRow { hover in
            VStack(alignment: .leading, spacing: 8) {
                if isEditing {
                    TextField("How should Kivi write?", text: $editor.draft, axis: .vertical)
                        .textFieldStyle(.plain).font(KiviTheme.body(15)).lineLimit(1...6)
                        .focused($fieldFocused).accessibilityLabel("rule instructions")
                        .padding(.vertical, 6)
                        .overlay(alignment: .bottom) { Rectangle().fill(KiviTheme.green.opacity(0.7)).frame(height: 1) }
                        .onSubmit { if editor.validation == nil && editor.changed { editor.save() } }
                        .onExitCommand(perform: editor.cancel)
                    if let validation = editor.validation {
                        Text(validation).font(KiviTheme.body(13)).foregroundStyle(KiviTheme.muted)
                    }
                    HStack {
                        Spacer()
                        Button("cancel", action: editor.cancel).buttonStyle(KiviRuleActionStyle())
                        Button("save", action: editor.save).buttonStyle(KiviButton(primary: true))
                            .disabled(editor.validation != nil || !editor.changed)
                    }
                } else {
                    HStack {
                        Button { editor.begin(rule) } label: {
                            Text(rule.text).font(KiviTheme.body(15)).multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain).focused($rowFocused).accessibilityLabel("edit rule: \(rule.text)")
                        HStack(spacing: 4) {
                            IconButton(icon: "pencil", label: "edit rule: \(rule.text)") { editor.begin(rule) }
                            IconButton(icon: "trash", label: "remove rule: \(rule.text)") { editor.begin(rule); editor.remove() }
                        }.opacity(hover.wrappedValue || rowFocused ? 1 : 0)
                    }.disabled(editor.editing)
                }
            }.frame(minHeight: 55).padding(.vertical, 8).contentShape(Rectangle())
                .onHover { hover.wrappedValue = $0 }
                .onChange(of: isEditing) { _, editing in if editing { fieldFocused = true } }
        }
    }
}


struct KiviGlobalRuleDialog: View {
    @ObservedObject var editor: KiviGlobalRulesEditor
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text(editor.editingID == nil ? "add a rule" : "edit rule").font(KiviTheme.medium(20))
                Spacer()
                IconButton(icon: "xmark", label: "close rule editor", action: editor.cancel)
            }
            TextField("How should Kivi write?", text: $editor.draft, axis: .vertical)
                .textFieldStyle(.plain).font(KiviTheme.body(16)).lineLimit(3...7).focused($focused)
                .padding(14).background(KiviTheme.background, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(focused ? KiviTheme.green.opacity(0.6) : KiviTheme.line))
                .accessibilityLabel("rule instructions").onExitCommand(perform: editor.cancel)
            if !editor.draft.isEmpty, let validation = editor.validation {
                Text(validation).font(KiviTheme.body(13)).foregroundStyle(KiviTheme.muted)
            }
            if editor.editingID == nil {
                VStack(alignment: .leading, spacing: 4) {
                    Text("suggestions").font(KiviTheme.body(12)).foregroundStyle(KiviTheme.muted).padding(.bottom, 4)
                    ForEach(KiviGlobalRules.suggestions.filter { suggestion in !editor.rules.contains { $0.text == suggestion } }, id: \.self) { suggestion in
                        Button { editor.draft = suggestion; focused = true } label: {
                            HStack { Text(suggestion).font(KiviTheme.body(13)).multilineTextAlignment(.leading); Spacer(); Image(systemName: "plus").font(.system(size: 10)) }
                                .padding(.vertical, 6).contentShape(Rectangle())
                        }.buttonStyle(KiviRuleRowStyle())
                    }
                }
            }
            HStack(spacing: 10) {
                if editor.editingID != nil {
                    Button("remove", action: editor.remove).buttonStyle(KiviRuleActionStyle()).accessibilityLabel("remove rule")
                }
                Spacer()
                Button("cancel", action: editor.cancel).buttonStyle(KiviRuleActionStyle()).keyboardShortcut(.cancelAction)
                Button("save", action: editor.save).buttonStyle(KiviButton(primary: true)).disabled(editor.validation != nil || !editor.changed)
            }
        }.padding(28).foregroundStyle(KiviTheme.ink)
            .onAppear { focused = true }
            .onExitCommand(perform: editor.cancel)
    }
}

private struct KiviRuleRowStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(KiviTheme.ink.opacity(configuration.isPressed ? 0.08 : (hovering ? 0.04 : 0)))
            .onHover { hovering = $0 }
    }
}

private struct KiviRuleActionStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(KiviTheme.medium(14))
            .foregroundStyle(hovering ? KiviTheme.ink : KiviTheme.muted)
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(KiviTheme.ink.opacity(configuration.isPressed ? 0.08 : (hovering ? 0.04 : 0)), in: RoundedRectangle(cornerRadius: 6))
            .onHover { hovering = $0 }
    }
}
