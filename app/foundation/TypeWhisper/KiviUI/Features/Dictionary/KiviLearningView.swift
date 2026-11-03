import SwiftUI

/// The dictionary shows the saved words; learning needs only one everyday control.
struct KiviLearningView: View {
    @EnvironmentObject var model: AppModel
    @State private var showsExplanation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("learn from corrections").font(KiviTheme.medium(16)).foregroundStyle(KiviTheme.ink)
                    Text(model.incognito ? "Paused while incognito is on." : "Kivi learns from repeated name corrections.")
                        .font(KiviTheme.body(13)).foregroundStyle(KiviTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                KiviLearningSwitch()
            }

            Button { showsExplanation.toggle() } label: {
                HStack(spacing: 5) {
                    Text(showsExplanation ? "show less" : "how it works")
                    Image(systemName: showsExplanation ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                }
                .font(KiviTheme.medium(12))
                .foregroundStyle(KiviTheme.green)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(showsExplanation ? "Show less about correction learning" : "How correction learning works")
            .accessibilityValue(showsExplanation ? "Expanded" : "Collapsed")

            if showsExplanation {
                VStack(alignment: .leading, spacing: 12) {
                    Rectangle().fill(KiviTheme.line).frame(height: 1)
                    Text("you correct it. kivi remembers.")
                        .font(KiviTheme.medium(14)).foregroundStyle(KiviTheme.ink)
                    Text("Kivi writes **Rohan** → you change it to **Rohaan**.")
                    Text("Make the same correction in two separate dictations, and Kivi can remember it for next time.")
                    Text("Remembered words appear in your dictionary. You can edit or delete them anytime.")
                    Text("Some apps don’t let Kivi see your edits, so learning won’t work everywhere.")
                        .font(KiviTheme.body(12))
                }
                .font(KiviTheme.body(13))
                .foregroundStyle(KiviTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(20)
        .background(KiviTheme.panel, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(KiviTheme.line))
    }
}

/// Both settings surfaces control the same complete automatic-learning behavior.
/// Reading an older capture-only preference does not silently change it.
struct KiviLearningSwitch: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var service = ServiceContainer.shared.targetAppCorrectionLearningService
    @AppStorage(TargetAppCorrectionLearningService.localEnabledKey) private var enabled = true
    @AppStorage(TargetAppCorrectionLearningService.automaticLearningKey) private var automatic = true

    var body: some View {
        Toggle("learn from corrections", isOn: Binding(
            get: { enabled && automatic },
            set: { value in
                enabled = value
                automatic = value
                if !value { service.stopDetection(); service.dismissReview() }
            }
        ))
        .labelsHidden()
        .toggleStyle(SettingsSwitchStyle())
        .disabled(model.incognito)
    }
}

/// A nonactivating acknowledgment keeps typing in the destination editor.
@MainActor
final class KiviLearnedWordsPanel: NSPanel {
    init(service: TargetAppCorrectionLearningService) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 350, height: 126),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        acceptsMouseMovedEvents = true
        hidesOnDeactivate = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = NSHostingView(rootView: KiviLearnedWordsNotice(service: service))
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func showFeedback() {
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            setFrameOrigin(NSPoint(x: visible.maxX - frame.width - 24, y: visible.minY + 32))
        }
        orderFrontRegardless()
    }
}

private struct KiviLearnedWordsNotice: View {
    @ObservedObject var service: TargetAppCorrectionLearningService

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(KiviTheme.green)
                Text("learning your words").font(KiviTheme.medium(15))
                Spacer()
                Button { service.hideLearningFeedback() } label: { Image(systemName: "xmark").font(.system(size: 11)) }
                    .buttonStyle(.plain).accessibilityLabel("Dismiss learned words notice")
            }
            Text(service.reviewMessage ?? "Saved in your dictionary.")
                .font(KiviTheme.body(13)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            Button("undo learning") { service.undoReviewedCorrections() }
                .font(KiviTheme.medium(12)).buttonStyle(.plain).foregroundStyle(KiviTheme.green)
        }
        .foregroundStyle(KiviTheme.ink)
        .padding(16)
        .frame(width: 350, height: 126, alignment: .leading)
        .background(KiviTheme.panel, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(KiviTheme.line))
        .onHover { service.setLearningFeedbackHovered($0) }
    }
}
