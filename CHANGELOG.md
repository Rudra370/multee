# Changelog

Notable changes to Multee. **A version's section here becomes that release's GitHub description and
the in-app "What's new."** Writing one is *optional*: if you add a `## [version]` block before
tagging, those polished notes are used; if you skip it, the release auto-generates notes from the
commits/PRs since the last tag. Newest first.

## [0.1.2] - 2026-06-12

### Fixed
- **No more freeze on large changesets** — opening a project with thousands of changed/untracked
  files (e.g. a build or dependency folder that isn't gitignored) no longer hangs the app. The
  Changes panel now renders rows lazily instead of building every one up front.

### Changed
- The file tree and Changes panel now share **one git poller per project** (a single file watcher
  and one source of truth) — lower overhead and no duplicate polling.

## [0.1.1] - 2026-06-12

### Changed
- **Native syntax highlighting** — replaced the JavaScript-based highlighter with a built-in
  TextMate-grammar engine. The editor uses **~70% less memory** (no embedded JavaScript engine) at
  about the same app size, with ~30 bundled languages. Highlighting also runs off the main thread, so
  large files never block typing or scrolling.

### Added
- **Resource monitor** — an optional CPU / memory readout in the title bar (Settings; off by default).

### Fixed
- Lower idle CPU and faster opening of large repositories (event-driven file watching).
- The editor scroll bar is now always visible instead of appearing only while scrolling.
- File-tree rows show the pointing-hand cursor on hover.

## [0.1.0] - 2026-06-12

First release of the **native AppKit** Multee — a full rewrite of the SwiftUI build for stability.
The cursor/tooltip/resize glitches are gone (AppKit owns those natively), and the file-open crash is
fixed. Feature parity with the previous build:

### Added
- **Multi-session workspace** — open multiple repos, each with its own tabs; switch and close freely.
- **Tabs** — Claude sessions (with arg presets: continue / resume / skip-permissions), plain shells,
  open files, and diffs. Tabs stay live across switches; restored tabs spawn lazily.
- **Native terminal** (SwiftTerm) — real `claude` and shells in a PTY with correct colors/glyphs,
  login-shell PATH, trackpad + wheel scrolling.
- **File tree** (NSOutlineView) — git-status colors, collapsed gitignored folders (toggle to expand),
  live refresh, click to open.
- **Editor** — syntax-highlighted (Highlightr), Cmd+S save, unsaved indicator, shared font size
  (Cmd +/−).
- **Changes & diff** — staged/unstaged lists with badges, commit (+ Commit & Push), stage/unstage,
  discard, stash/unstash; unified or split diff vs HEAD.
- **Status board** — per-tab and per-session dots (working / needs-you / idle) driven by Claude
  hooks, with an attention/completion sound.
- **Settings** — auto-launch Claude, show-gitignored, sound, restore-on-launch, font size, default
  Claude args.
- **Session restore** — reopens your sessions, tabs, and **resumes Claude conversations** on launch.
- **In-app updates** — banner when a new release ships, with one-click Homebrew self-update.
