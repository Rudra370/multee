# Multee — Feature Log

What each feature does and where it lives. (For the user-facing summary, see CHANGELOG.md.)

## Architecture
Pure AppKit + SwiftPM, bundled into `Multee.app`. Programmatic UI, no SwiftUI. State is `AppModel`
(Combine `ObservableObject`) holding `sessions`, `activeSessionID`, `settings`; each `Session` holds
its `tabs` + active tab + per-tab status. View controllers `sink` on the model and update AppKit
views by hand. **Why AppKit:** the prior SwiftUI build had recurring cursor/tooltip/resize glitches
and a release-only file-open crash, all rooted in the SwiftUI↔AppKit seam; AppKit owns those natively.

## Sessions & tabs — `Model/`, `UI/WorkspaceViewController`, `UI/CenterViewController`, `UI/TabBarView`
Multi-repo sessions (dedup by path); tabs for Claude / shell / file / diff. Tabs stay mounted across
switches; restored tabs **spawn lazily** (only when first viewed). Claude arg presets via the +menu.
Cmd+W closes the active tab. Closing a tab/folder or quitting with **unsaved editor edits** prompts
first (`UI/UnsavedGuard`: Save / Don't Save / Cancel for one, Save All / Discard / Cancel for many) —
the red close button is funnelled through quit so it's covered too; saving routes through a closure
`CenterViewController` registers (the model owns the dirty flag, the view owns `save()`). Persistence:
JSON snapshot in UserDefaults, debounce-saved; restore drops repos whose folder is gone.

## Terminal — `Terminal/`
`TerminalStore` caches one SwiftTerm PTY view per tab id (process survives tab/session switches).
Login-shell PATH via `Env.bootstrap`. Claude launches with `--settings <hooks>` + env; a shared
scroll monitor routes wheel/trackpad events (incl. alt-buffer SGR forwarding) to the terminal under
the cursor. Claude `--resume <cid>` only when its transcript still exists on disk.

## File tree & Changes — `UI/FileTree`, `UI/Changes`, `UI/RepoStore`, `Backend/Git`
`NSOutlineView` tree with git-status colors, collapsed gitignored dirs (expand toggle), reloads only
on change and preserves expansion by path; click a leaf to open it. A header toolbar (Files mode only)
gives **new file / new folder / collapse-all** (VS Code's Explorer actions); new file/folder are named
**inline in the tree** (a draft row with a focused text field — Return commits, Esc cancels). Because
git omits empty dirs, freshly-made empty folders are tracked in `pendingEmptyDirs` (persisted per-repo)
and injected as expandable folders until they hold a file. **Right-click** a row for rename (inline) /
delete (→ Trash, confirm) / new file / new folder / copy path / copy relative path; right-clicking a
**file tab** in the top bar offers copy path / copy relative path (`TabChipView.menu(for:)`). Open tabs
**follow renames** (the live editor retargets in place, keeping unsaved edits + redirecting saves;
read-only viewers rebuild) and **close on delete** — `Session.fileRenamed`/`fileDeleted`, wired from the
tree's `onRename`/`onDelete`. The active file is **auto-revealed** (VS Code-style): on tab switch / open
the tree expands to it, selects it, and scrolls it in (`FileTreeViewController.reveal`, driven by the
sidebar; re-applied after rebuilds so it survives reloads and launch). The Changes panel is a virtualized
`NSTableView` (staged/unstaged sections, hover row-actions, commit bar) — see D19 for why it's
virtualized. Both are fed by **one per-session `RepoStore`** (`UI/RepoStore`): a single FSEvents
watcher + git poll + the git mutation actions, of which only the *visible* sidebar mode's data is
fetched. One source of truth, one watcher.

## Editor — `UI/Editor`, `TextMate/`
`NSTextView` over a plain `NSTextStorage`, syntax-coloured by a **native TextMate-grammar highlighter**
(`TextMate/TextMateHighlighter`) — a small engine that runs `.tmLanguage.json` grammars via
`NSRegularExpression`, the regex engine built into macOS. No JavaScript engine: this replaced
Highlightr (highlight.js in JavaScriptCore), cutting editor RAM ~70% (a JS VM cost ~150 MB/process)
at roughly the same app size. ~30 grammars (from VS Code) ship in `TextMate/Grammars/` and load lazily
per language; theme is atom-one-dark. Tokenizing is **line-based** (begin/end state carried on a stack
across lines, so multi-line strings/comments stay correct) and runs **off the main thread** on a shared
serial queue — so even a large file never blocks typing or scrolling. A grammar's regexes are
precompiled on load, making `spans(for:)` a pure read safe to run on any thread; small files highlight
synchronously on open (no flash), large files and edits colour asynchronously. Edits coalesce via a
**150 ms debounce** and recolour only (text/selection/undo untouched), with a sequence guard dropping
any pass a newer edit superseded. Cmd+S saves; edits flag the tab dirty (chip dot). Shared font size
live-applies with in-place run resize. A **line-number gutter** (`UI/LineNumberRuler`, the scroll view's
vertical `NSRulerView`) draws VS Code-style numbers: only the lines in the visible rect are drawn each
pass, char-index→line is a binary search over a cached `lineStarts` array rebuilt only on text change,
wrapped logical lines number once (first visual row), the cursor's line is brighter, and width/font track
the editor font size. Coverage is "good, not tree-sitter-perfect": regex-based, and
external-grammar includes (e.g. CSS embedded in HTML) and Oniguruma-only regex are skipped. The
tokenizer is ~linear but call-bound (~0.3 ms/line); huge files colour off-main without freezing rather
than instantly — a combined-regex scanner would be the next step if instant huge-file colour is needed.

## Formatting — `Backend/Formatter`, `UI/FormatterPrompt`, `UI/SettingsWindow` (Formatters tab)
Format the active file with the user's installed CLI formatter (⌘⇧F / right-click → **Format Document**;
markdown/SVG format their Source). Formatters are **shelled out, never bundled** (zero idle cost): a
registry maps extensions → `{ binaries, run argv, install command }` for Prettier, gofmt, rustfmt, Ruff,
swift-format, clang-format. Detection prefers a **project-local** tool (`node_modules/.bin`, walking up
from the file) over the login-PATH global; the formatter runs stdin→stdout with `cwd` = the file's dir so
it finds project config. Running is off-main (stdin written + stderr read on background threads to avoid
pipe deadlock); the result is applied as a **common prefix/suffix diff** so the caret stays put and it's
one undo, and is dropped if you typed during the run or if the formatter emits empty output (never wipes a
file). Missing formatter → a prompt offers **one-click install** that opens a **Terminal tab running the
command** (`FormatterInstall` bridges to the session model; terminal tabs created with `args` run an
initial command then drop to an interactive shell), Homebrew-then-native per formatter. The **Settings →
Formatters** tab lists each one with live install status, an **Install in Terminal** button (icon +
command tooltip), and an enable toggle (off ones are skipped; persisted in `Settings.disabledFormatters`).
Deferred to Phase 2: format-on-save + per-language command overrides.

## File viewers — `UI/ImageViewController`, `UI/MarkdownViewController`, `UI/MarkdownRenderer`
A `.file` tab picks its view by extension (`CenterViewController.makeContentView`): images → viewer,
markdown → preview, else the text editor. **Images** (png/jpg/gif/bmp/tiff/webp/heic/`icns`/ico, plus
SVG when `NSImage` can render it) show in a magnifiable scroll view — fit-on-open, pinch/scroll zoom,
pan, double-click fit↔100%, centred — with a type·dimensions·size footer; SVG gets an Image/Source
toggle. **Markdown and SVG are editable**: the Source pane is the real `EditorViewController` (embedded
as a child — editable, syntax-highlighted, Cmd+S save, dirty dot, line numbers); toggling back to
Preview/Image re-renders live from the editor's current text. Raster images stay view-only.
**Markdown** (.md/.markdown) renders to an `NSAttributedString` (a native line-based block
parser + Foundation for inline + the TextMate engine for fenced code blocks + `NSTextTable` for tables +
inline image attachments) with a Preview/Source toggle. No WebKit, no dependency; RAM is just the
rendered content, freed on close.

## Changes & diff — `UI/Changes`, `UI/Diff`
`ChangesModel` polls staged/unstaged; the view has a commit bar (Commit / Commit & Push), section +
per-row git actions (stage/unstage/discard/stash/unstash), NSAlert confirms. Diff is an NSTableView
rendering `computeDiff` (stdlib Myers) rows, unified or split, with add/del row colors. A Files/Changes
segmented toggle (persisted) swaps the tree and changes views in the sidebar.

## Status board & notifications — `Terminal/HookServer`, `App/Notifier`, `App/AppDelegate`
Claude hooks `curl` a local `NWListener` with the tab id + state; routed to per-tab/session dots
(needs > working > idle). On a meaningful transition (a session wanting input, or finishing its work):
if you're **looking right at that tab** (Multee frontmost + it's the active tab of the active session)
it just plays an attention/completion `NSSound`; otherwise (backgrounded, or a different session/tab) it
posts a **macOS notification** (`App/Notifier`, UserNotifications) titled with the folder name — clicking
it brings Multee forward and focuses that exact session + tab. `Notifier` re-checks **live**
authorization on each post (a launch-time cache goes stale the moment you toggle the OS permission while
running) and falls back to the sound when notifications aren't authorized; `willPresent` lets a banner
show even while Multee is frontmost. Toggle in Settings (default on); the Settings window shows a warning
row with an "Open System Settings…" deep-link when macOS notifications are off for Multee (re-checked when
the window opens or regains focus).

## Settings & updates — `UI/SettingsWindow`, `UI/Updates`
Settings window (native controls) bound to `Settings`. Update checker hits the GitHub latest-release
API; a top banner offers Homebrew self-update (runs `brew upgrade` in an in-app terminal) or Download.

## Deferred (v0.1.1 polish)
Collapsible SESSIONS panel; drag-reorder tabs; per-button hand cursor. None are functional blockers.
