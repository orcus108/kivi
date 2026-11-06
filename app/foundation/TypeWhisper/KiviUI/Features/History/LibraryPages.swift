import SwiftUI
import AppKit

struct KiviHistoryControls: View {
    @ObservedObject var history: KiviHistoryStore
    let searchEnabled: Bool
    let heading: String
    let reduceMotion: Bool
    @State private var showSearch = false
    @State private var searchIconHovered = false
    @FocusState private var searchFocused: Bool
    @FocusState private var searchButtonFocused: Bool

    private var expanded: Bool { showSearch || !history.search.isEmpty }

    var body: some View {
        ZStack(alignment: .leading) {
            if expanded {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11)).foregroundStyle(KiviTheme.muted)
                        .accessibilityHidden(true)
                    TextField("search your words", text: $history.search)
                        .textFieldStyle(.plain).font(KiviTheme.body(13))
                        .focused($searchFocused)
                        .disabled(!searchEnabled)
                        .task {
                            await Task.yield()
                            if showSearch && searchEnabled && !Task.isCancelled { searchFocused = true }
                        }
                    Button(action: closeSearch) {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .medium))
                            .frame(width: 24, height: 24).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).foregroundStyle(KiviTheme.muted)
                    .accessibilityLabel("close history search")
                    .help("close history search")
                }
                .frame(maxWidth: 210)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(searchEnabled && searchFocused ? KiviTheme.green : KiviTheme.line)
                        .frame(height: 1).allowsHitTesting(false)
                }
                .background(KiviSearchFocusBoundary(focused: $searchFocused))
                .background(KiviEscapeCapture(enabled: searchEnabled && searchFocused, onEscape: closeSearch))
                .onChange(of: searchEnabled) { if !searchEnabled { searchFocused = false } }
                .transition(reduceMotion ? .identity : .modifier(
                    active: HistorySearchWidth(scale: 0.25),
                    identity: HistorySearchWidth(scale: 1)
                ).combined(with: .opacity))
                .allowsHitTesting(expanded)
            } else {
                HStack(spacing: 8) {
                    Text(heading)
                        .font(KiviTheme.medium(13)).foregroundStyle(KiviTheme.muted)
                        .accessibilityAddTraits(.isHeader)
                        .fixedSize()
                    searchButton
                }
                .transition(reduceMotion ? .identity : .opacity)
                .allowsHitTesting(!expanded)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.24), value: expanded)
    }

    private var searchButton: some View {
        Button { showSearch = true } label: {
            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium))
                .frame(width: 24, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(searchIconHovered || searchButtonFocused ? KiviTheme.green : KiviTheme.muted)
        .onHover { searchIconHovered = $0 }
        .focused($searchButtonFocused)
        .disabled(!searchEnabled)
        .accessibilityLabel("search history")
        .help("search history")
    }

    private func closeSearch() {
        searchFocused = false
        history.search = ""
        showSearch = false
        searchButtonFocused = true
    }
}

private struct HistorySearchWidth: ViewModifier {
    let scale: CGFloat

    func body(content: Content) -> some View {
        content.scaleEffect(x: scale, y: 1, anchor: UnitPoint(x: 0.25, y: 0.5))
    }
}

// Observe clicks without consuming them, so row actions and text selection still work.
private struct KiviSearchFocusBoundary: NSViewRepresentable {
    @FocusState.Binding var focused: Bool
    func makeNSView(context: Context) -> BoundaryView {
        let view = BoundaryView()
        view.clearFocus = { focused = false }
        view.isSearchFocused = { focused }
        return view
    }
    func updateNSView(_ view: BoundaryView, context: Context) {
        view.clearFocus = { focused = false }
        view.isSearchFocused = { focused }
    }
    static func dismantleNSView(_ view: BoundaryView, coordinator: ()) { view.stopObserving() }
    final class BoundaryView: NSView {
        var clearFocus: (() -> Void)?
        var isSearchFocused: (() -> Bool)?
        private var monitor: Any?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopObserving()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self, let window = self.window, event.window === window,
                      self.isSearchFocused?() == true else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                if !self.bounds.contains(point) {
                    self.clearFocus?()
                    window.makeFirstResponder(nil)
                }
                return event
            }
        }
        func stopObserving() {
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        }
    }
}

