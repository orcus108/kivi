#!/bin/zsh
# Compile public source only. Does not install, sign or replace any app.
set -euo pipefail
cd "${0:A:h:h}"
python3 scripts/register_ui.py
derived="${KIVI_SOURCE_DERIVED_DATA:-/private/tmp/kivi-public-source-build}"
packages=()
if [[ -n "${KIVI_SOURCE_PACKAGES:-}" ]]; then packages=(-clonedSourcePackagesDirPath "$KIVI_SOURCE_PACKAGES"); fi
xcodebuild build -project foundation/TypeWhisper.xcodeproj -scheme TypeWhisper \
 -configuration Release -destination 'platform=macOS,arch=arm64' \
 -derivedDataPath "$derived" -onlyUsePackageVersionsFromResolvedFile \
 -packageAuthorizationProvider netrc -skipPackagePluginValidation \
 "${packages[@]}" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
print "Compiled unsigned source: $derived/Build/Products/Release/TypeWhisper.app"
print 'This is a source-review build. No app was installed or launched.'
