import SwiftUI

/// A local, side-effect-free view of the production dictionary resolver.
struct KiviDictionaryMatchPreview: View {
    @ObservedObject var dictionary: DictionaryService
    var onReviewAlias: (DictionaryAliasSuggestion) -> Void
    @State private var expanded = false
    @State private var input = ""
    @State private var suggestions: [DictionaryAliasSuggestion] = []
    @State private var suggestionsChecked = false
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Button {
                expanded.toggle()
                inputFocused = expanded
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "text.magnifyingglass").foregroundStyle(KiviTheme.green)
                    Text("try your dictionary").font(KiviTheme.medium(15))
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11)).foregroundStyle(KiviTheme.muted)
                }.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(expanded ? "expanded" : "collapsed")
            if expanded {
                Text("test a recognition result here. nothing is saved or sent.")
                    .font(KiviTheme.body(13)).foregroundStyle(KiviTheme.muted)
                HStack(alignment: .top, spacing: 12) {
                    TextField("type what kivi heard", text: $input, axis: .vertical)
                        .textFieldStyle(.plain).font(KiviTheme.body(16))
                        .lineLimit(2...5).focused($inputFocused)
                        .accessibilityLabel("recognition result to test")
                    if !input.isEmpty {
                        IconButton(icon: "xmark", label: "clear dictionary test") { input = ""; inputFocused = true }
                    }
                }
                .padding(14).background(KiviTheme.background, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(inputFocused ? KiviTheme.green : KiviTheme.line))
                if input.isEmpty {
                    Text("try a name, a joined spelling, or a sentence with several saved words.")
                        .font(KiviTheme.body(13)).foregroundStyle(KiviTheme.muted)
                } else if input.count > 2_000 {
                    Text("keep this preview under 2,000 characters.")
                        .font(KiviTheme.body(13)).foregroundStyle(KiviTheme.muted)
                } else {
                    result(dictionary.reviewMatches(in: input))
                    Button("find possible spellings") {
                        suggestions = dictionary.suggestedAliases(in: input)
                        suggestionsChecked = true
                    }.buttonStyle(KiviButton())
                    if suggestionsChecked && suggestions.isEmpty {
                        Text("no close spellings found. you can still add a known mishearing yourself.")
                            .font(KiviTheme.body(13)).foregroundStyle(KiviTheme.muted)
                    }
                    if !suggestions.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("possible spellings · review before adding")
                                .font(KiviTheme.body(12)).foregroundStyle(KiviTheme.muted)
                            ForEach(Array(suggestions.enumerated()), id: \.offset) { _, suggestion in
                                Button { onReviewAlias(suggestion) } label: {
                                    HStack(spacing: 10) {
                                        Text("\(suggestion.heard) → \(suggestion.written)")
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        Text("review").foregroundStyle(KiviTheme.green)
                                    }.font(KiviTheme.body(14)).contentShape(Rectangle())
                                }.buttonStyle(KiviButton())
                            }
                        }
                    }
                }
                Text("saved aliases allow replacements. compound names also handle case, spaces and hyphens. ordinary words stay as vocabulary hints; add an alias to change them. unfamiliar spellings and sound-alikes need an alias.")
                    .font(KiviTheme.body(13)).foregroundStyle(KiviTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20).foregroundStyle(KiviTheme.ink)
        .background(KiviTheme.panel, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(KiviTheme.line))
        .onChange(of: input) { _, _ in suggestions = []; suggestionsChecked = false }
        .onReceive(dictionary.$entries) { _ in suggestions = []; suggestionsChecked = false }
        .onExitCommand { expanded = false; inputFocused = false }
    }

    private func result(_ review: DictionaryMatchReview) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("kivi would write").font(KiviTheme.body(12)).foregroundStyle(KiviTheme.muted)
            Text(review.text.isEmpty ? "(empty text)" : review.text)
                .font(KiviTheme.body(17)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if review.changes.isEmpty && review.conflicts.isEmpty {
                Text("no dictionary changes. similar-sounding words are not replaced automatically.")
                    .font(KiviTheme.body(13)).foregroundStyle(KiviTheme.muted)
            }
            ForEach(Array(review.changes.enumerated()), id: \.offset) { _, change in
                Text("\(change.heard) → \(change.written.isEmpty ? "(removed)" : change.written) · \(change.reason)")
                    .font(KiviTheme.body(13)).foregroundStyle(KiviTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(review.conflicts, id: \.self) { conflict in
                Label(conflict, systemImage: "exclamationmark.circle")
                    .font(KiviTheme.body(13)).foregroundStyle(KiviTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