struct TakeDetail: View {
    @EnvironmentObject var model: AppModel
    var take: Take
    @State private var showSource = false
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(take.source.lowercased()).font(KiviTheme.body(14)).foregroundStyle(KiviTheme.muted)
                Spacer()
                IconButton(icon: "xmark", label: "close take") { model.selectedTake = nil }
                    .keyboardShortcut(.cancelAction)
            }.padding(.horizontal, 28).padding(.vertical, 20)
            Rectangle().fill(KiviTheme.line).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack { Text("what kivi wrote").font(KiviTheme.body(14)).foregroundStyle(KiviTheme.muted); Spacer(); IconButton(icon: "doc.on.doc", label: "copy take") { model.copy(take.text) } }.frame(height: 18)
                    Text(take.text).font(KiviTheme.body(18)).lineSpacing(6).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    Text("\(take.source.lowercased()) · \(take.date.formatted(.dateTime.month(.abbreviated).day().hour().minute())) · \(take.isSpeech ? "dictate" : "typed")")
                        .font(KiviTheme.body(13)).foregroundStyle(KiviTheme.muted)
                    Rectangle().fill(KiviTheme.line).frame(height: 1).padding(.top, 4)
                    Button { withAnimation { showSource.toggle() } } label: {
                        HStack(spacing: 8) { Image(systemName: showSource ? "chevron.down" : "chevron.right").font(.system(size: 10)); Text("source").font(KiviTheme.body(14)); Spacer() }
                            .foregroundStyle(KiviTheme.muted).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    if showSource {
                        Text("what you said").font(KiviTheme.body(14)).foregroundStyle(KiviTheme.muted)
                        Text(take.raw).font(KiviTheme.body(16)).lineSpacing(5).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.padding(.horizontal, 28).padding(.top, 24).padding(.bottom, 28)
            }
            Rectangle().fill(KiviTheme.line).frame(height: 1)
            HStack {
                Button("continue in kivi") { model.draft = take.text; model.selectedTake = nil; model.page = .record }.buttonStyle(.plain).font(KiviTheme.body(14))
                Spacer()
                Button("delete") { model.deleteTake(take.id); model.selectedTake = nil }.buttonStyle(.plain).font(KiviTheme.body(14))
            }.padding(.horizontal, 24).padding(.vertical, 18)
        }.background(KiviTheme.background).foregroundStyle(KiviTheme.ink).ignoresSafeArea(.container, edges: .top)
            .overlay(alignment: .leading) { Rectangle().fill(KiviTheme.line).frame(width: 1) }
    }
}

private struct KiviDeleteButton: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        let red = colorScheme == .dark ? Color(red: 0.95, green: 0.49, blue: 0.44) : Color(red: 0.65, green: 0.18, blue: 0.15)
        return configuration.label
            .font(KiviTheme.medium(14)).padding(.horizontal, 14).padding(.vertical, 7)
            .foregroundStyle(red)
            .background(red.opacity(hovering ? 0.20 : 0.12), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(red.opacity(hovering ? 0.65 : 0.35)))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

