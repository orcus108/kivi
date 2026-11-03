import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// A frozen aggregate snapshot: no transcripts, destinations or recordings enter the export.
struct KiviInsightsShareSnapshot: Identifiable {
    let id = UUID()
    let report: KiviInsightReport
    let typingWPM: Int
    let isDemo: Bool
    var savedTime: String {
        guard let seconds = report.estimatedSavedSeconds(typingWPM: typingWPM) else { return "—" }
        let minutes = Int(seconds / 60)
        if seconds > 0 && minutes == 0 { return "<1 min" }
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes) min"
    }
    var writingComparison: String {
        let words = report.words
        guard words > 0 else { return "Your first words are still ahead." }
        let books = words / KiviInsightReport.wordsPerShortBook
        if books > 0 {
            return books == 1
                ? "That’s enough words for a whole short book!"
                : "That’s enough words for \(books.formatted()) short books!"
        }
        guard words >= KiviInsightReport.wordsPerPage else { return "That’s the start of your first page!" }
        let pages = Int((Double(words) / Double(KiviInsightReport.wordsPerPage)).rounded())
        return "That’s about \(pages.formatted()) \(pages == 1 ? "page" : "pages") of writing!"
    }
    var speed: String { report.dictationWPM.map { "\($0.formatted(.number.precision(.fractionLength(0)))) WPM" } ?? "—" }

}

struct KiviInsightsPoster: View {
    let snapshot: KiviInsightsShareSnapshot
    private let ink = Color(red: 0.055, green: 0.20, blue: 0.12)
    private let paper = Color(red: 1, green: 0.96, blue: 0.82)
    private var wordmark: CGImage? {
        guard let image = KiviTheme.image("kivi-wordmark"),
              let appearance = NSAppearance(named: .aqua) else { return nil }
        var resolved: CGImage?
        appearance.performAsCurrentDrawingAppearance {
            resolved = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        return resolved
    }
    var body: some View {
        ZStack(alignment: .bottom) {
            paper
            if let url = Bundle.main.url(forResource: "StatsArt-paper-all-time", withExtension: "png"), let artwork = NSImage(contentsOf: url) {
                VStack(spacing: 0) {
                    Image(nsImage: artwork).resizable().scaledToFill()
                        .frame(width: 720, height: 246, alignment: .trailing).clipped()
                        .mask {
                            LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .clear, location: 0.1), .init(color: .black, location: 0.3), .init(color: .black, location: 0.92), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom)
                        }
                    paper.frame(height: 70)
                }.accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center) {
                    if let wordmark {
                        Image(decorative: wordmark, scale: 1).resizable().scaledToFit().frame(width: 82, height: 42)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("all time").font(KiviTheme.body(18))
                        if snapshot.isDemo { Text("demo stats").font(KiviTheme.medium(14)) }
                    }
                }
                Text("less time typing.\nmore time doing.")
                    .font(KiviTheme.greeting(39)).tracking(-0.8).lineSpacing(-1).padding(.top, 32)
                Text(snapshot.report.words.formatted())
                    .font(KiviTheme.medium(120)).tracking(-5).lineLimit(1).minimumScaleFactor(0.38)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 20)
                Text("words dictated").font(KiviTheme.medium(26)).padding(.top, -6)
                Text(snapshot.writingComparison)
                    .font(KiviTheme.body(21)).padding(.top, 9)
                Rectangle().fill(ink.opacity(0.2)).frame(height: 1).padding(.top, 25).padding(.bottom, 21)
                HStack(alignment: .top, spacing: 28) {
                    stat(snapshot.savedTime, "of typing saved")
                    stat(snapshot.speed, "average dictation speed")
                }
                Spacer()

            }.padding(44)
            HStack(alignment: .firstTextBaseline) {
                Text("heykivi.ai").font(KiviTheme.medium(22))
                Spacer()
                Text("voice typing for Mac").font(KiviTheme.body(18))
            }.padding(.horizontal, 44).frame(height: 70)
        }
        .foregroundStyle(ink).frame(width: 720, height: 900).clipped()
        .environment(\.colorScheme, .light)
    }
    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(value).font(KiviTheme.medium(36)).lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(KiviTheme.body(19)).lineLimit(1).minimumScaleFactor(0.85)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct KiviInsightsSharePreview: View {
    let snapshot: KiviInsightsShareSnapshot
    @Environment(\.dismiss) private var dismiss
    @State private var image: NSImage?
    @State private var png: Data?
    @State private var feedback = ""
    @State private var saving = false
    @State private var hostWindow = KiviShareWindowReference()

    var body: some View {
        VStack(spacing: 20) {
            HStack {
                Text("share insights").font(KiviTheme.medium(18))
                Spacer()
                KiviShareAction(title: "close share preview", icon: "xmark", iconOnly: true) { dismiss() }
                    .disabled(saving)
            }
            GeometryReader { geometry in
                if let image {
                    Image(nsImage: image).resizable().scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityLabel("All-time recap: \(snapshot.report.words.formatted()) words. \(snapshot.writingComparison) Estimated typing time saved: \(snapshot.savedTime), compared with typing at \(snapshot.typingWPM) WPM. Average dictation speed: \(snapshot.speed).")
                } else {
                    Text("Preparing your image…").font(KiviTheme.body(14))
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }
            }
            HStack(spacing: 18) {
                Text(feedback).font(KiviTheme.body(12)).foregroundStyle(KiviTheme.muted)
                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(.updatesFrequently)
                KiviShareAction(title: "copy image", icon: "square.on.square", action: copy)
                    .disabled(png == nil || saving)
                KiviShareAction(title: saving ? "saving…" : "save image…", icon: "arrow.down.to.line", prominent: true, action: save)
                    .disabled(png == nil || saving)
            }.frame(minHeight: 32)
        }
        .padding(24).frame(width: 500, height: 650)
        .foregroundStyle(KiviTheme.ink).background(KiviBackground())
        .background(KiviShareWindowReader(reference: hostWindow, canDismiss: !saving) { dismiss() })
        .interactiveDismissDisabled(saving)
        .onAppear(perform: render)
        .onExitCommand { if !saving { dismiss() } }
    }

    @MainActor private func render() {
        let renderer = ImageRenderer(content: KiviInsightsPoster(snapshot: snapshot))
        renderer.scale = 2
        guard let cgImage = renderer.cgImage else { feedback = "Couldn’t prepare the image. Close this preview and try again."; return }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            feedback = "Couldn’t prepare the image. Close this preview and try again."; return
        }
        png = data
        image = NSImage(cgImage: cgImage, size: NSSize(width: 720, height: 900))
    }
    private func copy() {
        guard let png else { return }
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        NSPasteboard.general.clearContents()
        feedback = NSPasteboard.general.writeObjects([item]) ? "image copied" : "Couldn’t copy the image. Try saving it instead."
    }
    private func save() {
        guard let png else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "kivi-insights.png"
        panel.title = "Save your Kivi recap"
        panel.message = "Choose where to save your share image."
        guard let window = hostWindow.window else { feedback = "Couldn’t open the save dialog. Try again."; return }
        saving = true
        panel.beginSheetModal(for: window) { response in
            saving = false
            guard response == .OK, let url = panel.url else { feedback = ""; return }
            do {
                try png.write(to: url, options: .atomic)
                feedback = "image saved"
            } catch {
                feedback = "Couldn’t save the image. Choose another location or copy it instead."
            }
        }
    }
}

