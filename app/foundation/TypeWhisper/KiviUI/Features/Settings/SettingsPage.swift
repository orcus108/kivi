import SwiftUI
import AppKit
import AVFoundation
import Speech
import ServiceManagement

/// Kivi-owned settings, grouped by the task each preference affects.
struct SettingsPage: View {
    @EnvironmentObject var model: AppModel
    private let dictation = DictationViewModel.shared
    @StateObject private var signals = KiviSettingsSignals()
    private let devices = ServiceContainer.shared.audioDeviceService
    @AppStorage(IntentTextPipeline.cleanupKey) private var cleanup = true
    @AppStorage(IntentTextPipeline.structureKey) private var structure = true
    @AppStorage(SelfCorrectionService.enabledKey) private var spokenSelfCorrection = true
    @AppStorage(UserDefaultsKeys.historyEnabled) private var keepHistory = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var search = ""
    @State private var detailWidth: CGFloat = 800
    @State private var hoveredSettingsSection: KiviSettingsSection?
    @State private var showMoreShortcuts = false
    @State private var showMicrophones = false
    @FocusState private var focusedCancellation: CancellationBehavior?
    private let pillPreview = IndicatorPreviewSession.shared
    @State private var permissionRefresh = false
    private let mainSections: [KiviSettingsSection] = [.general, .writing, .keyboardShortcuts, .recording, .recordingIndicator]
    private let privacySections: [KiviSettingsSection] = [.permissions, .privacy]
    private let moreSections: [KiviSettingsSection] = [.advanced, .billing, .account, .about]
    private var section: KiviSettingsSection { .resolve(model.settingsSection) }
    private var resetTitle: String? {
        switch section {
        case .general: "reset appearance"
        case .recordingIndicator: "reset indicator look"
        default: nil
        }
    }