struct DictionaryPage: View {
    @State private var showImport = false
    @EnvironmentObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var showForm = false
    @State private var misspelling = ""
    @State private var correctMisspelling = false
    @State private var formError: String?
    @FocusState private var wordFocused: Bool
    @State private var written = ""
    @State private var editID: UUID?
    @State private var pendingDeletion: LexiconEntry?
    var body: some View {
        let terms = visibleTerms
        ScrollView {
            PageContent {
                VStack(alignment: .leading, spacing: 27) {
                    HStack(spacing: 12) {
                        PageTitle(title: "dictionary")
                        Spacer()
                        Button { showImport = true } label: {
                            Label("import", systemImage: "tray.and.arrow.down")
                        }.buttonStyle(KiviButton())
                        Button { beginNewTerm() } label: {
                            Label("add a word", systemImage: "plus")
                        }.buttonStyle(KiviButton(primary: true))
                    }
                    LazyVStack(spacing: 0) {
                        ForEach(terms) { term in
                            KiviHoverRow { hoverState in
                            HStack {
                                Button { beginEditing(term) } label: {
                                    HStack(spacing: 12) {
                                        if term.heard != term.written {
                                            Text(term.heard).foregroundStyle(KiviTheme.muted)
                                            Image(systemName: "arrow.right").font(.system(size: 14)).foregroundStyle(KiviTheme.muted)
                                        }
                                        Text(term.written)
                                    }
                                    .font(KiviTheme.body(18)).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                    .accessibilityElement(children: .ignore)
                                    .accessibilityLabel(term.heard == term.written ? term.written : "\(term.heard) → \(term.written)")
                                }.buttonStyle(.plain)
                                HStack(spacing: 4) {
                                    IconButton(icon: "pencil", label: "edit \(term.written)") { beginEditing(term) }
                                    IconButton(icon: "trash", label: "remove \(term.written)") { pendingDeletion = term }
                                }.opacity(hoverState.wrappedValue ? 1 : 0)
                            }.frame(minHeight: 55).padding(.vertical, 8).contentShape(Rectangle()).onHover { hoverState.wrappedValue = $0 }
                            }
                            if term.id != terms.last?.id {
                                Rectangle().fill(KiviTheme.line).frame(height: 1)
                            }
                        }
                    }.padding(.top, 6)
                }
            }
        }
        .sheet(isPresented: $showImport) { KiviDictionaryImportView() }
        .sheet(item: $pendingDeletion) { term in deletionDialog(for: term) }
        .overlay {
            if showForm {
                libraryFormOverlay(reduceMotion: reduceFormMotion, onDismiss: { showForm = false }) { termForm }
            }
        }
        .animation(reduceFormMotion ? nil : .easeOut(duration: 0.2), value: showForm)
    }
    private func deletionDialog(for term: LexiconEntry) -> some View {
        let isCorrection = term.heard != term.written
        let label = isCorrection ? "\(term.heard) → \(term.written)" : term.written
        return VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top, spacing: 20) {
                Text("delete “\(label)”?").font(KiviTheme.serif(28)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                IconButton(icon: "xmark", label: "cancel deletion") { pendingDeletion = nil }
            }
            Text(isCorrection ? "kivi will no longer correct these mishearings." : "kivi will no longer remember this word.")
                .font(KiviTheme.body(15)).foregroundStyle(KiviTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Spacer()
                Button("cancel") { pendingDeletion = nil }
                    .buttonStyle(KiviButton()).keyboardShortcut(.defaultAction)
                Button(isCorrection ? "delete correction" : "delete word", role: .destructive) {
                    model.saved.terms.removeAll { $0.written == term.written }
                    model.persistTerms()
                    pendingDeletion = nil
                }.buttonStyle(KiviDeleteButton())
            }.padding(.top, 4)
        }
        .padding(32).frame(width: 480).foregroundStyle(KiviTheme.ink)
        .background(KiviTheme.panel)
        .onExitCommand { pendingDeletion = nil }
    }
    private var visibleTerms: [LexiconEntry] {
        KiviDictionaryAdapter.grouped(model.saved.terms)
    }
    private var reduceFormMotion: Bool { model.saved.reduceMotion || systemReduceMotion }
    private var canSaveTerm: Bool {
        let word = written.trimmingCharacters(in: .whitespacesAndNewlines)
        let heard = correctMisspelling ? misspelling.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        guard !word.isEmpty, !correctMisspelling || !heard.isEmpty else { return false }
        guard let editID else { return true }
        guard let original = visibleTerms.first(where: { $0.id == editID }) else { return false }
        return word != original.written || heard != (original.heard == original.written ? "" : original.heard)
    }
    private var termForm: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack {
                Text(editID == nil ? "add a word" : "edit word").font(KiviTheme.serif(30))
                Spacer()
                IconButton(icon: "xmark", label: "close") { showForm = false }
            }
            HStack(alignment: .bottom, spacing: 22) {
                if correctMisspelling {
                    wordField("what kivi hears", prompt: "e.g. Kiwi, KV", text: $misspelling)
                    Image(systemName: "arrow.right").foregroundStyle(KiviTheme.muted).padding(.bottom, 12)
                }
                wordField("preferred spelling", prompt: "e.g. Sarvam", text: $written)
                    .focused($wordFocused)
            }
            HStack {
                Text("correct a known mishearing").font(KiviTheme.body(15)).accessibilityHidden(true)
                Spacer()
                Toggle("correct a known mishearing", isOn: $correctMisspelling)
                    .labelsHidden().toggleStyle(SettingsSwitchStyle())
            }
            if let formError { Text(formError).font(KiviTheme.body(13)).foregroundStyle(KiviTheme.ink) }
            HStack(spacing: 12) {
                Spacer()
                Button("cancel") { showForm = false }.buttonStyle(KiviButton()).keyboardShortcut(.cancelAction)
                Button(editID == nil ? "add word" : "save changes") { saveTerm() }
                    .buttonStyle(KiviButton(primary: true)).keyboardShortcut(.defaultAction)
                    .disabled(!canSaveTerm)
            }
        }
        .padding(32).frame(width: 560).foregroundStyle(KiviTheme.ink)
        .background(KiviTheme.panel)
        .onAppear { wordFocused = true }
        .onChange(of: written) { _, _ in formError = nil }
        .onChange(of: misspelling) { _, _ in formError = nil }
        .onChange(of: correctMisspelling) { _, _ in formError = nil }
        .onExitCommand { showForm = false }
    }
    private func wordField(_ label: String, prompt: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(label).font(KiviTheme.body(13)).foregroundStyle(KiviTheme.muted)
            TextField(prompt, text: text).textFieldStyle(.plain).font(KiviTheme.body(19))
                .onSubmit { saveTerm() }
            Rectangle().fill(KiviTheme.muted.opacity(0.6)).frame(height: 1)
        }.frame(maxWidth: .infinity)
    }
    private func beginNewTerm() {
        misspelling = ""; written = ""; correctMisspelling = false; formError = nil; editID = nil; showForm = true
    }
    private func beginEditing(_ term: LexiconEntry) {
        written = term.written; misspelling = term.heard == term.written ? "" : term.heard
        correctMisspelling = term.heard != term.written; editID = term.id; formError = nil; showForm = true
    }
    private func saveTerm() {
        guard canSaveTerm else { return }
        do {
            try KiviDictionaryAdapter.saveGroupedWord(written: written, misspellings: correctMisspelling ? misspelling : nil,
                                               editing: editID, service: model.services.dictionaryService)
            model.refreshTerms()
            showForm = false
            model.notify(editID == nil ? "word added" : "word updated")
        } catch { formError = error.localizedDescription }
    }
}

