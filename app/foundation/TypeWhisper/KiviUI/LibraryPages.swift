import SwiftUI

struct KiviHistoryPage: View {
    @EnvironmentObject var model: AppModel
    var body: some View { KiviHistoryContent(history: model.history) }
}

private struct KiviHistoryContent: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var history: KiviHistoryStore
    @State private var showFilter = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        ScrollView {
            PageContent {
                VStack(alignment: .leading, spacing: 28) {
                    PageTitle(title: "history")
                    HStack(spacing: 12) {
                        HStack(spacing: 12) {
                            Image(systemName: "magnifyingglass").font(.system(size: 16)).foregroundStyle(KiviTheme.muted)
                            TextField("search your words — try: the offsite flights", text: $history.search)
                                .textFieldStyle(.plain).font(KiviTheme.body(16)).focused($searchFocused)
                                .onSubmit { model.notify("showing matching words from your local history") }
                            if !history.search.isEmpty {
                                IconButton(icon: "xmark", label: "clear search") { history.search = "" }
                            }
                            Text("press enter to ask").font(KiviTheme.mono(10)).foregroundStyle(KiviTheme.muted).fixedSize()
                        }
                        .padding(.horizontal, 16).frame(height: 50)
                        .background(KiviTheme.panel, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(searchFocused ? libraryGold : KiviTheme.line))
                        Button { showFilter.toggle() } label: {
                            HStack(spacing: 5) { Image(systemName: "line.3.horizontal.decrease").font(.system(size: 11)); Text("filter") }
                                .font(KiviTheme.body(13)).frame(width: 63, height: 30)
                                .background(KiviTheme.panel, in: RoundedRectangle(cornerRadius: 7))
                                .overlay(RoundedRectangle(cornerRadius: 7).stroke(KiviTheme.line))
                        }.buttonStyle(.plain)
                            .popover(isPresented: $showFilter, arrowEdge: .bottom) { filterPopover }
                    }
                    LazyVStack(alignment: .leading, spacing: 23) {
                        if history.sections.isEmpty && !history.loading {
                            EmptyState(icon: "clock", title: history.search.isEmpty ? "your words will find a home here." : "no words found.", subtitle: history.search.isEmpty ? "Your saved takes will appear here." : "Try another word, or change the filter.")
                        }
                        ForEach(history.sections) { section in
                            let day = section.id
                            let takes = section.takes
                            LazyVStack(alignment: .leading, spacing: 9) {
                                HStack(spacing: 12) {
                                    Text(dayTitle(day)).foregroundStyle(KiviTheme.green)
                                    Rectangle().fill(KiviTheme.green.opacity(0.32)).frame(height: 1)
                                    Text("\(takes.count)").foregroundStyle(KiviTheme.muted)
                                }.font(KiviTheme.body(14))
                                LazyVStack(spacing: 0) {
                                    ForEach(takes) { take in
                                        HistoryTakeRow(take: take) { model.selectedTake = take }
                                        Rectangle().fill(KiviTheme.line).frame(height: 1)
                                    }
                                }
                            }
                        }
                        if history.loading { ProgressView().controlSize(.small) }
                        if history.hasMore && !history.loading {
                            Button("load more") { history.loadMore() }.buttonStyle(KiviButton())
                                .onAppear { history.loadMore() }
                        }
                        if let error = history.error { Text(error).font(KiviTheme.body(13)).foregroundStyle(.orange) }
                    }.padding(.top, 10)
                }
            }
        }.onAppear { history.activate() }.onDisappear { history.deactivate() }
    }

    private func dayTitle(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.month(.wide).day())
    }
    private var filterPopover: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("apps").font(KiviTheme.mono(11)).foregroundStyle(KiviTheme.muted).padding(.horizontal, 10).padding(.bottom, 3)
            filterRow("all apps", checked: history.source == nil, icon: "square.grid.2x2") { history.source = nil }
            ForEach(history.summary.sources, id: \.self) { source in
                Button { history.source = source } label: {
                    HStack(spacing: 10) { AppGlyph(name: source, size: 18); Text(source.lowercased()); Spacer(); if history.source == source { Image(systemName: "checkmark").font(.system(size: 11)) } }
                        .font(KiviTheme.body(14)).padding(.horizontal, 10).frame(height: 34).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            Rectangle().fill(KiviTheme.line).frame(height: 1).padding(.vertical, 6)
            Text("time").font(KiviTheme.mono(11)).foregroundStyle(KiviTheme.muted).padding(.horizontal, 10)
            ForEach(["all time", "today", "this week", "this month"], id: \.self) { period in
                filterRow(period, checked: history.period == period, icon: nil) { history.period = period }
            }
            Rectangle().fill(KiviTheme.line).frame(height: 1).padding(.vertical, 6)
            filterRow("system clipboard", checked: history.source == "system clipboard", icon: "clipboard") { history.source = "system clipboard" }
        }.padding(10).frame(width: 256).background(Color(nsColor: .init(white: 0.125, alpha: 1))).foregroundStyle(KiviTheme.ink)
    }
    private func filterRow(_ title: String, checked: Bool, icon: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let icon { Image(systemName: icon).frame(width: 18).foregroundStyle(KiviTheme.muted) }
                Text(title); Spacer(); if checked { Image(systemName: "checkmark").font(.system(size: 11)).foregroundStyle(KiviTheme.green) }
            }.font(KiviTheme.body(14)).padding(.horizontal, 10).frame(height: 34).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

