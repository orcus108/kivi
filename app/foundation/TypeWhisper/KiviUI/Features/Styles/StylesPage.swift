import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct StylesPage: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @StateObject private var globalRules = KiviGlobalRulesEditor()
    @State private var creatingGroup = false
    @State private var groupName = ""
    @State private var appSearch = ""
    @State private var dialogHeight: CGFloat = 400
    @State private var editing: WritingStyle?
    @State private var editingApp: String?
    @State private var showAppPicker = false
    @ObservedObject private var settings = SettingsViewModel.shared
    @State private var autoDetect = SettingsViewModel.shared.languageSelection == .auto
    @State private var secondLanguage = "none"
    @State private var showLanguagePicker = false
    @State private var showSecondLanguagePicker = false
    @State private var showApps = false
    @State private var showLanguage = false
    @FocusState private var languageDialogFocused: Bool
    @State private var hoveredStyleIcon: String?
    @State private var hoveredStyle: String?
    @State private var hoveredApp: String?

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .trailing) {
                ScrollView {
                    PageContent {
                        if showApps { appManagementPage } else { overview }
                    }
                }.disabled(drawerIsOpen || modalIsOpen)
                    .accessibilityHidden(drawerIsOpen || modalIsOpen)
                if drawerIsOpen {
                    Color.black.opacity(0.35).transition(.opacity).onTapGesture { closeDrawer() }.accessibilityHidden(true)
                    if let editing {
                        StyleDetail(style: editing, appName: editingApp, styles: model.saved.styles, onClose: closeDrawer, onSave: { updated in
                            model.saveStyle(updated, app: editingApp)
                            self.editing = updated
                        }, onOpenApp: openApp, onDelete: {
                            model.deleteStyleGroup(editing.id); closeDrawer()
                        }, onReset: {
                            if let app = editingApp { model.resetAppStyle(app) }; closeDrawer()
                        }, overrideApps: Set(model.saved.appOverrides.keys), hasOverride: editingApp.map { model.saved.appOverrides[$0] != nil } ?? false)
                        .id(editingApp ?? editing.id)
                        .frame(width: min(700, geometry.size.width))
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                if showLanguage || (globalRules.editing && globalRules.editingID == nil) {
                    ZStack {
                        Color.black.opacity(0.5).contentShape(Rectangle())
                            .onTapGesture(perform: dismissModal).accessibilityHidden(true)
                        ScrollView {
                            VStack(spacing: 0) {
                                if showLanguage { languageCard }
                                else { KiviGlobalRuleDialog(editor: globalRules) }
                            }.fixedSize(horizontal: false, vertical: true).background {
                                GeometryReader { content in
                                    Color.clear
                                        .onAppear { dialogHeight = content.size.height }
                                        .onChange(of: content.size.height) { _, height in dialogHeight = height }
                                }
                            }
                        }.scrollBounceBehavior(.basedOnSize)
                            .frame(width: min(520, max(280, geometry.size.width - 48)), height: min(dialogHeight, max(200, geometry.size.height - 48)))
                            .background(KiviTheme.panel, in: RoundedRectangle(cornerRadius: 16))
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                            .overlay(RoundedRectangle(cornerRadius: 16).stroke(KiviTheme.line))
                            .shadow(color: .black.opacity(0.25), radius: 24, y: 10)
                            .padding(24)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.opacity).onExitCommand(perform: dismissModal)
                }
                if creatingGroup {
                    libraryFormOverlay(reduceMotion: model.saved.reduceMotion || systemReduceMotion, onDismiss: { creatingGroup = false }) {
                        VStack(alignment: .leading, spacing: 22) {
                            Text("new group").font(KiviTheme.medium(22))
                            TextField("group name", text: $groupName).textFieldStyle(.plain).font(KiviTheme.body(19))
                                .padding(.vertical, 10).overlay(alignment: .bottom) { Rectangle().fill(KiviTheme.line).frame(height: 1) }
                                .accessibilityLabel("group name")
                            Text("Add apps and writing instructions after creating your group.").font(KiviTheme.body(14)).foregroundStyle(KiviTheme.muted)
                            if !groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !validGroupName {
                                Text("Choose a different group name.").font(KiviTheme.body(13)).foregroundStyle(KiviTheme.muted)
                            }
                            HStack {
                                Spacer()
                                Button("cancel") { creatingGroup = false }.buttonStyle(KiviButton()).keyboardShortcut(.cancelAction)
                                Button("create group") {
                                    let group = WritingStyle(id: UUID().uuidString, name: groupName.trimmingCharacters(in: .whitespacesAndNewlines), subtitle: "", mode: "balanced", rules: "", apps: "")
                                    model.saveStyle(group, app: nil); creatingGroup = false; editingApp = nil; editing = group
                                }.buttonStyle(KiviButton(primary: true)).disabled(!validGroupName)
                            }
                        }.padding(32).frame(width: 480).foregroundStyle(KiviTheme.ink).background(KiviTheme.panel)
                    }
                }

            }
            .animation(model.saved.reduceMotion ? nil : .easeInOut(duration: 0.16), value: drawerIsOpen)
            .animation(model.saved.reduceMotion ? nil : .easeInOut(duration: 0.16), value: modalIsOpen)
        }
        .onAppear {
            model.refreshWritingPreferences()
            if let app = model.styleAppToOpen {
                model.styleAppToOpen = nil
                openApp(app)
            }
        }
    }
    private var validGroupName: Bool {
        let name = groupName.trimmingCharacters(in: .whitespacesAndNewlines)
        return !name.isEmpty && name.count <= 60 && !model.saved.styles.contains { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }
    }
    private var modalIsOpen: Bool { showLanguage || (globalRules.editing && globalRules.editingID == nil) || creatingGroup }
    private func dismissModal() {
        guard !showLanguagePicker && !showSecondLanguagePicker else { return }
        showLanguage = false; globalRules.cancel()
    }
    private var overview: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                PageTitle(title: "styles")
                Spacer()
                Button { groupName = ""; creatingGroup = true } label: { Label("new group", systemImage: "plus") }.buttonStyle(KiviButton())
                Button { appSearch = ""; showApps = true } label: { Label("manage apps", systemImage: "square.grid.2x2") }.buttonStyle(KiviButton())
                Button {
                    autoDetect = settings.languageSelection == .auto
                    let codes = settings.languageSelection.selectedCodes
                    secondLanguage = codes.dropFirst().first.flatMap { code in settings.availableLanguages.first { $0.code == code }?.name } ?? "none"
                    showLanguage = true
                } label: { Label("language", systemImage: "globe") }.buttonStyle(KiviButton())
            }
            VStack(spacing: 0) {
                ForEach(model.saved.styles) { style in
                    styleRow(style)
                    if style.id != model.saved.styles.last?.id { Divider().overlay(KiviTheme.line) }
                }
            }.padding(.top, 24)
            KiviGlobalRulesView(editor: globalRules).padding(.top, 36)
        }
    }
    private var filteredApps: [String] { assignedApps.filter { appSearch.isEmpty || $0.localizedCaseInsensitiveContains(appSearch) } }
    private var appManagementPage: some View {
        VStack(alignment: .leading, spacing: 24) {
            Button { showAppPicker = false; showApps = false } label: { Label("styles", systemImage: "chevron.left") }
                .buttonStyle(.plain).font(KiviTheme.body(14)).foregroundStyle(KiviTheme.muted).accessibilityLabel("back to styles")
            HStack {
                PageTitle(title: "manage apps")
                Spacer()
                Button { showAppPicker = true } label: { Label("add app", systemImage: "plus") }
                    .buttonStyle(KiviButton(primary: true))
                    .popover(isPresented: $showAppPicker, arrowEdge: .trailing) {
                        AppAssignmentPopover(assignedApps: assignedApps, onClose: { showAppPicker = false }) { app in
                            showAppPicker = false; openApp(app)
                        }
                    }
            }
            Text("Choose an app to adjust its writing style.").font(KiviTheme.body(15)).foregroundStyle(KiviTheme.muted)
            TextField("search apps", text: $appSearch).textFieldStyle(.plain).font(KiviTheme.body(15))
                .padding(12).background(KiviTheme.panel, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(KiviTheme.line)).accessibilityLabel("search app preferences")
            if filteredApps.isEmpty {
                Text(appSearch.isEmpty ? "No app preferences yet. Add an app to get started." : "No apps found.")
                    .font(KiviTheme.body(15)).foregroundStyle(KiviTheme.muted).padding(.vertical, 24)
            } else {
                VStack(spacing: 0) {
                    ForEach(filteredApps, id: \.self) { app in
                        Button { openApp(app) } label: {
                            HStack(spacing: 12) {
                                AppGlyph(name: app, size: 28)
                                Text(app).font(KiviTheme.body(16))
                                Spacer()
                                Text(model.saved.appOverrides[app] == nil ? styleForApp(app).name : "custom rules · \(styleForApp(app).mode)")
                                    .font(KiviTheme.body(14)).foregroundStyle(KiviTheme.muted)
                                Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(KiviTheme.muted)
                            }.padding(.horizontal, 16).padding(.vertical, 16).contentShape(Rectangle())
                                .background(hoveredApp == app ? KiviTheme.ink.opacity(0.04) : .clear)
                        }.buttonStyle(.plain).onHover { hoveredApp = $0 ? app : nil }
                        if app != filteredApps.last { Rectangle().fill(KiviTheme.line).frame(height: 1).padding(.leading, 56) }
                    }
                }.background(KiviTheme.panel, in: RoundedRectangle(cornerRadius: 10))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(KiviTheme.line))
            }
        }.foregroundStyle(KiviTheme.ink)
            .onExitCommand { if !drawerIsOpen && !showAppPicker { showApps = false } }
    }
    private func sectionHeading(_ title: String) -> some View {
        HStack(spacing: 12) {
            Text(title).font(KiviTheme.medium(17))
            Rectangle().fill(KiviTheme.line).frame(height: 1)
        }.padding(.bottom, 12)
    }
    private var assignedApps: [String] { Array(Set(model.saved.styles.flatMap { $0.apps.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) } } + Array(model.saved.appOverrides.keys))).filter { !$0.isEmpty }.sorted() }
    private var drawerIsOpen: Bool { editing != nil }
    private func closeDrawer() {
        withAnimation(model.saved.reduceMotion ? nil : .easeInOut(duration: 0.2)) { editing = nil; editingApp = nil }
    }
    private func openApp(_ app: String) {
        withAnimation(model.saved.reduceMotion ? nil : .easeInOut(duration: 0.2)) { editingApp = app
            var draft = styleForApp(app)
            if let group = model.saved.styles.first(where: { $0.id != "other" && $0.appNames.contains(app) }) ?? model.saved.styles.first(where: { $0.id == "other" }) {
                draft.id = group.id; draft.name = group.name
            }
            if model.saved.appOverrides[app] == nil { draft.rules = ""; draft.usesGroupTone = true }
            if draft.usesGroupTone == true { draft.mode = model.saved.styles.first { $0.id == draft.id }?.mode ?? draft.mode }
            editing = draft }
    }
    private func styleForApp(_ app: String) -> WritingStyle {
        model.saved.appOverrides[app] ?? model.saved.styles.first(where: { $0.id != "other" && $0.appNames.contains(app) }) ?? model.saved.styles.first(where: { $0.id == "other" }) ?? WritingStyle.defaults[4]
    }
    private func styleRow(_ style: WritingStyle) -> some View {
        Button { withAnimation(model.saved.reduceMotion ? nil : .easeInOut(duration: 0.2)) { hoveredStyleIcon = nil; editingApp = nil; editing = style } } label: {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(style.name).font(KiviTheme.medium(18))
                    if style.id == "other" {
                        Text("everywhere else").font(KiviTheme.body(13)).foregroundStyle(KiviTheme.muted)
                    } else {
                        HStack(spacing: 7) {
                            ForEach(style.apps.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }, id: \.self) { app in
                                AppGlyph(name: app, size: 23)
                                    .clipShape(RoundedRectangle(cornerRadius: 5))
                                    .onHover { hoveredStyleIcon = $0 ? app : nil }
                                    .overlay(alignment: .topLeading) {
                                        if hoveredStyleIcon == app {
                                            Text(app).font(KiviTheme.body(12)).foregroundStyle(KiviTheme.ink)
                                                .padding(.horizontal, 9).padding(.vertical, 5)
                                                .background(KiviTheme.panel, in: RoundedRectangle(cornerRadius: 6))
                                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(KiviTheme.line))
                                                .fixedSize().offset(y: 28).allowsHitTesting(false)
                                        }
                                    }
                                    .zIndex(hoveredStyleIcon == app ? 1 : 0)
                            }
                        }.accessibilityHidden(true)
                    }
                }
                Spacer(minLength: 12)
                Text(KiviStyleRouter.load().enabled.contains(style.id) ? style.mode : "default")
                    .font(KiviTheme.body(14)).foregroundStyle(KiviTheme.muted)
                Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(KiviTheme.muted)
            }.padding(.horizontal, 12).padding(.vertical, 22).frame(minHeight: 84).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityLabel("\(style.name), \(style.id == "other" ? "everywhere else" : style.apps)")
            .accessibilityValue(KiviStyleRouter.load().enabled.contains(style.id) ? style.mode : "default")
            .onHover { hoveredStyle = $0 ? style.id : (hoveredStyle == style.id ? nil : hoveredStyle) }
            .animation(.easeOut(duration: 0.12), value: hoveredStyle == style.id)
            .background(hoveredStyle == style.id ? KiviTheme.panel : .clear, in: RoundedRectangle(cornerRadius: 8))
    }
    private var languageCard: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                Text("language").font(KiviTheme.medium(20))
                Spacer()
                IconButton(icon: "xmark", label: "close language", action: dismissModal)
            }
            VStack(alignment: .leading, spacing: 12) {
                Text("spoken language").font(KiviTheme.medium(14))
                Text("Detect it automatically, or choose a language.").font(KiviTheme.body(13)).foregroundStyle(KiviTheme.muted)
                HStack(spacing: 10) {
                Button { settings.languageSelection = .auto; autoDetect = true } label: {
                    HStack(spacing: 7) { if autoDetect { Image(systemName: "checkmark").font(.system(size: 11, weight: .medium)) }; Text("auto-detect") }
                }.buttonStyle(KiviButton(primary: autoDetect))
                Button { showLanguagePicker = true } label: {
                    menuLabel(settings.selectedLanguage.flatMap { code in settings.availableLanguages.first { $0.code == code }?.name } ?? "choose language", width: 180)
                }.buttonStyle(.plain).accessibilityLabel("choose language")
                    .accessibilityValue(settings.selectedLanguage.flatMap { code in settings.availableLanguages.first { $0.code == code }?.name } ?? "auto-detect")
                    .popover(isPresented: $showLanguagePicker) {
                        StyleLanguagePopover(title: "language", choices: settings.availableLanguages.map { .init(id: $0.code, name: $0.name) }, selected: settings.selectedLanguage, onClose: { showLanguagePicker = false }) { code in
                            settings.languageSelection = .exact(code); autoDetect = false; model.saved.locale = code; model.persist()
                            showLanguagePicker = false
                        }
                    }

                }
            }
            Rectangle().fill(KiviTheme.line).frame(height: 1)
            VStack(alignment: .leading, spacing: 12) {
                Text("second language").font(KiviTheme.medium(14))
                Text("Speak either language, or mix both.").font(KiviTheme.body(13)).foregroundStyle(KiviTheme.muted)
                Button { showSecondLanguagePicker = true } label: { menuLabel(secondLanguage, width: 145) }
                    .buttonStyle(.plain).accessibilityLabel("second language").accessibilityValue(secondLanguage)
                    .popover(isPresented: $showSecondLanguagePicker) {
                        StyleLanguagePopover(title: "second language", choices: [.init(id: "none", name: "none")] + settings.availableLanguages.map { .init(id: $0.code, name: $0.name) }, selected: secondLanguage == "none" ? "none" : settings.availableLanguages.first { $0.name == secondLanguage }?.code, onClose: { showSecondLanguagePicker = false }) { code in
                            if code == "none" {
                                secondLanguage = "none"
                                if let first = settings.languageSelection.selectedCodes.first { settings.languageSelection = .exact(first) } else { settings.languageSelection = .auto }
                            } else {
                                secondLanguage = settings.availableLanguages.first { $0.code == code }?.name ?? code
                                settings.languageSelection = .hints(Array(Set(settings.languageSelection.selectedCodes.prefix(1) + [code])).sorted())
                            }
                            showSecondLanguagePicker = false
                        }
                    }

            }
            HStack { Spacer(); Button("done", action: dismissModal).buttonStyle(KiviButton(primary: true)) }
        }.padding(28).foregroundStyle(KiviTheme.ink)
            .focusable().focusEffectDisabled().focused($languageDialogFocused)
            .onAppear { languageDialogFocused = true }
            .onChange(of: showLanguagePicker) { _, open in if !open { languageDialogFocused = true } }
            .onChange(of: showSecondLanguagePicker) { _, open in if !open { languageDialogFocused = true } }
            .onExitCommand(perform: dismissModal)
    }
    private func menuLabel(_ title: String, width: CGFloat) -> some View {
        HStack { Text(title).font(KiviTheme.body(14)); Spacer(); Image(systemName: "chevron.down").font(.system(size: 10)) }
            .padding(.horizontal, 12).frame(width: width + 24, height: 32)
            .background(KiviTheme.background.opacity(0.2), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(KiviTheme.line))
    }

}

