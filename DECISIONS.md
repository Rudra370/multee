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
  list); the rule the dock taught us only forbids it when a pane holds a terminal. **Gotcha:** the pane had a
  `viewDidLayout` "never let it vanish" self-heal that slammed the divider whenever the sessions pane was tiny —
  which is exactly the transient mid-glide state, so it fought the expand. Gate any such layout self-heal on
  "no animation in flight" (`collapseDriver == nil`).
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

### D29 — Self-update refreshes only our tap, with a timeout and an honest failure state
**Decision:** `Updates.installNow` no longer runs a global `brew update`. It refreshes **only** the cask's own tap
(`git -C "$(brew --repository Rudra370/tap)" fetch … && reset --hard FETCH_HEAD`), then `HOMEBREW_NO_AUTO_UPDATE=1
NONINTERACTIVE=1 brew upgrade --cask --force`. The network steps are wrapped in a portable timeout
(`perl -e 'alarm shift @ARGV; exec @ARGV' <secs>` — macOS ships no `timeout`): 30 s for the tap fetch, 180 s for the
upgrade. The command writes exactly one marker — `.done` on success → auto-relaunch, `.fail` on any failure/timeout/
cancel — and the watcher surfaces a **"Update failed — Retry"** banner instead of polling silently for 15 min.
**Why:** `brew update` re-fetches *every* tap the user has. A real user (the maintainer) had an unrelated tap
(`stripe/stripe-cli`) whose `git fetch` to GitHub stalled during a flaky-network moment; git-over-HTTPS has no
default connect timeout, so the whole self-update hung at "Updating Homebrew…" — before Multee's part even started —
and the old watcher just spun for 15 min then gave up with no feedback. Diagnosed live via the process tree (`ps`
showed the stuck `git-remote-https …/stripe/homebrew-stripe-cli`) and per-URL `curl` timing (github.com fast, that
tap's connection timed out at the connect stage). Refreshing only our tap removes the avoidable hang entirely; the
timeout bounds the unavoidable case (a stalled *download* of our own asset) to seconds instead of brew's minutes-long
internal retries; the `.fail` marker turns "frozen forever" into a one-click Retry. The whole chain runs with stdin
from `/dev/null`: Homebrew's `--ask`/`HOMEBREW_ASK` "proceed? [y/n]" confirmation is gated on a TTY (`ask.rb`:
`return false if !$stdin.tty?`) and is **not** suppressed by `NONINTERACTIVE` — a user with ask-mode on would
otherwise hang the unattended upgrade on an invisible prompt; a non-TTY stdin skips it (and blocks git credential
prompts too). `perl alarm` verified on macOS
(killed `sleep 10` at 2.0 s, exit 142; fast commands pass through); marker logic and the scoped fetch verified by
re-runnable harness. The real `brew upgrade` end-to-end isn't auto-verifiable without a live upgrade (see D17).
**Rejected:** keeping the global `brew update` but adding `GIT_HTTP_LOW_SPEED_*` env (only catches mid-transfer
stalls, not a connect stall); untapping unrelated taps (not ours to touch); a full rearchitecture away from shelling
out to brew in a PTY (the terminal approach is intentional — the user watches it run).

