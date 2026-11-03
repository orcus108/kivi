import SwiftUI

/// One decision at a time: source → review → explicit import.
struct KiviDictionaryImportView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = AppVocabularyImportViewModel(destination: .dictionary)
    @State private var hasChosenApp = false
    private let sources: [AppVocabularyImport.Source] = [.wisprFlow, .handy, .aquaVoice]
    private var reviewing: Bool { model.batch != nil }
    private var title: String {
        if model.importedCount != nil { return "your words are here" }
        if model.isLoading { return "finding your words" }
        if reviewing { return "make these words yours" }
        if !hasChosenApp { return "bring your dictionary" }
        return model.source == .aquaVoice ? "bring your Aqua words" : "let’s find your dictionary"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                Text(title).font(KiviTheme.serif(30)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                IconButton(icon: "xmark", label: "close dictionary import") { dismiss() }
            }.padding(.bottom, 12)
            content
            footer.padding(.top, 24)
        }
        .padding(30).frame(width: 580)
        .foregroundStyle(KiviTheme.ink).background(KiviTheme.panel)
        .onExitCommand { dismiss() }
        .onDisappear { model.reset() }
    }

    @ViewBuilder private var content: some View {
        if let count = model.importedCount {
            Text("\(count) words and corrections added to your dictionary.").font(KiviTheme.body(16)).padding(.bottom, 16)
            Label("ready for your next dictation", systemImage: "checkmark.circle.fill")
                .font(KiviTheme.body(14)).foregroundStyle(KiviTheme.green)
            Text("you can edit or remove them in Dictionary.").font(KiviTheme.body(13)).foregroundStyle(KiviTheme.muted).padding(.top, 10)
        } else if model.isLoading {
            Text("reading your \(model.source.name) dictionary on this Mac…")
                .font(KiviTheme.body(15)).foregroundStyle(KiviTheme.muted)
            ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.vertical, 40)
        } else if reviewing {
            review
        } else if !hasChosenApp {
            Text("already taught another app your words? bring them along.")
                .font(KiviTheme.body(15)).foregroundStyle(KiviTheme.muted).padding(.bottom, 26)
            Text("which app are you coming from?").font(KiviTheme.medium(14)).padding(.bottom, 12)
            VStack(spacing: 8) {
                ForEach(sources) { source in
                    KiviImportAppRow(source: source) {
                        model.reset()
                        model.source = source
                        hasChosenApp = true
                        if source.defaultURL != nil { model.loadDefault() }
                    }
                }
            }
            Text("you’ll review the words before anything is added.")
                .font(KiviTheme.body(12)).foregroundStyle(KiviTheme.muted).padding(.top, 18)
        } else {
            if model.source == .aquaVoice {
                Text("choose a text dictionary exported from Aqua Voice.")
                    .font(KiviTheme.body(16)).padding(.bottom, 12)
                Text("one word or phrase per line. you’ll see a preview next.")
                    .font(KiviTheme.body(14)).foregroundStyle(KiviTheme.muted)
                Link("how to export from Aqua Voice ↗", destination: URL(string: "https://aquavoice.com/docs/cli#import-and-export")!)
                    .font(KiviTheme.body(13)).foregroundStyle(KiviTheme.green).padding(.top, 18)
            } else {
                Text("we couldn’t read your \(model.source.name) dictionary.")
                    .font(KiviTheme.body(16)).padding(.bottom, 12)
                Text("if you use it on this Mac, try again. otherwise, choose a copy of its dictionary file to continue.")
                    .font(KiviTheme.body(14)).foregroundStyle(KiviTheme.muted)
                if let error = model.error {
                    DisclosureGroup("details") {
                        Text(error).font(KiviTheme.body(12)).foregroundStyle(KiviTheme.muted).textSelection(.enabled).padding(.top, 8)
                    }.font(KiviTheme.body(12)).foregroundStyle(KiviTheme.muted).padding(.top, 16)
                }
            }
        }
    }

    private var review: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("from \(model.source.name). uncheck anything you don’t want to bring over.")
                .font(KiviTheme.body(14)).foregroundStyle(KiviTheme.muted)
            if model.rows.isEmpty {
                Text("no words were found in this dictionary.").font(KiviTheme.body(16)).padding(.vertical, 24)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.rows) { row in
                            Button {
                                if model.selected.contains(row.id) { model.selected.remove(row.id) }
                                else { model.selected.insert(row.id) }
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: model.selected.contains(row.id) ? "checkmark.square.fill" : "square")
                                        .font(.system(size: 18)).foregroundStyle(row.outcome == .add ? KiviTheme.green : KiviTheme.muted)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(row.entry.replacement.map { row.entry.original + " → " + $0 } ?? row.entry.original)
                                            .font(KiviTheme.body(15)).foregroundStyle(KiviTheme.ink).fixedSize(horizontal: false, vertical: true)
                                        if row.outcome != .add {
                                            Text(row.outcome == .duplicate ? "already in your dictionary" : "different spelling already saved · skipped")
                                                .font(KiviTheme.body(12)).foregroundStyle(KiviTheme.muted)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                }.padding(.vertical, 13).padding(.horizontal, 12).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }.buttonStyle(.plain).disabled(row.outcome != .add)
                                .accessibilityLabel(row.entry.replacement.map { row.entry.original + " becomes " + $0 } ?? row.entry.original)
                                .accessibilityValue(row.outcome != .add ? "skipped" : model.selected.contains(row.id) ? "selected" : "not selected")
                            Rectangle().fill(KiviTheme.line).frame(height: 1)
                        }
                    }
                }.frame(height: min(280, CGFloat(model.rows.count) * 62))
                    .background(KiviTheme.background, in: RoundedRectangle(cornerRadius: 8))
            }
            Text("your existing words stay unchanged.").font(KiviTheme.body(12)).foregroundStyle(KiviTheme.muted)
            if let count = model.batch?.excluded, count > 0 {
                Text("\(count) unsupported or empty entries were left out.").font(KiviTheme.body(12)).foregroundStyle(KiviTheme.muted)
            }
            if let error = model.error { Text(error).font(KiviTheme.body(13)).foregroundStyle(.red).textSelection(.enabled) }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if hasChosenApp && model.importedCount == nil && !model.isLoading {
                Button("← back") { model.reset(); hasChosenApp = false }.buttonStyle(KiviButton())
            } else if model.importedCount == nil {
                Button("cancel") { dismiss() }.buttonStyle(KiviButton())
            }
            Spacer()
            if model.importedCount != nil {
                Button("done") { dismiss() }.buttonStyle(KiviButton(primary: true)).keyboardShortcut(.defaultAction)
            } else if reviewing {
                Button(model.additions.isEmpty ? "no new words selected" : "import \(model.additions.count) words") { model.commit() }
                    .buttonStyle(KiviButton(primary: true)).disabled(model.additions.isEmpty)
            } else if hasChosenApp && !model.isLoading {
                if model.source.defaultURL != nil {
                    Button("try again") { model.loadDefault() }.buttonStyle(KiviButton())
                }
                Button(model.source == .aquaVoice ? "choose dictionary file…" : "choose a file…") { model.chooseFile() }
                    .buttonStyle(KiviButton(primary: true))
            }
        }
    }
}

private struct KiviImportAppRow: View {
    let source: AppVocabularyImport.Source
    let action: () -> Void
    @State private var hovered = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(source.name).font(KiviTheme.medium(17)).foregroundStyle(KiviTheme.ink)
                    Text(source == .aquaVoice ? "from an exported dictionary" : "from this Mac")
                        .font(KiviTheme.body(13)).foregroundStyle(KiviTheme.muted)
                }
                Spacer()
                Image(systemName: "arrow.right").font(.system(size: 15)).foregroundStyle(hovered ? KiviTheme.green : KiviTheme.muted)
            }.padding(17).frame(maxWidth: .infinity, alignment: .leading)
                .background(hovered ? KiviTheme.green.opacity(0.07) : KiviTheme.background, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(hovered ? KiviTheme.green.opacity(0.5) : KiviTheme.line))
                .contentShape(RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(.plain).onHover { hovered = $0 }
            .accessibilityLabel("import dictionary from \(source.name)")
    }
}
