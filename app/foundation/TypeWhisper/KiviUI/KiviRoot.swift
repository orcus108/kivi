import SwiftUI
import AppKit
struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.identifier = NSUserInterfaceItemIdentifier("kivi-main")
            window.titlebarAppearsTransparent = true; window.titleVisibility = .hidden
            window.backgroundColor = NSColor(red: 0.043, green: 0.055, blue: 0.039, alpha: 1)
            window.minSize = NSSize(width: 1000, height: 650)
            window.setContentSize(NSSize(width: 1503, height: 846))
            window.isMovableByWindowBackground = false
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @State private var sidebarVisible = true
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var reducePageMotion: Bool { model.saved.reduceMotion || systemReduceMotion }
    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: sidebarVisible ? 264 : 76)
            ZStack(alignment: .topLeading) {
                if model.page == .record { KiviBackground() } else { KiviTheme.background }
                ZStack(alignment: .topLeading) {
                    Group {
                        switch model.page {
                        case .record: RecordPage()
                        case .history: KiviHistoryPage()
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
        }
        .ignoresSafeArea(.container, edges: .top)
        .font(KiviTheme.body()).foregroundStyle(KiviTheme.ink)
        .background(KiviBackground()).frame(minWidth: 1000, minHeight: 650)
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                HStack(spacing: 10) { Circle().fill(KiviTheme.green).frame(width: 6, height: 6); Text(toast).font(KiviTheme.body(13)); IconButton(icon: "xmark", label: "dismiss") { model.toast = nil } }
                    .padding(.leading, 16).padding(.trailing, 6).padding(.vertical, 4)
                    .background(KiviTheme.panel, in: Capsule()).overlay(Capsule().stroke(KiviTheme.line)).shadow(radius: 20).padding(.bottom, 24).padding(.horizontal, 30).transition(.opacity)
            }
        }
        .overlay { if model.showWelcome { WelcomePreview().environmentObject(model).ignoresSafeArea(.container, edges: .top).transition(.opacity) } }
        
        .onChange(of: model.page) { model.selectedTake = nil }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                if sidebarVisible {
                    Group {
                        if let logo = KiviTheme.image("kivi-wordmark") { Image(nsImage: logo).renderingMode(colorScheme == .light ? .template : .original).resizable().foregroundStyle(KiviTheme.ink).scaledToFit().frame(width: 70, height: 50).accessibilityLabel("kivi") }
                        else { Text("kivi").font(KiviTheme.serif(49)) }
                    }
                    Spacer(minLength: 0)
                    IconButton(icon: "sidebar.left", label: "collapse sidebar") { withAnimation(model.saved.reduceMotion ? nil : .easeInOut(duration: 0.2)) { sidebarVisible = false } }
                } else {
                    Group {
                        if let logo = KiviTheme.image("kivi-wordmark") { Image(nsImage: logo).renderingMode(colorScheme == .light ? .template : .original).resizable().foregroundStyle(KiviTheme.ink).scaledToFit().frame(width: 26, height: 24).accessibilityLabel("kivi") }
                        else { Text("k").font(KiviTheme.serif(24)).foregroundStyle(KiviTheme.ink).accessibilityLabel("kivi") }
                    }
                    Spacer(minLength: 0)
                    IconButton(icon: "sidebar.left", label: "expand sidebar") { withAnimation(model.saved.reduceMotion ? nil : .easeInOut(duration: 0.2)) { sidebarVisible = true } }
                }
            }.padding(.top, 35).padding(.bottom, 11).padding(.leading, sidebarVisible ? 26 : 13).padding(.trailing, sidebarVisible ? 14 : 8)
            Rectangle().fill(KiviTheme.line).frame(height: 1).padding(.horizontal, sidebarVisible ? 14 : 10).padding(.bottom, 11)
            nav(.record); nav(.history)
            if sidebarVisible {
                Text("your space").font(KiviTheme.mono(12)).tracking(1.4).foregroundStyle(Color(red: 0.35, green: 0.45, blue: 0.49))
                    .overlay(alignment: .bottomLeading) { BrushUnderline().fill(KiviTheme.green.opacity(0.3)).frame(width: 32, height: 4).offset(y: 5) }
                    .padding(.top, 14).padding(.leading, 13).padding(.bottom, 20)
            } else {
                Spacer().frame(height: 20)
            }
            nav(.dictionary); nav(.shortcuts); nav(.styles)
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
            }.frame(maxWidth: .infinity, alignment: sidebarVisible ? .leading : .center).padding(.leading, sidebarVisible ? 20 : 0).padding(.trailing, sidebarVisible ? 14 : 0).padding(.vertical, 20)
        }.background(KiviBackground()).overlay(alignment: .trailing) { Rectangle().fill(KiviTheme.line).frame(width: 1) }
    }
    private func nav(_ page: Page) -> some View {
        Button { model.selectedTake = nil; model.page = page } label: {
            HStack(spacing: 9) {
                if !sidebarVisible { Spacer(minLength: 0) }
                Image(systemName: page.icon).font(.system(size: 16)).foregroundStyle(model.page == page || hoveredNav == page ? KiviTheme.green : KiviTheme.muted).frame(width: 18)
                if sidebarVisible { Text(page.rawValue).font(KiviTheme.medium(18)); Spacer() }
                else { Spacer(minLength: 0) }
            }
            .padding(.horizontal, sidebarVisible ? 26 : 0).frame(maxWidth: .infinity).frame(height: 40)
            .background(hoveredNav == page ? KiviTheme.panel.opacity(0.55) : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { hoveredNav = $0 ? page : (hoveredNav == page ? nil : hoveredNav) }.animation(.easeOut(duration: 0.12), value: hoveredNav == page).accessibilityLabel(page.rawValue)
    }
    @State private var hoveredNav: Page?
}
