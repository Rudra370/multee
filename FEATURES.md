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
Cmd+W closes the active tab. Persistence: JSON snapshot in UserDefaults, debounce-saved; restore
drops repos whose folder is gone.

## Terminal — `Terminal/`
`TerminalStore` caches one SwiftTerm PTY view per tab id (process survives tab/session switches).
Login-shell PATH via `Env.bootstrap`. Claude launches with `--settings <hooks>` + env; a shared
scroll monitor routes wheel/trackpad events (incl. alt-buffer SGR forwarding) to the terminal under
the cursor. Claude `--resume <cid>` only when its transcript still exists on disk.

## File tree — `UI/FileTree`, `Backend/Git`
`NSOutlineView` with git-status colors, collapsed gitignored dirs (expand toggle), 1.5s poll that
reloads only on change and preserves expansion by path. Click a leaf to open it.

## Editor — `UI/Editor`
`NSTextView` + Highlightr `CodeAttributedString` (language by extension, atom-one-dark). Cmd+S saves;
edits flag the tab dirty (chip dot). Shared font size live-applies with in-place run resize.

## Changes & diff — `UI/Changes`, `UI/Diff`
`ChangesModel` polls staged/unstaged; the view has a commit bar (Commit / Commit & Push), section +
per-row git actions (stage/unstage/discard/stash/unstash), NSAlert confirms. Diff is an NSTableView
rendering `computeDiff` (stdlib Myers) rows, unified or split, with add/del row colors. A Files/Changes
segmented toggle (persisted) swaps the tree and changes views in the sidebar.

## Status board — `Terminal/HookServer`, `App/AppDelegate`
Claude hooks `curl` a local `NWListener` with the tab id + state; routed to per-tab/session dots
(needs > working > idle), with an attention/completion `NSSound`.

## Settings & updates — `UI/SettingsWindow`, `UI/Updates`
Settings window (native controls) bound to `Settings`. Update checker hits the GitHub latest-release
API; a top banner offers Homebrew self-update (runs `brew upgrade` in an in-app terminal) or Download.

## Deferred (v0.1.1 polish)
Collapsible SESSIONS panel; drag-reorder tabs; per-button hand cursor. None are functional blockers.
