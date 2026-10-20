#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
python3 scripts/register_ui.py
packages=()
if [[ -n "${KIVI_SOURCE_PACKAGES:-}" ]]; then packages=(-clonedSourcePackagesDirPath "$KIVI_SOURCE_PACKAGES"); fi
args=()
for suite in IntentExperimentsTests SpeechPunctuationServiceTests SettledEditDetectionTests IntentCorrectionReviewTests TargetAppCorrectionLearningServiceTests DictionaryServiceTests SelfCorrectionServiceTests DictationUndoServiceTests DictationRecoveryAudioStoreTests TextDiffServiceTests DictationViewModelIndicatorSettingsTests KiviIntegrationTests; do
 args+=("-only-testing:TypeWhisperTests/$suite")
done
xcodebuild test -project foundation/TypeWhisper.xcodeproj -scheme TypeWhisper \
 -configuration Debug -destination 'platform=macOS,arch=arm64' \
 -derivedDataPath "${KIVI_SOURCE_DERIVED_DATA:-/private/tmp/kivi-public-source-build}" \
 -onlyUsePackageVersionsFromResolvedFile -packageAuthorizationProvider netrc -skipPackagePluginValidation \
 "${packages[@]}" "${args[@]}" "$@" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