/// Quiet preview actions; hover and keyboard focus remain visible without filled boxes.
private struct KiviShareAction: View {
    let title: String
    let icon: String
    var iconOnly = false
    var prominent = false
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: icon).font(.system(size: iconOnly ? 16 : 13))
                if !iconOnly { Text(title).font(KiviTheme.body(14)) }
            }
            .padding(.horizontal, 4).frame(minWidth: 28, minHeight: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).fixedSize()
        .foregroundStyle(prominent || hovering || focused ? KiviTheme.green : KiviTheme.muted)
        .opacity(isEnabled ? (hovering ? 0.8 : 1) : 0.4)
        .focused($focused)
        .focusEffectDisabled()
        .overlay {
            if focused {
                RoundedRectangle(cornerRadius: 4).stroke(KiviTheme.green.opacity(0.65), lineWidth: 1)
                    .padding(-3).allowsHitTesting(false)
            }
        }
        .onHover { hovering = $0 }
        .accessibilityLabel(title).help(title)
    }
}

/// Bind the save panel to this exact preview, including when Kivi is not the key app.
private final class KiviShareWindowReference {
    weak var window: NSWindow?
}
private struct KiviShareWindowReader: NSViewRepresentable {
    let reference: KiviShareWindowReference
    let canDismiss: Bool
    let onDismiss: () -> Void

    func makeNSView(context: Context) -> WindowProbe {
        let view = WindowProbe()
        configure(view)
        view.setAccessibilityElement(false)
        return view
    }
    func updateNSView(_ view: WindowProbe, context: Context) { configure(view) }
    static func dismantleNSView(_ view: WindowProbe, coordinator: ()) { view.stopMonitoring() }
    private func configure(_ view: WindowProbe) {
        view.reference = reference
        view.canDismiss = canDismiss
        view.onDismiss = onDismiss
        reference.window = view.window
    }

    final class WindowProbe: NSView {
        var reference: KiviShareWindowReference?
        var canDismiss = false
        var onDismiss: (() -> Void)?
        private var clickMonitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            reference?.window = window
            stopMonitoring()
            guard window != nil else { return }
            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                guard let self, self.canDismiss,
                      let sheet = self.window, let parent = sheet.sheetParent,
                      parent.attachedSheet === sheet, sheet.attachedSheet == nil,
                      event.window === parent,
                      parent.contentLayoutRect.contains(event.locationInWindow),
                      !sheet.frame.contains(parent.convertPoint(toScreen: event.locationInWindow)) else { return event }
                // Consume the click before dismissal so the dimmed page cannot act on it.
                let dismiss = self.onDismiss
                DispatchQueue.main.async { dismiss?() }
                return nil
            }
        }
        func stopMonitoring() {
            if let clickMonitor { NSEvent.removeMonitor(clickMonitor); self.clickMonitor = nil }
        }
    }
}
