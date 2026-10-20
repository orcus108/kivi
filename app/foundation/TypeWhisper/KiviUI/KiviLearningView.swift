import SwiftUI

struct KiviLearningView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var service = ServiceContainer.shared.targetAppCorrectionLearningService
    @AppStorage(TargetAppCorrectionLearningService.localEnabledKey) private var enabled = true
    @AppStorage(TargetAppCorrectionLearningService.automaticLearningKey) private var automatic = true
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionTitle(title: "learning your words")
            VStack(alignment: .leading, spacing: 16) {
                HStack { VStack(alignment: .leading, spacing: 5) { Text("learn from corrections").font(KiviTheme.medium(16)); Text("Repeated, verified name-spelling edits become local dictionary rules.").font(KiviTheme.body(13)).foregroundStyle(KiviTheme.muted) }; Spacer(); Toggle("learn from corrections", isOn: $enabled).labelsHidden().toggleStyle(SettingsSwitchStyle()) }
                Toggle("remember repeated spellings automatically", isOn: $automatic).font(KiviTheme.body(14)).toggleStyle(.checkbox).disabled(!enabled)
                Text(service.detectionStatus).font(KiviTheme.body(13)).foregroundStyle(KiviTheme.muted)
                ForEach(service.detectedEdits.reversed()) { edit in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack { Text(edit.original).foregroundStyle(KiviTheme.muted); Image(systemName: "arrow.right").foregroundStyle(KiviTheme.green); Text(edit.edited) }.font(KiviTheme.body(14)).lineLimit(3)
                        Text(service.classification(for: edit)).font(KiviTheme.body(12)).foregroundStyle(KiviTheme.muted)
                        HStack {
                            if TargetAppCorrectionLearningService.spellingSuggestion(for: edit) != nil { Button("remember spelling") { service.rememberDetectedEdit(id: edit.id) }.buttonStyle(KiviButton(primary: true)) }
                            Button("discard") { service.removeDetectedEdit(id: edit.id) }.buttonStyle(KiviButton())
                        }
                    }.padding(.vertical, 8)
                }
                if let message = service.reviewMessage { Text(message).font(KiviTheme.body(13)).foregroundStyle(KiviTheme.muted) }
                HStack {
                    if !service.reviewedCorrections.isEmpty { Button("undo learned spelling") { service.undoReviewedCorrections() }.buttonStyle(KiviButton()) }
                    if !service.detectedEdits.isEmpty { Button("clear captures") { service.clearDetectedEdits() }.buttonStyle(KiviButton()) }
                }
            }.padding(22).background(KiviTheme.panel, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(KiviTheme.line))
        }.disabled(model.incognito).onChange(of: enabled) { _, value in if !value { service.stopDetection(); service.dismissReview() } }
    }
}
