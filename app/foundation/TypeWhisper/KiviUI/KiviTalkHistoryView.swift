import SwiftUI

struct KiviTalkHistoryView: View {
    @ObservedObject var conversation: KiviTalkConversation

    private var visibleChanges: [KiviTalkChangeRecord] {
        conversation.changes.filter { $0.state != .removed && $0.state != .undone }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("changes").font(KiviTheme.heading()).accessibilityAddTraits(.isHeader)
                if let error = conversation.historyError {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(error).font(KiviTheme.body(14)).fixedSize(horizontal: false, vertical: true)
                        Button("try again") { conversation.refreshChanges() }.buttonStyle(KiviButton())
                    }
                }
                if visibleChanges.isEmpty && conversation.historyError == nil {
                    VStack(spacing: 12) {
                        Image(systemName: "clock").font(.system(size: 25, weight: .light)).foregroundStyle(KiviTheme.muted)
                        Text("no saved changes").font(KiviTheme.serif(25))
                        Text("Preferences you save through for you will appear here.")
                            .font(KiviTheme.body(14)).foregroundStyle(KiviTheme.muted).multilineTextAlignment(.center).frame(maxWidth: 360)
                    }.frame(maxWidth: .infinity).padding(.vertical, 65)
                }
                ForEach(visibleChanges) { record in
                    KiviTalkHistoryRow(record: record, canUndo: conversation.canRemoveChange(record)) {
                        conversation.removeChange(record.id)
                    }
                }
            }.frame(maxWidth: 690, alignment: .leading).padding(.horizontal, 36).padding(.top, 26).padding(.bottom, 36)
                .frame(maxWidth: .infinity)
        }
        .onAppear { conversation.refreshChanges() }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in conversation.refreshChanges() }
    }
}

