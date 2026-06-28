# Multee — Feature Log

What each feature does and where it lives. (For the user-facing summary, see CHANGELOG.md.)

## Architecture
Pure AppKit + SwiftPM, bundled into `Multee.app`. Programmatic UI, no SwiftUI. State is `AppModel`
(Combine `ObservableObject`) holding `sessions`, `activeSessionID`, `settings`; each `Session` holds
its `tabs` + active tab + per-tab status. View controllers `sink` on the model and update AppKit
views by hand. **Why AppKit:** the prior SwiftUI build had recurring cursor/tooltip/resize glitches
and a release-only file-open crash, all rooted in the SwiftUI↔AppKit seam; AppKit owns those natively.

## Sessions & tabs — `Model/`, `UI/WorkspaceViewController`, `UI/CenterViewController`, `UI/TabBarView`
Multi-repo sessions (dedup by path); tabs for Claude / shell / file / diff. Open an existing folder (⌘O), or
**New Project** (`UI/NewProject`, ⌘⇧N / empty-state button / SESSIONS-header folder icon): an `NSSavePanel`
with an optional "Initialize a Git repository" checkbox (off by default) creates the folder, optionally
`git init`s it (`Git.initRepo`), and opens it. A non-git project still lists files (the tree falls back to
`Git.repoFiles` → `fsFiles`); only Changes/branch are git-only. Tabs stay mounted across
switches; restored tabs **spawn lazily** (only when first viewed). Claude arg presets via the +menu.
Cmd+W closes the active tab. Closing a tab/folder or quitting with **unsaved editor edits** prompts
first (`UI/UnsavedGuard`: Save / Don't Save / Cancel for one, Save All / Discard / Cancel for many) —
the red close button is funnelled through quit so it's covered too; saving routes through a closure
`CenterViewController` registers (the model owns the dirty flag, the view owns `save()`). Persistence:
JSON snapshot in UserDefaults, debounce-saved; restore drops repos whose folder is gone.

**Fork a Claude session.** A Claude tab can be forked into a new, independent session that starts with
a *copy* of the same conversation — Claude Code's `--resume <cid> --fork-session` (new session id, no
effect on the original). The surface is a small **`⑂` icon on each Claude chip** (`TabChipView`), shown
only on **forkable** tabs (a Claude tab that's captured a conversation id); a fresh Claude tab or a
just-created fork that hasn't earned its own id yet shows none. It's a `PointerButton` routed through
the chip's `hitTest` alongside the close button. `Session.forkTab` adds a `.claude` tab titled
"Claude (fork)" carrying the source's launch flags and a transient `Tab.forkParentId` (the source `cid`).
`launchSpec` turns that into `--resume <parent> --fork-session` *once* — guarded by `claudeSessionId ==
nil`, so the moment the fork's own id is captured from the hooks a Restart resumes the fork in place (no
double-fork). `forkParentId` isn't persisted: forking before the fork's first activity (the only window
it matters) then quitting just restores a fresh tab. Verify the (invisible) flag construction with the
`forkClaude` / `setClaudeId` / `dumpLaunchArgs` harness actions (`TerminalStore.debugLaunchArgs`).