    var body: some View {
        let _ = signals.revision
        HStack(spacing: 0) {
            sidebar
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    adaptiveRow {
                        Text(section.title).font(.custom("Matter-SemiBold", size: 22))
                        if detailWidth >= 600 { Spacer() }
                        if let resetTitle {
                            Button { resetPage() } label: { Label(resetTitle, systemImage: "arrow.counterclockwise") }.buttonStyle(KiviButton()).help(section == .general ? "Restore system appearance and allow animations. Other settings stay unchanged." : "Restore the compact indicator, classic theme and waveform. Position, visibility and feedback stay unchanged.")
                        }
                    }.frame(minHeight: 30, alignment: .leading).padding(.bottom, 30)
                    detail
                }.padding(.horizontal, 32).padding(.top, 44).padding(.bottom, 44).frame(maxWidth: .infinity, alignment: .leading)
            }.id(model.settingsSection)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { detailWidth = $0 }
        }
        .foregroundStyle(KiviTheme.ink)
        .onAppear { model.refreshEngineStatus() }
        .onChange(of: section) { _, _ in showMicrophones = false }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in permissionRefresh.toggle(); model.refreshEngineStatus() }

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
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    sidebarLabel("kivi")
                    ForEach(mainSections.filter { $0.matches(search) }) { sidebarRow($0) }
                    if privacySections.contains(where: { $0.matches(search) }) {
                        sidebarLabel("privacy").padding(.top, 20)
                        ForEach(privacySections.filter { $0.matches(search) }) { sidebarRow($0) }
                    }
                    if moreSections.contains(where: { $0.matches(search) }) {
                        sidebarLabel("more").padding(.top, 20)
                        ForEach(moreSections.filter { $0.matches(search) }) { sidebarRow($0) }
                    }
                    if !KiviSettingsSection.allCases.contains(where: { $0.matches(search) }) {
                        Text("no settings match").font(KiviTheme.body(13)).foregroundStyle(KiviTheme.muted).padding(10)
                        Button("clear search") { search = "" }.buttonStyle(KiviButton()).padding(.horizontal, 10)
                    }
                }.padding(.bottom, 12)
            }
            Spacer()
            Rectangle().fill(KiviTheme.line).frame(height: 1).padding(.bottom, 14)
            Text("kivi 2026.10.18.0630").font(KiviTheme.mono(10)).foregroundStyle(KiviTheme.muted).padding(.leading, 10).padding(.bottom, 5)
        }.padding(.horizontal, 10).padding(.top, 44).padding(.bottom, 12).frame(width: 232)
            .background(KiviTheme.panel.opacity(0.13)).overlay(alignment: .trailing) { Rectangle().fill(KiviTheme.line).frame(width: 1) }
    }
    private func sidebarLabel(_ title: String) -> some View {
        Text(title).font(KiviTheme.mono(10)).foregroundStyle(KiviTheme.muted).padding(.leading, 10).padding(.bottom, 7)
    }
    private func sidebarRow(_ destination: KiviSettingsSection) -> some View {
        let isSelected = section == destination
        let isHovered = hoveredSettingsSection == destination
        return Button { model.settingsSection = destination.rawValue } label: {
            HStack(spacing: 9) {
                Image(systemName: destination.icon).font(.system(size: 13)).frame(width: 17)
                    .foregroundStyle(isSelected || isHovered ? KiviTheme.green : KiviTheme.muted)
                Text(destination.title).font(KiviTheme.body(14))
                Spacer()
            }.padding(.horizontal, 10).frame(height: 34)
                .foregroundStyle(isSelected ? KiviTheme.green : KiviTheme.ink)
                .background(isSelected ? KiviTheme.green.opacity(0.10) : (isHovered ? KiviTheme.panel.opacity(0.55) : .clear), in: RoundedRectangle(cornerRadius: 8))
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain)
            .onHover { hovering in
                hoveredSettingsSection = hovering ? destination : (isHovered ? nil : hoveredSettingsSection)
            }
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
    @ViewBuilder private var detail: some View {
        switch section {
        case .general: general
        case .writing: writing
        case .keyboardShortcuts: keyboardShortcuts
        case .recordingIndicator: recordingIndicator
        case .recording: recording
        case .permissions: permissions
        case .privacy: privacy
        case .advanced: advancedTools
        case .billing: billing
        case .account: account
        case .about: about
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

            sectionLabel("behavior").padding(.top, 30)
            group {
                settingsRow("open at login", "start Kivi when you log in to your Mac") { Toggle("open at login", isOn: $launchAtLogin).labelsHidden().toggleStyle(SettingsSwitchStyle()).onChange(of: launchAtLogin) { _, enabled in Task { do { if enabled { try SMAppService.mainApp.register() } else { try await SMAppService.mainApp.unregister() } } catch { launchAtLogin = SMAppService.mainApp.status == .enabled; model.notify(error.localizedDescription) } } } }
                rowDivider
                settingsRow("reduce motion", "use less animation throughout Kivi") {
                    Toggle("reduce motion", isOn: $model.saved.reduceMotion).labelsHidden().toggleStyle(SettingsSwitchStyle()).onChange(of: model.saved.reduceMotion) { model.persist() }
                }
            }
            sectionLabel("getting started").padding(.top, 30)
            group {
                settingsRow("welcome demo", "replay the first-run walkthrough.") { Button("replay") { model.showWelcome = true }.buttonStyle(KiviButton()) }
            }
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

    private var keyboardShortcuts: some View {
        VStack(alignment: .leading, spacing: 24) {
            group {
                KiviShortcutRow(slot: .hybrid, title: "kivi key", subtitle: "tap to toggle; hold to dictate")
                rowDivider
                KiviShortcutRow(slot: .pushToTalk, title: "hold to dictate", subtitle: "release to finish recording")
                rowDivider
                KiviShortcutRow(slot: .toggle, title: "toggle recording", subtitle: "press once to start, again to finish")
            }
            group {
                KiviShortcutRow(slot: .pasteLastTranscription, title: "paste latest take", subtitle: "insert your latest take in the focused app")
                rowDivider
                KiviShortcutRow(slot: .copyLastTranscription, title: "copy latest take", subtitle: "copy your latest take to the clipboard")
                rowDivider
                KiviShortcutRow(slot: .recentTranscriptions, title: "recent takes", subtitle: "choose an earlier take to insert")
            }
            Button { showMoreShortcuts.toggle() } label: {
                HStack { Text("more keyboard shortcuts"); Spacer(); Image(systemName: showMoreShortcuts ? "chevron.up" : "chevron.down") }
            }.buttonStyle(KiviButton()).accessibilityValue(showMoreShortcuts ? "expanded" : "collapsed")
            if showMoreShortcuts {
                group {
                    KiviShortcutRow(slot: .undoLastDictation, title: "undo last dictation", subtitle: "remove the last insertion when it is safe")
                    rowDivider
                    KiviShortcutRow(slot: .restoreRawTranscript, title: "restore original transcript", subtitle: "replace the last insertion with its raw text")
                    rowDivider
                    KiviShortcutRow(slot: .promptPalette, title: "workflow picker", subtitle: "process selected or copied text")
                    rowDivider
                    KiviShortcutRow(slot: .recorderToggle, title: "audio recorder", subtitle: "start or stop a recorder session")
                }.padding(.top, 12)
            }
            caption("click a shortcut to change it, or set another. press Escape to cancel. conflicting keys keep their existing assignment.")
        }
    }

    private var recordingIndicator: some View {
        VStack(alignment: .leading, spacing: 0) {
            caption("the compact indicator shows when Kivi is listening or processing your words.").padding(.bottom, 20)
            group {
                settingsRow("preview indicator", "see the listening animation without using your microphone") {
                    Button(pillPreview.isActive ? "stop preview" : "preview") {
                        if pillPreview.isActive { pillPreview.stop() } else { pillPreview.start() }
                    }.buttonStyle(KiviButton())
                }
            }
            sectionLabel("visibility & position").padding(.top, 30)
            group {
                VStack(alignment: .leading, spacing: 14) {
                    Text("show indicator").font(KiviTheme.medium(16))
                    KiviSettingsChoices(label: "show indicator", selection: Binding(get: { dictation.notchIndicatorVisibility }, set: { dictation.notchIndicatorVisibility = $0 }),
                        options: [(.duringActivity, "while active"), (.always, "always"), (.never, "never")])
                }.padding(20)
                rowDivider
                VStack(alignment: .leading, spacing: 14) {
                    Text("screen position").font(KiviTheme.medium(16))
                    KiviSettingsChoices(label: "screen position", selection: Binding(get: { dictation.overlayPosition }, set: { dictation.overlayPosition = $0 }),
                        options: [(.bottom, "bottom"), (.top, "top")])
                }.padding(20)
                rowDivider
                settingsRow("center indicator", "center it horizontally on its current screen") {
                    Button("center") { NotificationCenter.default.post(name: .centerRecordingPill, object: nil) }.buttonStyle(KiviButton())
                }
                rowDivider
                settingsRow("show in screen captures", "include the indicator in screenshots and screen sharing") {
                    Toggle("show in screen captures", isOn: Binding(get: { dictation.indicatorVisibleInScreenCaptures }, set: { dictation.indicatorVisibleInScreenCaptures = $0 })).labelsHidden().toggleStyle(SettingsSwitchStyle())
                }
            }
            sectionLabel("feedback").padding(.top, 30)
            group {
                settingsRow("spoken feedback", "read feedback aloud") { Toggle("spoken feedback", isOn: Binding(get: { dictation.spokenFeedbackEnabled }, set: { dictation.spokenFeedbackEnabled = $0 })).labelsHidden().toggleStyle(SettingsSwitchStyle()) }
                rowDivider
                settingsRow("recording sounds", "play a sound when recording starts and stops") { Toggle("recording sounds", isOn: Binding(get: { dictation.soundFeedbackEnabled }, set: { dictation.soundFeedbackEnabled = $0 })).labelsHidden().toggleStyle(SettingsSwitchStyle()) }
            }
            advancedLink("more indicator options", detail: "advanced display, transcript and theme settings", destination: "appearance").padding(.top, 24)
        }.onDisappear { pillPreview.stop() }
    }

    private var recording: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("input")
            group {
                settingsRow("microphone", devices.disconnectedDeviceName.map { "disconnected: \($0)" } ?? "choose the microphone Kivi records from") {
                    Button { showMicrophones = true } label: {
                        menuLabel(devices.selectedDeviceUID == nil ? "system default" : (devices.inputDevices.first(where: { $0.uid == devices.selectedDeviceUID })?.name ?? devices.disconnectedDeviceName ?? "microphone unavailable"))
                    }.buttonStyle(.plain).accessibilityLabel("choose microphone")
                        .popover(isPresented: $showMicrophones) {
                            KiviMicrophoneChooser(devices: devices, onClose: { showMicrophones = false })
                        }
                }
                rowDivider
                settingsRow("test microphone", devices.previewError?.localizedDescription ?? "speak to see your input level") {
                    HStack { KiviDeviceMeter(devices: devices, reduceMotion: model.saved.reduceMotion).frame(width: 70); Button(devices.isPreviewActive ? "stop" : "test") { if devices.isPreviewActive { devices.stopPreview() } else { devices.startPreview() } }.buttonStyle(KiviButton()) }
                }
            }
            sectionLabel("while recording").padding(.top, 30)
            group {
                settingsRow("live typing", "show partial words in supported text fields while you speak") {
                    Toggle("live typing", isOn: Binding(get: { dictation.liveFieldTranscriptEnabled }, set: { dictation.liveFieldTranscriptEnabled = $0 })).labelsHidden().toggleStyle(SettingsSwitchStyle())
                }
                rowDivider
                VStack(alignment: .leading, spacing: 12) {
                    Text("cancel a take").font(KiviTheme.medium(16))
                    Text("choose how Escape cancels a recording or processing").font(KiviTheme.body(14)).foregroundStyle(KiviTheme.muted)
                    ForEach(KiviCancellationChoice.all) { choice in
                        Button { dictation.cancellationBehavior = choice.value } label: {
                            HStack(spacing: 12) {
                                Image(systemName: dictation.cancellationBehavior == choice.value ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(dictation.cancellationBehavior == choice.value ? KiviTheme.green : KiviTheme.muted)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(choice.title).font(KiviTheme.medium(14))
                                    Text(choice.detail).font(KiviTheme.body(12)).foregroundStyle(KiviTheme.muted)
                                }
                                Spacer(minLength: 0)
                            }.padding(10).contentShape(Rectangle())
                        }.buttonStyle(KiviSettingsOptionStyle(selected: dictation.cancellationBehavior == choice.value, focused: focusedCancellation == choice.value))
                            .focused($focusedCancellation, equals: choice.value).focusEffectDisabled()
                            .accessibilityAddTraits(dictation.cancellationBehavior == choice.value ? .isSelected : [])
                    }
                }.padding(20)
            }
            sectionLabel("recovery").padding(.top, 30)
            group {
                settingsRow("recording recovery", "recover a cancelled or interrupted recording") { Button("open recovery") { KiviRecoveryWindow.shared.show() }.buttonStyle(KiviButton()) }
            }
            advancedLink("more recording options", detail: "advanced input priority and transcription settings", destination: "microphone").padding(.top, 24)
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
                settingsRow("target-app context", "recognize the app and text field where your words should appear") { Image(systemName: accessibility ? "checkmark.circle" : "lock").foregroundStyle(accessibility ? KiviTheme.green : KiviTheme.muted) }
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
                settingsRow("save takes", "keep completed dictations on this Mac") { Toggle("save takes", isOn: $keepHistory).labelsHidden().toggleStyle(SettingsSwitchStyle()).disabled(model.incognito) }
                rowDivider
                settingsRow("incognito", "new takes and correction learning are not saved") { Toggle("incognito", isOn: $model.incognito).labelsHidden().toggleStyle(SettingsSwitchStyle()) }
                rowDivider
                settingsRow("export your dictations", "save this app’s history as a text file") { Button("export") { model.exportHistory() }.buttonStyle(KiviButton()) }
            }
            sectionLabel("on this Mac").padding(.top, 30)
            group {
                settingsRow("local storage", "your saved takes and settings are kept on this Mac") { Image(systemName: "internaldrive").foregroundStyle(KiviTheme.green) }
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

    private var writing: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("text processing")
            group {
                settingsRow("light cleanup", "remove clear hesitations and accidental repeats") { Toggle("light cleanup", isOn: $cleanup).labelsHidden().toggleStyle(SettingsSwitchStyle()) }
                rowDivider
                settingsRow("format spoken lists", "format explicit lists and new-paragraph instructions") { Toggle("format spoken lists", isOn: $structure).labelsHidden().toggleStyle(SettingsSwitchStyle()) }
                rowDivider
                settingsRow("literal mode", "skip cleanup, dictionary replacements, text shortcuts and writing styles") { Toggle("literal mode", isOn: $model.saved.literal).labelsHidden().toggleStyle(SettingsSwitchStyle()).onChange(of: model.saved.literal) { model.persist() } }
            }
            sectionLabel("personalization").padding(.top, 30)
            group {
                settingsRow("learn from corrections", model.incognito ? "paused while incognito is on" : "remember names you correct repeatedly in supported apps") { KiviLearningSwitch() }
                rowDivider
                settingsRow("styles & rules", "choose how Kivi writes in different apps") { Button("open styles") { model.page = .styles }.buttonStyle(KiviButton()) }
            }
            sectionLabel("for you").padding(.top, 30)
            group { KiviTalkModelSettings(conversation: model.talk) }
            sectionLabel("spoken corrections").padding(.top, 30)
            group {
                settingsRow("resolve spoken corrections", "keep your final wording after phrases like ‘no, I mean…’") {
                    Toggle("resolve spoken corrections", isOn: $spokenSelfCorrection).labelsHidden().toggleStyle(SettingsSwitchStyle())
                }
            }
            caption("when configured, transcript text is sent to \(SelfCorrectionService.groqSelected ? "Groq" : "Gemini") for this step. audio stays on your Mac. provider and key settings are in advanced tools.").padding(.top, 12)
        }
    }

    private var advancedTools: some View {
        VStack(alignment: .leading, spacing: 0) {
            caption("these options open the existing advanced settings window.").padding(.bottom, 24)
            sectionLabel("models & providers")
            group {
                settingsRow("speech engine", model.modelStatus) { Button("manage engines") { model.openAdvanced("models") }.buttonStyle(KiviButton()) }
                rowDivider
                settingsRow("spoken-correction provider", "configure the text provider and API key for spoken corrections") {
                    Button("configure provider") { model.openAdvanced("general") }.buttonStyle(KiviButton())
                }
            }
            sectionLabel("editing & workflows").padding(.top, 30)
            group {
                settingsRow("edit selected text", "review a rewrite, then apply or copy it") { Button("open editor") { model.openEditor() }.buttonStyle(KiviButton()) }
                rowDivider
                settingsRow("workflows", "configure reusable processing steps") { Button("open workflows") { model.openAdvanced("workflows") }.buttonStyle(KiviButton()) }
                rowDivider
                settingsRow("transcribe a file", "turn an existing audio file into text") { Button("open files") { model.openAdvanced("files") }.buttonStyle(KiviButton()) }
                rowDivider
                settingsRow("audio recorder", "record and manage longer sessions") { Button("open recorder") { model.openAdvanced("recorder") }.buttonStyle(KiviButton()) }
            }
        }
    }

    private func advancedLink(_ title: String, detail: String, destination: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Button(title) { model.openAdvanced(destination) }.buttonStyle(KiviButton())
            caption(detail + " · opens advanced settings")
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
        adaptiveRow {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) { Text(title).font(KiviTheme.medium(16)); if info { Image(systemName: "info.circle").font(.system(size: 11)).foregroundStyle(KiviTheme.muted) } }
                Text(subtitle).font(KiviTheme.body(14)).foregroundStyle(KiviTheme.muted).fixedSize(horizontal: false, vertical: true)
            }
            if detailWidth >= 600 { Spacer(minLength: 4) }
            content()
        }.padding(.horizontal, 20).padding(.vertical, 12).frame(minHeight: 66)
    }
    private func adaptiveRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        let layout = detailWidth < 600
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(spacing: 20))
        return layout(content)
    }
    private func menuLabel(_ value: String) -> some View { HStack(spacing: 18) { Text(value).font(KiviTheme.body(13)).lineLimit(1).truncationMode(.middle); Image(systemName: "chevron.up.chevron.down").font(.system(size: 9)) }.padding(.horizontal, 11).frame(maxWidth: 240).frame(height: 30).background(KiviTheme.background.opacity(0.4), in: RoundedRectangle(cornerRadius: 6)).overlay(RoundedRectangle(cornerRadius: 6).stroke(KiviTheme.line)) }
    private func resetPage() {
        switch section {
        case .general: model.saved.appearance = "system"; model.saved.reduceMotion = false; model.persist()
        case .recordingIndicator: dictation.indicatorStyle = .minimal; dictation.indicatorTheme = .classic; dictation.notchIndicatorRightContent = .waveform
        default: break
        }
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
