import SwiftUI
import AppKit
import CoreText

enum KiviTheme {
    // Set false to restore both pre-banner page layouts.
    static let usesIllustratedSummaries = true
    private static func adaptive(_ dark: NSColor, _ light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light })
    }
    static let ink = adaptive(NSColor(red: 0.91, green: 0.90, blue: 0.85, alpha: 1), NSColor(red: 0.14, green: 0.17, blue: 0.12, alpha: 1))
    static let green = adaptive(NSColor(red: 0.58, green: 0.77, blue: 0.40, alpha: 1), NSColor(red: 0.35, green: 0.53, blue: 0.22, alpha: 1))
    static let muted = adaptive(NSColor(red: 0.49, green: 0.51, blue: 0.47, alpha: 1), NSColor(red: 0.44, green: 0.46, blue: 0.40, alpha: 1))
    // A near-black frame surrounds a deeper black page.
    static let sidebarNSColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 9/255, green: 10/255, blue: 9/255, alpha: 1)
            : NSColor(white: 249/255, alpha: 1)
    }
    // Light surfaces use Radix Gray 1/2/3/6 (body/frame/panel/border).
    static let background = adaptive(NSColor(white: 5/255, alpha: 1), NSColor(white: 252/255, alpha: 1))
    static let sidebarBackground = Color(nsColor: sidebarNSColor)
    static let panel = adaptive(NSColor(red: 0.105, green: 0.108, blue: 0.105, alpha: 1), NSColor(white: 240/255, alpha: 1))
    static let line = adaptive(NSColor(red: 39/255, green: 43/255, blue: 37/255, alpha: 1), NSColor(white: 217/255, alpha: 1))
    static func body(_ size: CGFloat = 15) -> Font { .custom("Matter-Regular", size: size) }
    static func medium(_ size: CGFloat = 15) -> Font { .custom("Matter-Medium", size: size) }
    // Set to false to restore the previous Petrona headings without changing other styling.
    static let usesKaliceHeadings = true
    static func serif(_ size: CGFloat = 34) -> Font {
        usesKaliceHeadings
            ? .custom("Kalice-Regular", size: size)
            : .custom("Petrona", size: size).weight(.medium)
    }
    static func heading(_ size: CGFloat = 30) -> Font { serif(size) }
    static func section(_ size: CGFloat = 24) -> Font { serif(size) }
    static func greeting(_ size: CGFloat = 45) -> Font { .custom("Kalice-Regular", size: size) }
    static func mono(_ size: CGFloat = 12) -> Font { .custom("MatterMono-Regular", size: size) }
    static func registerFonts() {
        for name in ["Matter-Regular", "Matter-Medium", "Matter-SemiBold", "MatterMono-Regular", "Kalice-Regular"] {
            if let url = Bundle.main.url(forResource: name, withExtension: "otf") { CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil) }
        }
        for name in ["Petrona", "Petrona-Italic"] {
            if let url = Bundle.main.url(forResource: name, withExtension: "ttf") { CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil) }
        }
    }
    static let grain: NSImage = {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 128, pixelsHigh: 128, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 512, bitsPerPixel: 32)!
        var seed: UInt32 = 71
        if let pixels = rep.bitmapData {
            for i in 0..<(128 * 128) {
                seed = 1664525 &* seed &+ 1013904223
                let shade: UInt8 = (seed >> 8) & 1 == 0 ? 0 : 255
                pixels[i * 4] = shade; pixels[i * 4 + 1] = shade; pixels[i * 4 + 2] = shade
                pixels[i * 4 + 3] = UInt8((seed >> 16) % 9)
            }
        }
        let image = NSImage(size: NSSize(width: 128, height: 128)); image.addRepresentation(rep); return image
    }()
    private static let assetBundle = Bundle.main.resourceURL.flatMap { Bundle(url: $0.appendingPathComponent("KiviAssets.bundle")) }
    static func image(_ name: String) -> NSImage? { assetBundle?.image(forResource: NSImage.Name(name)) ?? Bundle.main.image(forResource: NSImage.Name(name)) }
}

