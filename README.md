# Kivi — an independent macOS interaction study

A working native macOS prototype exploring what happens around dictation: correcting a take, making preferred spellings stick, shaping text for its destination, and recovering when speech recognition produces nothing useful.

Built by Vedant Misra as a product and engineering study inspired by Kivi. This is an independent project, with no affiliation with or endorsement from Sarvam AI or TypeWhisper.

## What I worked on

The speech-to-text foundation comes from **[TypeWhisper](https://github.com/TypeWhisper/typewhisper-mac)**, pinned to `v1.7.1`. I did not build the underlying recognition engines. My work adds a Kivi-inspired SwiftUI interface and modifies the surrounding interaction and text-processing flows:

- **Correction and personalization:** preferred vocabulary, spelling corrections, reviewed correction learning, and reusable spoken shortcuts.
- **Text processing:** typed input for testing, local cleanup and structure, app-specific style choices, and a Literal mode.
- **Selection editing:** keep the original, preview a rewrite, explicitly apply it, check for document/selection changes, and guard Undo. Copying remains available if insertion cannot be verified.
- **Recovery:** clear no-speech feedback, retry, and access to a saved take when recovery is enabled.
- **For You:** conversational app-specific writing preferences, editable Before → After examples, local previews before saving, independent preference removal, and locally saved chats/drafts. Conversation planning can use Groq with your own key or the local model; example previews use the local editor.
- **Home and Insights:** searchable saved takes with app/date filters, expandable transcripts, usage summaries and configurable time-saved estimates.
- **Everyday interaction:** compact dictionary and shortcut dialogs, inline global-rule editing, deletion confirmation, keyboard/focus refinements, and transitions that respect reduced motion.

Start with [the contribution map](docs/CONTRIBUTIONS.md) for source locations and [verification](docs/VERIFICATION.md) for evidence and limits.

## Source layout

```text
app/
  foundation/                 modified TypeWhisper source, tests and upstream notices
    TypeWhisper/KiviUI/       Kivi interface, adapters and local editor routing
    TypeWhisper/Services/     transcription, text processing, insertion and recovery
    TypeWhisperTests/         regression coverage
  scripts/                    public source build and test commands
docs/                         contribution map, verification and publication scope
```

This repository is a reviewed source snapshot. Older prototypes, private development notes, personal recordings, installed-app data, model weights, credentials and signing materials are excluded. The private development history remains local; the public snapshot continues from the repository's previously public history.

## Build and test

Requires macOS on Apple Silicon, Xcode with its command-line tools, Python 3, and network access for the locked Swift packages. From the repository root:

```sh
zsh app/scripts/build.sh
zsh app/scripts/test.sh
```

The build compiles an **unsigned source-review app** in `/private/tmp/kivi-public-source-build`. It does not install, launch or replace Kivi, Kivi Dev or TypeWhisper. The internal Xcode scheme/product is still named TypeWhisper to preserve the upstream project structure.

**This is not a one-command replica of my signed laptop installation.** Original Kivi artwork, fonts, compiled assets and sounds are not distributed here. Missing optional images fall back or are omitted, and custom fonts may fall back to system fonts. Local recognition/editing requires separately installed models; the local editor integration expects Ollama and a `qwen3:1.7b` model. The private installation's resource provisioning, signing identity and preference import are deliberately excluded. No API key is required for the local path; optional cloud integrations remain in the foundation source.

## Attribution and license

The modified TypeWhisper-based source is shared under **GPL-3.0-or-later**; see [LICENSE](LICENSE). Upstream copyright, commercial-license information and [trademark notices](app/foundation/TRADEMARK.md) are retained. [Provenance and modification notes](app/foundation/UPSTREAM.md) distinguish the foundation from the added work.

Kivi and Sarvam names identify the inspiration for this study. Their branding and original media are not offered under this repository's source license. No compiled app or original Kivi asset bundle is published.
