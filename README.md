# Multee

A native macOS app to manage multiple Claude Code sessions across projects — embedded terminals, a
VS Code-style file tree, in-app editing, a changes/diff view, a status board, and settings.

Built with **AppKit + Swift Package Manager** (no Xcode required; Command Line Tools only).
Terminal rendering is [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm); editor highlighting is
native — a small TextMate-grammar engine over `NSRegularExpression` (no JavaScript engine), with ~30
bundled languages.

## Install (Homebrew)

```sh
brew install --cask Rudra370/tap/multee
xattr -dr com.apple.quarantine "/Applications/Multee.app"
```

The app is **ad-hoc signed (not notarized)** and Homebrew quarantines downloaded casks, so the
second command clears the quarantine flag — without it macOS blocks the app on first launch.
(Alternatively, right-click → Open the first time.) The proper fix is Developer ID signing +
notarization, which needs a paid Apple Developer account.

### Update / reinstall

`brew upgrade` won't move to a lower version, so to switch builds reinstall:

```sh
brew reinstall --cask Rudra370/tap/multee && xattr -dr com.apple.quarantine "/Applications/Multee.app"
```

To remove it entirely: `brew uninstall --cask multee`.

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