### D30 — Hiding the Files panel tears the git stack down; sidebar width is per mode
**Decision:** ⌘B / the Settings checkbox (`Settings.showFilesPanel`) removes the FILES pane from the sidebar
split entirely and **destroys the session's `RepoStore`** — no FSEvents watcher, no git poll — instead of
hiding a view that keeps polling. The status bar's branch, which the store normally bridges, is then fetched
once per repo (`fetchBranchOnce`). ⌘⇧F falls back to a project-search **tab**. The outer split's width is
remembered under two keys (`sidebarWidthFiles` / `sidebarWidthSessions`) and AppKit's `autosaveName` was
**dropped** from that split.
**Why:** The feature exists for people who never browse files here, and for them the point is that the app
stops watching the repo — a hidden-but-live tree would keep an FSEvents watcher and a poll timer per session,
against the performance goal. Removing the pane (rather than `isHidden`) keeps `NSSplitView` honest: a hidden
arranged subview still owns a divider. Two width keys because a files+sessions sidebar wants ~320pt while a
sessions-only one is comfortable at ~260 — one shared number leaves a half-empty column after every toggle.
Shortcuts that only existed inside the panel must land somewhere real, hence the search tab (the `.search`
tab kind already existed for "Open as Tab").
**Gotchas that shaped the code** (both cost a debugging round, both are load-bearing):
`NSSplitView`'s **autosave restores its position *after* the first `viewDidLayout`**, so a width applied there
is silently overwritten at launch — and `viewDidLayout` then never fires again for later window sizing, so
convergence has to live in `splitViewDidResizeSubviews`. That notification is **delivered asynchronously**,
so a "we're moving the divider ourselves" flag around `setPosition` doesn't catch it; our own moves are
recognised by landing exactly on the computed target (or on the width AppKit's constraints substituted for
it — `clamp` subtracts `dividerThickness` so it agrees with `constrainMinCoordinate`), and a window resize
(total width changed) re-asserts the remembered width instead of storing the squeezed one.
**Verified:** harness runs — launch/toggle/round-trip widths, simulated drags (`sidebarDrag`), ⌘B through the
real menu (`menuKey:b`), branch with no poller across a session switch, search-tab fallback + dedupe, ⌘P
with the panel off, no-session toggling, and toggling while the Search/Changes segments are live.

### D31 — The update timeout is a freeze backstop, not a speed limit
**Decision:** The self-update chain now runs `brew fetch --cask` before `brew upgrade`, gives each step a
**600s** alarm (was one 180s alarm over the whole upgrade), passes `--verbose` and `--no-ask`, and reports a
distinct **"Update timed out — slow connection"** state (a `.timeout` marker, written when a step exits 142 =
128 + SIGALRM) instead of blaming GitHub.
**Why:** A real report: the update sat at "Upgrading 1 outdated package:" and then failed with *"couldn't
reach GitHub"*. It was neither hung nor unreachable — on that link a **dual-stack connect stalls ~10s** before
falling back (measured: `curl -4` 1.07s, `curl -6` 1.09s, plain `curl` 10.9s with 10.03s in connect), so a
cold cask download took **~78s** of wall time with **zero output** — Homebrew passes curl `--silent` when
stdout isn't a TTY and shows no progress line before the transfer. Several such requests blew past the 180s
cap, the alarm killed a *working* upgrade, and the banner told the user the opposite of the truth. Fetching
first puts the slow part under its own budget (the upgrade that follows is cache-warm: measured **3.0s**);
`--verbose` keeps curl's meter on screen; the marker split makes the message honest.
**Also:** Homebrew 6 flipped the confirmation prompt to **on by default** (`cmd/upgrade.rb`:
`ask = !args.no_ask? && !args.dry_run?`), and merely reaching it costs a full dry-run planning pass — that's
the `==> Would upgrade …` block users saw before the real run. `--no-ask` skips it, but it's detected at
runtime (`brew upgrade --help | grep -q -- '--no-ask'`) because older brews reject an unknown flag. The
`< /dev/null` guard from D29 still does the real work of suppressing the prompt (`Ask.confirm?` returns false
off a TTY).
**Verified:** the marker branch exercised for all three outcomes (success → `.done`, exit 1 → `.fail`,
SIGALRM → `.timeout`), the composed command dumped from the app (`dumpUpdateCmd`) and run end-to-end for real
(0.1.19 → 0.1.20 in 3.0s, `.done` written, Info.plist reads 0.1.20), and the new banner state rendered via
`updateBanner:timeout`.
**Note:** a self-updater only fixes *future* updates — the version doing the updating is the old one, so this
lands for anyone updating **from 0.1.21 onward**.

---

## Chat tab

