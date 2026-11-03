# Kivi source map

Kivi adds a SwiftUI interface to the TypeWhisper foundation. All files compile into the existing app target.

| Folder | Responsibility |
| --- | --- |
| `App/` | App model, navigation, onboarding preview and presentation-state persistence |
| `Shared/` | Theme and reusable Kivi controls/panels |
| `Services/` | Isolated local-editor runtime |
| `Features/Home/` | Recording page, saved-take entry points and recovery feedback |
| `Features/History/` | Saved-take queries, search, filtering and library pages |
| `Features/Insights/` | Usage summaries, charts and sharing |
| `Features/Dictionary/` | Dictionary import, matching previews and correction-learning review |
| `Features/Styles/` | Writing groups, global rules and destination-style routing |
| `Features/Settings/` | Settings screens, navigation and keyboard-shortcut controls |
| `Features/ForYou/` | Conversation UI, planning, preview/save orchestration and change history |

Views use the existing app model and foundation services; dictation, insertion and recovery remain in `TypeWhisper/Services/` and `TypeWhisper/ViewModels/`. Keep shared controls in `Shared/` only when multiple features use them.

For You keeps separate roles: `KiviTalkPage`/`Composer`/`HistoryView` render the UI, `KiviTalkConversation` owns session state, `KiviTalkService` plans/validates preferences, and `KiviTalkChangeHistory` owns the settings-change journal. Opening a chat does not replay a settings transaction.

After adding or moving a Swift file, run `python3 app/scripts/register_ui.py` from the repository root. Registration is recursive and retains existing Xcode IDs when folders change; Swift filenames must remain unique within KiviUI. Build/test scripts run it automatically. Check registration with `python3 app/scripts/test_register_ui.py`.
