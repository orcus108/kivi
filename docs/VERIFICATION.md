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