private struct HistoryTakeRow: View {
    @EnvironmentObject var model: AppModel
    var take: Take
    var action: () -> Void
    @State private var hovering = false
    var body: some View {
        HStack(spacing: 14) {
            Button(action: action) {
                HStack(spacing: 14) { AppGlyph(name: take.source, size: 18); Text(take.text.replacingOccurrences(of: "\n", with: " ")).font(KiviTheme.body(16)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading) }
                    .contentShape(Rectangle())
            }.buttonStyle(.plain)
            Text(take.date, format: .dateTime.hour().minute()).font(KiviTheme.body(13)).foregroundStyle(KiviTheme.muted)
            IconButton(icon: "doc.on.doc", label: "copy take") { model.copy(take.text) }
        }.padding(.horizontal, 8).frame(height: 51)
            .background(hovering ? KiviTheme.panel.opacity(0.5) : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle()).onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
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
    @EnvironmentObject var model: AppModel
    @State private var showForm = false
    @State private var misspelling = ""
    @State private var correctMisspelling = false
    @State private var formError: String?
    @FocusState private var wordFocused: Bool
    @State private var written = ""
    @State private var editID: UUID?
    @State private var pendingDeletion: LexiconEntry?
    var body: some View {
        ScrollView {
            PageContent {
                VStack(alignment: .leading, spacing: 27) {
                    HStack { PageTitle(title: "dictionary"); Spacer(); Button { model.importTerms() } label: { Label("import", systemImage: "tray.and.arrow.down") }.buttonStyle(KiviButton()) }
                    dictionaryDemo
                    LibraryAddBar(title: "add a word", expanded: false) { beginNewTerm() }
                        .background(KiviTheme.panel, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(KiviTheme.line))
                    LazyVStack(spacing: 0) {
                        ForEach(visibleTerms) { term in
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
                            }.frame(height: 55).contentShape(Rectangle()).onHover { hoverState.wrappedValue = $0 }
                            }
                            Rectangle().fill(KiviTheme.line).frame(height: 1)
                        }
                    }.padding(.top, 6)
                    KiviLearningView().padding(.top, 28)
                }
            }
        }
        .sheet(isPresented: $showForm) { termForm }
        .sheet(item: $pendingDeletion) { term in deletionDialog(for: term) }
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
            Text(isCorrection ? "kivi will no longer correct this spelling." : "kivi will no longer remember this word.")
                .font(KiviTheme.body(15)).foregroundStyle(KiviTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Spacer()
                Button("cancel") { pendingDeletion = nil }
                    .buttonStyle(KiviButton()).keyboardShortcut(.defaultAction)
                Button(isCorrection ? "delete correction" : "delete word", role: .destructive) {
                    model.saved.terms.removeAll { $0.id == term.id }
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
        model.saved.terms
    }
    private var dictionaryDemo: some View {
        HStack(spacing: 18) {
            HStack(spacing: 0) {
                Text("kivi spells the way ")
                Text("you")
                    .overlay(alignment: .bottom) { LibraryBrush().fill(KiviTheme.green.opacity(0.45)).frame(height: 5).offset(y: 3) }
                Text(" do")
            }.font(KiviTheme.serif(24)).fixedSize()
                .accessibilityElement(children: .combine)
            Spacer(minLength: 10)
            Rectangle().fill(KiviTheme.line).frame(width: 1, height: 38).padding(.horizontal, 8)
            VStack(alignment: .leading, spacing: 6) { Text("you say").font(KiviTheme.body(12)).foregroundStyle(KiviTheme.muted); Text("“aditya shatriya”").font(KiviTheme.serif(17)).italic() }
            LibraryArrow().stroke(KiviTheme.green, style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round)).frame(width: 65, height: 22)
            VStack(alignment: .leading, spacing: 6) { Text("kivi writes").font(KiviTheme.body(12)).foregroundStyle(KiviTheme.muted); Text("Aaditya Kshatriya").font(KiviTheme.medium(18)).fixedSize() }
        }.padding(.horizontal, 24).frame(maxWidth: .infinity).frame(height: 134)
            .background(KiviTheme.panel, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(KiviTheme.line))
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
                    wordField("misspelling", prompt: "e.g. sir vum", text: $misspelling)
                    Image(systemName: "arrow.right").foregroundStyle(KiviTheme.muted).padding(.bottom, 12)
                }
                wordField(correctMisspelling ? "correct spelling" : "word", prompt: "e.g. Sarvam", text: $written)
                    .focused($wordFocused)
            }
            Toggle("correct a misspelling", isOn: $correctMisspelling)
                .toggleStyle(.switch).tint(KiviTheme.green).font(KiviTheme.body(15))
            if let formError { Text(formError).font(KiviTheme.body(13)).foregroundStyle(KiviTheme.ink) }
            HStack(spacing: 12) {
                Spacer()
                Button("cancel") { showForm = false }.buttonStyle(KiviButton()).keyboardShortcut(.cancelAction)
                Button(editID == nil ? "add word" : "save changes") { saveTerm() }
                    .buttonStyle(KiviButton(primary: true)).keyboardShortcut(.defaultAction)
                    .disabled(written.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                              (correctMisspelling && misspelling.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            }
        }
        .padding(32).frame(width: 560).foregroundStyle(KiviTheme.ink)
        .background(KiviTheme.panel)
        .onAppear { wordFocused = true }
        .onChange(of: written) { _, _ in formError = nil }
        .onChange(of: misspelling) { _, _ in formError = nil }
        .onChange(of: correctMisspelling) { _, _ in formError = nil }
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
        do {
            try KiviDictionaryAdapter.saveWord(written: written, misspelling: correctMisspelling ? misspelling : nil,
                                               editing: editID, service: model.services.dictionaryService)
            model.refreshTerms()
            showForm = false
            model.notify(editID == nil ? "word added" : "word updated")
        } catch { formError = error.localizedDescription }
    }
}

