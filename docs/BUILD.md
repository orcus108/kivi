# Building the public source

Requires macOS on Apple Silicon, Xcode with its command-line tools, Python 3, and network access for the locked Swift packages. From the repository root:

```sh
zsh app/scripts/build.sh
zsh app/scripts/test.sh
```

The build compiles an unsigned source-review app in `/private/tmp/kivi-public-source-build`. It does not install, launch or replace an existing app. The internal Xcode scheme/product remains TypeWhisper.

Original Kivi artwork, fonts, compiled assets and sounds are excluded. Optional images fall back or are omitted; custom fonts may fall back to system fonts. The source build therefore differs visually from the development installation.

Recognition and editing need separately installed models. The local editor expects Ollama with `qwen3:1.7b`. No API key is required for the local path; optional cloud integrations require your own credentials. For You conversation planning supports the local model or Groq; its example previews use the local editor.

Private resource provisioning, signing, preference imports and installed-app data are excluded. See [publication scope](PUBLICATION.md), [verification](VERIFICATION.md) and the [upstream README](../app/foundation/README.md) for further context.
