# Multee (native macOS app — AppKit)

Native macOS app to manage multiple Claude Code sessions. **Pure AppKit** (no SwiftUI) +
Swift Package Manager. This is a rewrite of an earlier SwiftUI build; AppKit was chosen because the
SwiftUI↔AppKit seam caused recurring cursor/tooltip/resize glitches and a file-open crash. See
**FEATURES.md** for the per-feature log and **DECISIONS.md** for *why* each major choice was made
(read it before reworking an area; add an entry when you make a non-obvious design decision).

## Stack
- AppKit, built with Swift Package Manager (no Xcode; Command Line Tools only). Programmatic UI
  (no storyboards/xibs). Model layer uses **Combine** `@Published` (independent of SwiftUI).
- **SwiftTerm** — native terminal (ships its own PTY).
- **Editor highlighting is native** — a small TextMate-grammar engine driven by `NSRegularExpression`
  (`UI/Editor.swift` + `TextMate/TextMateHighlighter.swift`), no third-party dep. ~30 `.tmLanguage.json`
  grammars (from VS Code) live in `TextMate/Grammars/` and ship as the `Multee_Multee.bundle` SwiftPM
  resource. This replaced **Highlightr** (highlight.js via JavaScriptCore), which cost ~150 MB RAM per
  process for a ~5 MB on-disk JS bundle; the native engine is ~70% lighter on RAM at roughly the same
  app size. Grammars load lazily per language; "good, not tree-sitter-perfect" (regex, external-grammar
  includes skipped). See the resource-bundle gotcha below for how the bundle is resolved.

## Build & run
- `./dev.sh` — build (debug) → install to **`/Applications/Multee Dev.app`** → relaunch. Debug
  builds are a **separate app** ("Multee Dev", bundle id `com.multee.native.dev`, amber icon) so
  they never clash with a real/brew-installed Multee. Its defaults domain is `com.multee.native.dev`.
- `./build.sh release` — optimized **`Multee.app`** (`com.multee.native`). Copies the binary, icon,
  and SwiftPM resource bundles into `Contents/`, then ad-hoc signs.
- Type-check only: `swift build`.

## Releasing
- **The version is the git tag** — no version constant. `build.sh` reads `MULTEE_VERSION` (CI passes
  it from the tag, `v0.1.0` → `0.1.0`) into Info.plist.
- **Push a `v*` tag** → `.github/workflows/release.yml` builds the app, publishes the GitHub Release,
  and refreshes the Homebrew cask via the tap (`Rudra370/homebrew-tap`, needs `TAP_DEPLOY_KEY`).
- **Release notes are hybrid:** a `## [x.y.z]` section in `CHANGELOG.md` becomes the Release body and
  the in-app "What's new"; if absent, CI auto-generates from commits. Prefer writing the section.

## Debugging without a human (dev build only)
The dev build reads `/tmp/multee-debug.json` on launch (release ignores it):
```json
{ "shot": "/tmp/multee-shot.png", "state": "/tmp/multee-state.json",
  "actions": ["openRepo:/path", "openFile:rel", "openDiff:rel", "newClaude", "newTerminal",
              "closeActiveTab", "closeSession", "openSettings", "sendText:hi", "sendEnter",
              "scroll:up:10", "setStatus:needs", "editorType:x", "editorSave", "setFont:16",
              "editorFind:foo", "editorFindToggle:case|word|regex", "editorFindNext",
              "editorEol:CRLF", "editorIndent:Tabs", "editorLang:markdown", "paletteLineJump",
              "gitCheckout:branch", "gitBranchNew:name", "gitBranchDel:name",
              "treeNewFile:a.txt", "treeNewFolder:dir", "treeBeginFile", "treeExpandAll",
              "treeCollapseAll", "treeRename:old.txt|new.txt", "treeDelete:path",
              "paletteOpen", "paletteCommands", "paletteType:foo", "paletteDown", "paletteUp",
              "paletteEnter", "paletteClose", "sidebarMode:2", "revealSearch", "projectSearch:foo",
              "searchOpenFirst", "searchOpenAsTab", "openSearchTab", "projectSearchTab:foo",
              "openAt:file.md|3"] }
```
- `shot` → self-screenshot of the window each 1s (no Screen-Recording permission). **Captures
  standard AppKit (chips, tree, editor, diff, panels) but NOT the SwiftTerm terminal** — it draws via
  CoreText in a way `cacheDisplay` can't grab. **Verify terminal content via `terminalText` in the
  state dump, not the screenshot.** (Corollary: don't make the terminal's ancestor views non-layer
  to "fix" terminal capture — it breaks chip/editor capture instead. Terminal stays buffer-verified.)
