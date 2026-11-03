import SwiftUI
import AppKit
struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        KiviWindowConfiguratorView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            KiviWindowConfiguratorView.configure(window)
        }
    }
}

final class KiviWindowConfiguratorView: NSView {
    private weak var observedWindow: NSWindow?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        guard observedWindow !== window else { return }

        NotificationCenter.default.removeObserver(self)
        observedWindow = window

        for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification, NSWindow.didResizeNotification] {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(fullScreenTransitionFinished(_:)),
                name: name,
                object: window
            )
        }
        DispatchQueue.main.async { [weak self] in
            guard let window = self?.window else { return }
            Self.configure(window)
        }
    }

    @objc private func fullScreenTransitionFinished(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let window = self?.window else { return }
            Self.configure(window)
        }
    }

    static func configure(_ window: NSWindow) {
        window.identifier = NSUserInterfaceItemIdentifier("kivi-main")
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = KiviTheme.sidebarNSColor
        window.collectionBehavior.remove(.fullScreenNone)
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.isMovableByWindowBackground = false
        // Keep the native controls, with a larger title-bar hit region.
        guard !window.styleMask.contains(.fullScreen) else { return }
        for (index, kind) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
            guard let button = window.standardWindowButton(kind), let container = button.superview else { continue }
            var frame = container.frame
            let top = frame.maxY
            frame.size.height = max(frame.height, 52)
            frame.origin.y = top - frame.height
            container.frame = frame
            let center = container.convert(NSPoint(x: 24 + CGFloat(index) * 23, y: window.frame.height - 26), from: nil)
            button.setFrameOrigin(NSPoint(x: center.x - button.frame.width / 2, y: center.y - button.frame.height / 2))
        }
    }

}

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @State private var sidebarVisible = true
    @State private var windowIsFullScreen = false
    @FocusState private var focusedNav: Page?
    @State private var visibleNavLabel: Page?
    private var navLabelCandidate: Page? { sidebarVisible ? nil : (hoveredNav ?? focusedNav) }
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var reducePageMotion: Bool { model.saved.reduceMotion || systemReduceMotion }
    var body: some View {
        VStack(spacing: 0) {
            windowHeader
            KiviPendingRecoveryBar(dictation: model.services.dictationViewModel)
            HStack(spacing: 0) {
                sidebar.frame(width: sidebarVisible ? 264 : 76)
                ZStack(alignment: .topLeading) {
                    KiviBackground()
                    ZStack(alignment: .topLeading) {
                        Group {
                            switch model.page {
                            case .record: RecordPage()
                            case .talk: KiviTalkPage(conversation: model.talk)
                            case .insights: InsightsPage(history: model.services.historyService)
                            case .dictionary: DictionaryPage()
                            case .shortcuts: ShortcutsPage()
                            case .styles: StylesPage()
                            case .settings: SettingsPage()
                            }
                        }
                        .id(model.page)
                        .transition(reducePageMotion ? .identity : .asymmetric(
                            insertion: .opacity.combined(with: .offset(y: 8)),
                            removal: .opacity
                        ))
                    }
                    .animation(reducePageMotion ? nil : .easeOut(duration: 0.2), value: model.page)
                    if let take = model.selectedTake {
                        TakeDetail(take: take).id(take.id).frame(width: 430).frame(maxHeight: .infinity)
                            .background(KiviBackground()).overlay(alignment: .leading) { Rectangle().fill(KiviTheme.line).frame(width: 1) }
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing).zIndex(5)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(KiviTheme.line.opacity(0.55)))
                .padding(.trailing, 8).padding(.bottom, 8)
            }
        }
        .font(KiviTheme.body()).foregroundStyle(KiviTheme.ink)
        .background(KiviSidebarBackground()).frame(minWidth: 1000, minHeight: 650)
        .ignoresSafeArea(.container, edges: .top)
        .overlayPreferenceValue(KiviNavLabelAnchors.self) { anchors in
            GeometryReader { geometry in
                if let page = visibleNavLabel, !sidebarVisible, let anchor = anchors[page] {
                    let row = geometry[anchor]
                    Text(page.title)
                        .font(KiviTheme.medium(14)).foregroundStyle(KiviTheme.ink)
                        .padding(.horizontal, 12).frame(height: 36)
                        .background(KiviTheme.panel, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(KiviTheme.line))
                        .shadow(color: .black.opacity(0.14), radius: 8, y: 3)
                        .fixedSize()
                        .offset(x: row.maxX + 8, y: row.midY - 18)
                        .accessibilityHidden(true)
                }
            }.allowsHitTesting(false)
        }
        .task(id: navLabelCandidate) {
            visibleNavLabel = nil
            guard let candidate = navLabelCandidate else { return }
            if hoveredNav == candidate {
                do { try await Task.sleep(for: .milliseconds(300)) }
                catch { return }
            }
            guard !Task.isCancelled, navLabelCandidate == candidate else { return }
            visibleNavLabel = candidate
        }
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                HStack(spacing: 10) { Circle().fill(KiviTheme.green).frame(width: 6, height: 6); Text(toast).font(KiviTheme.body(13)); IconButton(icon: "xmark", label: "dismiss") { model.toast = nil } }
                    .padding(.leading, 16).padding(.trailing, 6).padding(.vertical, 4)
                    .background(KiviTheme.panel, in: Capsule()).overlay(Capsule().stroke(KiviTheme.line)).shadow(radius: 20).padding(.bottom, 24).padding(.horizontal, 30).transition(.opacity)
            }
        }
        .overlay { if model.showWelcome { WelcomePreview().environmentObject(model).ignoresSafeArea(.container, edges: .top).transition(.opacity) } }
        
        .onAppear {
            if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "kivi-main" }) {
                windowIsFullScreen = window.styleMask.contains(.fullScreen)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { notification in
            guard let window = notification.object as? NSWindow, window.identifier?.rawValue == "kivi-main" else { return }
            windowIsFullScreen = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { notification in
            guard let window = notification.object as? NSWindow, window.identifier?.rawValue == "kivi-main" else { return }
            windowIsFullScreen = false
        }
        .onChange(of: model.page) { model.selectedTake = nil; visibleNavLabel = nil }
        .environment(\.kiviReduceMotion, model.saved.reduceMotion)
    }
    // The header and navigation share one continuous outer surface.
    private var windowHeader: some View {
        HStack(spacing: 0) {
            IconButton(icon: "sidebar.left", label: sidebarVisible ? "collapse sidebar" : "expand sidebar") {
                withAnimation(reducePageMotion ? nil : .timingCurve(0.22, 0.8, 0.25, 1, duration: 0.42)) {
                    sidebarVisible.toggle()
                }
            }
            .accessibilityValue(sidebarVisible ? "expanded" : "collapsed")
            Spacer(minLength: 0)
        }
        .padding(.leading, windowIsFullScreen ? 24 : 98)
        .frame(height: 52)
        .animation(reducePageMotion ? nil : .easeInOut(duration: 0.2), value: windowIsFullScreen)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            KiviSidebarWordmark(expansion: sidebarVisible ? 1 : 0)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 50)
                .padding(.top, 8).padding(.bottom, 11)
            Rectangle().fill(KiviTheme.line).frame(height: 1).padding(.horizontal, sidebarVisible ? 14 : 10).padding(.bottom, 11)
            nav(.record)
            nav(.talk)
            nav(.insights); nav(.dictionary); nav(.shortcuts); nav(.styles)
            Spacer()
            Rectangle().fill(KiviTheme.line).frame(height: 1).padding(.horizontal, sidebarVisible ? 16 : 10)
            HStack(spacing: 6) {
                Button { model.page = .settings; model.settingsSection = "account" } label: {
                    Text("v").font(KiviTheme.medium(14)).foregroundStyle(KiviTheme.background).frame(width: 28, height: 28).background(KiviTheme.green, in: Circle()).overlay(Circle().stroke(KiviTheme.green.opacity(0.3), lineWidth: 4))
                }.buttonStyle(.plain).help("Your local workspace").accessibilityLabel("account settings")
                if sidebarVisible {
                    Button { model.page = .settings; model.settingsSection = "account" } label: {
                        HStack(spacing: 6) {
                            Text("Vedant Misra").font(KiviTheme.medium(14)).lineLimit(1).fixedSize()
                            Text("pro").font(KiviTheme.medium(11).italic()).fixedSize().foregroundStyle(KiviTheme.green).padding(.horizontal, 6).padding(.vertical, 1).background(KiviTheme.green.opacity(0.13), in: Capsule())
                        }
                    }.buttonStyle(.plain).help("Your local workspace")
                    Spacer(minLength: 0)
                    IconButton(icon: model.incognito ? "eye.slash" : "eye", label: model.incognito ? "turn incognito off" : "turn incognito on") { model.incognito.toggle(); model.notify(model.incognito ? "incognito on · new takes are not saved" : "incognito off") }
                        .foregroundStyle(model.incognito ? KiviTheme.green : KiviTheme.muted)
                    IconButton(icon: "gearshape", label: "settings") { model.page = .settings }
                }
            }
            // Keep the avatar anchored as the wider account controls are revealed.
            .frame(height: 30)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 24).padding(.trailing, 14).padding(.vertical, 20)
        }
    }
    private func nav(_ page: Page) -> some View {
        Button { model.selectedTake = nil; model.page = page } label: {
            HStack(spacing: 0) {
                Image(systemName: page.icon)
                    .font(.system(size: 16))
                    .foregroundStyle(model.page == page || hoveredNav == page ? KiviTheme.green : KiviTheme.muted)
                    .frame(width: 18, height: 40)
                    .padding(.leading, 29).padding(.trailing, 9)
                    .fixedSize()
                if sidebarVisible {
                    Text(page.title).font(KiviTheme.medium(18))
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).frame(height: 40)
            .background(hoveredNav == page ? KiviTheme.panel.opacity(0.55) : .clear, in: RoundedRectangle(cornerRadius: 7))
            .clipped()
            .contentShape(Rectangle())
        }
        .focused($focusedNav, equals: page)
        .anchorPreference(key: KiviNavLabelAnchors.self, value: .bounds) { [page: $0] }
        .onKeyPress(.escape) {
            guard visibleNavLabel != nil else { return .ignored }
            visibleNavLabel = nil
            return .handled
        }
        .buttonStyle(.plain).onHover { hoveredNav = $0 ? page : (hoveredNav == page ? nil : hoveredNav) }.animation(.easeOut(duration: 0.12), value: hoveredNav == page).accessibilityLabel(page.title)
    }
    @State private var hoveredNav: Page?
}

