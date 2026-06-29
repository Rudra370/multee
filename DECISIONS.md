# Multee — Decision Log

Why we built things the way we did. This is the *reasoning* record — the trade-offs and the
options we rejected — so that when we revisit an area we don't relitigate settled questions or
forget what a choice cost us.

- **FEATURES.md** = *what* each feature does and *where* it lives.
- **CLAUDE.md** = *how* to build/run/release and the concrete gotchas.
- **DECISIONS.md** (this file) = *why* we chose X over Y.

Each entry: the decision, the reasoning, and what we rejected. Newest areas first within a section.
When a decision is reversed later, leave the old entry and add a new one that references it — the
history is the point. Mark anything still open with **Status: open**.

---

## Architecture

### D1 — Pure AppKit, no SwiftUI
**Decision:** Rewrite the app in pure AppKit (NSApplication/AppDelegate, NSViewController,
NSSplitView, NSOutlineView, NSTextView). Model layer uses Combine `@Published` (independent of
SwiftUI).
**Why:** The previous SwiftUI build had recurring cursor, tooltip, and resize glitches plus a
release-only file-open crash — all rooted in the SwiftUI↔AppKit bridging seam. We spent a lot of
time patching symptoms. AppKit owns windows, cursors, tracking areas, and text natively, so those
classes of bug disappear instead of being whack-a-mole'd.
**Rejected:** Continuing to patch SwiftUI (endless seam bugs); a Catalyst/hybrid approach (same seam).
**Cost accepted:** More verbose, manual code (programmatic layout, manual model→view wiring).

### D2 — Fresh repo, reset to v0.1.0
**Decision:** Start the rewrite in a clean repo and reset the public version to v0.1.0; leave the
old app/repo untouched until the rewrite shipped.
**Why:** The rewrite is a clean break; a fresh history is clearer than a giant squash on top of the
Tauri→SwiftUI lineage. Users keep the old app working until the new one is ready.

### D3 — SwiftPM + Command Line Tools, no Xcode project
**Decision:** Build with `swift build` / shell scripts; no `.xcodeproj`.
**Why:** Scriptable, diff-friendly, no project-file churn or merge conflicts. `build.sh`/`dev.sh`
own the bundling + signing.

### D4 — SwiftTerm for the terminal
**Decision:** Use SwiftTerm as the terminal view.
**Why:** Native CoreText rendering (correct glyphs/ligatures), ships its own PTY, mature. Writing a
terminal emulator ourselves is not the product.

---

## Performance (the #1 priority)

Performance — low CPU and RAM — is Multee's top quality bar. The guiding rules: prefer event-driven
over polling, share heavy resources instead of duplicating them, and **measure before/after** rather
than guess. Several decisions below exist purely to honor this.

### D5 — Event-driven file watching (FSEvents), not git polling
**Decision:** Watch the repo with FSEvents; fall back to a slow (15 s) timer only as a safety net.
**Why:** Continuous git polling burned CPU at idle. FSEvents wakes us only on real changes.

### D6 — Signature-gated, expanded-only tree reloads
**Decision:** Reload the file tree only when the visible set's signature changes, and re-expand only
branches that are actually expanded (never walk the whole tree on the main thread).
**Why:** Idle CPU was ~15% and large repos hung on open because we rebuilt + re-walked the full tree
every poll. After this, idle CPU → 0%.