struct ShortcutsPage: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var showForm = false
    @State private var trigger = ""
    @State private var expansion = ""
    @State private var editID: UUID?
    @State private var pendingDeletion: ExpansionEntry?
    @FocusState private var triggerFocused: Bool
    var body: some View {
        ScrollView {
            PageContent {
                VStack(alignment: .leading, spacing: 27) {
                    HStack {
                        PageTitle(title: "shortcuts")
                        Spacer()
                        Button { beginNewShortcut() } label: {
                            Label("add a shortcut", systemImage: "plus")
                        }.buttonStyle(KiviButton(primary: true))
                    }
                    if model.saved.shortcuts.isEmpty && !showForm {
                        VStack(spacing: 22) {
                            if let bird = KiviTheme.image("onboarding-sitting") { Image(nsImage: bird).resizable().scaledToFit().frame(width: 96, height: 128).opacity(0.32) }
                            Text("nothing here yet — add your first shortcut.").font(KiviTheme.body(14)).foregroundStyle(KiviTheme.muted)
                        }.frame(maxWidth: .infinity).padding(.top, 24)
                    }
                    LazyVStack(spacing: 0) {
                        ForEach(model.saved.shortcuts) { item in
                            KiviHoverRow { hoverState in
                            HStack(spacing: 16) {
                                Button { beginEditing(item) } label: {
                                    HStack(spacing: 25) {
                                        Text("“\(item.trigger)”").font(KiviTheme.body(18)).frame(minWidth: 180, alignment: .leading)
                                        Image(systemName: "arrow.right").font(.system(size: 14)).foregroundStyle(KiviTheme.muted)
                                            .accessibilityHidden(true)
                                        Text(item.expansion.replacingOccurrences(of: "\n", with: " ")).font(KiviTheme.body(14)).foregroundStyle(KiviTheme.muted).lineLimit(1)
                                        Spacer(minLength: 0)
                                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                        .accessibilityElement(children: .ignore)
                                        .accessibilityLabel("when you say \(item.trigger), kivi writes \(item.expansion)")
                                }.buttonStyle(.plain)
                                HStack(spacing: 4) {
                                    IconButton(icon: "doc.on.doc", label: "copy shortcut") { model.copy(item.expansion) }
                                    IconButton(icon: "trash", label: "remove shortcut") { pendingDeletion = item }
                                }.opacity(hoverState.wrappedValue ? 1 : 0)
                            }.frame(height: 55).contentShape(Rectangle()).onHover { hoverState.wrappedValue = $0 }
                            }
                            if item.id != model.saved.shortcuts.last?.id {
                                Rectangle().fill(KiviTheme.line).frame(height: 1)
                            }
                        }
                    }.padding(.top, 6)
                }
            }
        }
        .sheet(item: $pendingDeletion) { item in deletionDialog(for: item) }
        .overlay {
            if showForm {
                libraryFormOverlay(reduceMotion: reduceFormMotion, onDismiss: { showForm = false }) { shortcutForm }
            }
        }
        .animation(reduceFormMotion ? nil : .easeOut(duration: 0.2), value: showForm)
    }
    private func deletionDialog(for item: ExpansionEntry) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top, spacing: 20) {
                Text("delete “\(item.trigger)”?").font(KiviTheme.serif(28)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                IconButton(icon: "xmark", label: "cancel deletion") { pendingDeletion = nil }
            }
            Text("kivi will no longer expand this phrase into your saved text.")
                .font(KiviTheme.body(15)).foregroundStyle(KiviTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Spacer()
                Button("cancel") { pendingDeletion = nil }
                    .buttonStyle(KiviButton()).keyboardShortcut(.defaultAction)
                Button("delete shortcut", role: .destructive) {
                    model.saved.shortcuts.removeAll { $0.id == item.id }
                    model.persistShortcuts()
                    pendingDeletion = nil
                }.buttonStyle(KiviDeleteButton())
            }.padding(.top, 4)
        }
        .padding(32).frame(width: 480).foregroundStyle(KiviTheme.ink)
        .background(KiviTheme.panel)
        .onExitCommand { pendingDeletion = nil }
    }
    private var duplicateShortcut: ExpansionEntry? {
        let phrase = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.saved.shortcuts.first { $0.id != editID && $0.trigger.caseInsensitiveCompare(phrase) == .orderedSame }
    }
    private var reduceFormMotion: Bool { model.saved.reduceMotion || systemReduceMotion }
    private var canSave: Bool {
        !trigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !expansion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && duplicateShortcut == nil && shortcutChanged
    }
    private var shortcutChanged: Bool {
        guard let editID else { return true }
        guard let original = model.saved.shortcuts.first(where: { $0.id == editID }) else { return false }
        return trigger.trimmingCharacters(in: .whitespacesAndNewlines) != original.trigger || expansion != original.expansion
    }
    private var shortcutForm: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack {
                Text(editID == nil ? "add a shortcut" : "edit shortcut").font(KiviTheme.serif(30))
                Spacer()
                IconButton(icon: "xmark", label: "close") { showForm = false }
            }
            VStack(alignment: .leading, spacing: 12) {
                Text("when i say").font(KiviTheme.body(13)).foregroundStyle(KiviTheme.muted)
                TextField("e.g. my sign-off", text: $trigger).textFieldStyle(.plain)
                    .font(KiviTheme.body(19)).focused($triggerFocused)
                Rectangle().fill(KiviTheme.muted.opacity(0.6)).frame(height: 1)
            }
            VStack(alignment: .leading, spacing: 12) {
                Text("kivi writes").font(KiviTheme.body(13)).foregroundStyle(KiviTheme.muted)
                KiviTextEditor(text: $expansion, prompt: "the text to insert when you say this phrase")
                    .padding(12).frame(height: 170)
                    .background(KiviTheme.background, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(KiviTheme.line))
            }
            if let duplicate = duplicateShortcut {
                VStack(alignment: .leading, spacing: 8) {
                    Text("a shortcut already uses this phrase.").font(KiviTheme.body(13)).foregroundStyle(KiviTheme.muted)
                    Button("edit existing shortcut") { beginEditing(duplicate) }.buttonStyle(KiviButton())
                }
            }
            HStack(spacing: 12) {
                Spacer()
                Button("cancel") { showForm = false }.buttonStyle(KiviButton()).keyboardShortcut(.cancelAction)
                Button(editID == nil ? "add shortcut" : "save changes") { saveShortcut() }
                    .buttonStyle(KiviButton(primary: true)).disabled(!canSave)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(32).frame(width: 560).foregroundStyle(KiviTheme.ink)
        .background(KiviTheme.panel)
        .onAppear { triggerFocused = true }
        .onExitCommand { showForm = false }
    }
    private func beginNewShortcut() {
        trigger = ""; expansion = ""; editID = nil; showForm = true
    }
    private func beginEditing(_ item: ExpansionEntry) {
        trigger = item.trigger; expansion = item.expansion; editID = item.id; showForm = true
    }
    private func saveShortcut() {
        guard canSave else { return }
        let value = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        if let editID {
            guard let index = model.saved.shortcuts.firstIndex(where: { $0.id == editID }) else { return }
            model.saved.shortcuts[index].trigger = value
            model.saved.shortcuts[index].expansion = expansion
        } else {
            model.saved.shortcuts.append(ExpansionEntry(trigger: value, expansion: expansion))
        }
        if model.persistShortcuts() { showForm = false; model.notify("shortcut saved") }
    }
}

