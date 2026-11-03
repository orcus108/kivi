import SwiftUI

/// Session-only recovery: each unresolved take keeps its own text, even if History is off.
/// Indicator expiry and subsequent dictations deliberately do not change this queue.
struct KiviPendingRecovery {
    struct Item: Identifiable, Equatable {
        let id: UUID
        let text: String
    }
    private(set) var items: [Item] = []

    mutating func add(id: UUID, text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !items.contains(where: { $0.id == id }) else { return }
        items.append(Item(id: id, text: text))
    }

    mutating func resolve(_ id: UUID) { items.removeAll { $0.id == id } }
}

struct KiviPendingRecoveryBar: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var dictation: DictationViewModel

    var body: some View {
        if let item = dictation.pendingInsertionRecovery.items.first {
            HStack(spacing: 16) {
                Image(systemName: "doc.on.clipboard").foregroundStyle(KiviTheme.green)
                VStack(alignment: .leading, spacing: 3) {
                    Text(dictation.pendingInsertionRecovery.items.count == 1
                         ? "your text is ready"
                         : "\(dictation.pendingInsertionRecovery.items.count) takes ready to copy")
                        .font(KiviTheme.medium(14))
                    Text(item.text).font(KiviTheme.body(13)).foregroundStyle(KiviTheme.muted).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Button("copy") {
                    if dictation.copyPendingInsertionRecovery(item.id) {
                        model.notify("copied — paste with ⌘V")
                    } else { model.notify("couldn’t copy — please try again") }
                }.buttonStyle(KiviButton(primary: true))
                Button("dismiss") { dictation.dismissPendingInsertionRecovery(item.id) }
                    .buttonStyle(KiviButton())
                    .help("Dismiss this recovery reminder. Saved history is unchanged.")
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
            .foregroundStyle(KiviTheme.ink)
            .background(KiviTheme.panel, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(KiviTheme.line))
            .padding(.horizontal, 16).padding(.bottom, 12)
            .accessibilityElement(children: .contain)
        }
    }
}

struct KiviHomeShortcutHint: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var dictation: DictationViewModel
    @ObservedObject var hotkeys: HotkeyService

    private var hint: String {
        if hotkeys.dictationHotkeysPaused { return "dictation shortcuts are paused" }
        if let key = dictation.hotkeys(for: .pushToTalk).first {
            return "hold \(HotkeyService.displayName(for: key)) to dictate · release to finish"
        }
        if let key = dictation.hotkeys(for: .hybrid).first {
            return "hold \(HotkeyService.displayName(for: key)) to dictate · or tap to start and stop"
        }
        if let key = dictation.hotkeys(for: .toggle).first {
            return "press \(HotkeyService.displayName(for: key)) to dictate · press again to finish"
        }
        return "set a shortcut to dictate anywhere"
    }

    var body: some View {
        Button {
            model.settingsSection = "shortcuts"
            model.page = .settings
        } label: {
            Label(hint, systemImage: "keyboard")
                .font(KiviTheme.body(13)).foregroundStyle(KiviTheme.muted)
                .padding(.vertical, 3).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .help("Open keyboard shortcuts")
    }
}