private struct StyleLanguageChoice: Identifiable {
    let id: String
    let name: String
}

private struct StyleLanguagePopover: View {
    let title: String
    let choices: [StyleLanguageChoice]
    let selected: String?
    let onClose: () -> Void
    let onSelect: (String) -> Void
    @State private var search = ""
    private var filteredChoices: [StyleLanguageChoice] {
        choices.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(title).font(KiviTheme.medium(17))
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark").font(.system(size: 12)) }
                    .buttonStyle(KiviButton()).accessibilityLabel("close languages")
            }
            TextField("search languages", text: $search).textFieldStyle(.plain).font(KiviTheme.body(14))
                .padding(10).background(KiviTheme.panel, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(KiviTheme.line))
                .accessibilityLabel("search languages")
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    if filteredChoices.isEmpty {
                        Text("No languages found").font(KiviTheme.body(14)).foregroundStyle(KiviTheme.muted).padding(.vertical, 12)
                    }
                    ForEach(filteredChoices) { choice in
                        Button { onSelect(choice.id) } label: {
                            HStack {
                                Text(choice.name)
                                Spacer()
                                if choice.id == selected { Image(systemName: "checkmark").foregroundStyle(KiviTheme.green) }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(KiviButton()).accessibilityAddTraits(choice.id == selected ? .isSelected : [])
                    }
                }
            }
        }.padding(18).frame(width: 320, height: 390).foregroundStyle(KiviTheme.ink).background(KiviBackground())
            .onExitCommand(perform: onClose)
    }
}