struct KiviBackground: View {
    var body: some View {
        KiviTheme.background.overlay {
            Image(nsImage: KiviTheme.grain).resizable(resizingMode: .tile).opacity(0.25).allowsHitTesting(false).accessibilityHidden(true)
        }
    }
}
struct KiviSidebarBackground: View {
    var body: some View {
        KiviTheme.sidebarBackground.overlay {
            Image(nsImage: KiviTheme.grain).resizable(resizingMode: .tile).allowsHitTesting(false).accessibilityHidden(true)
        }
    }
}
private struct KiviReduceMotionKey: EnvironmentKey {
    static let defaultValue = false
}
extension EnvironmentValues {
    var kiviReduceMotion: Bool {
        get { self[KiviReduceMotionKey.self] }
        set { self[KiviReduceMotionKey.self] = newValue }
    }
}

struct KiviButton: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.kiviReduceMotion) private var appReduceMotion
    @State private var isHovering = false
    var primary = false
    func makeBody(configuration: Configuration) -> some View {
        let transition: Animation? = systemReduceMotion || appReduceMotion
            ? nil : .easeOut(duration: configuration.isPressed ? 0.055 : 0.12)
        return configuration.label
            .font(KiviTheme.body(14)).padding(.horizontal, 14).padding(.vertical, 7)
            .foregroundStyle(primary ? Color(red: 0.043, green: 0.055, blue: 0.039) : (isEnabled ? KiviTheme.ink : KiviTheme.muted))
            .background {
                KiviButtonSurface(primary: primary, hovered: isHovering, pressed: configuration.isPressed, enabled: isEnabled)
            }
            .onHover { isHovering = $0 }
            .onChange(of: isEnabled) { if !isEnabled { isHovering = false } }
            .animation(transition, value: isHovering)
            .animation(transition, value: configuration.isPressed)
    }
}