struct ShortcutsPage: View {
    @EnvironmentObject var model: AppModel
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
                    PageTitle(title: "shortcuts")
                    shortcutDemo
                    LibraryAddBar(title: "add a shortcut", expanded: false) { beginNewShortcut() }
                        .background(KiviTheme.panel, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(KiviTheme.line))
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
                            Rectangle().fill(KiviTheme.line).frame(height: 1)
                        }
                    }.padding(.top, 6)
                }
            }
        }
        .sheet(isPresented: $showForm) { shortcutForm }
        .sheet(item: $pendingDeletion) { item in deletionDialog(for: item) }
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
    private var shortcutDemo: some View {
        HStack(spacing: 18) {
            Text("say less. write more.").font(KiviTheme.serif(24)).fixedSize()
            Spacer(minLength: 10)
            Rectangle().fill(KiviTheme.line).frame(width: 1, height: 38).padding(.horizontal, 8)
            VStack(alignment: .leading, spacing: 7) { Text("you say").font(KiviTheme.body(12)).foregroundStyle(KiviTheme.muted); Text("“my sign-off”").font(KiviTheme.serif(18)).italic() }
            LibraryArrow().stroke(KiviTheme.green, style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round)).frame(width: 60, height: 28)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 5) { ForEach(0..<3) { _ in Circle().fill(KiviTheme.muted.opacity(0.35)).frame(width: 5, height: 5) }; Spacer() }.frame(height: 16).padding(.horizontal, 10).background(KiviTheme.line.opacity(0.55))
                Text("Warm regards,\nPranav Sridhar\nSarvam AI").font(KiviTheme.body(13)).lineSpacing(2).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 14).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(width: 340, height: 90).background(KiviTheme.background.opacity(0.65), in: RoundedRectangle(cornerRadius: 6)).clipShape(RoundedRectangle(cornerRadius: 6)).overlay(RoundedRectangle(cornerRadius: 6).stroke(KiviTheme.line))
        }.padding(.horizontal, 24).frame(maxWidth: .infinity).frame(height: 134).background(KiviTheme.panel, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(KiviTheme.line))
    }
    private var duplicateShortcut: ExpansionEntry? {
        let phrase = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.saved.shortcuts.first { $0.id != editID && $0.trigger.caseInsensitiveCompare(phrase) == .orderedSame }
    }
    private var canSave: Bool {
        !trigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !expansion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && duplicateShortcut == nil
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

private struct LibraryArrow: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: 1, y: rect.height * 0.25))
            path.addQuadCurve(to: CGPoint(x: rect.maxX - 2, y: rect.height * 0.28), control: CGPoint(x: rect.midX, y: rect.height * 1.2))
            path.move(to: CGPoint(x: rect.maxX - 11, y: rect.height * 0.2))
            path.addLine(to: CGPoint(x: rect.maxX - 2, y: rect.height * 0.28))
            path.addLine(to: CGPoint(x: rect.maxX - 7, y: rect.height * 0.65))
        }
    }
}

private struct LibraryBrush: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: 0, y: rect.height * 0.5))
            path.addLine(to: CGPoint(x: rect.width * 0.08, y: 0))
            path.addLine(to: CGPoint(x: rect.width * 0.98, y: rect.height * 0.2))
            path.addLine(to: CGPoint(x: rect.width, y: rect.height * 0.7))
            path.addLine(to: CGPoint(x: rect.width * 0.12, y: rect.height))
            path.closeSubpath()
        }
    }
}

private struct KiviHoverRow<Content: View>: View {
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