- `state` → UI + active-terminal state each 1s (active session/tab, tab list, terminal rows/cols/
  scroll/repaints/**terminalText**, editorDirty, a `layout` frame diagnostic). Assert on values.
- `actions` → scripted with delays; `wait:N` inserts N extra seconds.
- `DebugHarness.swift` holds it all; `TerminalStore.debugText/debugState` inspect terminals.
- Clear stale dev state between runs: `defaults delete com.multee.native.dev multee.state`.

## Gotchas learned
- **Never spawn a subprocess from a view layout path** — do PATH bootstrap (`Env.bootstrap`) once at
  startup in `AppDelegate`.
- **Trim `Shell.run` output** — an untrimmed `"true\n"` from git made `isRepo` false.
- **git omits empty dirs**, so the git-derived file tree can't show a freshly-created empty folder
  (`ls-files` lists no path under it). `FileTreeViewController` tracks user-made empty folders in
  `pendingEmptyDirs` (persisted per-repo in UserDefaults, filtered on load to ones still on disk &
  empty), injects them as `isDir` entries, and post-processes the built tree (`markEmptyFolder`) to
  give them `children = []` so they render as real expandable folders, not dead `name/` leaves.
- **NSOutlineView row animations end inline editing (field-editor teardown).** When an `expandItem`
  or an animated row-insert (`reloadItem(reloadChildren:)`, `insertItems(withAnimation: .effect…)`)
  finishes, AppKit removes the animation's temporary `NSTableRowsClipView`; that `removeFromSuperview`
  calls `-[NSWindow endEditingFor:]`, which resigns the inline field's first responder ~0.2s later →
  `controlTextDidEndEditing` fires and the draft row commits empty/vanishes. Bit creating a file/folder
  inside an **empty/collapsed** folder (which must expand); already-open folders never animated, so they
  worked — the asymmetry that pinned it. Fix in `FileTree.beginCreate`: mutate the model + set
  `editingNode` synchronously, insert the row with `withAnimation: []`, and when an expand is unavoidable
  **focus the field only after the animation settles** (`asyncAfter ~0.3s` — there is *no* public
  completion for expand; `NSAnimationContext`/`animator()` do **not** suppress the expand animation).
  Diagnosing this needed a **call-stack trace at `controlTextDidEndEditing`** (the stack named
  `animationDidStop` → `endEditingFor:`) — theory-guessing failed for many rounds. Note: the dev harness
  drives the *model*, so it can't surface view-layer/animation/first-responder bugs; this class needs
  real HID or in-code stack instrumentation.
- **SwiftPM resource bundles don't resolve in a distributed `.app`.** The generated `Bundle.module`
  accessor only checks the `.app` *root* and the build-machine path — neither exists for a user, and
  a code-signed `.app` must keep resources in `Contents/Resources/` (nothing at the root, or the
  signature is invalid → Gatekeeper "damaged"). So `Bundle.module` `fatalError`s on file-open. Fix:
  resolve the bundle from `Bundle.main.resourceURL` first (where `build.sh` copies it), only falling
  back to `Bundle.module` outside a packaged `.app`. Our grammar bundle does this in `GrammarBundle`
  (`TextMate/TextMateHighlighter.swift`). Any new resource-bearing target/dep needs the same shim.
  (Dev builds *hide* this bug — their baked build path exists locally — so always test a release `.app`.)
- **`NSTextBlock`/`NSTextTable` collapse to ~0 width in an auto-resizing text view** (text wraps one
  char per line). Fix: `block.setContentWidth(100, type: .percentageValueType)` *and* give the text view
  a real initial frame width (a `.zero` frame collapses block layout). See `MarkdownRenderer`/`MarkdownViewController`.
- **Self-screenshot needs layer-backed standard views** to capture; the terminal is the exception
  (see harness note above).
- **Two cursor mechanisms that don't compose (custom cursors).** AppKit resolves a view's cursor via
  either cursor **rects** (`resetCursorRects`/`addCursorRect`, window-owned) or a **tracking-area
  `cursorUpdate`** callback. Once you interact with *any* cursor-rect view (every `NSButton` registers
  cursor rects), the window runs in cursor-rect mode and **stops delivering `cursorUpdate` to
  tracking-area-only views** — their custom cursor freezes until a relayout or focus change re-arms it.
  This was the file-tree bug: the pointing hand reverted to arrow after a toolbar-button click and only
  recovered on expanding a folder *with rows* (relayout) or opening a file (focus change); an empty
  folder or re-clicking an open file did nothing. **Rule: any view with a custom cursor must implement
  `resetCursorRects` (cursor rects are load-bearing). Dynamic views (changing rows) also keep a
  `cursorUpdate` for live hit-testing and must `invalidateCursorRects` on content change.** All
  `Pointer*` views in `UI/Cursor.swift` now do both; `ScrollerCursorOverlay` (terminal) already used
  cursor rects to match SwiftTerm. Cursor *shape* can't be checked by the screenshot harness, and the
  sandbox blocks synthetic mouse events (CGEvent/NSEvent) — so this class of bug needs a human to verify.

## File map (Sources/Multee/)
- `App/` — `main.swift`, `AppDelegate.swift` (menu, key monitors, status routing, settings/update
  wiring), `MainWindowController.swift` (window + banner + workspace).
- `Model/` — `AppModel`, `Session`, `Tab`, `Settings` (Combine), `Persistence` (JSON snapshot).
- `Backend/` — `Shell`/`Env`, `Git` (status + actions), `Search` (project-wide `git grep`).
- `Terminal/` — `TerminalStore` (PTY per tab + scroll), `HookServer` (status listener), `Hooks`.
- `UI/` — `WorkspaceViewController` (split + sidebar), `CenterViewController` (tab bar + content),
  `TabBarView`, `FileTree` (virtualized tree + a toolbar row: new file / new folder / collapse-all,
  with **inline in-tree naming** like VS Code), `RepoStore` (one per-session git poller — single
  FSEvents watcher + poll + actions, feeds the tree *and* Changes), `Editor` (plain NSTextStorage +
  native highlighter; line-based tokenizing run off-main on a serial queue, debounced re-highlight on
  edit), `Changes` (virtualized list), `Diff`, `SearchPanel` (`SearchViewController` — project search UI,
  shared by the sidebar Search segment and a `.search` tab), `SettingsWindow`, `Updates`. A `.file` tab routes by
  extension in `CenterViewController.makeContentView`: `ImageViewController` (images/icns/SVG — zoom/pan,
  source toggle), `MarkdownViewController` + `MarkdownRenderer` (rendered preview — code blocks reuse the
  TextMate engine, tables via NSTextTable, inline images), else the text `Editor`.
- `TextMate/` — `TextMateHighlighter` (grammar engine + theme + ext→language map + bundle resolver)
  and `Grammars/*.json` (~30 `.tmLanguage.json`, bundled as a SwiftPM resource).
- `Debug/` — `DebugHarness` (dev-only shot/state/actions).

## UI conventions
- Icon/icon-buttons get a native **`.toolTip`** (reliable in AppKit, unlike SwiftUI). 
- Deferred to a follow-up: per-button hand cursor, collapsible SESSIONS panel, drag-reorder tabs.