### D32 — A native chat tab over `claude -p` stream-json, beside (not instead of) the terminal tab
**Decision:** The chat tab drives the unmodified `claude` binary in print mode with stream-json in and out
and `--permission-prompt-tool stdio`, one long-lived process per tab. It's a new tab kind; terminal Claude
tabs are untouched, and a tab can switch between the two (same conversation id).
**Why:** Rendering the conversation ourselves is the only way to get a fast, customizable UI (the status
line, a background-task manager, native prompts). The stream-json protocol is what Claude's own SDK speaks,
so hooks, skills, CLAUDE.md, subagents, resume and compaction all keep working, and the user's own
subscription login is used as-is. Verified live (2.1.278): control requests `initialize`, `interrupt`,
`set_model`, `set_permission_mode`, `stop_task`, `get_context_usage`; `can_use_tool` for permissions,
AskUserQuestion and ExitPlanMode; `background_tasks_changed` / `task_*` events; `-p --resume` keeps the
session id and persists even pure-text transcripts.
**Rejected:** scraping the terminal UI (fragile, no structure); the Agent SDK in a sidecar (another
runtime to ship for the same protocol); calling the API directly (loses Claude Code's tools and settings,
and subscription auth).
**Costs accepted:** the control protocol is undocumented, so a CLI update can break it (the harness actions
make a regression quick to see). Moving a conversation between chat and terminal costs one uncached turn
(different prompt prefixes — D23). Some terminal-only commands (`/rewind`, `/permissions`, editors) aren't
available in chat; "Open in Terminal" is the escape hatch. **Status: open** — distributing this in a public
build: Anthropic's terms bar third-party apps from *offering* claude.ai login, but this only runs the user's
own signed-in CLI; confirm before release.

### D33 — Exact row heights in a hand-rolled virtual list (rejected: NSTableView, one big NSTextView)
**Decision:** The transcript is our own virtual list. Each row's height is measured with the same TextKit 1
stack the row draws with, before the row is shown; rows reconcile with the session by item id; large
batches are rendered and measured off-main in parallel.
**Why:** Scroll-up lag in long chats comes from *estimated* heights corrected during scrolling (measured:
NSTableView estimates even with `heightOfRow`; up to 563,000 pt content jumps). Exact heights make the
content height true, so scrolling is just moving a clip view. Measured on a 200 MB transcript: 0 jumps,
p50 0.9 ms per frame. A custom list also avoids the undocumented `NSTableViewCanEstimateRowHeights`
default, which would have been app-wide.
**Rejected:** one big NSTextView (re-estimates layout; 250–480 ms jumps); auto-layout rows (thousands of
jumps); NSTableView + the defaults key (works, but global and undocumented).
**Learned the hard way:** (1) never let a newer measuring pass cancel an older one — rows went missing
(10,255 items / 9,264 rows) until reconciliation by id replaced "generation" dropping; (2) a Markdown
paragraph must always consume its first line — a line like `#tag` looked like a block start, and the loop
spun forever (the `chatMarkdownSelfTest` harness action pins 34 such cases); (3) text from
`JSONSerialization` is a bridged NSString — render native Swift strings (`.native`), per-character Swift
ops on bridged strings are ~100× slower; (4) streaming must replace only the text's tail — replacing the
whole string repainted the entire message layer each update (30% CPU → 12%, now below a terminal tab's).

### D34 — A chat tab asks for folder trust, because print mode doesn't
**Decision:** Before a chat's first launch in a folder, `ChatTrust` checks Claude's own
`~/.claude.json` (`projects[<exact path>].hasTrustDialogAccepted`) and our own list; if neither trusts the
folder, the chat shows a "Trust folder & start" card naming the folder's own Claude settings (hooks,
pre-approved tool rules).
**Why:** `claude -p` skips the terminal UI's trust dialog, so a chat would otherwise load an untrusted repo's
`.claude/settings*.json` silently. Exact-path only: the user's config trusts `/`, yet Claude still prompted
for a subfolder — Claude doesn't inherit trust from parents, so neither do we. We record our own trust in
Multee's defaults and never write `~/.claude.json`, which live Claude processes also write.