/// Only the surface changes tone; text, icons, geometry and neutral borders stay steady.
struct KiviButtonSurface: View {
    let primary: Bool
    let hovered: Bool
    let pressed: Bool
    let enabled: Bool
    @Environment(\.colorScheme) private var scheme
    private var isPressed: Bool { enabled && pressed }
    private var isHovered: Bool { enabled && hovered }
    private var wash: Color {
        if primary { return scheme == .dark && isPressed ? .black : .white }
        return scheme == .dark && !isPressed ? .white : .black
    }
    private var intensity: Double {
        guard enabled else { return 0 }
        if primary {
            if scheme == .dark { return isPressed ? 0.07 : isHovered ? 0.07 : 0 }
            // Press returns to the original green, retaining contrast with the dark label.
            return isPressed ? 0 : isHovered ? 0.10 : 0.035
        }
        if scheme == .dark { return isPressed ? 0.14 : isHovered ? 0.035 : 0 }
        return isPressed ? 0.055 : isHovered ? 0.025 : 0
    }
    var body: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(primary ? (enabled ? KiviTheme.green : Color(white: 0.43)) : KiviTheme.panel)
            .overlay { RoundedRectangle(cornerRadius: 8).fill(wash.opacity(intensity)) }
            .overlay { RoundedRectangle(cornerRadius: 8).stroke(primary ? .clear : KiviTheme.line) }
    }
}
struct BrushUnderline: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 2, y: r.height * 0.25))
        p.addQuadCurve(to: CGPoint(x: r.width - 1, y: 0), control: CGPoint(x: r.width * 0.55, y: r.height * 0.13))
        p.addLine(to: CGPoint(x: r.width - 2, y: r.height * 0.8))
        p.addQuadCurve(to: CGPoint(x: 1, y: r.height * 0.85), control: CGPoint(x: r.width * 0.35, y: r.height * 1.2))
        p.addQuadCurve(to: CGPoint(x: 2, y: r.height * 0.25), control: CGPoint(x: -6, y: r.height * 0.6))
        return p
    }
}
struct PageTitle: View {
    var title: String
    var body: some View {
        Text(title).font(KiviTheme.heading()).tracking(-0.6).fixedSize(horizontal: false, vertical: true)
            .overlay(alignment: .bottomLeading) {
                BrushUnderline().fill(KiviTheme.green.opacity(0.18)).frame(height: 7).offset(y: 2).padding(.trailing, -4)
            }
    }
}
struct SectionTitle: View {
    var title: String
    var body: some View { HStack(alignment: .firstTextBaseline, spacing: 12) { Text(title).font(KiviTheme.section()); Rectangle().fill(KiviTheme.line).frame(height: 1) }.padding(.top, 18).padding(.bottom, 12) }
}
/// Shared native content column measured against the installed app.
struct PageContent<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        content().frame(maxWidth: 980, alignment: .leading)
            .padding(.horizontal, 32).padding(.top, 44).padding(.bottom, 44)
            .frame(maxWidth: .infinity, alignment: .top)
    }
}
struct AppGlyph: View {
    var name: String
    var size: CGFloat = 20
    @State private var icon: NSImage?
    var body: some View {
        Group {
            if let icon { Image(nsImage: icon).resizable().interpolation(.high) }
            else { Image(systemName: name.lowercased().contains("speech") ? "waveform" : "doc.text").resizable().scaledToFit().padding(2).foregroundStyle(KiviTheme.muted) }
        }.frame(width: size, height: size).accessibilityHidden(true)
            .task(id: name) { icon = KiviAppIconCache.shared.icon(for: name) }
    }
}
struct IconButton: View {
    var icon: String
    var label: String
    var action: () -> Void
    @State private var isHovering = false
    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 15)).frame(width: 28, height: 30)
                .background(isHovering ? KiviTheme.panel.opacity(0.75) : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isHovering ? KiviTheme.green : KiviTheme.muted)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .help(label).accessibilityLabel(label)
    }
}
struct EmptyState: View {
    var icon: String
    var title: String
    var subtitle: String
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 27, weight: .ultraLight)).foregroundStyle(KiviTheme.green)
            Text(title).font(KiviTheme.serif(25))
            Text(subtitle).font(KiviTheme.body(14)).foregroundStyle(KiviTheme.muted).multilineTextAlignment(.center).frame(maxWidth: 360)
        }.frame(maxWidth: .infinity).padding(.vertical, 65)
    }
}
struct KiviField: View {
    var title: String
    @Binding var text: String
    var body: some View {
        TextField(title, text: $text).textFieldStyle(.plain).font(KiviTheme.body(15)).padding(13)
            .background(KiviTheme.panel, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(KiviTheme.line))
    }
}
struct KiviTextEditor: View {
    @Binding var text: String
    var prompt: String = ""
    var fontSize: CGFloat = 16
    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty { Text(prompt).font(KiviTheme.body(fontSize)).foregroundStyle(KiviTheme.muted.opacity(0.6)).padding(.horizontal, 6).padding(.top, 8).allowsHitTesting(false) }
            TextEditor(text: $text).font(KiviTheme.body(fontSize)).scrollContentBackground(.hidden).background(.clear).foregroundStyle(KiviTheme.ink)
        }
    }
}