private struct KiviTalkHistoryRow: View {
    let record: KiviTalkChangeRecord
    let canUndo: Bool
    let onUndo: () -> Void
    @State private var details = false
    @State private var confirmingUndo = false

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Rectangle().fill(KiviTheme.line).frame(height: 1)
            HStack(alignment: .top, spacing: 12) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 18) {
                        ForEach(record.apps, id: \.self) { app in appLabel(app, size: 16) }
                    }.fixedSize(horizontal: true, vertical: false)
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(record.apps, id: \.self) { app in appLabel(app, size: 16) }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                if record.state != .saved || !canUndo {
                    Text(stateLabel).font(KiviTheme.body(12)).foregroundStyle(KiviTheme.muted)
                }
            }
            Text(record.date.formatted(date: .abbreviated, time: .shortened)).font(KiviTheme.body(12)).foregroundStyle(KiviTheme.muted)
            Text(record.instructions).font(KiviTheme.body(15)).lineSpacing(3).textSelection(.enabled)
            HStack(spacing: 18) {
                Button(details ? "hide details" : "details") { details.toggle(); confirmingUndo = false }.buttonStyle(KiviButton())
                if record.state == .saved && canUndo && !confirmingUndo {
                    Button("remove change…") { confirmingUndo = true }.buttonStyle(KiviButton())
                }
            }
            if details {
                ForEach(comparisonGroups, id: \.self) { apps in
                    VStack(alignment: .leading, spacing: 14) {
                        if comparisonGroups.count > 1 {
                            Text(apps.joined(separator: " · ")).font(KiviTheme.medium(13))
                        }
                        ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 18) {
                            previousValues(apps).frame(width: 250, alignment: .leading)
                            Image(systemName: "arrow.right").foregroundStyle(KiviTheme.muted).padding(.top, 3).accessibilityHidden(true)
                            snapshot("updated", data: record.after, app: apps[0]).frame(width: 250, alignment: .leading)
                        }
                        VStack(alignment: .leading, spacing: 18) {
                            previousValues(apps)
                            Image(systemName: "arrow.down").foregroundStyle(KiviTheme.muted).accessibilityHidden(true)
                            snapshot("updated", data: record.after, app: apps[0])
                        }
                        }
                    }.padding(18)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(KiviTheme.panel, in: RoundedRectangle(cornerRadius: 12))
                }
            }

            if confirmingUndo {
                Text("Remove this preference from \(record.apps.joined(separator: " and "))? Later changes will stay.").font(KiviTheme.body(14))
                HStack(spacing: 12) {
                    Button("cancel") { confirmingUndo = false }.buttonStyle(KiviButton())
                    Button("remove change") { onUndo(); confirmingUndo = false }.buttonStyle(KiviButton(primary: true)).disabled(!canUndo)
                }
            }
            if details && record.state == .saved && !canUndo {
                Text("This entry could not be safely read. Your current preferences have not been changed.")
                    .font(KiviTheme.body(12)).foregroundStyle(KiviTheme.muted)
            } else if record.state == .needsReview {
                Text("An interrupted change couldn’t be verified. Review your current rules in Styles.")
                    .font(KiviTheme.body(12)).foregroundStyle(KiviTheme.muted)
            }
        }.accessibilityElement(children: .contain)
    }

    private func appLabel(_ app: String, size: CGFloat) -> some View {
        HStack(spacing: 8) {
            AppGlyph(name: app, size: 22)
            Text(app).font(KiviTheme.medium(size)).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var stateLabel: String {
        switch record.state {
        case .saved: canUndo ? "" : "needs review"
        case .undone: "undone"
        case .removed: "removed"
        case .notSaved: "not saved"
        case .needsReview, .applying, .undoing: "needs review"
        }
    }

    // Updated values are shared once even when the apps started differently.
    private var comparisonGroups: [[String]] {
        var groups: [[String]] = []
        for app in record.apps {
            if let index = groups.firstIndex(where: { snapshotText(record.after, app: $0[0], updated: true) == snapshotText(record.after, app: app, updated: true) }) {
                groups[index].append(app)
            } else { groups.append([app]) }
        }
        return groups
    }

    private func previousValues(_ apps: [String]) -> some View {
        let same = apps.allSatisfy { snapshotText(record.before, app: $0) == snapshotText(record.before, app: apps[0]) }
        return VStack(alignment: .leading, spacing: 18) {
            if same { snapshot("previous", data: record.before, app: apps[0]) }
            else {
                ForEach(apps, id: \.self) { app in snapshot("previous · " + app, data: record.before, app: app) }
            }
        }
    }

    private func snapshot(_ label: String, data: Data?, app: String) -> some View {
        let value = snapshotText(data, app: app, updated: label == "updated")
        let parts = value.components(separatedBy: "\n")
        let hasTone = value.hasPrefix("Tone: ")
        let paragraphs = hasTone ? Array(parts.dropFirst()) : parts
        return VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                Text(label).font(KiviTheme.medium(12)).foregroundStyle(KiviTheme.muted)
                if hasTone {
                    Text(parts[0].replacingOccurrences(of: "Tone: ", with: "") + " tone")
                        .font(KiviTheme.body(12)).foregroundStyle(KiviTheme.muted)
                }
            }
            Text(paragraphs.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines))
                .font(KiviTheme.body(14)).lineSpacing(5).foregroundStyle(KiviTheme.ink).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func snapshotText(_ data: Data?, app: String, updated: Bool = false) -> String {
        let config: KiviStyleConfiguration
        if let data {
            guard let decoded = try? JSONDecoder().decode(KiviStyleConfiguration.self, from: data) else { return "Snapshot unavailable." }
            config = decoded
        } else { config = .init() }
        guard let style = KiviStyleRouter.resolved(appName: app, configuration: config) else { return "Default preferences." }
        let instructions = updated ? record.instructions : style.rules.replacingOccurrences(of: "Latest preference (wins conflicts with older app instructions): ", with: "")
        let result = "Tone: \(style.mode)\n\(instructions)"
        return result
    }
}

/// Model choice remains available after removing its control from the chat header.
struct KiviTalkModelSettings: View {
    @ObservedObject var conversation: KiviTalkConversation
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("for you model").font(KiviTheme.medium(16))
            KiviSettingsChoices(label: "for you model", selection: Binding(get: { conversation.usesGroq }, set: { conversation.selectGroq($0) }),
                                options: [(true, "Groq"), (false, "on this Mac")])
                .disabled(conversation.busy || conversation.listening || conversation.transcribing)
            Text(conversation.usesGroq ? "Groq interprets conversation requests using your saved key. On this Mac keeps the conversation local." : "Conversation requests are interpreted locally, without an API key.")
                .font(KiviTheme.body(12)).foregroundStyle(KiviTheme.muted)
        }.padding(20)
    }
}