### D36 — Resume, Remote Control, effort and bypass via Claude's control protocol
**Decision:** Print mode refuses `/resume` and has no `/remote-control`, so the chat does them itself:
resume lists `~/.claude/projects/<encoded cwd>/*.jsonl` and relaunches the tab with `--resume <id>`;
Remote Control sends the `remote_control` control request (`enabled`, optional `name`) and shows the
returned `session_url`; effort and fast mode go through `apply_flag_settings` (`effortLevel`, `fastMode`).
Every chat launches with `--allow-dangerously-skip-permissions` so bypass is a mode you can pick (the
terminal UI's flag for exactly that); turning it on asks once per install.
**Why:** all verified live against 2.1.278 (the schemas are in the CLI's own bundle: `remote_control`,
`apply_flag_settings`, `list_models`, `control_cancel_request`, `rewind_files`, …). The model *list* is the
same five the terminal's `/model` shows — what the chat menu lacked was the picker's effort control, fast
mode, and "other model". `control_cancel_request` (a prompt answered elsewhere, e.g. from Remote Control)
removes the local card.
**Status:** `rewind_files` is used by /rewind — see D37.

### D37 — /rewind through Claude's rewind requests; history shows the live branch only
**Decision:** Every user message the chat sends carries its own `uuid` (Claude keeps it as the message id).
/rewind runs `rewind_files` (a dry run for the dialog's "N files changed", then for real) and
`rewind_conversation` (Claude cuts its conversation in place and returns the message text to prefill). Chats
launch with `CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING=1` — print mode keeps no file checkpoints otherwise.
Chat history follows the transcript's `parentUuid` chain from its leaf (the last message, or an explicit
`last-prompt` marker a rewind writes after it) — the branch Claude itself resumes. Each rewind also names the
newest message the chat sent (`last_seen_user_message_uuid`); without it Claude only rewinds to the latest
message ("stale target"), a guard against wiping turns a client never showed.
**Why:** verified live on 2.1.278: both requests work in print mode, the cut survives a resume, and a
transcript is a tree — undone messages (and prompts you retracted with esc before a reply) stay in the
file. Reading it linearly would show messages Claude no longer has. Rejected: relaunching with
`--resume <id> --resume-session-at <uuid>` (a restart — drops the warm process and its background tasks).
/fork uses `--resume <id> --fork-session` in a new chat tab (the `fork_conversation` request needs a Remote
Control server) and names the fork with `rename_session`, so `ClaudeTranscript.title` now prefers
`custom-title` over `ai-title`.
**Status:** built. Rewind reaches past a compaction only while the process that compacted is still running —
it keeps the full messages in memory; a restarted (`--resume`d) process loads only what follows the compaction
and answers `target_not_found` (measured). So the picker stops at the last compaction this process *read from
the file*, not at the last one on screen.

### D38 — `!` shell mode runs in Multee; its output reaches Claude as the terminal UI records it
**Decision:** A chat's `!command` runs in your `$SHELL -c` in the chat's folder (120 s cap, esc stops it) and
shows as a shell row. The command and output then go to Claude as two user messages in the terminal UI's own
format (`<bash-input>…`, `<bash-stdout>…<bash-stderr>…`) with `shouldQuery: false`, so they join the
conversation without a model call; a failure adds "[exit code N]" (Claude sees it; history reads it back —
the transcript keeps no exit status). `/btw` uses the `side_question` control request; `/plan open` uses
`get_plan`.
**Why:** verified on 2.1.278: print mode has no bash mode, but a `shouldQuery: false` message lands in
context (Claude then quotes the output) at zero model cost. Its empty turn (`init` → `result`) is matched by
uuid through `command_lifecycle`, so the chat doesn't flash "working"/"done" — and when Claude merges it with
a real queued message, that turn is treated as real.

### D39 — Pasted images: the box claims the image clipboard types, a marker is one character, the transcript draws the picture
**Decision:** `ChatInputTextView` adds the image types to `readablePasteboardTypes`. In the box an
`[Image #n]` marker behaves as a single character — the caret steps over it, and backspace, ⌦ or any edit
touching part of it takes the whole marker and drops its image. The markers in the text are the record:
numbering comes from the highest marker present, an attachment whose marker is gone is released, and a
marker no attachment claims is stripped when the message is sent. A sent message shows a ~200pt thumbnail
(an `NSTextAttachment` in the row's attributed string) instead of the marker, rebuilt from the transcript's
base64 blocks when the chat is reopened.
**Why:** ⌘V is the Edit menu's key equivalent, and AppKit greys that item out — swallowing the keystroke —
when the focused view lists nothing on the clipboard as readable; a plain-text `NSTextView` lists only text,
so an image-only clipboard was a silent no-op (a Finder copy worked only because it carries the filename as
text). Editing the marker's text ourselves was worse than letting AppKit do it: a plain backspace is not
undoable in an `NSTextView`, so a custom edit put the deletion on the undo stack and ⌘Z brought the marker
back without its image. Drawing the image as a text attachment keeps the transcript's exact-height measuring
pass (D33) covering it with no change to the virtual list. Thumbnails come from ImageIO, which decodes
straight to size and is safe off the main thread — history is parsed on a background queue.
**Status:** built. 57 real transcripts (to 64 MB) still parse in ≤25 ms each with images decoded.

### D40 — A closed tab is hung up on, not asked to stop
**Decision:** `TerminalStore.close` captures the child's pid before `terminate()`, then `ProcessEnd` sends
`SIGHUP` to its process group, `SIGKILL`s anything still alive 1.5 s later, and reaps it. `applicationWillTerminate`
does the same for every open PTY. A view whose process already exited is never signalled.
**Why:** SwiftTerm's `terminate()` is `kill(shellPid, SIGTERM)`, and an interactive shell ignores SIGTERM —
measured: closing three terminal tabs left three live shells and three leaked pseudo-terminal descriptors,
and a four-day-old Multee carried nine `<defunct>` children. A hangup is what a closing terminal actually
means, the group reaches the `node` and MCP processes Claude started, and once the child is gone the
descriptor sees EOF and closes itself — so the fd leak needed no separate fix. Rejected: forking SwiftTerm
(this is five lines at the call site), and closing the descriptor ourselves (DispatchIO still owns it —
their own comment warns that closing underneath it crashes).
**Status:** built and verified — three terminal tabs opened and closed return the app's open-PTY count to
baseline with no survivor and no `Z`; a Claude tab takes its `npm exec @playwright/mcp` child with it;
quitting with three tabs open leaves nothing behind.

### D41 — The chat holds queued messages itself and sends one per turn
**Decision:** A message sent while Claude works waits in `ChatSession.queued` and goes to Claude only when the
running turn ends (`sendNextQueued`, esc'd turns included), one per turn. Editing one (↑ ⏎) just takes it out.
**Why:** Claude merges everything in its own queue into one user message when its next turn starts — measured
with no `priority` and with `next` and `later`: three questions, one message, one answer. The user wants an answer
each. Held here, the queue is also trivially editable (earlier builds withdrew with `cancel_async_message` and had
to handle "already started"). **Cost, accepted:** Claude can no longer fold a message into a turn still running
at a tool boundary (mid-task steering) — the correction waits for the turn, or esc first.
**Status:** built — three queued, the middle one taken back: the other two got a turn and an answer each; a queued
message sent after an esc'd turn runs on its own.

### D43 — Chat voice speaks Claude Code's private `voice_stream` protocol
**Decision:** The chat's dictation streams the mic to `wss://api.anthropic.com/api/ws/speech_to_text/voice_stream`
exactly as the terminal UI does (query, headers incl. `User-Agent: claude-cli/<installed version>`, KeepAlive /
CloseStream, `TranscriptText`/`TranscriptEndpoint`), with the claude.ai token read from Claude Code's Keychain item.
**Why:** The user wanted Claude's own transcription, not Apple's. `claude -p` has no voice, so there is no public
route. Protocol read from the CLI's bundled JS (2.1.280) and proven with a standalone probe before building.
**Costs, accepted:** a private endpoint can change with any Claude Code release (the terminal's voice keeps working
then; ours breaks); we never refresh the token (that would race Claude's own copy) — an expired one asks you to use
a Claude tab once. The token is read through `/usr/bin/security` (0.02 s) because the item trusts it; Multee's own
`SecItemCopyMatching` took ~3.7 s every call on an ad-hoc-signed build.
**Status:** built — file-fed harness runs transcribe exactly; real mic + fn⌃ need a human.

### D35 — Chat processes drop a parent Claude session's environment markers
**Decision:** A chat's `claude` is launched without `CLAUDECODE`, `CLAUDE_CODE_SESSION_ID`,
`CLAUDE_CODE_CHILD_SESSION`, `CLAUDE_EFFORT` and the other per-session markers.
**Why:** When Multee itself is started from inside a Claude Code session (how the dev build is driven), those
leak into every child and Claude treats the tab as that session's child — e.g. "Transcript saving is off".
A chat is its own session. **Status: open** — terminal Claude tabs inherit the same markers today
(`Env.array`); same fix proposed separately.

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
