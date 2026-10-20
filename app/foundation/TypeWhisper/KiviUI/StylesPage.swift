import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct StylesPage: View {
    @EnvironmentObject var model: AppModel
    @State private var editing: WritingStyle?
    @State private var editingApp: String?
    @State private var showAppPicker = false
    @ObservedObject private var settings = SettingsViewModel.shared
    @State private var autoDetect = SettingsViewModel.shared.languageSelection == .auto
    @State private var secondLanguage = "none"
    @State private var script = "roman"
    @State private var hoveredStyle: String?
    @State private var hoveredApp: String?

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .trailing) {
                ScrollView {
                    PageContent {
                        VStack(alignment: .leading, spacing: 0) {
                            PageTitle(title: "how you sound, app by app")
                            SectionTitle(title: "language and script").padding(.top, 26).padding(.bottom, 10)
                            languageCard
                            SectionTitle(title: "your styles").padding(.top, 16)
                            VStack(spacing: 12) {
                                ForEach(model.saved.styles) { style in styleRow(style) }
                            }
                            SectionTitle(title: "your apps").padding(.top, 16)
                            VStack(spacing: 0) {
                                ForEach(assignedApps, id: \.self) { app in
                                    Button { openApp(app) } label: {
                                        HStack(spacing: 12) {
                                            AppGlyph(name: app, size: 25)
                                            Text(app).font(KiviTheme.body(16))
                                            Spacer()
                                            Text(styleForApp(app).name).font(KiviTheme.body(14)).foregroundStyle(KiviTheme.muted)
                                            Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(KiviTheme.muted)
                                        }.padding(.horizontal, 18).frame(height: 58)
                                            .background(hoveredApp == app ? KiviTheme.background.opacity(0.42) : .clear)
                                            .contentShape(Rectangle())
                                    }.buttonStyle(.plain).onHover { hoveredApp = $0 ? app : (hoveredApp == app ? nil : hoveredApp) }
                                        .animation(.easeOut(duration: 0.12), value: hoveredApp == app)
                                    if app != "System Settings" { Divider().overlay(KiviTheme.line).padding(.leading, 55) }
                                }
                            }.background(KiviTheme.panel, in: RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(KiviTheme.line))
                            Button { showAppPicker = true } label: { Label("add app", systemImage: "plus") }
                                .buttonStyle(KiviButton()).padding(.top, 14)
                                .popover(isPresented: $showAppPicker, arrowEdge: .trailing) {
                                    AppAssignmentPopover(assignedApps: model.saved.styles.flatMap { $0.apps.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) } }, onClose: { showAppPicker = false }) { app in
                                        openApp(app)
                                        showAppPicker = false
                                    }
                                }
                        }
                    }
                }.blur(radius: drawerIsOpen ? 5 : 0).allowsHitTesting(!drawerIsOpen).disabled(drawerIsOpen)
                if drawerIsOpen {
                    Color.black.opacity(0.35).transition(.opacity).onTapGesture { closeDrawer() }
                    if let editing {
                        StyleDetail(style: editing, appName: editingApp, styles: model.saved.styles, onClose: closeDrawer, onSave: { updated in
                            model.saveStyle(updated, app: editingApp)
                            self.editing = updated

                        }, onOpenApp: openApp)
                        .id(editingApp ?? editing.id)
                        .frame(width: min(700, geometry.size.width))
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
            }
            .animation(model.saved.reduceMotion ? nil : .easeInOut(duration: 0.2), value: drawerIsOpen)
        }
    }
    private var assignedApps: [String] { Array(Set(model.saved.styles.flatMap { $0.apps.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) } } + Array(model.saved.appOverrides.keys))).filter { !$0.isEmpty }.sorted() }
    private var drawerIsOpen: Bool { editing != nil }
    private func closeDrawer() {
        withAnimation(model.saved.reduceMotion ? nil : .easeInOut(duration: 0.2)) { editing = nil; editingApp = nil }
    }
    private func openApp(_ app: String) {
        withAnimation(model.saved.reduceMotion ? nil : .easeInOut(duration: 0.2)) { editingApp = app; editing = styleForApp(app) }
    }
    private func styleForApp(_ app: String) -> WritingStyle {
        model.saved.appOverrides[app] ?? model.saved.styles.first(where: { $0.apps.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.contains(app) }) ?? model.saved.styles.first(where: { $0.id == "other" }) ?? WritingStyle.defaults[4]
    }
    private func styleRow(_ style: WritingStyle) -> some View {
        Button { withAnimation(model.saved.reduceMotion ? nil : .easeInOut(duration: 0.2)) { editingApp = nil; editing = style } } label: {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(style.name).font(KiviTheme.serif(32))
                    Text(style.subtitle).font(KiviTheme.body(15)).foregroundStyle(KiviTheme.muted)
                }
                Spacer(minLength: 12)
                let apps = style.apps.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                HStack(spacing: 8) {
                    ForEach(Array(apps.prefix(4)), id: \.self) { app in AppGlyph(name: app, size: 25) }
                    if apps.count > 4 { Text("+\(apps.count - 4)").font(KiviTheme.body(12)).foregroundStyle(KiviTheme.muted).padding(.leading, 2) }
                }
                Image(systemName: "arrow.right").font(.system(size: 17)).foregroundStyle(KiviTheme.muted).padding(.leading, 6)
            }.padding(.horizontal, 22).frame(height: 96).contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { hoveredStyle = $0 ? style.id : (hoveredStyle == style.id ? nil : hoveredStyle) }
            .animation(.easeOut(duration: 0.12), value: hoveredStyle == style.id)
            .background(KiviTheme.panel.opacity(hoveredStyle == style.id ? 0.75 : 1), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(KiviTheme.line))
    }
    private var languageCard: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("language").font(KiviTheme.medium(14))
                    Text("let kivi detect it, or choose what you usually speak").font(KiviTheme.body(13)).foregroundStyle(KiviTheme.muted)
                }
                Spacer(minLength: 10)
                Button { settings.languageSelection = .auto; autoDetect = true } label: {
                    HStack(spacing: 7) { if autoDetect { Image(systemName: "checkmark").font(.system(size: 11, weight: .medium)) }; Text("auto-detect") }
                }.buttonStyle(KiviButton(primary: autoDetect))
                Menu {
                    ForEach(settings.availableLanguages, id: \.code) { language in
                        Button(language.name) { settings.languageSelection = .exact(language.code); autoDetect = false; model.saved.locale = language.code; model.persist() }
                    }
                } label: { menuLabel(settings.selectedLanguage.flatMap { code in settings.availableLanguages.first { $0.code == code }?.name } ?? "choose language", width: 180) }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            }.padding(.bottom, 21)
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("second language").font(KiviTheme.medium(14))
                    Text("you can speak either language, or mix both").font(KiviTheme.body(13)).foregroundStyle(KiviTheme.muted)
                }
                Spacer()
                Menu {
                    Button("none") { secondLanguage = "none"; if let first = settings.languageSelection.selectedCodes.first { settings.languageSelection = .exact(first) } else { settings.languageSelection = .auto } }
                    ForEach(settings.availableLanguages, id: \.code) { language in Button(language.name) { secondLanguage = language.name; settings.languageSelection = .hints(Array(Set(settings.languageSelection.selectedCodes.prefix(1) + [language.code])).sorted()) } }
                } label: { menuLabel(secondLanguage, width: 145) }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            }.padding(.bottom, 22)
            Divider().overlay(KiviTheme.line)
            VStack(alignment: .leading, spacing: 6) {
                Text("choose script").font(KiviTheme.medium(14))
                Text("English uses roman letters. Other languages follow the selected engine’s output.").font(KiviTheme.body(13)).foregroundStyle(KiviTheme.muted)
                HStack(spacing: 12) {
                    scriptButton("native", sample: "see you tomorrow").disabled(true)
                    scriptButton("roman", sample: "see you tomorrow")
                }.padding(.top, 9)
            }.padding(.top, 18)
        }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
            .background(KiviTheme.panel, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(KiviTheme.line))
    }
    private func menuLabel(_ title: String, width: CGFloat) -> some View {
        HStack { Text(title).font(KiviTheme.body(14)); Spacer(); Image(systemName: "chevron.down").font(.system(size: 10)) }
            .padding(.horizontal, 12).frame(width: width + 24, height: 32)
            .background(KiviTheme.background.opacity(0.2), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(KiviTheme.line))
    }
    private func scriptButton(_ title: String, sample: String) -> some View {
        VStack(spacing: 7) {
            Button { script = title } label: {
                HStack(spacing: 8) { Text(title); if script == title { Image(systemName: "checkmark").font(.system(size: 11)) } }.frame(maxWidth: .infinity).frame(height: 32)
            }.buttonStyle(.plain).font(KiviTheme.medium(14))
                .foregroundStyle(script == title ? KiviTheme.green : KiviTheme.ink)
                .background(script == title ? KiviTheme.green.opacity(0.10) : KiviTheme.background.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(script == title ? KiviTheme.green.opacity(0.55) : KiviTheme.line))
            Text(sample).font(KiviTheme.body(12)).foregroundStyle(KiviTheme.muted)
        }.frame(maxWidth: .infinity)
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
    @State private var showAppPicker = false
    @State private var hasChanges = false

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
    private var quote: String {
        switch category {
        case "developer": return "hey first update the retry handler so it only retries 429s then keep the session active and finally run the websocket tests before pushing"
        case "work": return "hey for your information I do not know if the launch review can stay at three tomorrow please check the final numbers by noon and let me know"
        case "personal": return "hey I am not gonna lie I do not know if I can make dinner at eight but I will call you when I am free"
        case "email": return "email Maya say the launch review moved to three tomorrow please send the final numbers by noon sign off Pranav"
        default: return "um so the launch review is going to be tomorrow at three PM and the deck is going to be ready before noon"
        }
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
                    Text(appName ?? style.name).font(KiviTheme.serif(32))
                    if appName == nil { Text(headerDescription).font(KiviTheme.body(16)).foregroundStyle(KiviTheme.muted).lineSpacing(8).fixedSize(horizontal: false, vertical: true) }
                }
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark").font(.system(size: 13)).frame(width: 42, height: 30) }
                    .buttonStyle(.plain).background(KiviTheme.panel.opacity(0.7), in: RoundedRectangle(cornerRadius: 6)).overlay(RoundedRectangle(cornerRadius: 6).stroke(KiviTheme.line)).accessibilityLabel("close style")
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            Divider().overlay(KiviTheme.line)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if appName != nil {
                        Menu {
                            ForEach(styles) { candidate in Button(candidate.name) { style = candidate } }
                        } label: {
                            HStack { Text("uses \(style.name)").font(KiviTheme.medium(14)); Spacer(); Image(systemName: "chevron.down").font(.system(size: 11)) }
                                .padding(.horizontal, 12).frame(height: 34).background(KiviTheme.panel, in: RoundedRectangle(cornerRadius: 6)).overlay(RoundedRectangle(cornerRadius: 6).stroke(KiviTheme.line))
                        }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).padding(.bottom, 24)
                    }
                    drawerSection("writing style")
                    Text("“\(quote)”").font(KiviTheme.serif(15)).italic().foregroundStyle(KiviTheme.muted).lineSpacing(3).fixedSize(horizontal: false, vertical: true).padding(.top, 14).padding(.bottom, 12)
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(modes) { mode in
                            StyleModeCard(mode: mode, category: category, selected: selectedMode == mode.name) { style.mode = mode.name }
                        }
                    }
                    drawerSection("custom rules").padding(.top, 28)
                    ZStack(alignment: .topLeading) {
                        if style.rules.isEmpty { Text(rulesHint).font(KiviTheme.body(14)).foregroundStyle(KiviTheme.muted.opacity(0.7)).lineSpacing(6).padding(13).allowsHitTesting(false) }
                        TextEditor(text: $style.rules).font(KiviTheme.body(14)).scrollContentBackground(.hidden).padding(7).background(.clear)
                    }.frame(height: 118).background(KiviTheme.background.opacity(0.45), in: RoundedRectangle(cornerRadius: 7)).overlay(RoundedRectangle(cornerRadius: 7).stroke(KiviTheme.line)).padding(.top, 14)
                    HStack { Spacer(); Button("save") { style.mode = selectedMode; onSave(style); hasChanges = false }.buttonStyle(KiviButton(primary: true)).disabled(!hasChanges) }.padding(.top, 12)
                    if appName == nil {
                        drawerSection("apps").padding(.top, 28).padding(.bottom, 10)
                        VStack(spacing: 0) {
                            ForEach(apps, id: \.self) { app in
                                Button { onOpenApp(app) } label: {
                                    HStack(spacing: 11) { AppGlyph(name: app, size: 18); Text(app).font(KiviTheme.body(16)); Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(KiviTheme.muted); Spacer() }.padding(.horizontal, 14).frame(height: 44).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                Rectangle().fill(KiviTheme.line).frame(height: 1)
                            }
                            Button { showAppPicker = true } label: {
                                Label("add app", systemImage: "plus").font(KiviTheme.body(15)).foregroundStyle(KiviTheme.green).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).frame(height: 44)
                            }.buttonStyle(.plain).popover(isPresented: $showAppPicker, arrowEdge: .trailing) {
                                AppAssignmentPopover(assignedApps: apps, onClose: { showAppPicker = false }) { app in
                                    style.apps = (apps + [app]).joined(separator: ", "); onSave(style); showAppPicker = false
                                }
                            }
                        }.background(KiviTheme.panel, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(KiviTheme.line))
                    }

                }.padding(24)
            }
        }.onChange(of: style.id) { hasChanges = true }.onChange(of: style.mode) { hasChanges = true }.onChange(of: style.rules) { hasChanges = true }.foregroundStyle(KiviTheme.ink).background(drawerColor).overlay(alignment: .leading) { Rectangle().fill(KiviTheme.line).frame(width: 1) }
    }
    private var headerDescription: String {
        if category == "other" { return "this style is used for every app that isn't in another style." }
        if apps.count == 1 { return "this style is used by 1 app. editing the style or its rules changes it for that app." }
        return "this style is shared by \(apps.count) apps. editing the style or its rules changes it for all of them."
    }
    private var categoryIcon: String { "person.2" }
    private func drawerSection(_ title: String) -> some View {
        HStack(spacing: 12) { Text(title).font(KiviTheme.medium(14)); Rectangle().fill(KiviTheme.line).frame(height: 1) }
    }
}

