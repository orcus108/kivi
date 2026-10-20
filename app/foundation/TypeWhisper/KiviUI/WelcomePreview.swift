import SwiftUI

/// Replays observed onboarding screens without requesting access or changing preferences.
struct WelcomePreview: View {
    @EnvironmentObject var model: AppModel
    @State private var stage = 0
    @State private var language = "Auto-detect"
    @State private var second = "None"
    @State private var roman = true
    private let ink = Color(red: 0.035, green: 0.035, blue: 0.055)
    private let green = Color(red: 0.28, green: 0.40, blue: 0.19)
    private let light = Color(red: 0.99, green: 1, blue: 0.94)
    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color(red: 0.97, green: 0.97, blue: 0.96)
                RadialGradient(colors: [Color(red: 0.89, green: 0.92, blue: 0.83).opacity(0.8), .clear], center: .topLeading, startRadius: 0, endRadius: geo.size.width * 0.85)
                RadialGradient(colors: [Color(red: 1, green: 1, blue: 0.85).opacity(0.5), .clear], center: .bottomTrailing, startRadius: 0, endRadius: geo.size.width * 0.55)
                if stage == 0 {
                    Text("Hi, welcome to Kivi!").font(KiviTheme.greeting(65))
                } else if stage == 1 {
                    VStack(spacing: 35) {
                        (Text("Where your thoughts\nturn into text,\n") + Text("everywhere.").foregroundColor(green)).font(KiviTheme.greeting(65)).lineSpacing(1).multilineTextAlignment(.center)
                        welcomeButton("Let’s begin") { stage = 2 }
                        Text("Press return ↵").font(KiviTheme.body(17)).foregroundStyle(.gray).padding(.top, -12)
                    }.offset(y: 32)
                    bird("onboarding-happy", width: 210).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading).padding(.leading, geo.size.width * 0.13).padding(.bottom, 18)
                } else if stage == 2 {
                    VStack(spacing: 0) {
                        Text("Your languages. Your voice.").font(KiviTheme.greeting(50)).padding(.top, 98)
                        Text("Speak naturally, in one language or a mix. Kivi will write it down.\nTell us the languages you use most.").font(KiviTheme.body(20)).foregroundStyle(.gray).multilineTextAlignment(.center).lineSpacing(7).padding(.top, 22)
                        HStack(spacing: 30) {
                            welcomeLanguage("Primary language", value: $language, choices: ["Auto-detect", "English", "हिन्दी (Hindi)", "தமிழ் (Tamil)"])
                            welcomeLanguage("Second language · optional", value: $second, choices: ["None", "English", "हिन्दी (Hindi)", "தமிழ் (Tamil)"])
                        }.frame(maxWidth: 736).padding(.top, 54)
                        Text("How should your words look?").font(KiviTheme.medium(19)).padding(.top, 66)
                        HStack(spacing: 0) {
                            scriptButton("English letters", isRoman: true)
                            scriptButton("Native script", isRoman: false)
                        }.padding(4).background(light, in: Capsule()).frame(width: 425).padding(.top, 16)
                        Text(roman ? "namaste, aap kaise hain?" : "नमस्ते, आप कैसे हैं?").font(KiviTheme.body(25)).padding(.top, 50)
                        Spacer(minLength: 24)
                        welcomeButton("Continue") { stage = 3 }.padding(.bottom, 38)
                    }
                    Button("Skip for now") { stage = 3 }.buttonStyle(.plain).font(KiviTheme.body(18)).foregroundStyle(.gray).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing).padding(.trailing, geo.size.width * 0.13).padding(.bottom, 34)
                } else {
                    VStack(spacing: 0) {
                        bird("onboarding-nest", width: 108).padding(.top, 62)
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Accessibility").font(KiviTheme.body(14))
                            Divider()
                            HStack(spacing: 18) {
                                if let icon = KiviTheme.image("AppIcon") { Image(nsImage: icon).resizable().frame(width: 34, height: 34) }
                                Text("Kivi").font(KiviTheme.body(18))
                                Spacer()
                                Capsule().fill(Color.gray.opacity(0.18)).frame(width: 58, height: 26).overlay(alignment: .leading) { Circle().fill(.white).frame(width: 22, height: 22).shadow(radius: 3).padding(2) }
                            }.padding(12)
                            Text("Privacy & Security").font(KiviTheme.body(14)).foregroundStyle(.gray)
                        }.frame(width: 325).padding(.top, 54)
                        Text("Enable Accessibility").font(KiviTheme.greeting(50)).padding(.top, 53)
                        Text("Turn on Kivi in System Settings so it can\ntype wherever your cursor is.").font(KiviTheme.body(20)).foregroundStyle(.gray).lineSpacing(7).multilineTextAlignment(.center).padding(.top, 15)
                        welcomeButton("Open System Settings") { model.showWelcome = false; model.page = .settings; model.settingsSection = "permissions"; model.bridge.requestAccessibility() }.help("Open macOS Accessibility settings for this application.").padding(.top, 19)
                        Button("recovery options →") { model.showWelcome = false }.buttonStyle(.plain).font(KiviTheme.body(15)).foregroundStyle(green).padding(.top, 20)
                        Spacer(minLength: 30)
                    }.frame(width: 640, height: min(678, geo.size.height - 100)).background(.white, in: RoundedRectangle(cornerRadius: 13)).overlay(RoundedRectangle(cornerRadius: 13).stroke(Color.black.opacity(0.08)))
                }
                Button { model.showWelcome = false } label: { Image(systemName: "xmark").font(.system(size: 13)).frame(width: 30, height: 30) }.buttonStyle(.plain).foregroundStyle(.gray.opacity(0.6)).help("Close welcome preview").accessibilityLabel("close welcome preview").frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(20)
            }.foregroundStyle(ink).preferredColorScheme(.light)
                .task { try? await Task.sleep(for: .seconds(1.4)); if !Task.isCancelled && stage == 0 { withAnimation(.easeInOut(duration: 0.6)) { stage = 1 } } }
                .onKeyPress(.return) { stage = min(stage + 1, 3); return .handled }
                .onKeyPress(.escape) { model.showWelcome = false; return .handled }
        }
    }
    private func bird(_ name: String, width: CGFloat) -> some View {
        Group { if let image = KiviTheme.image(name) { Image(nsImage: image).resizable().scaledToFit().frame(width: width) } }
    }
    private func welcomeButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).font(KiviTheme.medium(19)).foregroundStyle(.white).frame(width: title == "Open System Settings" ? 300 : 250, height: 56).background(ink, in: Capsule()) }.buttonStyle(.plain)
    }
    private func welcomeLanguage(_ label: String, value: Binding<String>, choices: [String]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(label).font(KiviTheme.body(18)).foregroundStyle(.gray).padding(.leading, 20)
            Menu { ForEach(choices, id: \.self) { choice in Button(choice) { value.wrappedValue = choice } } } label: {
                HStack { Text(value.wrappedValue).font(KiviTheme.body(20)); Spacer(); Image(systemName: "chevron.down").foregroundStyle(green) }.padding(.horizontal, 22).frame(height: 62).background(light, in: Capsule()).overlay(Capsule().stroke(Color.black.opacity(0.08)))
            }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        }.frame(maxWidth: .infinity)
    }
    private func scriptButton(_ title: String, isRoman: Bool) -> some View {
        Button { roman = isRoman } label: {
            HStack(spacing: 8) { if roman == isRoman { Image(systemName: "checkmark") }; Text(title) }.font(KiviTheme.body(18)).foregroundStyle(roman == isRoman ? green : .gray).frame(maxWidth: .infinity).frame(height: 47).background(roman == isRoman ? Color(red: 0.90, green: 0.94, blue: 0.79) : .clear, in: Capsule())
        }.buttonStyle(.plain)
    }
}
