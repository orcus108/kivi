# Contribution map

This project builds on TypeWhisper v1.7.1 rather than implementing speech recognition from scratch. The upstream commit is `2137334f7f70a92f154b4f6e2ecfa737c9da7f3f`.

| Area | Source entry points | Work in this study |
|---|---|---|
| Interface | `app/foundation/TypeWhisper/KiviUI/` | SwiftUI screens and adapters for Record, History, Dictionary, Shortcuts, Styles and Settings; dialogs, recovery presentation and navigation |
| Typed/local text processing | `TypeWhisper/Services/IntentTextPipeline.swift`, `TypeWhisperTests/IntentExperimentsTests.swift` | Cleanup, structure, preferred spelling protection, destination rules and Literal mode |
| Selection editing | `TypeWhisper/Services/IntentSelectionEditor.swift` | Original retention, local rewrite preview, Apply drift checks, copying and guarded Undo |
| Correction learning | `TypeWhisper/Services/TargetAppCorrectionLearningService.swift` | Conservative capture/review and guarded rule changes, using the existing insertion foundation |
| Local styles | `TypeWhisper/KiviUI/KiviStyleRouter.swift`, `KiviLocalEditorRuntime.swift` | Destination style routing and isolated local editor runtime |
| Conversational preferences | `TypeWhisper/KiviUI/KiviTalkPage.swift`, `KiviTalkConversation.swift`, `KiviTalkService.swift`, `KiviTalkChangeHistory.swift` | App-scoped proposals, preview/save drift checks, independent removal and local conversation/draft persistence |
| Insights | `TypeWhisper/KiviUI/InsightsPage.swift`, `InsightsData.swift`, `KiviInsightsShare.swift` | Usage summaries, estimated time savings, app patterns and sharing |
| History responsiveness | `TypeWhisper/Services/HistoryService.swift`, `TypeWhisper/KiviUI/LibraryPages.swift` | Pagination, cancellable search, background summaries/export and reduced UI work |

Paths in rows after the first are relative to `app/foundation/`. Some filenames may expose upstream naming; provenance is preserved rather than presenting the foundation as original work.

The implementation was developed with AI coding assistance. Product direction, iteration and evaluation were driven by Vedant; the repository is evidence of the resulting implementation, not a claim that every line was written manually. Inherited recognition engines, plugins, accounts, sync and other upstream facilities should not be read as new contributions here.
