# Source provenance and modifications

Based on [TypeWhisper for Mac](https://github.com/TypeWhisper/typewhisper-mac), stable tag `v1.7.1`, commit `2137334f7f70a92f154b4f6e2ecfa737c9da7f3f`, copied on 9 October 2026. Upstream licenses and notices remain in this directory.

This modified source snapshot was prepared on 21 October 2026. The added interface is in `TypeWhisper/KiviUI/`. Modifications include correction-learning review, typed/local text processing, preferred spelling protection, explicit text structure, destination rules, Literal mode, local selection rewriting with preview/drift checks/guarded Undo, history responsiveness and Kivi-inspired dialogs/recovery/navigation.

Upstream binary replacement is disabled for the development build. The development application's bundle identifier and preference namespace are isolated. The public build script compiles source only and does not install or sign it.

TypeWhisper's recognition engines and existing services remain the foundation; they are not represented as original work. Original Kivi media and the private installation's resource cache are excluded. See the root README and contribution map for scope and verification limits.
