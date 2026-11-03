import SwiftUI

/// Short, always-visible preference choices with ordinary button focus and arrow navigation.
struct KiviSettingsChoices<Value: Hashable>: View {
    let label: String
    @Binding var selection: Value
    let options: [(Value, String)]
    @FocusState private var focused: Value?

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                Button { selection = option.0 } label: {
                    Text(option.1).frame(maxWidth: .infinity)
                }.buttonStyle(KiviButton(primary: selection == option.0))
                    .focused($focused, equals: option.0).focusEffectDisabled()
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(focused == option.0 ? KiviTheme.green : .clear, lineWidth: 2))
                    .accessibilityLabel("\(label): \(option.1)")
                    .accessibilityAddTraits(selection == option.0 ? .isSelected : [])
                    .onKeyPress(.leftArrow) { move(-1); return .handled }
                    .onKeyPress(.rightArrow) { move(1); return .handled }
            }
        }
    }
    private func move(_ direction: Int) {
        guard !options.isEmpty, let index = options.firstIndex(where: { $0.0 == (focused ?? selection) }) else { return }
        let next = options[(index + direction + options.count) % options.count].0
        selection = next
        focused = next
    }
}

struct KiviCancellationChoice: Identifiable {
    let value: CancellationBehavior
    let title: String
    let detail: String
    var id: CancellationBehavior { value }
    static let all: [Self] = [
        .init(value: .doubleEscape, title: "press Escape twice", detail: "confirm before cancelling"),
        .init(value: .singleEscape, title: "press Escape once", detail: "cancel and show a brief confirmation"),
        .init(value: .instant, title: "cancel silently", detail: "press Escape once, without a confirmation notice"),
        .init(value: .disabled, title: "don’t use Escape", detail: "ignore Escape while recording or processing")
    ]
}

struct KiviMicrophoneChooser: View {
    @ObservedObject var devices: AudioDeviceService
    let onClose: () -> Void
    @State private var search = ""
    @FocusState private var searchFocused: Bool
    @FocusState private var focusedDevice: String?
    private struct Choice: Identifiable {
        let id: String
        let title: String
        let uid: String?
    }
    private var choices: [Choice] {
        ([Choice(id: "system", title: "system default", uid: nil)] + devices.inputDevices.map {
            Choice(id: "device-" + $0.uid, title: $0.name, uid: $0.uid)
        }).filter { search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || $0.title.localizedCaseInsensitiveContains(search.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("microphone").font(KiviTheme.medium(17))
                Spacer()
                IconButton(icon: "xmark", label: "close microphone chooser", action: onClose)
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(KiviTheme.muted)
                TextField("search microphones", text: $search).textFieldStyle(.plain).font(KiviTheme.body(14))
                    .focused($searchFocused)
                    .onExitCommand(perform: onClose)
                    .onKeyPress(.downArrow) {
                        guard let first = choices.first else { return .ignored }
                        focusedDevice = first.id
                        return .handled
                    }
            }.padding(10).background(KiviTheme.background, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(searchFocused ? KiviTheme.green : KiviTheme.line))
            if choices.isEmpty {
                Text("no microphones match your search").font(KiviTheme.body(14)).foregroundStyle(KiviTheme.muted).padding(.vertical, 12)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(choices) { choice in
                            Button {
                                devices.selectedDeviceUID = choice.uid
                                onClose()
                            } label: {
                                HStack(spacing: 10) {
                                    Text(choice.title).font(KiviTheme.body(14)).multilineTextAlignment(.leading)
                                    Spacer(minLength: 8)
                                    if choice.uid == devices.selectedDeviceUID {
                                        Image(systemName: "checkmark").foregroundStyle(KiviTheme.green)
                                    }
                                }.padding(10).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }.buttonStyle(KiviSettingsOptionStyle(selected: choice.uid == devices.selectedDeviceUID, focused: focusedDevice == choice.id))
                                .focused($focusedDevice, equals: choice.id).focusEffectDisabled()
                                .accessibilityAddTraits(choice.uid == devices.selectedDeviceUID ? .isSelected : [])
                                .onKeyPress(.downArrow) { move(1, from: choice.id); return .handled }
                                .onKeyPress(.upArrow) { move(-1, from: choice.id); return .handled }
                        }
                    }
                }.frame(height: min(260, CGFloat(choices.count) * 44))
            }
            if devices.inputDevices.isEmpty {
                Text("no microphones are currently available. reconnect a microphone to see it here.")
                    .font(KiviTheme.body(12)).foregroundStyle(KiviTheme.muted).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(18).frame(width: 310).foregroundStyle(KiviTheme.ink).background(KiviTheme.panel)
            .onAppear { searchFocused = true }
            .background {
                Button("cancel microphone chooser", action: onClose).keyboardShortcut(.cancelAction)
                    .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
            }
    }
    private func move(_ direction: Int, from id: String) {
        guard let index = choices.firstIndex(where: { $0.id == id }) else { return }
        if index == 0 && direction < 0 { searchFocused = true; return }
        focusedDevice = choices[min(max(index + direction, 0), choices.count - 1)].id
    }
}

struct KiviSettingsOptionStyle: ButtonStyle {
    var selected: Bool
    var focused: Bool
    @State private var hovered = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(selected ? KiviTheme.green.opacity(0.08) : (hovered ? KiviTheme.background.opacity(0.65) : .clear), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(focused ? KiviTheme.green : (hovered ? KiviTheme.line : .clear)))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .onHover { hovered = $0 }
    }
}