private struct KiviSidebarWordmark: View, Animatable {
    @Environment(\.colorScheme) private var colorScheme
    var expansion: CGFloat
    nonisolated var animatableData: CGFloat {
        get { expansion }
        set { expansion = newValue }
    }
    private var resolvedWordmark: CGImage? {
        guard let image = KiviTheme.image("kivi-wordmark"),
              let appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua) else { return nil }
        // Resolve the asset using SwiftUI's current scheme, not AppKit's cached
        // appearance. A concrete image also invalidates the previous template rendering.
        var resolved: CGImage?
        appearance.performAsCurrentDrawingAppearance {
            resolved = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        return resolved
    }
    private var wordmark: some View {
        Group {
            if let image = resolvedWordmark {
                Image(decorative: image, scale: 1)
                    .renderingMode(colorScheme == .light ? .template : .original)
                    .resizable().scaledToFit()
                    .id(colorScheme)
            } else {
                Text("kivi").font(KiviTheme.serif(49)).fixedSize()
            }
        }
        .foregroundStyle(KiviTheme.ink)
        .frame(width: 70, height: 50)
    }
    var body: some View {
        ZStack(alignment: .leading) {
            // Keep the existing wordmark artwork; its tail retracts behind the initial.
            wordmark
                .mask(alignment: .leading) { Rectangle().frame(width: 24) }
            wordmark
                .offset(x: -24 - 18 * (1 - expansion))
                .frame(width: 46, height: 50, alignment: .leading)
                .clipped()
                .mask(alignment: .trailing) { Rectangle().frame(width: 46 * expansion) }
                .opacity(expansion)
                .offset(x: 24)
        }
        .frame(width: 70, height: 50, alignment: .leading)
        .offset(x: 26)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("kivi")
    }
}

private struct KiviNavLabelAnchors: PreferenceKey {
    nonisolated static var defaultValue: [Page: Anchor<CGRect>] { [:] }
    nonisolated static func reduce(value: inout [Page: Anchor<CGRect>], nextValue: () -> [Page: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}