private struct StyleMode: Identifiable {
    var name: String
    var description: String
    var example: String
    var id: String { name }
}

private struct StyleDetail: View {
    @State var style: WritingStyle
    var appName: String?
    let styles: [WritingStyle]
    let onClose: () -> Void
    let onSave: (WritingStyle) -> Void
    let onOpenApp: (String) -> Void
    let onDelete: () -> Void
    let onReset: () -> Void
    let overrideApps: Set<String>
    let hasOverride: Bool
    @State private var showAppPicker = false
    @State private var savedStyle: WritingStyle?
    private var hasChanges: Bool { savedStyle.map { style != $0 } ?? false }
    @State private var confirmDelete = false
    @State private var showStyleChoices = false
    @State private var showRules = false

    private let drawerColor = Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.125, alpha: 1) : NSColor(white: 0.96, alpha: 1) })
    private var category: String { style.id }
    private var modes: [StyleMode] {
        switch category {
        case "developer": return [
            .init(name: "clear", description: "the full instruction, plainly.", example: "First, update the retry handler so it only retries 429s. Then keep the session active and run the websocket tests before pushing."),
            .init(name: "concise", description: "compact wording, all the details.", example: "Update retry handler: retry only 429s, keep session active, run websocket tests before pushing."),
            .init(name: "structured", description: "goal, changes, validation.", example: "Update the retry handler\n• Retry only 429s\n• Keep the session active\n• Run websocket tests before pushing")]
        case "work": return [
            .init(name: "clear", description: "clean sentences, shorthand kept.", example: "Hey, FYI, I do not know if the launch review can stay at 3 tomorrow. Please check the final numbers by noon and let me know."),
            .init(name: "casual", description: "lowercase workplace shorthand.", example: "hey FYI idk if the launch review can stay at 3 tomorrow, please check the final numbers by noon and let me know"),
            .init(name: "formal", description: "everything spelled out, properly.", example: "Hey, for your information, I do not know if the launch review can stay at 3 tomorrow. Please check the final numbers by noon and let me know.")]
        case "personal": return [
            .init(name: "natural", description: "light cleanup, your voice kept.", example: "hey I’m not gonna lie, idk if I can make dinner at 8 but I will call you when I am free"),
            .init(name: "very casual", description: "lowercase, shorthand, zero fuss.", example: "hey ngl idk if i can make dinner at 8 but i will call you when i am free"),
            .init(name: "polished", description: "full punctuation and grammar.", example: "Hey, I am not going to lie, I do not know if I can make dinner at 8, but I will call you when I am free.")]
        case "email": return [
            .init(name: "professional", description: "conventional and to the point.", example: "Hi Maya,\n\nThe launch review moved to 3 tomorrow. Please send the final numbers by noon.\n\nBest,\nPranav"),
            .init(name: "friendly", description: "the same note, with warmth.", example: "Hi Maya,\n\nThe launch review moved to 3 tomorrow. Please send the final numbers by noon.\n\nThanks,\nPranav"),
            .init(name: "formal", description: "highest formality, full forms.", example: "Dear Maya,\n\nThe launch review has been moved to 3 PM tomorrow. Please send the final numbers by noon.\n\nKind regards,\nPranav")]
        default: return [
            .init(name: "balanced", description: "cleaned, but still yours.", example: "The launch review is tomorrow at 3 PM, and the deck will be ready before noon."),
            .init(name: "minimal", description: "compressed to fragments.", example: "launch review tomorrow 3 PM. deck ready before noon"),
            .init(name: "polished", description: "composed, complete sentences.", example: "The launch review will take place tomorrow at 3 PM. The presentation will be ready before noon.")]
        }
    }
    private var selectedMode: String {
        if modes.contains(where: { $0.name == style.mode }) { return style.mode }
        return ["personal": "very casual", "email": "professional", "other": "minimal"][category] ?? modes[0].name
    }
    private var rulesHint: String {
        let hints: String
        switch category {
        case "developer": hints = "• keep code words like useState, npm and git exactly as i say them\n• write prompts for ai tools in clear english, even when i speak hinglish"
        case "work": hints = "• keep messages short. skip greetings and sign-offs\n• put action items as bullet points"
        case "personal": hints = "• keep my hinglish as it is. don't turn it into english\n• no full stop at the end of a message"
        case "email": hints = "• end every email with \"thanks,\" and my name\n• keep paragraphs short, two or three sentences each"
        default: hints = "• use indian spelling, like colour and organise\n• write numbers as digits"
        }
        return "tell kivi how to write here, for example:\n" + hints
    }
    private var apps: [String] { style.apps.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                Group {
                    if let appName { AppGlyph(name: appName, size: 46) }
                    else { Image(systemName: categoryIcon).font(.system(size: 23, weight: .light)).frame(width: 46, height: 46).background(KiviTheme.panel.opacity(0.9), in: RoundedRectangle(cornerRadius: 9)).overlay(RoundedRectangle(cornerRadius: 9).stroke(KiviTheme.line)) }
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(appName ?? style.name).font(KiviTheme.medium(24))
                    if appName == nil { Text(headerDescription).font(KiviTheme.body(14)).foregroundStyle(KiviTheme.muted).lineSpacing(3).fixedSize(horizontal: false, vertical: true) }
                }
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark").font(.system(size: 13)).frame(width: 42, height: 30) }
                    .buttonStyle(.plain).background(KiviTheme.panel.opacity(0.7), in: RoundedRectangle(cornerRadius: 6)).overlay(RoundedRectangle(cornerRadius: 6).stroke(KiviTheme.line)).accessibilityLabel("close style")
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            Divider().overlay(KiviTheme.line)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if appName != nil {
                        VStack(alignment: .leading, spacing: 8) {
                            Button { showStyleChoices.toggle() } label: {
                                HStack {
                                    Text("group · \(styles.first { $0.id == style.id }?.name ?? style.name)")
                                    Spacer()
                                    Image(systemName: showStyleChoices ? "chevron.up" : "chevron.down").font(.system(size: 11))
                                }.frame(maxWidth: .infinity).frame(height: 22)
                            }.buttonStyle(KiviButton())
                                .accessibilityLabel("writing category")
                                .accessibilityValue("\(style.name), \(showStyleChoices ? "expanded" : "collapsed")")
                            if showStyleChoices {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text("choose a group · saved with this style").font(KiviTheme.medium(13)).foregroundStyle(KiviTheme.muted).padding(6)
                                    ForEach(styles) { candidate in
                                        Button { let rules = style.rules; let inherit = style.usesGroupTone; style = candidate; style.rules = rules; style.usesGroupTone = inherit; showStyleChoices = false } label: {
                                            HStack {
                                                VStack(alignment: .leading, spacing: 3) {
                                                    Text(candidate.name).font(KiviTheme.medium(14))
                                                    Text(candidate.subtitle).font(KiviTheme.body(12)).foregroundStyle(KiviTheme.muted)
                                                }
                                                Spacer()
                                                if candidate.id == style.id { Image(systemName: "checkmark").foregroundStyle(KiviTheme.green) }
                                            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
                                        }.buttonStyle(KiviButton())
                                            .accessibilityAddTraits(candidate.id == style.id ? .isSelected : [])
                                    }
                                }.padding(10).background(KiviTheme.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(KiviTheme.line))
                            }
                        }.padding(.bottom, 24)
                    }
                    if appName == nil {
                        Text("group name").font(KiviTheme.body(13)).foregroundStyle(KiviTheme.muted)
                        TextField("group name", text: $style.name).textFieldStyle(.plain).font(KiviTheme.body(18))
                            .padding(12).background(KiviTheme.background, in: RoundedRectangle(cornerRadius: 7))
                            .accessibilityLabel("group name").padding(.bottom, 20)
                    } else {
                        Text(hasOverride ? "custom rules · group rules still apply unless they conflict" : "inherits group rules · add instructions just for this app below")
                            .font(KiviTheme.body(13)).foregroundStyle(KiviTheme.muted).padding(.bottom, 16)
                        if hasOverride {
                            Button("reset to group rules", action: onReset).buttonStyle(KiviButton()).padding(.bottom, 20)
                        }
                    }
                    Text("how should it sound?").font(KiviTheme.medium(17)).padding(.bottom, 14)
                    if appName != nil {
                        Button {
                            style.usesGroupTone = true
                            style.mode = styles.first { $0.id == style.id }?.mode ?? style.mode
                        } label: {
                            Label("use group tone", systemImage: style.usesGroupTone == true ? "checkmark.circle.fill" : "circle")
                        }.buttonStyle(KiviButton()).accessibilityAddTraits(style.usesGroupTone == true ? .isSelected : []).padding(.bottom, 12)
                    }
                    HStack(spacing: 8) {
                        ForEach(modes) { mode in
                            Button { style.mode = mode.name; if appName != nil { style.usesGroupTone = false } } label: {
                                Text(mode.name).frame(maxWidth: .infinity)
                            }.buttonStyle(KiviButton(primary: selectedMode == mode.name))
                                .accessibilityAddTraits(selectedMode == mode.name ? .isSelected : [])
                        }
                    }
                    Text(modes.first(where: { $0.name == selectedMode })?.description ?? "")
                        .font(KiviTheme.body(14)).foregroundStyle(KiviTheme.muted).padding(.top, 12)
                    VStack(alignment: .leading, spacing: 16) {
                        Text("example").font(KiviTheme.mono(11)).foregroundStyle(KiviTheme.muted)
                        Text(modes.first(where: { $0.name == selectedMode })?.example ?? "")
                            .font(KiviTheme.body(18)).lineSpacing(6).fixedSize(horizontal: false, vertical: true)
                    }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
                        .background(KiviTheme.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 10)).padding(.top, 24)
                    Button { showRules.toggle() } label: {
                        HStack { Text("custom instructions"); Spacer(); Image(systemName: showRules ? "chevron.up" : "chevron.down") }
                    }.buttonStyle(KiviButton()).padding(.top, 24)
                        .accessibilityValue(showRules ? "expanded" : "collapsed")
                    if showRules {
                    ZStack(alignment: .topLeading) {
                        if style.rules.isEmpty { Text(rulesHint).font(KiviTheme.body(14)).foregroundStyle(KiviTheme.muted.opacity(0.7)).lineSpacing(6).padding(13).allowsHitTesting(false) }
                        TextEditor(text: $style.rules).accessibilityLabel("custom instructions").font(KiviTheme.body(14)).scrollContentBackground(.hidden).padding(7).background(.clear)
                    }.frame(height: 118).background(KiviTheme.background.opacity(0.45), in: RoundedRectangle(cornerRadius: 7)).overlay(RoundedRectangle(cornerRadius: 7).stroke(KiviTheme.line)).padding(.top, 14)
                    }
                    HStack { Spacer(); Button("save style") { style.mode = selectedMode; style.name = style.name.trimmingCharacters(in: .whitespacesAndNewlines); onSave(style); savedStyle = style }.buttonStyle(KiviButton(primary: true)).disabled(!hasChanges || invalidName) }.padding(.top, 12)
                    if invalidName { Text("Use a unique group name, up to 60 characters.").font(KiviTheme.body(13)).foregroundStyle(KiviTheme.muted).padding(.top, 8) }
                    if appName == nil {
                        drawerSection("apps").padding(.top, 28).padding(.bottom, 10)
                        VStack(spacing: 0) {
                            ForEach(apps, id: \.self) { app in
                                Button { onOpenApp(app) } label: {
                                    HStack(spacing: 11) { AppGlyph(name: app, size: 18); Text(app).font(KiviTheme.body(16)); Text(overrideApps.contains(app) ? "custom rules" : "app rules").font(KiviTheme.body(12)).foregroundStyle(KiviTheme.muted); Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(KiviTheme.muted); Spacer() }.padding(.horizontal, 14).frame(height: 44).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                Rectangle().fill(KiviTheme.line).frame(height: 1)
                            }
                            Button { showAppPicker = true } label: {
                                Label("add app", systemImage: "plus").font(KiviTheme.body(15)).foregroundStyle(KiviTheme.green).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).frame(height: 44)
                            }.buttonStyle(.plain).popover(isPresented: $showAppPicker, arrowEdge: .trailing) {
                                AppAssignmentPopover(assignedApps: apps, onClose: { showAppPicker = false }) { app in
                                    style.apps = (apps + [app]).joined(separator: ", "); showAppPicker = false
                                }
                            }
                        }.background(KiviTheme.panel, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(KiviTheme.line))
                        if style.id != "other" {
                            if confirmDelete {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text("Delete this group? Its apps will move to other apps. App-specific rules will be kept.").font(KiviTheme.body(14))
                                    HStack {
                                        Button("cancel") { confirmDelete = false }.buttonStyle(KiviButton())
                                        Button("delete group", action: onDelete).buttonStyle(KiviButton())
                                    }
                                }.padding(.top, 24)
                            } else {
                                Button("delete group") { confirmDelete = true }.buttonStyle(KiviButton()).padding(.top, 24)
                            }
                        }
                    }

                }.padding(24)
            }
        }
        .background {
            // A window command works even before a text field becomes first responder.
            Button("cancel style editor") {
                if showStyleChoices { showStyleChoices = false } else { onClose() }
            }.keyboardShortcut(.cancelAction).frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
        }
        .onAppear { if savedStyle == nil { savedStyle = style }; if appName != nil { showRules = true } }.foregroundStyle(KiviTheme.ink).background(drawerColor).overlay(alignment: .leading) { Rectangle().fill(KiviTheme.line).frame(width: 1) }
    }
    private var invalidName: Bool {
        guard appName == nil else { return false }
        let name = style.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty || name.count > 60 || styles.contains { $0.id != style.id && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }
    }
    private var headerDescription: String {
        if category == "other" { return "this style is used for every app that isn't in another style." }
        if apps.isEmpty { return "add apps below, then save to use this group’s writing style and rules." }
        if apps.count == 1 { return "this style is used by 1 app. editing the style or its rules changes it for that app." }
        return "this style is shared by \(apps.count) apps. editing the style or its rules changes it for all of them."
    }
    private var categoryIcon: String { "person.2" }
    private func drawerSection(_ title: String) -> some View {
        HStack(spacing: 12) { Text(title).font(KiviTheme.medium(14)); Rectangle().fill(KiviTheme.line).frame(height: 1) }
    }
}

