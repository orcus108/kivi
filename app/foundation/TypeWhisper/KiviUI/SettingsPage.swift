import SwiftUI
import AppKit
import AVFoundation
import Speech
import ServiceManagement

/// The settings surface follows the observed native app. Account and service controls
/// are session-only visual previews; local controls retain their real behavior.
struct SettingsPage: View {
    @EnvironmentObject var model: AppModel
    private let dictation = DictationViewModel.shared
    @StateObject private var signals = KiviSettingsSignals()
    private let devices = ServiceContainer.shared.audioDeviceService
    @AppStorage(IntentTextPipeline.cleanupKey) private var cleanup = true
    @AppStorage(IntentTextPipeline.structureKey) private var structure = true
    @AppStorage(TargetAppCorrectionLearningService.localEnabledKey) private var learning = false
    @AppStorage(UserDefaultsKeys.historyEnabled) private var keepHistory = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var search = ""
    @State private var previewValues: [String: Bool] = [:]
    private let pillPreview = IndicatorPreviewSession.shared
    @State private var inactivity = "3 min"
    @State private var confirmClear = false
    @State private var permissionRefresh = false
    private let mainSections = ["general", "shortcuts", "the orb", "microphone", "permissions"]
    private let personalSections = ["privacy & data", "plan & billing", "account", "about"]
    private let icons = ["general": "gearshape", "shortcuts": "keyboard", "the orb": "circle", "microphone": "mic", "permissions": "checkmark.shield", "privacy & data": "lock", "plan & billing": "creditcard", "account": "person.crop.circle", "about": "info.circle"]