**Claude tabs are named after the session.** Instead of every Claude tab reading "Claude", each shows the
conversation's name. The **primary, reliable source is the first prompt, captured live from the hook** —
the `UserPromptSubmit` hook ships the prompt text (base64url, capped) to `HookServer.onPrompt`, and
`AppDelegate` names the tab from it *while it still shows the default label* (so the name is the first
message and doesn't churn each turn). This is necessary because **Claude doesn't write the session
transcript to disk while a (pure-text) session runs** — only after it does tool work — so reading the file
isn't reliable for a live tab (see the gotcha). As a secondary path, `Backend/ClaudeTranscript` reads the
transcript when it *does* exist (restored tabs, established sessions) and upgrades the label to Claude's
own `ai-title` (the `--resume` title), falling back to the first prompt; it **tails 256 KB** for `ai-title`
and **heads 256 KB** for the first prompt (bounded reads — transcripts reach tens of MB), debounced per tab
in `scheduleTitleRefresh`, plus a `refreshAllClaudeTitles` pass at launch for restored tabs. The chip
truncates a long name to a max width with "…" and shows the full text in its tooltip. A tab with no prompt
yet stays "Claude"; a fork starts "Claude (fork)" and names itself from its first prompt. Captured ids:
`SessionStart` reports the id too (so a tab resumed at launch is named without a prompt) — status-neutral,
skipping brand-new "startup" sessions and the parent id a fork reports. Harness: `dumpCid`, `applyTitle`.

**Quick Ask (⌘/).** Ask the active Claude chat a side question *without touching its history*. A centered
overlay (`UI/QuickAsk` — `QuickAskController` + `QuickAskPanel`) hosts a **real interactive fork** of the
chat (`claude --resume <activeCid> --fork-session`) in a SwiftTerm PTY. Forking *in interactive mode* reuses
the chat's warm prompt cache, so the first answer is as fast as the ongoing chat (~3–4 s) — the key reason
it's a real terminal, not a headless `claude -p` panel, which sends a different request prefix and so cold-
prefills the whole context (~1 min); see DECISIONS.md D23. A **Context | Blank** toggle forks the chat vs
starts a fresh context-free session (Blank-only when no forkable chat is active). **New** drops the fork and
starts another; **Open as Tab** promotes the live fork into a real Claude tab — the PTY is keyed by a real
tab id, so promotion is just `session.addTab` (process + scrollback survive) and it then behaves like any
forked tab (`forkParentId` restart semantics). The fork PTY persists across hide (reopen continues), and is
dropped when you switch sessions or start a New thread. It reuses `TerminalStore.view(for:)` + `launchSpec`
(the committed Fork feature's flags). Harness: `quickAskShow`/`Hide`/`New`/`Mode:context|blank`/`Send`/
`OpenAsTab`, `dumpQuickAsk` (launch args + terminal text). Forking a large/old chat makes Claude show a
"Resume from summary/full" menu; Quick Ask **auto-picks "full"** (warm-cache reuse) by watching the fork's
screen (`TerminalStore.screenText`) and sending the option's number — digit only, since a trailing Enter
would accept Claude's ghost history suggestion and run a stray command. Each fork duplicates the conversation
on disk (Claude prunes after `cleanupPeriodDays`, default 30).

## Terminal — `Terminal/`
`TerminalStore` caches one SwiftTerm PTY view per tab id (process survives tab/session switches).
Login-shell PATH via `Env.bootstrap`. Claude launches with `--settings <hooks>` + env; a shared
scroll monitor routes wheel/trackpad events (incl. alt-buffer SGR forwarding) to the terminal under
the cursor. Claude `--resume <cid>` only when its transcript still exists on disk. The launch exe/args/env
live in one `launchSpec(for:cwd:)`. **Continue/resume flags are dropped for folders Claude has never seen**
(`hasConversation(forCwd:)` checks `~/.claude/projects/<encoded cwd>` for any `.jsonl`) so a default like
`--continue` starts a *fresh* session on a brand-new project instead of failing with "no conversation to
continue"; it's kept when the folder has history. A wrong encoding guess only ever means "launch fresh".

**Session end.** Every spawned terminal sets `TerminalStore` as its SwiftTerm `processDelegate`; on
`processTerminated` it maps the view → id and fires `onExit(tabID)` (AppDelegate → `Session.markExited`,
which flags the tab) or `onQuickExit(sessionID)` for the ⌃` shell (closes the panel). A flagged tab shows
the **`SessionEndedOverlay`** (`UI/CenterViewController`) — a prominent centered card (dimming scrim +
shadow, so it isn't missed; scrim clicks pass through via `hitTest` so the dead terminal stays scrollable)
with an icon, title, next-step text, and **Restart** (accent/primary — `Session.restartTab`), **Open
Terminal** (`convertToTerminal`, flips kind → `.terminal`; Claude-only), and **Close**. Restart/convert **rebuild a fresh view** via the `TerminalLifecycle.rebuild` hook
(`CenterViewController.rebuildTerminal`: close the old PTY, drop the cached content view, re-`render`) —
re-running `startProcess` on a dead SwiftTerm view spawns a process that immediately dies, so it can't be
restarted in place.

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
live-applies with in-place run resize.
**New File (⌘N).** `Session.newUntitled` opens a blank editor tab — a `.file` tab with `path == nil`,
titled `Untitled-N` where N is the **lowest free** number among open untitled tabs (VS Code-style, so
closing them all brings the next back to `Untitled-1` rather than a counter that only climbs) — reusing
all the editor plumbing. The editor starts in
"untitled" mode (`EditorViewController.UntitledFile`): the first ⌘S (or "Save & Close" from the unsaved
guard) runs an `NSSavePanel` (default dir = repo root, suggested name = the tab title); on confirm it
`retarget`s to the chosen path (adopting the file + re-deriving the grammar/language), writes, and fires
`onSavedAs` so the session adopts the path + filename title and `CenterViewController` updates its path
cache (so the rename-detector doesn't rebuild the editor). `saveImmediately` returns `false` when the
panel is cancelled, so the guard **aborts the close** instead of losing the text. Untitled tabs are
ephemeral — skipped in the persisted snapshot (no on-disk content to restore). **⌘F find / replace** is a custom VS Code-style bar (`UI/FindBar`)
floating at the editor's **top-right** in its own borderless child window (`FindPanel`, added via
`addChildWindow`, pinned by converting the editor view's top-right to screen coords and repositioned on
window move/resize + editor relayout). **Why a separate window:** an earlier same-window overlay *subview*
glitched the cursor — its button cursor-rects overlapped the text view's I-beam rect in a *different* view
subtree, which AppKit leaves "undefined" (hand/I-beam flicker). A separate window has its own cursor-rect
domain, so there's no conflict. Trade-off: the panel must be key to type (its `canBecomeKey` is overridden),
so the main window's title bar dims while the find field is focused. The panel closes when its editor's tab
stops being active (`CenterViewController` calls `hideFindIfShown` on the outgoing editor). A search field with
**Match-Case / Whole-Word / Regex** toggles (the native `NSTextFinder` has none of these), a `3 of 12`
counter, prev/next (⏎ / ⇧⏎), Esc to close, and a disclosure chevron that expands a **Replace** row
(Replace current / Replace All; ⌥⌘F opens it expanded). Matches are found via `NSString` substring or
`NSRegularExpression` (invalid regex → red field, no crash), highlighted with **layout-manager temporary
`.backgroundColor` attributes** (no text mutation / undo pollution — they sit alongside the highlighter's
foreground attributes), the current one stronger + centered; replace is one undoable edit (reverse order
keeps ranges valid) and expands `$1` templates in regex mode. The toggle states persist in `Settings`
(remembered across files + launches); find re-runs on edits while open. Edit → Find routes
⌘F / ⌘G / ⌘⇧G / ⌘E / ⌥⌘F to the active editor's bar. The bar's buttons are `PointerButton`s (hand cursor +
tooltips).
A **line-number gutter** (`UI/LineNumberRuler`, the scroll view's
vertical `NSRulerView`) draws VS Code-style numbers: only the lines in the visible rect are drawn each
pass, char-index→line is a binary search over a cached `lineStarts` array rebuilt only on text change,
wrapped logical lines number once (first visual row), the cursor's line is brighter, and width/font track
the editor font size. Coverage is "good, not tree-sitter-perfect": regex-based, and
external-grammar includes (e.g. CSS embedded in HTML) and Oniguruma-only regex are skipped. The
tokenizer is ~linear but call-bound (~0.3 ms/line); huge files colour off-main without freezing rather
than instantly — a combined-regex scanner would be the next step if instant huge-file colour is needed.

## Formatting — `Backend/Formatter`, `UI/FormatterPrompt`, `UI/SettingsWindow` (Formatters tab)
Format the active file with the user's installed CLI formatter (⇧⌥F / right-click → **Format Document**;
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
A **Format on save (⌘S)** toggle (off by default) formats before writing — async so it never blocks, and
it silently skips a missing/disabled formatter (no prompt on save). The unsaved-changes guard saves via a
separate **synchronous** `saveImmediately()` so "Save & Close" / quit always persists *now* — format-on-
save's async write could otherwise run after the editor is torn down and drop the edits. (Per-language
command overrides were intentionally not built — niche + UI cost; revisit if a default command is ever wrong.)

## Status bar — `UI/StatusBar`, `Model/Session` (gitBranch), `Backend/Git` (branch ops)
A VS Code-style bar pinned to the bottom of the **center pane only** — it's an arranged subview of
`CenterViewController`'s vstack (not the window root), so it doesn't span the sidebar; hidden when no repo
is open. **Left:** the active session's git **branch** + (when the resource-monitor setting is on) the
process **mem · CPU**. **Right (editor tabs only):** `Ln X, Col Y` · indentation · line-ending · language —
context-aware, hidden for terminal / Claude / diff / image tabs. Everything **scales with the shared font
size** (the bar's `intrinsicContentSize` height tracks it).

All items are **clickable** (flat `PointerButton`s, hand cursor — non-overlapping, so no cursor conflict):
- **Branch** → menu: switch (checkout), **Create New Branch…** (its text field is focused on open), **Delete
  Branch…** (submenu; *always* confirms, with a stronger warning + force-delete only for an unmerged branch,
  detected via `git merge-base --is-ancestor`). Git failures surface in an alert; the label refreshes
  immediately after an op (not waiting for the FS poll, which won't fire when branches share a commit).
- **Ln/Col** → Go to Line (opens the palette in `:` mode).
- **Indentation** → Tabs / Spaces 2·4·8 (rewrites existing indentation, one undoable edit; heuristic).
- **Line ending** → LF / CRLF (converts the buffer — `\r\n` actually lands, so it persists on save).
- **Language** → Auto-detect + the bundled grammars (overrides highlighting for the open file; resets on reopen).

Data sources, **no new pollers**: **branch** rides the existing per-session `RepoStore` git poll (bridged to
`Session.gitBranch`); **Ln/Col** comes from the editor's selection (the gutter's cached line index) via the
`EditorStatus.onChange` nudge on `textViewDidChangeSelection`; **EOL/indent/language** are read once on load;
**mem/CPU** is pushed from `AppDelegate`'s `ResourceMonitor` via `ResourceStatus.onUpdate` (only while the
setting is on — it used to live in the title-bar subtitle). Opening a file now parks the caret at the **top**
(Ln 1) rather than the end (`setAttributedString` had left it at the end — the status bar surfaced it).

## Command palette (⌘P quick-open) — `UI/CommandPalette`, `App/MainWindowController`, `App/AppDelegate`
A VS Code-style quick-open: **⌘P** (File → **Go to File…**) drops a top-centered overlay — a search field
over a results list — to jump to any file in the active session's repo. Type to **fuzzy-match** (a
case-insensitive subsequence over the repo-relative path, scored with bonuses for consecutive runs,
word-boundary / camelCase starts, and matches in the filename), **↑/↓** to move, **Enter** (or click) to
open, **Esc** / click-outside to dismiss. An empty query lists the **currently-open file tabs** (quick
switch). Rows show the filename tinted by git status (reusing the tree's `nsStatusColor`) + a dim parent
dir, with the **matched chars brightened + bold** (`Fuzzy.matches` returns the same greedy alignment the
scorer uses). The file list is fetched **once per open** via `Git.repoFiles(expandIgnored: false)` off-main
(so gitignored dirs are excluded and it's always fresh) — there's **no extra git poller**, and the overlay
is mounted only while shown, so ⌘P costs nothing until pressed.

The same field has **three modes**, picked by the leading char: **file** (default), **`:123` line-jump**
(Enter moves the caret to that 1-based line in the active editor and centers it, via
`EditorViewController.goToLine`), and **`>` command mode** (**⌘⇧P**, File → **Command Palette…**) — fuzzy-run
an action: New Claude Session / New Terminal / Format Document / Go to File… / Settings… / Close Tab. The
command list is rebuilt each keystroke so availability tracks state (New Claude only with a session, Format
only with an editor open); most commands dismiss-then-run, while "Go to File…" keeps the palette open and
switches back to file mode. The results list uses `NSTableView.style = .plain` (the default `.automatic`
inset-pads rows and stretched the single-row selection band).

The palette is owned by `MainWindowController` (hosted over the banner + workspace) and reached from the
menu via the `CommandPaletteHook` static hook (`toggle` for ⌘P, `command` for ⌘⇧P — same pattern as
`FormatterInstall` / `ActiveEditor`). Harness-driveable for verification (`paletteOpen` / `paletteCommands`
/ `paletteType:` / `paletteDown` / `paletteUp` / `paletteEnter` / `paletteClose`, with a `palette` block —
mode, results, selected — in the state dump) since ⌘P + arrows are HID the harness can't synthesize.

## Project search — `Backend/Search`, `UI/SearchPanel`, `UI/WorkspaceViewController`, `UI/CenterViewController`
VS Code-style project-wide text search, **scoped to the active session's repo**. The backend `ProjectSearch.run`
shells out to **`git grep`** — every session is a git repo, so no extra dependency: it respects `.gitignore`
and (with `--untracked`) covers tracked *and* new-but-not-ignored files. Flags map the toggles: `-i` (not
Match Case), `-w` (Whole Word), `-E` regex vs `-F` fixed-string. Exit codes are read via `Shell.runFull`
(0 = matches, 1 = none, **>1 = error** → `failed`, e.g. an invalid regex); output is parsed `FILE:LINE:TEXT`
into `[FileHits]`, previews trimmed of indentation and capped, total matches capped.

`SearchViewController` (the shared UI) is a query field + **Match-Case / Whole-Word / Regex** toggles over an
`NSOutlineView` of file → matching lines. Searches run **debounced (~220 ms) off-main** with a token to drop
stale results, so it costs nothing until you type. Results group by file (expanded by default), previews show
the line with **matched ranges highlighted** (an `NSRegularExpression` mirroring the same options). The
outline (`SearchOutlineView`) **hides the system disclosure triangle** (`frameOfOutlineCell` → `.zero`) and
draws its **own chevron** in the file cell, so match rows sit **flush-left** (line number hugging the preview)
instead of nested — and the chevron has a real gap to the filename. Clicking a result calls the
`FileNavigator.openAt` static hook → opens the file in the active session and **jumps to the line**
(`goToLine`); for **markdown / SVG** files it first flips the viewer to **Source** (`setSourceVisible(true)`)
since the hit is in the source, not the rendered preview.

Two surfaces: (1) the **right sidebar's Search segment** — the Files/Changes switcher became a **3-icon**
control (Files / Changes / Search); selecting Search shows the panel and focuses the field. (2) a **standalone
Search tab** (`TabKind.search`, `⌕` glyph) — a full-width search in the center. **⌘⇧F** (and the palette's
**Find in Files…**) **reveals the sidebar** Search section via the `SidebarSearchHook.reveal` hook (Format
Document moved to **⇧⌥F** to free the shortcut). The sidebar panel has an **Open-as-Tab** button (⬈, sidebar
instance only) that opens a **fresh** search tab each time (multiple allowed, titled `Search: <query>`),
**carrying the query + toggles** via the `SearchSeed` holder, consumed in `CenterViewController.render` when the
tab activates. Search tabs are **excluded from session restore** (`AppModel.save` filters `.search`, indexing
the active tab against the filtered list). Harness: `projectSearch:` / `searchOpenFirst` / `sidebarMode:` /
`revealSearch` / `searchOpenAsTab` / `openSearchTab` / `projectSearchTab:` / `openAt:file|line`, with `search`
+ `searchTab` blocks in the state dump (the field/outline are HID the harness can't drive).

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

## Menu-bar attention — `App/AttentionItem`, `App/AttentionMenu`, `App/AppDelegate`
A persistent `NSStatusItem` (toggleable: `Settings.showMenuBarStatus`, default on) showing aggregate session
status while Multee is in the background — complementing the transient notification banners and the in-app dots.
The icon is the **Multee `»` mark drawn as a single-color silhouette** (rounded caps), tinted by aggregate
state: **blue** working, **orange + a count of how many need you** when any session needs attention, else an
adaptive template (white/black per the menu bar). It's drawn (not the two-tone app icon) so it tints cleanly —
`button.contentTintColor` renders a template monochrome in the menu bar. **Dev builds add a small dot** in the
top-right (gated on `Bundle.main.isDev`) so the dev `»` is distinguishable from a release Multee at a glance.
Recompute is event-driven off the same per-session `objectWillChange` the sidebar uses — no polling.

The dropdown (`AttentionMenu`) is built from **custom `NSMenuItem.view`s** so it reads like a status panel: a
header summary ("N sessions need you", colored by urgency), then session rows — **status dot + name + a
right-aligned colored status word** (Needs you / Working / Done / Idle), needs-first, with a rounded **hover
highlight** (tracking-area driven; text brightens on the accent). Sessions running more than one Claude tab
expand to indented per-tab rows. Selecting a row jumps to that session/tab (`mouseUp` → `cancelTracking` +
`onJump`, supplied by AppDelegate: switch + `NSApp.activate` + window front). Footer actions (Settings / Open
Multee) stay standard `NSMenuItem`s with SF Symbol icons for native highlight + action. `AttentionMenu.debugRender`
renders a representative panel to a PNG (the menu is HID — hover/click are user-verified, the static design isn't).

The **"done / waiting for you" attention state** (`ClaudeState.done`) lives in the shared status model so all
three surfaces agree: when a turn ends (was working → idle) while you're **not** looking, the tab is flagged
`.done` (orange, like `.needs`) instead of plain idle, cleared when you next view that tab (`Session.clearAttention`,
called on tab activation in `CenterViewController` and on app-foreground in `AppDelegate`). The `Stop`→done
transition is **debounced** (`finishDebounce` = 2.5s): Claude often stops for a beat then keeps going or pops a
question, so the deferred finish (and its completion notification) is cancelled by any following event —
avoiding a false "finished". `StatusDot` and the menu both color `.needs`/`.done` orange.

## Keyboard shortcuts panel — `UI/ShortcutsWindow`, `UI/StatusBar`
A keyboard icon at the far right of the bottom status bar (always visible while the bar is) opens
`ShortcutsWindowController` — a floating, dark, scrollable panel listing every shortcut from `Shortcuts.sections`
(General / Navigation / Tabs / Editing / Find in File / View), each row a command name + **keycap chips** (one
fixed-width rounded `KeycapView` per glyph). Esc or the close button dismisses it. The list is a hand-maintained
mirror of `AppDelegate.buildMenu` + the ⌘+/− monitor + ⌘S — keep it in sync when adding shortcuts.
**Format Document is ⇧⌥F** (moved off ⌘⇧F, which now opens Find in Files); because a non-Command shortcut is
swallowed as text input over the editor (Option composes a special char), it's handled in `AppDelegate`'s key
monitor — intercepted before the editor when one is focused — not as a menu key-equivalent.

**New Claude / New Terminal shortcuts (`NewItemHook`).** Three File-menu commands, backed by one hook enum so
the menu items, the key monitor, and the harness share an implementation: **New Claude Session (⌘⇧C)** opens a
Claude tab with the default args; **New Claude with Args… (⌘⌥C)** pops the tab bar's existing preset menu
(Default / `--continue` / `--resume` / `--dangerously-skip-permissions`) via `TabBarHook.popClaudeArgsMenu` —
one source of presets, anchored to the ▾ button; **New Terminal (⌃⇧`)** is context-aware — it adds a shell to
the quick terminal when that panel is open (`QuickTerminalController.addShell`), otherwise opens a terminal tab.
⌃⇧` is intercepted in the key monitor next to ⌃` (matched by `keyCode == 50`, the grave key, so Shift's `→~
remap is irrelevant); the ⌘-based Claude shortcuts work as plain menu key-equivalents. The args menu is gated on
an open repo (its anchor button lives in the otherwise-hidden tab bar).

## Quick terminal (⌃`) — `UI/QuickTerminal`, `Terminal/TerminalStore`, `UI/CenterViewController`, `UI/SettingsWindow`
A VS Code-style quick-access terminal: **⌃`** pops per-session login shells and the same key hides them
(`QuickTerminalController.toggle`, reached via `QuickTerminalHook` from `AppDelegate`'s key monitor +
the View ▸ Toggle Terminal menu item). A session can hold **several shells**; each is a PTY (cwd = its
repo) owned by `TerminalStore` under a reserved id (`__quick__<sid>::<n>`, never a tab). The controller
keeps a per-session ordered list + active selection (`lists`, ephemeral — not persisted); `ensureList`
spawns the first lazily, `newQuickView` adds more, `closeAllQuick(sessionID:)` kills them all in
`Session.killTerminals`. Switching session swaps the whole set; each shell keeps its own buffer.

**Shared chrome (`QuickTerminalPanel`).** All three modes mount the *same* composite view — a header
strip above the active terminal — so the controller re-parents one `chrome` between containers (the
terminal lives inside it and never re-parents on its own). The header carries the three affordances:
a **chip strip** (one `QuickTermChip` per shell, numbered by position — click to switch, ✕ to close,
`+` to add), an **↗ "Open as tab"** button (`promoteQuick` re-keys the live PTY to a new `.terminal`
tab id so the running process + scrollback move into the workspace; the shell drops out of the list),
and a **`⌃\` to hide` keycap hint** so users learn the shortcut also dismisses. Closing the last shell
(or it `exit`ing) hides the panel; `onQuickExit` now hands back the **full** quick id so the controller
can map it to a session + list.

It appears in one of **three modes** (Settings ▸ "Quick terminal opens as", persisted as
`Settings.quickTermMode`): **floating** (a key-able `NSPanel`; close button just hides), **centered**
(an in-window dimmed scrim + rounded box, click-outside to dismiss — what we call the non-blocking
"modal"), or **bottom** (a VS Code-style dock under the content, via a vertical `NSSplitView` in
`CenterViewController` with a draggable divider). ⌃` is intercepted in the key monitor (like ⇧⌥F)
because a focused terminal would otherwise eat Control-backtick. Closing restores first-responder to the
active tab's content (`CenterViewController.focusActiveContent` from `hide()`), so focus returns to your
session/file.
**Verification:** the harness can't synthesize ⌃` (sandbox) and the floating panel's terminal doesn't
screenshot, so the keystroke is user-verified; the chip strip / hint / buttons *are* standard AppKit and
self-screenshot. The rest is driven via `quickToggle` / `quickMode` / `quickSend` / `quickNew` /
`quickActivate:<n>` / `quickClose:<n>` / `quickOpenAsTab` harness actions + `quickTerminal` state
(`count`, `activeIndex`, the active shell's buffer); promotion is verified by the promoted tab's
`terminalText` still carrying the pre-move scrollback.

**Known issue — bottom-dock repaint gap (PARKED, unresolved).** In **bottom** mode only, after you close
the dock the Claude TUI stays top-anchored with blank space below until you type in it; it then snaps to
full height. Floating/centered modes are unaffected (they never resize the Claude terminal). What we
established before parking it:
- It is **our** issue, not Claude's: Claude repaints fine on a normal window resize.
- The data layer works in the harness: forcing a layout on close grows the embedded terminal 22→36 rows
  *synchronously* (`MacTerminalView.setFrameSize` → `processSizeChange` → `sizeChanged` → `setWinSize`,
  the `TIOCSWINSZ`/SIGWINCH path), and the real Claude process's output buffer reflows to 36 lines with
  its input bar back at the bottom — **no typing needed**. So resize → SIGWINCH → Claude-redraw is correct
  at the buffer level.
- Yet the user still sees the on-screen gap, and it could **not be reproduced** in the harness, nor the
  rendered terminal observed (SwiftTerm doesn't appear in `cacheDisplay` self-shots; `screencapture` is
  blocked without Screen-Recording permission). Leading hypothesis: a **view-render refresh** issue — the
  buffer is correct but the grown region's pixels aren't repainted until an event (typing) forces a full
  redraw. Untested open question for resuming: does dragging the window edge fix the gap like typing does?
- Tried and reverted (didn't resolve it): forcing a synchronous `window.layoutIfNeeded()` in
  `hideBottomDock` on close; a duplicate-toggle debounce in `toggle()` (for a separate "auto-reopen" that
  appeared during these attempts). Focus restoration on close was **kept** (it's good UX regardless).
- Next ideas to try: a view-redraw nudge (`setNeedsDisplay`) after Claude responds; a small resize
  "nudge" (grow past then back) to force a full re-render; or a redesign that doesn't resize the Claude
  terminal (the user rejected an overlay-style bottom panel).

## Docker — `Backend/Docker`, `UI/DockerPanel`, `UI/StatusBar`, `Terminal/TerminalStore`
A VS Code-style **bottom-dock panel** to manage the active repo's Docker Compose stack — services,
their state/ports/logs/shell, and volumes. Entry point is a **shippingbox icon** at the bottom-left of
the status bar (`UI/StatusBar`, left of the git branch) that **only appears when the Docker daemon is
reachable** (`AppModel.dockerAvailable`); clicking it toggles the dock (`DockerHook.toggle`). The dock is
the **same bottom container the quick terminal uses** — only one occupies it at a time, so each yields to
the other (`DockerPanelController.show` closes a bottom quick terminal; the quick terminal calls
`vacateDock()`); see D24.

**Availability is event-driven, not polled** (perf #1): one `docker info` off-main at startup and on every
app-activate (you typically start/stop Docker in another app, so returning focus is the natural re-check),
never overlapping. No idle timer.

**Compose files are user-picked, persisted per-repo.** `Docker.discoverComposeFiles` scans the repo **root**
(no subfolders) and classifies the standard names + the auto-`override` + env variants (`compose.prod.yaml`);
a chevron picker (`ComposeFilePickerViewController`) is a checklist with an **"Add compose file…"** escape
hatch (`NSOpenPanel` scoped to the repo — files outside are rejected) for odd-named/sub-folder files. The
selection persists in UserDefaults per repo (`docker.compose.selection::<repo>`), defaulting to base+override.
This handles the common multi-file case (a dev vs prod compose in one root); see D25.

**Services come only from `docker compose config`, never `ps`** (a `ps` fallback surfaced leftover orphan
containers from a previous compose version as phantom services). `Docker.services` reads `config --format json`
for the defined service names **and** which have a `build:` context (`hasBuild`), with a fallback to
`config --services` if the JSON won't parse; live state/ports/replica-count come from `ps -a`. Each row
(`DockerServiceRow`) shows a **state dot** (filled green = running, **hollow ring = stopped**, yellow =
starting — colour-blind-safe by shape too), the name, an `×N` replica badge when scaled, **ports**, and
state-driven action buttons with **logs always rightmost** (the one button every row has → a stable column).
Buttons: image action (**Build** if `hasBuild`, else **Pull** — gated so neither is a no-op), lifecycle
(Start / **Rebuild&start** `up --build` when stopped+buildable / Stop / Restart), **Shell** (running only,
`compose exec <svc> sh` → a terminal tab), Logs. **Published ports are clickable links** → open
`http://localhost:<host-port>` (`hostPort` parses `15432->5432` and `0.0.0.0:15432->5432/tcp`); internal-only
ports stay plain text. While a service's action runs, **its row shows a spinner** instead of buttons
(`actingService`, cleared on the action's PTY exit) so it can't be double-fired.

**Project-wide actions** sit in the header, **grouped into clusters with dividers**: lifecycle (Up · Stop ·
Restart · Down) │ images (Build · Pull, the cluster hidden when nothing is buildable/pullable) │ All-logs.
`down` confirms first (recoverable). The Services/Volumes segmented toggle, a spinner, the peek eye, and
refresh are on the right.

**Actions run in a watchable PTY**, not captured output — `runAction` spawns a `TerminalStore.commandView`
(reserved `__cmd__` id) running `docker compose …`; a **peek overlay** (`DockerActionOverlay`) hosts the live
view (build/pull output streams), auto-revealed on a **non-zero exit**, with **Open as Tab** (`promoteCommand`
re-keys the PTY into a real terminal tab). The **event stream drives the dots** — `DockerEvents` streams
`docker events` (NDJSON) while the panel is open (stopped on hide/quit → a closed panel does zero work),
filters to the current project, debounces bursts into one `ps`, and auto-reconnects + re-snapshots on a
daemon restart. Logs open as a roomy **terminal tab** (`compose logs -f`, per-service or all interleaved).

**Volumes tab** (`DockerVolumeRow`): label-scoped to the project (host-wide — volumes persist across `down`),
each row showing the name, a teal **"in use"** badge (from the `dangling=true` filter), the **service(s) that
mount it** (`volumeUsers`, one `ps --no-trunc`), an **on-demand size** (`system df -v`, a clickable chip → the
scan is expensive so never in the list refresh), and a **trash** that's **dimmed+disabled while in use** (kept
in place so the size column stays aligned) and a strong confirm when removable.

**Look & feel:** rows are a real table — fixed columns, **zebra striping** (`HoverRow.baseBackground`),
**hover highlight**, column **headers** with a hairline separator, and **hover-brightening icon buttons**
(`HoverIconButton`; disabled buttons drop the hand cursor). The `size` control is a pill **`ChipButton`** so
it reads as tappable, not a label.

**Verification:** the panel is standard AppKit so it self-screenshots (dots, ports, badges, header, stripes);
the action PTY output is SwiftTerm so it's buffer-verified via the overlay's `screenText`, not the shot. Hover
states and the click→browser open are user-verified (no synthetic mouse / browser launch in CI) — the port
URL is asserted from the `links` field in the docker state dump instead. Driven by `docker*` harness actions
(`dockerToggle`/`Refresh`/`Pick`/`Start`/`Stop`/`Build`/`Pull`/`StartBuild`/`Logs`/`Exec`/`Volumes`/`VolSize`/
`VolRemove`/`Acting`/`OpenPort`/…, `dockerForceAvailable` to fake the daemon, `dockerConfirm:ok` to answer the
modal) with a `docker` block in the state dump (available, services + their state/ports/links, volumes,
`actingService`, event-stream up, cumulative `dockerCmdCount` for the no-idle-poll guarantee).

## Settings & updates — `UI/SettingsWindow`, `UI/Updates`
Settings window (native controls) bound to `Settings`. Update checker hits the GitHub latest-release
API; a top banner offers Homebrew self-update or Download. **Install now** runs
`NONINTERACTIVE=1 brew upgrade --cask --force …` (no Y/N prompt) in an in-app terminal — opening a bare
home-folder session if nothing is open — then **auto-relaunches** into the new build: the command writes a
temp flag on success, which `watchForCompletion` polls for before calling `relaunch()`.

## Deferred (v0.1.1 polish)
Collapsible SESSIONS panel; drag-reorder tabs; per-button hand cursor. None are functional blockers.