### D7 — Native TextMate highlighter, replacing Highlightr *(supersedes the original Highlightr choice)*
**Decision:** Editor syntax highlighting runs on a small in-house TextMate-grammar engine driven by
`NSRegularExpression` (macOS's built-in regex engine). ~30 `.tmLanguage.json` grammars from VS Code
ship as a resource and load lazily per language.
**Why:** Highlightr ran highlight.js inside JavaScriptCore — a ~150 MB JS VM *per process*, just to
color text. Measured: opening code files took editor RAM from +148 MB to +42 MB over idle (~70% less)
at roughly the same app size (~5.7 MB). No JS engine, no GC heap.
**Rejected — tree-sitter (via CodeEditLanguages):** Most accurate, and the prebuilt xcframework
solved the grammar-packaging pain. But it force-links *all ~40 grammars* and added **+92 MB** to the
binary (5.3 → 100 MB), non-trimmable even when using 8 languages. That destroys the "tiny, fast app"
identity. Tree-sitter is light on RAM but heavy on disk; we couldn't have one without the other.
**Rejected — Splash:** pure-Swift and lovely, but Swift-only — useless for a multi-language viewer.
**Rejected — existing TextMate libs (SyntaxKit etc.):** archived/unmaintained or SwiftUI-coupled;
writing a compact engine we control was cleaner than depending on dead code.
**Cost accepted:** Coverage is "good, not tree-sitter-perfect" — regex-based, so external-grammar
includes (CSS-in-HTML, code in Markdown) and Oniguruma-only regex features are skipped. Fine for a
file *viewer* in a terminal-centric app; it's what VS Code itself shipped for years.

### D8 — Highlighting runs off the main thread; tokenizer is line-based
**Decision:** Tokenize on a shared serial background queue and apply colors back on main; the
tokenizer is line-based with begin/end state carried on a stack across lines. Small files highlight
synchronously on open (no flash), large files + edits go async with a sequence guard.
**Why:** We measured that the tokenizer is **call-bound** — ~90 regex calls per line — not
scan-bound, so a line-based rewrite *alone* didn't make it faster (~0.3 ms/line either way). The
real user requirement for a file viewer is that the **UI never freezes**, which off-main delivers
cleanly and safely. The line-based state stack also fixes multi-line correctness (strings/comments
spanning lines). Grammar regexes are precompiled on load so `spans()` is a pure read, safe to run on
any thread.
**Rejected (for now) — combined-regex scanner:** Testing all of a frame's patterns in one combined
regex per step would cut calls ~10× and make huge files color instantly. We deliberately deferred it:
it needs careful capture-offset bookkeeping and backreference handling, where a subtle bug silently
*miscolors*. The honest trade is "huge files color over a few seconds, never freezing" — which the
user confirmed is fine.
**Status: open** — revisit the combined-regex scanner if instant coloring on very large files is ever
wanted.

### D9 — Resource monitor behind a setting, default off
**Decision:** The in-app CPU/RAM monitor (title-bar readout) is opt-in via a setting, off by default.
**Why:** Measuring is for when you're investigating; normal users shouldn't pay any cost for a meter
they don't want. (Measurement uses Mach `task_info` `phys_footprint` = Activity Monitor's "Memory".)

### D19 — Virtualize any list that grows with repo size (generalizes D6)
**Decision:** The git Changes panel renders its rows with a virtualized `NSTableView` (only ~visible
rows are built), with a high per-section cap (~2,000) + a "…and N more" footer.
**Why:** The old panel built one view + Auto-Layout constraint *per changed file* in an `NSStackView`.
A repo with a large changeset (thousands of modified/untracked files — e.g. a build/deps dir not
gitignored) meant thousands of stacked views, so Auto Layout went ~O(n²) and **hung the main thread
for tens of seconds at launch**. Reproduced: an 8,000-file repo froze the app ~30 s at 100% CPU.
Virtualization makes layout cost O(visible) regardless of total count.
**This is D6 generalized:** the file tree already virtualizes via `NSOutlineView`; the rule now applies
to *any* list that can grow with the repo. **When adding a list UI, virtualize it** unless its length
is provably bounded and small.
**Resolved — the shared-poll follow-up (Phase 2):** a per-session `RepoStore` (`UI/RepoStore.swift`)
now owns the single FSEvents watcher + git poll + git actions; the file tree and Changes panel are
pure subscribers, and only the *visible* mode's data is fetched. This removed the two duplicate
watchers and the on-open quirk where the Changes pane polled git even while the Files tab was showing
— one source of truth, the "share heavy resources" principle.

---

## Resource bundling