    var body: some View {
        let _ = signals.revision
        HStack(spacing: 0) {
            sidebar
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text(model.settingsSection).font(.custom("Matter-SemiBold", size: 22))
                        Spacer()
                        if mainSections.contains(model.settingsSection) {
                            Button { resetPage() } label: { Label("reset", systemImage: "arrow.counterclockwise") }.buttonStyle(KiviButton()).help("Reset this page’s local display preferences")
                        }
                    }.frame(height: 30).padding(.bottom, 30)
                    detail
                }.padding(.horizontal, 32).padding(.top, 44).padding(.bottom, 44).frame(maxWidth: .infinity, alignment: .leading)
            }.id(model.settingsSection)
        }
        .foregroundStyle(KiviTheme.ink)
        .onAppear { model.refreshEngineStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in permissionRefresh.toggle(); model.refreshEngineStatus() }
        .confirmationDialog("Clear all saved takes?", isPresented: $confirmClear) {
            Button("clear history", role: .destructive) { model.clearHistory() }
            Button("cancel", role: .cancel) {}
        } message: { Text("This permanently removes your saved takes and their stored audio.") }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").font(.system(size: 12))
                TextField("search settings", text: $search).textFieldStyle(.plain).font(KiviTheme.body(13))
            }.foregroundStyle(KiviTheme.muted).padding(.horizontal, 10).frame(height: 30)
                .background(KiviTheme.panel, in: RoundedRectangle(cornerRadius: 7)).overlay(RoundedRectangle(cornerRadius: 7).stroke(KiviTheme.line))
            Button { model.settingsSection = "account" } label: {
                HStack(spacing: 10) {
                    avatar(size: 32)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) { Text("Vedant Misra").font(KiviTheme.medium(14)); proBadge }
                        Text("personal").font(KiviTheme.body(13)).foregroundStyle(KiviTheme.muted)
                    }
                    Spacer(minLength: 0)
                }.padding(.horizontal, 10).padding(.vertical, 18)
            }.buttonStyle(.plain)
            sidebarLabel("kivi")
            ForEach(mainSections.filter(matches), id: \.self) { sidebarRow($0) }
            sidebarLabel("you").padding(.top, 20)
            ForEach(personalSections.filter(matches), id: \.self) { sidebarRow($0) }
            Spacer()
            Rectangle().fill(KiviTheme.line).frame(height: 1).padding(.bottom, 14)
            Text("kivi 2026.10.18.0630").font(KiviTheme.mono(10)).foregroundStyle(KiviTheme.muted).padding(.leading, 10).padding(.bottom, 5)
        }.padding(.horizontal, 10).padding(.top, 44).padding(.bottom, 12).frame(width: 232)
            .background(KiviTheme.panel.opacity(0.13)).overlay(alignment: .trailing) { Rectangle().fill(KiviTheme.line).frame(width: 1) }
    }
    private func matches(_ title: String) -> Bool { search.isEmpty || title.localizedCaseInsensitiveContains(search) }
    private func sidebarLabel(_ title: String) -> some View {
        Text(title).font(KiviTheme.mono(10)).foregroundStyle(KiviTheme.muted).padding(.leading, 10).padding(.bottom, 7)
    }
    private func sidebarRow(_ title: String) -> some View {
        Button { model.settingsSection = title } label: {
            HStack(spacing: 9) {
                Image(systemName: icons[title] ?? "circle").font(.system(size: 13)).frame(width: 17)
                Text(title).font(KiviTheme.body(14))
                Spacer()
            }.padding(.horizontal, 10).frame(height: 34)
                .foregroundStyle(model.settingsSection == title ? KiviTheme.green : KiviTheme.ink)
                .background(model.settingsSection == title ? KiviTheme.green.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain)
    }
    @ViewBuilder private var detail: some View {
        switch model.settingsSection {
        case "shortcuts": shortcuts
        case "the orb": orb
        case "microphone": microphone
        case "permissions": permissions
        case "privacy & data": privacy
        case "plan & billing": billing
        case "account": account
        case "about": about
        default: general
        }
    }

    private var general: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("appearance")
            group {
                HStack(spacing: 16) {
                    ForEach(["light", "dark", "system"], id: \.self) { appearanceChoice($0) }
                }.padding(18)
            }
            caption("the orb and its transcript box follow this too.").padding(.top, 5)
            sectionLabel("behavior").padding(.top, 30)
            group {
                settingsRow("open at restart", "open kivi automatically when you log in to your Mac.") { Toggle("open at restart", isOn: $launchAtLogin).labelsHidden().toggleStyle(.checkbox).tint(KiviTheme.green).onChange(of: launchAtLogin) { _, enabled in Task { do { if enabled { try SMAppService.mainApp.register() } else { try await SMAppService.mainApp.unregister() } } catch { launchAtLogin = SMAppService.mainApp.status == .enabled; model.notify(error.localizedDescription) } } } }
                rowDivider
                settingsRow("recording and recovery", "input, cancellation, recovery and transcription options") { Button("configure") { model.openAdvanced("microphone") }.buttonStyle(KiviButton()) }
                rowDivider
                settingsRow("reduce animation", "calms the orb, box, and pill motion for a snappier feel.") {
                    Toggle("reduce animation", isOn: $model.saved.reduceMotion).labelsHidden().toggleStyle(SettingsSwitchStyle()).onChange(of: model.saved.reduceMotion) { model.persist() }
                }
            }
            sectionLabel("getting started").padding(.top, 30)
            group {
                settingsRow("welcome demo", "replay the first-run walkthrough.") { Button("replay") { model.showWelcome = true }.buttonStyle(KiviButton()) }
            }
            localAdvanced.padding(.top, 30)
        }
    }
    private func appearanceChoice(_ mode: String) -> some View {
        Button { model.saved.appearance = mode; model.persist() } label: {
            VStack(spacing: 10) {
                GeometryReader { geometry in
                    ZStack {
                        appearanceMini(dark: mode == "dark")
                        if mode == "system" {
                            appearanceMini(dark: true).mask {
                                Path { p in p.move(to: CGPoint(x: 0, y: geometry.size.height)); p.addLine(to: CGPoint(x: geometry.size.width, y: 0)); p.addLine(to: CGPoint(x: geometry.size.width, y: geometry.size.height)); p.closeSubpath() }
                            }
                        }
                    }.clipShape(RoundedRectangle(cornerRadius: 7)).overlay(RoundedRectangle(cornerRadius: 7).stroke(model.saved.appearance == mode ? KiviTheme.green : KiviTheme.line, lineWidth: model.saved.appearance == mode ? 2 : 1))
                }.frame(height: 87)
                HStack(spacing: 5) {
                    if model.saved.appearance == mode { Circle().fill(KiviTheme.green).frame(width: 5, height: 5) }
                    Text(mode).font(KiviTheme.body(14))
                }
            }.frame(maxWidth: .infinity)
        }.buttonStyle(.plain)
    }
    private func appearanceMini(dark: Bool) -> some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(0..<3) { i in Capsule().fill(i == 0 ? KiviTheme.green.opacity(0.45) : Color.gray.opacity(0.25)).frame(height: 4) }
                    Spacer(minLength: 0)
                }.padding(6).frame(width: geometry.size.width * 0.30).background(dark ? KiviTheme.panel : Color(white: 0.98))
                Rectangle().fill(Color.gray.opacity(0.2)).frame(width: 1)
                VStack(alignment: .leading, spacing: 5) {
                    Capsule().fill(Color.gray.opacity(0.30)).frame(height: 5)
                    Capsule().fill(Color.gray.opacity(0.30)).frame(width: geometry.size.width * 0.44, height: 5)
                    Spacer(minLength: 0)
                    HStack { Spacer(); Circle().fill(dark ? KiviTheme.ink : Color(white: 0.12)).frame(width: 11, height: 11) }
                }.padding(8).frame(maxWidth: .infinity).background(dark ? KiviTheme.background : Color(red: 0.97, green: 0.96, blue: 0.92))
            }
        }
    }

    private var shortcuts: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("the kivi key")
            group {
                settingsRow("kivi key", "hold to dictate or tap to toggle, using your existing shortcut") { Button(dictation.hybridHotkeyLabel.isEmpty ? "set shortcut" : dictation.hybridHotkeyLabel) { model.openAdvanced("hotkeys") }.buttonStyle(KiviButton()) }
                rowDivider
                settingsRow("edit selected text", "select text in another app, then choose this from the menu bar") { Button("open editor") { IntentSelectionEditor.shared.captureSelection() }.buttonStyle(KiviButton()) }
                rowDivider
                settingsRow("cancel take", "choose how escape cancels a recording") { Picker("cancel take", selection: Binding(get: { dictation.cancellationBehavior }, set: { dictation.cancellationBehavior = $0 })) { ForEach(CancellationBehavior.allCases, id: \.self) { Text($0.title).tag($0) } }.labelsHidden().frame(width: 130) }
            }
            sectionLabel("text").padding(.top, 30)
            group {
                settingsRow("paste last content", "your most recent take, ready to use again") { Button(dictation.pasteLastTranscriptionHotkeyLabel.isEmpty ? "set shortcut" : dictation.pasteLastTranscriptionHotkeyLabel) { model.openAdvanced("hotkeys") }.buttonStyle(KiviButton()) }
            }
            Button("all shortcuts and recording modes →") { model.openAdvanced("hotkeys") }.buttonStyle(KiviButton()).padding(.top, 24)
        }
    }

    private var orb: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("recording pill")
            caption("the compact recording indicator from your TypeWhisper version.").padding(.bottom, 20)
            group {
                settingsRow("look", "the same listening, processing and feedback animations") {
                    Button("restore TypeWhisper look") {
                        dictation.indicatorStyle = .minimal
                        dictation.indicatorTheme = .classic
                        dictation.notchIndicatorRightContent = .waveform
                    }.buttonStyle(KiviButton())
                }
                rowDivider
                settingsRow("preview", "see the listening animation without using your microphone") {
                    Button(pillPreview.isActive ? "stop preview" : "preview pill") {
                        if pillPreview.isActive { pillPreview.stop() } else { pillPreview.start() }
                    }.buttonStyle(KiviButton())
                }
            }
            sectionLabel("visibility & place").padding(.top, 30)
            group {
                settingsRow("show pill", "choose when the recording indicator appears") {
                    Picker("show pill", selection: Binding(get: { dictation.notchIndicatorVisibility }, set: { dictation.notchIndicatorVisibility = $0 })) {
                        Text("while active").tag(NotchIndicatorVisibility.duringActivity)
                        Text("always").tag(NotchIndicatorVisibility.always)
                        Text("never").tag(NotchIndicatorVisibility.never)
                    }.labelsHidden().frame(width: 140)
                }
                rowDivider
                settingsRow("position", "keep the pill at the top or bottom of the screen") {
                    Picker("position", selection: Binding(get: { dictation.overlayPosition }, set: { dictation.overlayPosition = $0 })) {
                        Text("bottom").tag(OverlayPosition.bottom)
                        Text("top").tag(OverlayPosition.top)
                    }.labelsHidden().frame(width: 140)
                }
                rowDivider
                settingsRow("center pill", "align with the middle of its screen, keeping its top or bottom position") {
                    Button("Center pill") { NotificationCenter.default.post(name: .centerRecordingPill, object: nil) }.buttonStyle(KiviButton())
                }
                rowDivider
                settingsRow("visible in screen captures", "include the pill in screenshots and screen sharing") {
                    Toggle("visible in screen captures", isOn: Binding(get: { dictation.indicatorVisibleInScreenCaptures }, set: { dictation.indicatorVisibleInScreenCaptures = $0 })).labelsHidden().toggleStyle(SettingsSwitchStyle())
                }
                rowDivider
                settingsRow("live typing", "insert partial text in supported apps") {
                    Toggle("live typing", isOn: Binding(get: { dictation.liveFieldTranscriptEnabled }, set: { dictation.liveFieldTranscriptEnabled = $0 })).labelsHidden().toggleStyle(SettingsSwitchStyle())
                }
            }
            sectionLabel("feedback").padding(.top, 30)
            group {
                settingsRow("spoken feedback", "read feedback aloud") { Toggle("spoken feedback", isOn: Binding(get: { dictation.spokenFeedbackEnabled }, set: { dictation.spokenFeedbackEnabled = $0 })).labelsHidden().toggleStyle(SettingsSwitchStyle()) }
                rowDivider
                settingsRow("sounds", "a small sound when recording starts and stops") { Toggle("sounds", isOn: Binding(get: { dictation.soundFeedbackEnabled }, set: { dictation.soundFeedbackEnabled = $0 })).labelsHidden().toggleStyle(SettingsSwitchStyle()) }
                rowDivider
                settingsRow("indicator options", "more display, transcript and appearance settings") { Button("configure") { model.openAdvanced("appearance") }.buttonStyle(KiviButton()) }
            }
        }.onDisappear { pillPreview.stop() }
    }

    private var microphone: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("input")
            group {
                settingsRow("input device", devices.disconnectedDeviceName.map { "disconnected: \($0)" } ?? "your existing audio input, with the same capture engine") {
                    Menu {
                        Button("system default") { devices.selectedDeviceUID = nil }
                        ForEach(devices.inputDevices, id: \.uid) { device in Button(device.name) { devices.selectedDeviceUID = device.uid } }
                    } label: { menuLabel(devices.inputDevices.first(where: { $0.uid == devices.selectedDeviceUID })?.name ?? "system default") }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                }
                rowDivider
                settingsRow("test your mic", devices.previewError?.localizedDescription ?? "speak to see your input level") {
                    HStack { KiviDeviceMeter(devices: devices, reduceMotion: model.saved.reduceMotion).frame(width: 70); Button(devices.isPreviewActive ? "stop" : "test") { if devices.isPreviewActive { devices.stopPreview() } else { devices.startPreview() } }.buttonStyle(KiviButton()) }
                }
            }
            Button("input priority and recording options →") { model.openAdvanced("microphone") }.buttonStyle(KiviButton()).padding(.top, 24)
        }.onDisappear { devices.stopPreview() }
    }

    private var permissions: some View {
        let micAllowed = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let accessibility = model.bridge.hasAccessibility
        return VStack(alignment: .leading, spacing: 0) {
            group {
                settingsRow("microphone", "lets kivi hear you when you dictate") {
                    if micAllowed { permissionBadge("granted") }
                    else { Button("allow") { AVCaptureDevice.requestAccess(for: .audio) { _ in DispatchQueue.main.async { permissionRefresh.toggle() } } }.buttonStyle(KiviButton()) }
                }
                rowDivider
                settingsRow("accessibility", "lets kivi type into your apps") {
                    if accessibility { permissionBadge("active this session") }
                    else { Button("allow") { model.bridge.requestAccessibility(); permissionRefresh.toggle() }.buttonStyle(KiviButton()) }
                }
                rowDivider
                settingsRow("target-app context", "the existing insertion engine detects the active app and supported text fields") { Image(systemName: accessibility ? "checkmark.circle" : "lock").foregroundStyle(accessibility ? KiviTheme.green : KiviTheme.muted) }
            }.id(permissionRefresh)
            caption("The selected speech engine handles recognition. Parakeet runs locally and does not require Apple Speech Recognition access.").padding(.top, 18)
        }
    }
    private func permissionBadge(_ text: String) -> some View {
        HStack(spacing: 6) { Image(systemName: "checkmark.circle.fill").font(.system(size: 12)); Text(text).font(KiviTheme.body(13)) }.foregroundStyle(KiviTheme.green)
    }

    private var privacy: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("your data")
            group {
                settingsRow("save history", "keep completed takes on this Mac") { Toggle("save history", isOn: $keepHistory).labelsHidden().toggleStyle(SettingsSwitchStyle()).disabled(model.incognito) }
                rowDivider
                settingsRow("incognito", "new takes and correction learning are not saved") { Toggle("incognito", isOn: $model.incognito).labelsHidden().toggleStyle(SettingsSwitchStyle()) }
                rowDivider
                settingsRow("recover interrupted recordings", "review a failed take and retry it explicitly") { Button("open recovery") { model.openAdvanced("recovery") }.buttonStyle(KiviButton()) }
                rowDivider
                settingsRow("export your dictations", "save this app’s history as a text file") { Button("export") { model.exportHistory() }.buttonStyle(KiviButton()) }
            }
            sectionLabel("on this Mac").padding(.top, 30)
            group {
                settingsRow("independent storage", "changes here never change the working TypeWhisper version") { Image(systemName: "internaldrive").foregroundStyle(KiviTheme.green) }
                rowDivider
                settingsRow("retention and backups", "manage recording audio, history retention and local backups") { Button("configure") { model.openAdvanced("privacy") }.buttonStyle(KiviButton()) }
            }
            Text(model.dataDirectory.path).font(KiviTheme.mono(11)).foregroundStyle(KiviTheme.muted).textSelection(.enabled).padding(.top, 18)
        }
    }

    private var billing: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 24) {
                HStack { Text("kivi").font(KiviTheme.serif(34)); Text("local").font(KiviTheme.serif(27)).italic().foregroundStyle(KiviTheme.green); Spacer(); Text("personal").font(KiviTheme.mono(11)).foregroundStyle(KiviTheme.muted) }
                HStack(alignment: .firstTextBaseline) { KiviTodayWords(history: model.history); Text("words today").foregroundStyle(KiviTheme.muted); Spacer() }
                Rectangle().fill(KiviTheme.line).frame(height: 1)
                Text("Your existing engines, your Mac. No Kivi subscription is connected to this independent build.").font(KiviTheme.body(15)).foregroundStyle(KiviTheme.muted)
            }.padding(24).background(LinearGradient(colors: [KiviTheme.green.opacity(0.13), KiviTheme.panel], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 9)).overlay(RoundedRectangle(cornerRadius: 9).stroke(KiviTheme.green.opacity(0.2)))
            sectionLabel("capabilities").padding(.top, 30)
            group { settingsRow("speech and editing models", model.modelStatus) { Button("manage") { model.openAdvanced("models") }.buttonStyle(KiviButton()) } }
        }
    }

    private var account: some View {
        VStack(alignment: .leading, spacing: 0) {
            group {
                HStack(spacing: 18) { avatar(size: 56); VStack(alignment: .leading, spacing: 8) { Text("Vedant Misra").font(KiviTheme.medium(20)); caption("personal · on this Mac") }; Spacer() }.padding(24)
                rowDivider
                settingsRow("local workspace", "your functional app, separate from the original Kivi and Intent installations") { Image(systemName: "checkmark.circle").foregroundStyle(KiviTheme.green) }
            }
            sectionLabel("your setup").padding(.top, 30)
            group {
                settingsRow("engines and integrations", "manage your existing speech and text providers") { Button("configure") { model.openAdvanced("models") }.buttonStyle(KiviButton()) }
                rowDivider
                settingsRow("data and privacy", "your dictations, retention and exports") { Button("open") { model.settingsSection = "privacy & data" }.buttonStyle(KiviButton()) }
            }
        }
    }

    private var about: some View {
        VStack(alignment: .leading, spacing: 0) {
            group {
                HStack(spacing: 16) {
                    if let icon = NSImage(named: NSImage.applicationIconName) { Image(nsImage: icon).resizable().frame(width: 46, height: 46) }
                    if let wordmark = KiviTheme.image("kivi-wordmark") { Image(nsImage: wordmark).resizable().scaledToFit().frame(width: 94, height: 60) }
                    else { Text("kivi").font(KiviTheme.serif(60)) }
                    Spacer()
                    Button { model.notify("Independent private UI study of Kivi by Sarvam AI. Combined version 1.0. Original artwork and fonts belong to their respective owners.") } label: { Image(systemName: "questionmark.circle").font(.system(size: 17)) }.buttonStyle(.plain).foregroundStyle(KiviTheme.muted).help("About this independent recreation")
                }.padding(20)
                rowDivider
                settingsRow("software updates", "you’re using the local development build") { Button("check now") { model.notify("Kivi Dev 1.0 · built locally. Automatic upstream replacement is disabled.") }.buttonStyle(KiviButton()) }
            }
            sectionLabel("follow kivi").padding(.top, 30)
            group {
                settingsRow("come talk to us", "@heykiviai") {
                    HStack(spacing: 8) {
                        Link(destination: URL(string: "https://x.com/heykiviai")!) { Text("𝕏").font(.system(size: 17)).frame(width: 32, height: 30).overlay(RoundedRectangle(cornerRadius: 6).stroke(KiviTheme.line)) }
                        Link(destination: URL(string: "https://www.instagram.com/heykiviai/")!) { Image(systemName: "camera").font(.system(size: 15)).frame(width: 32, height: 30).overlay(RoundedRectangle(cornerRadius: 6).stroke(KiviTheme.line)) }
                    }.foregroundStyle(KiviTheme.ink)
                }
            }
            group { settingsRow("privacy policy", "how kivi handles your data") { Link(destination: URL(string: "https://heykivi.ai/privacy")!) { Image(systemName: "arrow.up.right").font(.system(size: 13)).frame(width: 30, height: 28) }.foregroundStyle(KiviTheme.muted) } }.padding(.top, 14)
            Text("Kivi Dev · private build · TypeWhisper foundation · no Sarvam affiliation").font(KiviTheme.mono(10)).foregroundStyle(KiviTheme.muted).padding(.top, 18)
        }
    }

    private var localAdvanced: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("your words")
            group {
                settingsRow("light cleanup", "remove clear hesitations and accidental repeats") { Toggle("light cleanup", isOn: $cleanup).labelsHidden().toggleStyle(SettingsSwitchStyle()) }
                rowDivider
                settingsRow("automatic structure", "format explicit lists and new paragraph instructions") { Toggle("automatic structure", isOn: $structure).labelsHidden().toggleStyle(SettingsSwitchStyle()) }
                rowDivider
                settingsRow("literal text", "skip ordinary cleanup, dictionary and shortcut expansion") { Toggle("literal text", isOn: $model.saved.literal).labelsHidden().toggleStyle(SettingsSwitchStyle()).onChange(of: model.saved.literal) { model.persist() } }
                rowDivider
                settingsRow("learn from corrections", "learn conservative name spellings from repeated verified edits") { Toggle("learn from corrections", isOn: $learning).labelsHidden().toggleStyle(SettingsSwitchStyle()).disabled(model.incognito) }
            }
            sectionLabel("engines & tools").padding(.top, 30)
            group {
                settingsRow("speech engine", model.modelStatus) { Button("manage engines") { model.openAdvanced("models") }.buttonStyle(KiviButton()) }
                rowDivider
                settingsRow("spoken self-corrections", "configure your optional API cleanup, or keep processing local") { Button("configure") { model.openAdvanced("general") }.buttonStyle(KiviButton()) }
                rowDivider
                settingsRow("selection editing", "type an instruction, review the preview, then apply or copy") { Button("open editor") { model.openEditor() }.buttonStyle(KiviButton()) }
                rowDivider
                settingsRow("workflows, files and recordings", "all of your foundation’s tools remain available") { Button("all tools") { model.openAdvanced("workflows") }.buttonStyle(KiviButton()) }
            }
        }
    }

    private var proBadge: some View { Text("pro").font(KiviTheme.serif(12)).italic().foregroundStyle(KiviTheme.green).padding(.horizontal, 5).padding(.vertical, 1).background(KiviTheme.green.opacity(0.10), in: Capsule()) }
    private func avatar(size: CGFloat) -> some View {
        Text("V").font(KiviTheme.medium(size * 0.39)).foregroundStyle(Color(red: 0.77, green: 0.85, blue: 0.70)).frame(width: size, height: size).background(Color(red: 0.19, green: 0.25, blue: 0.16), in: Circle()).overlay(Circle().stroke(KiviTheme.line, lineWidth: 3))
    }
    private func sectionLabel(_ text: String) -> some View { Text(text).font(KiviTheme.medium(16)).padding(.bottom, 9) }
    private func caption(_ text: String) -> some View { Text(text).font(KiviTheme.body(13)).foregroundStyle(KiviTheme.muted).fixedSize(horizontal: false, vertical: true) }
    private func group<Content: View>(@ViewBuilder content: () -> Content) -> some View { VStack(spacing: 0, content: content).frame(maxWidth: .infinity).background(KiviTheme.panel, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(KiviTheme.line)) }
    private var rowDivider: some View { Rectangle().fill(KiviTheme.line).frame(height: 1).padding(.horizontal, 20) }
    private func settingsRow<Content: View>(_ title: String, _ subtitle: String, info: Bool = false, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) { Text(title).font(KiviTheme.medium(16)); if info { Image(systemName: "info.circle").font(.system(size: 11)).foregroundStyle(KiviTheme.muted) } }
                Text(subtitle).font(KiviTheme.body(14)).foregroundStyle(KiviTheme.muted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            content()
        }.padding(.horizontal, 20).padding(.vertical, 12).frame(minHeight: 66)
    }
    private func previewSwitch(_ key: String, initial: Bool) -> some View {
        Toggle(key, isOn: Binding(get: { previewValues[key] ?? initial }, set: { previewValues[key] = $0 })).labelsHidden().toggleStyle(SettingsSwitchStyle()).help("Visual preview only; no service setting is changed")
    }
    private func previewRow(_ title: String, _ subtitle: String, key: String, initial: Bool) -> some View { settingsRow(title, subtitle) { previewSwitch(key, initial: initial) } }
    private func keycap(_ value: String, faint: Bool = false) -> some View { Text(value).font(KiviTheme.mono(12)).foregroundStyle(faint ? KiviTheme.muted : KiviTheme.ink).padding(.horizontal, 9).frame(height: 27).background(KiviTheme.background.opacity(0.45), in: RoundedRectangle(cornerRadius: 5)).overlay(RoundedRectangle(cornerRadius: 5).stroke(KiviTheme.line)) }
    private func menuLabel(_ value: String) -> some View { HStack(spacing: 18) { Text(value).font(KiviTheme.body(13)); Image(systemName: "chevron.up.chevron.down").font(.system(size: 9)) }.padding(.horizontal, 11).frame(height: 30).background(KiviTheme.background.opacity(0.4), in: RoundedRectangle(cornerRadius: 6)).overlay(RoundedRectangle(cornerRadius: 6).stroke(KiviTheme.line)) }
    private func visualPreview(_ name: String) { model.notify("\(name) is a visual preview. No account service is connected.") }
    private func resetPage() {
        switch model.settingsSection {
        case "general": model.saved.appearance = "system"; model.saved.reduceMotion = false; inactivity = "3 min"; model.persist()
        case "the orb": dictation.indicatorStyle = .minimal; dictation.indicatorTheme = .classic; dictation.notchIndicatorRightContent = .waveform
        default: break
        }
        previewValues = [:]
    }
}

