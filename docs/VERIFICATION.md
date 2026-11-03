# Verification and limits

Evidence recorded on 21 October 2026 for the active development source:

- Signed Release compilation, installation and strict signature verification passed on the development Mac.
- The selected app regression suites passed **270 tests with zero failures** after repository reorganization.
- The installed Kivi Dev process was confirmed running, separate from original Kivi.
- The isolated local editor recognized the existing `qwen3:1.7b` model after the model directory was relocated.

These results do not establish microphone permission retention, live speech accuracy, cross-app insertion, or selection Apply/Undo behavior in every application. ScreenCaptureKit error `-3811` blocked the final visual inspection. Earlier checks and synthetic fixtures are not user research or measurements of general reliability.

The public source-review build excludes the laptop installation's original Kivi resources and private provisioning. Public export build/test results are recorded below. No compiled application or personal test data is distributed.

## Public export check — 21 October 2026

The reviewed source export based on local source commit `3c18703572d26f609a90b5def9135112e551cb68` passed its own **unsigned Release build** and **270 selected regression tests with zero failures**. Both commands ran from the exported directory, with locked Swift dependencies and without the private resource cache, model weights, preference import or signing tools. The existing dependency download cache was reused. No compiled app was installed or launched by these public scripts.

The export allowlist, new documentation links, cited contribution source paths, dependency lockfiles and personal-machine-path checks passed. A scan for common credential formats found no real credentials; the only private-key marker is the upstream `SCREENSHOT FIXTURE` literal. Inherited source formatting was retained. These checks do not establish the complete absence of every possible secret or verify live microphone/cross-app behavior.

## Public export check — 3 November 2026

The updated source snapshot, including For You conversations, preference removal, Home/Insights and the pending filter, inline-rule and banner refinements, passed its own **unsigned Release build** and **389 selected regression tests with zero failures**. Commands ran from the exported directory using the public build/test scripts, locked dependencies and a separate build directory. The dependency cache was reused; the private resource cache and signing/install tools were not required. The compiled source matched the committed development snapshot `ac7411bfb50b0c1784fcd19944dc380030315b44` after verification.

The export inventory and overlay links were checked. Common credential-pattern matches were synthetic upstream/test fixtures; machine-path matches were examples, fixtures or inherited upstream documentation. Private development logs, recordings, caches, credentials and original Kivi media are excluded. This is a source/inventory review, not a claim that every possible secret pattern was exhaustively ruled out.

Separate signed-development checks verified local chat/draft restoration across relaunch, independent chat switching/deletion, and reopened proposals requiring fresh review/preview before saving. Inline global-rule/filter refinements were compiled and regression-tested here; their complete rendered states were not reverified for this publication. Live microphone, cross-app behavior, VoiceOver and every light/narrow/reduced-motion state remain outside this export check. Original artwork/fonts are absent from the public build as described in the README.

## Source organization — 3 November 2026

The Kivi layer now groups 32 Swift files into app setup, shared controls, services and feature folders. Their contents are unchanged. Xcode file/build IDs are preserved, source registration handles nested folders, and the public export uses the same registration script as development. Four registration regression checks pass in both locations.

The reorganized source passed the signed development build and 389 selected tests, then the exported unsigned Release build and its own 389 tests. File-reference and source-content checks passed. The installed development app relaunched with its existing identity/signature; the native smoke check remained unverified because all three bounded capture attempts failed with ScreenCaptureKit `-3811`. This refactor changes organization and build registration, not application behavior. See the [source map](../app/foundation/TypeWhisper/KiviUI/README.md).
