# Multee

A native macOS app to manage multiple Claude Code sessions across projects — embedded terminals, a
VS Code-style file tree, in-app editing, a changes/diff view, a status board, and settings.

Built with **AppKit + Swift Package Manager** (no Xcode required; Command Line Tools only).
Terminal rendering is [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm); editor highlighting is
a vendored [Highlightr](https://github.com/raspu/Highlightr).

## Install (Homebrew)

```sh
brew install --cask Rudra370/tap/multee
```

## Build from source

```sh
./dev.sh           # debug build → installs "Multee Dev.app" and launches it
./build.sh release # optimized build → Multee.app
```

The app is ad-hoc signed (no Apple Developer account). On first launch, right-click → Open if macOS
prompts about an unidentified developer.

## Develop

See **CLAUDE.md** for the build/release flow, the dev debug-harness, and gotchas, and **FEATURES.md**
for what each feature does and how it's built.