@MainActor final class KiviAppIconCache {
    static let shared = KiviAppIconCache()
    private struct Entry { let image: NSImage?; let expires: Date }
    private var entries: [String: Entry] = [:]
    private var observer: NSObjectProtocol?
    init() {
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.entries.removeAll() }
        }
    }
    func icon(for name: String) -> NSImage? {
        let now = Date()
        if let cached = entries[name], cached.expires > now { return cached.image }
        let image = resolve(name)
        if entries.count > 256 { entries.removeAll() }
        entries[name] = Entry(image: image, expires: now.addingTimeInterval(60))
        return image
    }
    private func resolve(_ name: String) -> NSImage? {
        let ids = ["Outlook": "com.microsoft.Outlook", "Slack": "com.tinyspeck.slackmacgap", "WhatsApp": "net.whatsapp.WhatsApp", "Signal": "org.whispersystems.signal-desktop", "Cursor": "com.todesktop.230313mzl4w4u92", "Xcode": "com.apple.dt.Xcode", "ChatGPT": "com.openai.chat", "Mail": "com.apple.mail", "Messages": "com.apple.MobileSMS", "Safari": "com.apple.Safari", "Notes": "com.apple.Notes", "Pages": "com.apple.iWork.Pages", "Microsoft Teams": "com.microsoft.teams2", "Teams": "com.microsoft.teams2", "Zoom": "us.zoom.xos", "Terminal": "com.apple.Terminal", "System Settings": "com.apple.systempreferences", "Finder": "com.apple.finder", "Calendar": "com.apple.iCal", "Maps": "com.apple.Maps", "Google Chrome": "com.google.Chrome"]
        let url = ids[name].flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) } ?? URL(fileURLWithPath: "/Applications/\(name).app")
        if FileManager.default.fileExists(atPath: url.path) { return NSWorkspace.shared.icon(forFile: url.path) }
        return NSImage(named: "KiviApp\(name)")
    }
}

/// One wide composition, with its quiet left side reserved for real summary text.
struct KiviSummaryBanner: View {
    @Environment(\.colorScheme) private var colorScheme
    enum ArtworkPlacement: Equatable { case home, insights }
    var subject: String
    var value: String
    var caption: String
    var detail: String? = nil
    var bannerAspectRatio: CGFloat = 3
    var artworkPlacement: ArtworkPlacement = .home
    private static let artworkSubjects = ["words-today", "all-time", "top-app", "time-saved"]
    private var ink: Color { colorScheme == .dark ? Color(red: 1, green: 0.97, blue: 0.86) : Color(red: 0.12, green: 0.20, blue: 0.11) }
    var body: some View {
        TimelineView(.periodic(from: .now, by: 300)) { timeline in
        GeometryReader { geometry in
            let compact = geometry.size.width < 620
            let slot = Int(timeline.date.timeIntervalSince1970 / (6 * 60 * 60))
            let offset = artworkPlacement == .home ? 0 : 1
            let artworkSubject = Self.artworkSubjects[(slot + offset) % Self.artworkSubjects.count]
            ZStack(alignment: .leading) {
                if let url = Bundle.main.url(forResource: "StatsArt-\(colorScheme == .dark ? "night" : "paper")-\(artworkSubject)", withExtension: "png"),
                   let artwork = NSImage(contentsOf: url) {
                    Image(nsImage: artwork).resizable().interpolation(.high)
                        .scaledToFill().frame(width: geometry.size.width, height: geometry.size.height).clipped()
                        .accessibilityHidden(true)
                } else { KiviTheme.panel }
                VStack(alignment: .leading, spacing: compact ? 6 : 9) {
                    Text(value).font(KiviTheme.greeting(compact ? 52 : 70)).tracking(-1.5)
                        .lineLimit(1).minimumScaleFactor(0.55).monospacedDigit()
                    Text(caption).font(KiviTheme.medium(compact ? 14 : 17))
                    if let detail { Text(detail).font(KiviTheme.body(compact ? 13 : 15)) }
                }
                .foregroundStyle(ink)
                .frame(width: geometry.size.width * 0.55, alignment: .leading)
                .padding(.leading, compact ? 22 : 32)
            }
        }
        }
        .aspectRatio(bannerAspectRatio, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(KiviTheme.line))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([value, caption, detail].compactMap { $0 }.joined(separator: ", "))
    }
}