struct SettingsSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            Capsule().fill(configuration.isOn ? KiviTheme.green.opacity(0.72) : Color.gray.opacity(0.28)).frame(width: 30, height: 18)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) { Circle().fill(configuration.isOn ? Color(red: 0.85, green: 0.93, blue: 0.77) : Color.gray.opacity(0.78)).frame(width: 12, height: 12).padding(3) }
        }.buttonStyle(.plain).accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label }.toggleStyle(.switch) }
    }
}
private struct SettingsDangerStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(KiviTheme.body(13)).foregroundStyle(Color(red: 0.88, green: 0.42, blue: 0.39)).padding(.horizontal, 12).padding(.vertical, 8).background(Color.red.opacity(configuration.isPressed ? 0.12 : 0.04), in: RoundedRectangle(cornerRadius: 6)).overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.red.opacity(0.2)))
    }
}
private struct HotkeyToggle: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var bridge: NativeBridge
    var body: some View {
        Button(bridge.hotkeysEnabled ? "disable global shortcuts" : "enable global shortcuts") {
            if bridge.hotkeysEnabled { bridge.stopHotkey() } else { do { try bridge.startHotkey() } catch { model.notify(error.localizedDescription) } }
        }.buttonStyle(KiviButton(primary: !bridge.hotkeysEnabled))
    }
}

private struct KiviDeviceMeter: View {
    @ObservedObject var devices: AudioDeviceService
    var reduceMotion: Bool
    var body: some View { Waveform(level: Double(devices.previewAudioLevel), reduceMotion: reduceMotion || !devices.isPreviewActive) }
}
private struct KiviTodayWords: View {
    @ObservedObject var history: KiviHistoryStore
    var body: some View { Text("\(history.summary.todayWords)").font(KiviTheme.mono(30)) }
}