func libraryFormOverlay<Content: View>(reduceMotion: Bool, onDismiss: @escaping () -> Void, @ViewBuilder content: () -> Content) -> some View {
    ZStack {
        Color.black.opacity(0.58)
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture(perform: onDismiss)
            .accessibilityHidden(true)
            .transition(reduceMotion ? .identity : .opacity)

        content()
            .background(KiviTheme.panel, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(KiviTheme.line))
            .shadow(color: .black.opacity(0.35), radius: 28, y: 12)
            .padding(24)
            .transition(reduceMotion ? .identity : .asymmetric(
                insertion: .opacity.combined(with: .scale(scale: 0.98).combined(with: .offset(y: 8))),
                removal: .opacity.combined(with: .scale(scale: 0.99))
            ))
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .zIndex(10)
}

private let libraryGold = Color(red: 0.80, green: 0.71, blue: 0.42)

private struct LibraryAddBar: View {
    var title: String
    var expanded: Bool
    var action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: expanded ? "minus.circle" : "plus.circle").font(.system(size: 22, weight: .light)).foregroundStyle(libraryGold)
                Text(title).font(KiviTheme.body(16)); Spacer(); Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 11)).foregroundStyle(libraryGold)
            }.padding(.horizontal, 17).frame(height: 48).contentShape(Rectangle())
                .background((hovering || expanded ? libraryGold.opacity(0.035) : Color.clear), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(hovering ? libraryGold : .clear))
        }.buttonStyle(.plain).onHover { hovering = $0 }
    }
}

private struct LibraryUnderlinedField: View {
    var label: String?
    var prompt: String
    @Binding var text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let label { Text(label).font(KiviTheme.body(14)) }
            TextField(prompt, text: $text).textFieldStyle(.plain).font(KiviTheme.body(15)).padding(.vertical, 6)
            Rectangle().fill(KiviTheme.line).frame(height: 1)
        }
    }
}

struct KiviHoverRow<Content: View>: View {
    @State private var hovering = false
    @ViewBuilder var content: (Binding<Bool>) -> Content
    var body: some View {
        content(hoverBinding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .background(hovering ? KiviTheme.panel.opacity(0.45) : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
    private var hoverBinding: Binding<Bool> {
        Binding(get: { hovering }, set: { hovering = $0 })
    }
}
