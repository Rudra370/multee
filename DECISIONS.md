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
