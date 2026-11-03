import SwiftUI

struct KiviShortcutRow: View {
    @ObservedObject private var dictation = DictationViewModel.shared
    let slot: HotkeySlotType
    let title: String
    let subtitle: String
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(KiviTheme.body(15))
                    Text(subtitle).font(KiviTheme.body(12)).foregroundStyle(KiviTheme.muted)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 6) {
                    ForEach(dictation.hotkeys(for: slot), id: \.self) { hotkey in
                        HotkeyRecorderView(label: HotkeyService.displayName(for: hotkey), title: title, presentation: .kivi,
                            onRecord: { save($0, replacing: hotkey) },
                            onClear: { dictation.removeHotkey(hotkey, for: slot); error = nil }, hotkey: hotkey)
                    }
                    HotkeyRecorderView(label: "", title: title, presentation: .kivi,
                        onRecord: { save($0, replacing: nil) }, onClear: {})
                }
            }
            if let error { Text(error).font(KiviTheme.body(12)).foregroundStyle(.red) }
        }.padding(18)
    }

    private func save(_ key: UnifiedHotkey, replacing previous: UnifiedHotkey?) {
        guard dictation.isHotkeyAssigned(key, excluding: slot) == nil,
              ServiceContainer.shared.hotkeyService.isHotkeyAssignedToWorkflow(key, excludingWorkflowId: nil) == nil else {
            error = "that shortcut is already used by another action. choose another key."
            return
        }
        guard !dictation.hotkeys(for: slot).contains(where: { $0 != previous && $0.conflicts(with: key) }) else {
            error = "this action already has that shortcut."
            return
        }
        if let previous { dictation.replaceHotkey(previous, with: key, for: slot) }
        else { dictation.addHotkey(key, for: slot) }
        error = nil
    }
}