### D10 — Resolve resource bundles from `Bundle.main.resourceURL`, never `Bundle.module`
**Decision:** Look up bundled resources (grammars; previously Highlightr's JS) from
`Contents/Resources` via `Bundle.main.resourceURL`, falling back to `Bundle.module` only outside a
packaged `.app`.
**Why:** SwiftPM's generated `Bundle.module` accessor only checks the `.app` *root* and the
*build-machine* path — neither exists for a user, and a signed `.app` must keep resources in
`Contents/Resources/`. So `Bundle.module` `fatalError`s on first use in a distributed app (this was
the original file-open crash). **Dev builds hide it** (their baked build path exists locally), so
always test a release `.app`. First discovered fixing Highlightr; the same shim now lives in
`GrammarBundle`.

---

## Build & release

### D11 — Version is the git tag (no version constant)
**Decision:** `build.sh` reads `MULTEE_VERSION`; pushing a `v*` tag triggers CI to build, publish the
GitHub Release, and refresh the Homebrew cask.
**Why:** One source of truth; releasing is "push a tag," nothing to edit and forget.

### D12 — Debug build is a separate app
**Decision:** Debug builds install as "Multee Dev" (distinct bundle id `com.multee.native.dev`, amber
icon, separate defaults domain).
**Why:** Local dev builds never clash with a real/brew-installed Multee you use day-to-day.

### D13 — Self-screenshot + state-dump debug harness (dev only)
**Decision:** The dev build reads `/tmp/multee-debug.json` to self-screenshot, dump UI/terminal state
to JSON, and run scripted actions.
**Why:** Lets the assistant drive and verify the app without a human, in an environment where screen
capture and input injection are blocked. **Known limit:** it can't move the real mouse, so cursor
behavior is never CI-verifiable — cursor fixes are reasoned from the established pattern and
hover-tested by the user.

---

## UI

### D14 — Custom drag handles + `@AppStorage`, not HSplitView/VSplitView
**Decision:** Implement resizable panes with custom drag handles and persist widths ourselves.
**Why:** `HSplitView`/`VSplitView` ignore `idealWidth` (default to `maxWidth`) and don't persist
position.

### D15 — Every clickable thing gets a tooltip + hand cursor
**Decision:** Icon buttons use our `.tip(...)` tooltip and a pointing-hand cursor; cursors are set via
a `.cursorUpdate` tracking area (see `Cursor.swift`), not cursor rects.
**Why:** Native `.help()` tooltips rely on AppKit tracking that SwiftUI re-renders reset, so they
often never fire; cursor *rects* aren't reliably re-established. `cursorUpdate` + tracking areas are
the dependable path. Applied to file-tree rows via `PointerOutlineView`.

### D16 — Editor uses legacy (always-visible) scrollers
**Decision:** The editor scroll view forces `scrollerStyle = .legacy`, `autohidesScrollers = false`.
**Why:** The overlay scroller appeared only mid-scroll and floated over the text, so the text view's
I-beam bled under it. Legacy scrollers are persistent and get their own gutter, so the bar is always
visible and the scroller area shows the normal arrow cursor.

### D20 — Quick terminal: one shared chrome, multiple shells per session
**Decision:** The quick terminal (⌃`) supports several shells per session, surfaced by a chip strip in
a single composite header (`QuickTerminalPanel` = header + terminal content). The controller re-parents
*that one chrome* between the floating / centered / bottom containers; the active terminal lives inside
the chrome and never re-parents on its own. Shells are `__quick__<sid>::<n>` PTYs in `TerminalStore`;
the per-session list + active selection is ephemeral UI state in the controller, not persisted.
"Open as tab" re-keys the live PTY to a `.terminal` tab id (`promoteQuick`) so the running process and
scrollback move intact.
**Why:** The three asks (manage multiple terminals, a shortcut hint, open-as-tab) all needed shared
chrome the original raw-terminal mount had nowhere to put. Building one composite and moving *it* (not
the terminal) makes the chrome identical across all three modes for free, and means mode/session/shell
switches still never restart a process — the property the original single-view design was built around.
Quick shells stay ephemeral (scratch terminals); persisting them would conflate them with tabs, which
they explicitly are not.

### D21 — Fork a Claude session via `--fork-session`, as a one-shot launch flag
**Decision:** "Fork session" reuses Claude Code's native `--resume <cid> --fork-session` rather than any
transcript copying of our own. The fork is encoded as a **transient** `Tab.forkParentId` (the source
conversation id), and `launchSpec` emits `--fork-session` **only while `claudeSessionId == nil`** — i.e.
exactly once, on the fork's first launch. Once the hooks report the fork's own id, the normal
`--resume <ownId>` path takes over, so a Restart resumes the fork in place instead of forking it again.
`forkParentId` is not persisted.
**Why:** Claude already owns conversation storage and forking semantics; duplicating that (copying
`.jsonl`, rewriting ids) would be fragile and could corrupt Claude's own state. A one-shot flag keyed on
"has this fork captured its own id yet?" is the minimal correct trigger — it can't double-fork on
restart, and the only lost case (fork, then quit before the fork's first activity) harmlessly restores a
fresh tab. The flag construction is invisible in the UI, so it's pinned by deterministic harness actions
(`forkClaude`/`setClaudeId`/`dumpLaunchArgs` → `TerminalStore.debugLaunchArgs`) rather than a screenshot.

### D22 — Name Claude tabs from the live hook prompt, with the transcript as a secondary upgrade
**Decision:** A Claude tab's name comes **primarily from the first prompt, captured live from the
`UserPromptSubmit` hook** (`HookServer.onPrompt`). The transcript (`ClaudeTranscript`, read by tailing
256 KB for `ai-title` / heading 256 KB for the first prompt, off-main, debounced) is a *secondary* path
that upgrades to Claude's `ai-title` when the file exists (established/restored sessions).
**Why:** The obvious design — just read the transcript's `ai-title` — **doesn't work for a live tab**:
Claude doesn't persist the `.jsonl` while a pure-text session runs (only after tool work), so a freshly
prompted tab has no file to read (verified: id captured, `file=<no file on disk>`). The hook already has
the prompt text in hand, so shipping it through (base64url, capped) names the tab immediately and reliably,
no file dependency. The transcript path still earns its keep for restored tabs and the nicer `ai-title`,
and stays bounded (fixed-size tail/head) because transcripts reach tens of MB. We name from the *first*
prompt (only while the label is still default) so it identifies the conversation and doesn't churn.

### D23 — Quick Ask: embed a real interactive fork (rejected: headless `claude -p`)
**Decision:** Quick Ask hosts a **real interactive** `claude --resume <cid> --fork-session` inside a centered
panel (a SwiftTerm PTY keyed by a real tab id, so "Open as Tab" is just `session.addTab` — the live PTY +
conversation carry over). A `Context | Blank` toggle forks the active chat vs starts a fresh session. It
reuses the committed Fork feature's `launchSpec` flags and the SessionStart hook; no bespoke streaming code.
**Why:** The "ask a side question without dirtying the chat" goal is just a fork shown in a panel instead of
a tab. Forking **in interactive mode reuses the chat's warm prompt cache**, so the first answer is as fast
as the ongoing chat (measured in production via the ⑂ fork button: ~3–4 s).
**Rejected — headless `claude -p` with a custom rendered panel (the first build):** it was always slow
(~1 min on a big chat) and we proved why. A `-p` fork sends a **different request prefix** (print mode's
system prompt/tools) than the interactive session, and the prompt cache is **prefix-matched** — so a headless
fork *cannot* read the live chat's warm cache and cold-prefills the whole context. Hard data: a `-p` fork of
a `-p`-**warm** parent is a *full* hit (≈237 k read / ~5 s), but of an interactive-warm parent it misses; the
only variable is the mode. (An earlier "752 k cold" reading was *also* confounded by the ~5-min cache TTL — a
separate trap.) Pre-warming on panel-open (fork + throwaway prompt while the user types) hid *some* of the
cold prefill but couldn't beat it when the user asks fast or the parent is cold, and it littered a large
fork transcript per open. The embedded interactive fork is faster (warm-cache reuse), natively smooth (it
*is* the CLI, so Esc interrupts, streaming/markdown are free), and *less* code. Cost: it's Claude's terminal
UI, not a styled Q&A panel. Forking a large/old chat shows Claude's native "Resume from summary/full" menu;
Quick Ask **auto-picks "full"** (full reuses the warm cache — a summary is freshly generated, so cold + lossy)
by watching the fork's screen and sending the option's **number** when the menu text appears. Subtlety: send
the digit *only* — the digit auto-confirms, and a trailing Enter would land on the input box and accept Claude's
ghost history suggestion, running a stray past command (we hit exactly that with `/compact`). Disk: each fork duplicates the
conversation on disk (~chat size) and Claude only auto-prunes after `cleanupPeriodDays` (default 30) — **open**:
delete an abandoned fork's transcript on New/close (not one promoted via Open as Tab). Verified by harness
(`dumpQuickAsk` → launch args + terminal text): Context → `--resume <cid> --fork-session`; Blank → no
`--resume`; Open as Tab → fork handed off to a real tab.

---

## Docker

### D24 — Docker panel is the shared bottom dock, not its own window
**Decision:** The Docker manager mounts into the **same bottom-dock container the quick terminal uses**
(`CenterViewController.showBottomDock`), and the two **share it** — opening one closes/vacates the other
(`DockerPanelController.show` ↔ `QuickTerminalController` `vacateDock`). Entry is a status-bar shippingbox
icon shown only when the daemon is reachable.
**Why:** A resizable dock under the editor is exactly the surface a service/volume table wants, and it
already existed. A separate window would duplicate the split/resize/focus plumbing and let Docker + the
quick terminal fight over screen space. "Share it" was explicitly fine for v1.
**Rejected:** a standalone Docker window; a sidebar segment (too narrow for a table with actions).

### D25 — Services come from `compose config`, and compose files are user-picked & persisted
**Decision:** The service list is whatever `docker compose config` defines for the **selected** compose
file(s) — never derived from `docker ps`. The user picks which compose files are active (a checklist +
"Add compose file…"), and the selection is saved per-repo in UserDefaults (default = base + auto-override).
`config --format json` yields both the names and which services have a `build:` context in one call (fallback
to `config --services`).
**Why (config not ps):** falling back to `ps` to list services surfaced **leftover/orphan containers** from a
previous compose revision as phantom services (the "phantom api" bug) — `config` is the source of truth for
what the project *defines*. **Why user-picked files:** real projects keep several root compose files (dev vs
prod env overrides); hard-coding "the" compose file works for no one. Saving the pick is just convenience —
the user attaches once and can switch later. **Why one JSON config call:** it gives names + build-context
together, so Build/Pull affordances can be gated (below) without a second subprocess.
**Rejected:** auto-merging every compose file in the root (wrong for prod/dev variants); listing services from
running containers (phantoms); a second `config` call just for build detection (perf).

### D26 — Live updates via the `docker events` stream; availability re-checked on activate — zero idle polling
**Decision:** While the panel is open, a single `docker events` subprocess (`DockerEvents`) pushes
container-state changes (debounced into one `ps`), filtered to the current project; it's **stopped on hide/
quit** so a closed panel does no work, and **auto-reconnects + re-snapshots** on a daemon restart. Daemon
*availability* is one `docker info` at startup and on each app-activate — no timer.
**Why:** Performance is the #1 bar (see the Performance section). Polling `ps` on an interval would burn CPU
at idle for a panel that's usually closed; the event stream is the event-driven equivalent of FSEvents (D5).
A socket drop is observable, so reconnect+re-snapshot replaces the need for a safety-net poll. App-activate is
the natural availability re-check because you start/stop Docker in another app. The cumulative `dockerCmdCount`
in the state dump is the guarantee's assertion handle — it must stay flat while idle.
**Rejected:** a 15 s fallback refresh timer (the stream drop is already observable, so it's pure idle cost);
polling availability on a timer.

### D27 — Actions run in a watchable PTY; Build/Pull/port affordances are gated so they're never no-ops
**Decision:** Every compose action runs in a real PTY (`TerminalStore.commandView`, `__cmd__` id) shown in a
peek overlay (live build/pull output, auto-revealed on failure, promotable to a tab), rather than captured
output. Per-service **Build/Rebuild** show only when the service has a `build:` context, **Pull** only when it
doesn't (`!hasBuild` ⟹ it has an `image:`), and the project Build/Pull buttons + the images cluster hide when
nothing qualifies. Published ports become **clickable links**; internal-only ports don't.
**Why:** `docker compose up --build` / `pull` produce long streaming output a user wants to watch (and to read
when it fails) — a PTY gives that for free and is consistent with the rest of the app. Gating means the row
never shows a button that would silently do nothing (build on an image-only service, pull on a build-only one,
"open" on an unpublished port) — the affordance present is always the one that applies. The per-row spinner
(`actingService`) gives immediate feedback and blocks a double-fire while one action's PTY is in flight.
**Rejected:** capturing action output into a styled log view (reinvents the terminal, loses streaming); showing
Build+Pull on every row (no-op buttons confuse); a hidden modifier (⌥-click) for rebuild — the user wanted the
options visible as buttons.

---

## Motion / animations

### D28 — One `Motion` helper; animate GPU layer properties, never layout
**Decision:** All app animation routes through a single `UI/Motion` enum — shared durations/curves plus one
Reduce-Motion gate (`NSWorkspace…accessibilityDisplayShouldReduceMotion`) so everything degrades to instant in
one place. The rule it enforces: animate only GPU-composited **layer** properties (`transform`, `opacity`,
`backgroundColor`) — **never** drive Auto Layout / view frames per frame.
- **Bottom-dock open/close** (`CenterViewController`): the dock is sized to its resting height in *one* layout
  pass, then its content slides via a layer `transform` (`Motion.slideY`) — open rises in, close slides down +
  fades, then detaches. The shared dock is also force-**emptied** across the close (`finalizeDockClose`, called
  up-front by `showBottomDock`) so opening the *other* occupant mid-close can't leave stale content stacked.
- **Centered overlays** (Quick Ask, centered quick terminal): scrim dim fades + box `transform.scale` 0.96→1
  (`presentOverlay`/`dismissOverlay`) — the macOS popover feel.
- **Hover** (`HoverRow` bg, `HoverIconButton` tint) crossfades; **button press** (`PointerButton.mouseDown`)
  scales to 0.92 while held via an *explicit* `transform.scale` animation.
- **Tab bar** (`TabBarView`): a persistent `selectionPill` behind the chips slides to the active chip's frame on
  selection change (jumps on tab add/remove/reorder, since chip positions shift); the active chip goes transparent
  so the pill is its only highlight. **Docker action peek** overlay reuses `presentOverlay`/`dismissOverlay`.
- **SESSIONS panel** collapse/expand glides the sidebar divider via `Motion.drive` (eased per-frame `setPosition`).
  This is the *one* place a per-frame divider drive is OK — both panes are plain AppKit (file tree + sessions
  list); the rule the dock taught us only forbids it when a pane holds a terminal.
- **Docker status dot** crossfades on state change: `renderServices` keeps the existing `DockerServiceRow`s when the
  service set/order is unchanged (the common live-event case) and calls `refresh` to rebuild contents + crossfade
  the dot from its old colour/shape; any structural change falls back to the proven full rebuild. (Row insert/remove
  animation was *not* done — it'd mean diffing the whole list, more risk than the payoff for a rare case.)
**Why:** the first cut animated the `NSSplitView` divider per frame — every step relaid out the split and
reflowed **both** SwiftTerm terminals (PTY `SIGWINCH` ×~24 in 200 ms), so it stuttered *and* burned CPU (the
#1 anti-goal). Transforms are GPU-composited: zero per-frame layout, zero PTY churn. The async close then
exposed a latent bug — the bottom dock is a *shared, persistent* container (quick terminal **or** Docker), and
nothing ever emptied it, so the next occupant rendered on top of stale content; `finalizeDockClose` makes the
empty-dock contract explicit.
**Gotchas:** layer-backed AppKit views suppress *implicit* CA animations — press uses an explicit animation, and
must reset to identity under Reduce Motion (else a press in flight when RM flips on stays shrunk). `transform.scale`
read back via KVC is an `NSNumber` → read as `Double`, not `CGFloat` (the latter doesn't bridge, dropping the
current scale so the spring-back jumps). Cursor/hover/press *feel* can't be harness-verified (the sandbox blocks
synthetic mouse) — those are HID-checked by the user (see D13/D17). For a *persistent* overlay toggled by the
render loop (the session-ended card), an idempotent `if intent == lastIntent { return }` guard is a trap: the
render observer fires on `objectWillChange` (pre-change), so an exit produces a stale show→hide→show flip that can
no-op the real reveal and leave the view `isHidden`. Key the reveal on actual `isHidden` state (self-correcting),
not the intent flag — keep the flag only to stop a dismiss-in-flight from hiding a re-shown view.
**Rejected:** animating the split divider position per frame (the stutter above); animating real view heights for
the dock (reflows the terminal continuously).

---

## How we work (process)

### D17 — User tests the dev build before we ship
**Decision:** The user personally tests a dev build before any release/tag.
**Why:** Cursor and rendering behavior can't be fully auto-verified (see D13); a human pass catches
what the harness can't.

### D18 — Root-cause fixes, plus self-verification tooling
**Decision:** Prefer the concrete root-cause fix over a narrow patch; build re-runnable tooling
(harness, measurements) to prove a fix rather than relying on "should work."
**Why:** Patches accrete into the kind of fragility that drove the AppKit rewrite in the first place.