private struct StyleModeCard: View {
    let mode: StyleMode
    let category: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false
    private var textColor: Color { KiviTheme.ink }
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(mode.name).font(KiviTheme.medium(16))
                    Spacer(minLength: 0)
                    if selected { Image(systemName: "checkmark").font(.system(size: 13)).foregroundStyle(KiviTheme.background).frame(width: 19, height: 19).background(KiviTheme.green, in: Circle()) }
                    else { Circle().stroke(KiviTheme.line, lineWidth: 1.5).frame(width: 18, height: 18) }
                }
                Text(mode.description).font(KiviTheme.body(13)).foregroundStyle(textColor.opacity(0.65)).lineSpacing(2).frame(height: 38, alignment: .topLeading).padding(.top, 6)
                Spacer(minLength: 10)
                miniPreview
            }.padding(12).frame(maxWidth: .infinity).frame(height: 236).foregroundStyle(textColor)
                .background(selected ? KiviTheme.green.opacity(0.10) : KiviTheme.panel.opacity(hovering ? 0.95 : 0.6), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? KiviTheme.green : (hovering ? KiviTheme.green.opacity(0.45) : KiviTheme.line), lineWidth: selected ? 2 : 1))
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
    private var miniPreview: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach([Color(red: 0.88, green: 0.39, blue: 0.36), Color(red: 0.92, green: 0.73, blue: 0.34), Color(red: 0.40, green: 0.66, blue: 0.41)], id: \.self) { color in Rectangle().fill(color).frame(width: 4, height: 4) }
                Rectangle().fill(.gray.opacity(0.65)).frame(width: 50, height: 4).padding(.leading, 4)
                Spacer()
                Rectangle().fill(KiviTheme.green).frame(width: 4, height: 4)
            }.padding(.horizontal, 6).frame(height: 13).background(Color(white: 0.15))
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: category == "personal" ? 5 : 7) {
                    ForEach(0..<4) { i in
                        HStack(spacing: 4) {
                            if category == "work" || category == "personal" { Rectangle().fill(i == 1 ? KiviTheme.green : Color.gray.opacity(0.5)).frame(width: category == "work" ? 4 : 10, height: category == "work" ? 4 : 10) }
                            Rectangle().fill(category == "work" ? Color(red: 0.54, green: 0.37, blue: 0.56) : (i == 0 && category == "email" ? .blue : Color(white: 0.40))).frame(height: 3)
                        }
                    }
                    Spacer(minLength: 0)
                }.padding(.horizontal, 7).padding(.top, 9).frame(width: category == "work" || category == "personal" ? 44 : 36, height: 84, alignment: .topLeading).background(category == "work" ? Color(red: 0.16, green: 0.10, blue: 0.16) : Color(white: 0.09))
                if category == "work" || category == "personal" {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 4) { if category == "work" { Rectangle().fill(Color.yellow.opacity(0.7)).frame(width: 11, height: 11) }; Rectangle().fill(Color.gray.opacity(0.75)).frame(width: 40, height: 3); Spacer() }
                        HStack(alignment: .top, spacing: 4) {
                            if category == "work" { Rectangle().fill(KiviTheme.green).frame(width: 11, height: 11) }
                            Text(mode.example).font(KiviTheme.body(category == "work" ? 5.7 : 6.7)).lineSpacing(1.5).foregroundStyle(Color(white: 0.92)).padding(4).frame(maxWidth: .infinity, alignment: .leading).background(category == "work" ? Color(red: 0.12, green: 0.18, blue: 0.11) : Color(red: 0.17, green: 0.34, blue: 0.19))
                        }
                        Spacer(minLength: 0)
                    }.padding(8).frame(maxWidth: .infinity).frame(height: 84).background(Color(white: 0.075))
                } else {
                    VStack(alignment: .leading, spacing: 5) {
                        Rectangle().fill(category == "developer" ? Color(white: 0.14) : Color(white: 0.45)).frame(width: category == "email" ? 80 : 52, height: category == "email" ? 3 : 6)
                        HStack(spacing: 3) {
                            if category == "developer" { Rectangle().fill(KiviTheme.green.opacity(0.8)).frame(width: 3) }
                            Text(mode.example).font(category == "developer" ? KiviTheme.mono(mode.name == "structured" ? 5.3 : 7.0) : KiviTheme.body(category == "email" ? 5.9 : 7.7)).lineSpacing(category == "email" ? 1 : 1.2).foregroundStyle(category == "developer" ? Color(white: 0.9) : Color(white: 0.20)).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        }.padding(category == "developer" ? 2 : 0).background(category == "developer" ? Color(red: 0.11, green: 0.14, blue: 0.12) : .clear)
                    }.padding(.horizontal, 8).padding(.vertical, category == "email" ? 6 : 10).frame(maxWidth: .infinity).frame(height: 84).background(category == "developer" ? Color(white: 0.11) : Color(red: 0.96, green: 0.95, blue: 0.91))
                }
            }
            Spacer(minLength: 0)
        }.frame(height: 135).background(Color(white: 0.06), in: RoundedRectangle(cornerRadius: 7)).clipShape(RoundedRectangle(cornerRadius: 7)).overlay(RoundedRectangle(cornerRadius: 7).stroke(KiviTheme.line)).padding(2).background(Color.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
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
        }.frame(width: 380, height: 460).foregroundStyle(KiviTheme.ink).background(KiviBackground()).clipShape(RoundedRectangle(cornerRadius: 18))
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