private struct AppAssignmentPopover: View {
    let assignedApps: [String]
    let onClose: () -> Void
    let onSelect: (String) -> Void
    @State private var search = ""
    private var apps: [String] {
        NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.compactMap(\.localizedName).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "app.dashed").font(.system(size: 17))
                Text("add an app").font(KiviTheme.medium(16))
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark.circle.fill").font(.system(size: 18)).foregroundStyle(KiviTheme.muted) }.buttonStyle(.plain).accessibilityLabel("close apps")
            }.padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 16)
            HStack(spacing: 8) { Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(KiviTheme.muted); TextField("search running apps", text: $search).textFieldStyle(.plain).font(KiviTheme.body(14)) }.padding(.horizontal, 10).frame(height: 34).background(KiviTheme.panel, in: RoundedRectangle(cornerRadius: 7)).overlay(RoundedRectangle(cornerRadius: 7).stroke(KiviTheme.line)).padding(.horizontal, 16).padding(.bottom, 10)
            ScrollView {
                VStack(spacing: 0) {
                    if apps.filter({ search.isEmpty || $0.localizedCaseInsensitiveContains(search) }).isEmpty {
                        Text("No running apps found. Browse applications below.").font(KiviTheme.body(14)).foregroundStyle(KiviTheme.muted).padding(20)
                    }
                    ForEach(apps.filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) }, id: \.self) { app in
                        let assigned = assignedApps.contains(app)
                        Button { onSelect(app) } label: {
                            HStack(spacing: 11) { AppGlyph(name: app, size: 22); Text(app).font(KiviTheme.body(16)); Spacer(); Image(systemName: assigned ? "checkmark.circle.fill" : "plus.circle").font(.system(size: 17)).foregroundStyle(assigned ? KiviTheme.green : KiviTheme.muted) }.frame(height: 42).contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(assigned).padding(.horizontal, 20)
                    }
                }
            }
            Divider().overlay(KiviTheme.line)
            Button(action: browseApplications) { Label("browse applications…", systemImage: "folder").font(KiviTheme.body(14)).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).frame(height: 49) }.buttonStyle(.plain)
        }.frame(width: 380, height: 460).foregroundStyle(KiviTheme.ink).background(KiviBackground()).clipShape(RoundedRectangle(cornerRadius: 18)).onExitCommand(perform: onClose)
    }
    private func browseApplications() {
        let picker = NSOpenPanel()
        picker.title = "Choose an application"
        picker.directoryURL = URL(fileURLWithPath: "/Applications")
        picker.canChooseFiles = true
        picker.canChooseDirectories = false
        picker.allowsMultipleSelection = false
        picker.allowedContentTypes = [.applicationBundle]
        if picker.runModal() == .OK, let url = picker.url { onSelect(url.deletingPathExtension().lastPathComponent) }
    }
}
