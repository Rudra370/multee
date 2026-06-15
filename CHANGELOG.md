# Changelog

Notable changes to Multee. **A version's section here becomes that release's GitHub description and
the in-app "What's new."** Writing one is *optional*: if you add a `## [version]` block before
tagging, those polished notes are used; if you skip it, the release auto-generates notes from the
commits/PRs since the last tag. Newest first.

## [0.1.11] - 2026-06-15

### Added
- **Project search (⌘⇧F)** — VS Code-style search across the active session's repo. **⌘⇧F** (or the command
  palette → **Find in Files…**) opens the **Search** section in the sidebar (a new third icon next to Files /
  Changes); type to search, with **Match Case**, **Whole Word**, and **Regular Expression** toggles and a live
  result count. Results group by file (matches highlighted); click one to **open the file at that line**. It
  uses `git grep`, so it respects `.gitignore` and needs nothing installed.
- **Search as a tab** — the search panel has an **Open-as-Tab** button that promotes the current search to a
  full-width tab (carrying your query + toggles). You can open **several** search tabs at once.
- Opening a search hit in a **Markdown** or **SVG** file now switches to its **Source** (where the match is),
  instead of the rendered preview.

### Changed
- **Format Document** moved to **⇧⌥F** (it was ⌘⇧F), freeing ⌘⇧F for Find in Files — matching VS Code.

## [0.1.10] - 2026-06-15

### Added
- **Status bar** — a bar across the bottom of the editor/terminal area showing, at a glance: the current
  **git branch**, and for a file: the **cursor position** (Ln/Col), **indentation** (spaces/tabs), **line
  ending** (LF/CRLF), and **language**. Optionally the app's **memory · CPU** (Settings → Show resource
  monitor; it moved here from the title bar). Every item is **clickable**:
  - **Branch** → switch branches, create a new one, or delete one (always asks first; warns before deleting
    an unmerged branch).
  - **Cursor** → Go to Line. **Indentation** → convert to tabs or 2/4/8 spaces. **Line ending** → switch
    LF/CRLF. **Language** → override the syntax highlighting for the open file.
  - The bar scales with your font size (⌘ +/−).

### Changed
- Opening a file now puts the cursor at the **top** of the file instead of the bottom.

## [0.1.9] - 2026-06-15

### Added
- **Command palette (⌘P)** — a VS Code-style quick-open. Press **⌘P**, type part of a filename, and fuzzy-
  matched files appear (matched letters highlighted, git-status colored); arrow keys to move, Enter to open.
  An empty query lists your open files. Two more modes from the same field: type **`:123`** to jump to a line
  in the current file, or **`>`** (also **⌘⇧P**) for **commands** — New Claude Session, New Terminal, Format
  Document, Go to File…, Settings, Close Tab.
- **Find & Replace in the editor (⌘F)** — a find bar floats at the editor's top-right with **Match Case**,
  **Whole Word**, and **Regular Expression** toggles (which the previous build couldn't do), a live match
  count, and next/previous (**⏎** / **⇧⏎**). Expand it (or **⌥⌘F**) for **Replace** / **Replace All** — regex
  replacements support `$1` capture groups. Your toggle choices are remembered across files and launches.

### Fixed
- **Go to line** now scrolls to and centers the target line instead of jumping to the bottom.
- **Opening a file focuses its editor** — you can type, search, or jump right away without clicking in first.

## [0.1.8] - 2026-06-14

### Added
- **Code formatting** — press **⌘⇧F** (or right-click → **Format Document**) to format the current file
  with the matching formatter installed on your machine: Prettier (JS/TS/JSON/CSS/HTML/Markdown/YAML…),
  gofmt, rustfmt, Ruff, swift-format, clang-format. Markdown and SVG format their Source. Your cursor
  stays put and it's a single undo. Multee uses a project-local tool (`node_modules/.bin`) when present.
- **One-click install** — if a file's formatter isn't installed, Multee offers to install it for you in a
  Terminal tab (Homebrew where available, else the tool's own installer) so you can watch it run.
- **Formatters settings** — Settings now has a **Formatters** tab listing each formatter with its install
  status, an Install button, and an on/off toggle. A **Format on save** option (off by default) formats
  every time you save.

## [0.1.7] - 2026-06-14

### Added
- **Unsaved-changes guard** — closing a tab, closing a folder, or quitting with unsaved editor changes
  now asks first instead of silently discarding them (one file: **Save & Close** / **Cancel** /
  **Don't Save & Close**; several: **Save All** / **Cancel** / **Discard**). The red close button is
  covered too.
- **Notifications when a background session needs you** — when a Claude session needs input or finishes
  while you're not looking at that tab (Multee in the background, or you're in another session), you get a
  macOS notification titled with the folder name; click it to jump straight to that session and tab. Toggle
  in Settings (on by default), which also warns — with a one-click link to System Settings — if macOS
  notifications are turned off for Multee.

## [0.1.6] - 2026-06-14

### Added
- **Line numbers in the editor** — a VS Code-style gutter on the left of every file you open. It tracks
  scrolling and the font size (⌘ +/−), numbers wrapped lines once, and highlights the current line.
- **Edit Markdown & SVG** — the **Source** view for `.md` files and the **Source** view for `.svg` files
  are now fully editable (syntax-highlighted, ⌘S to save, unsaved indicator), not just read-only. Switch
  back to **Preview** / **Image** and it re-renders with your changes immediately. Renaming a file while
  you have unsaved edits keeps them. Raster images stay view-only.

### Changed
- Markdown's **Preview / Source** toggle moved to the bottom-right, matching the SVG viewer's bar.

## [0.1.5] - 2026-06-14

### Added
- **File-tree toolbar** — new file, new folder, and collapse-all, right above the tree (like VS Code's
  Explorer). New files and folders are **named inline in the tree**; type the name and press Return.
- **Right-click menu in the tree** — rename (inline), delete (to the Trash), new file / new folder, and
  **Copy Path / Copy Relative Path**, contextual to the row you click.
- **Copy Path / Copy Relative Path on file tabs** — right-click an open file's tab in the top bar.
- **Open tabs follow file changes** — rename a file that's open and its tab + editor follow the new
  name (unsaved edits kept, saves go to the new path); delete a file and its tab closes.
- **Auto-reveal the active file** — switching tabs expands the tree to the current file and highlights it.

### Fixed
- **Syntax highlighting** — fixed a case where one line could turn the rest of a file a single colour,
  and toned down the over-aggressive red on member access (`.foo`).
- **File tree** — deleted files no longer linger in the tree (they show only in Changes); the
  pointing-hand cursor no longer goes stale after using the toolbar; rows fill the full width when
  folders are expanded.
- **Creating inside a folder** — the inline name field no longer vanishes when you add a file or folder
  inside an empty or collapsed folder.
- **Empty folders** — always show in the tree now (even ones made earlier, externally, or in another
  session), so you can open and add files to them.

## [0.1.4] - 2026-06-13

### Added
- **Image viewer** — open images and icons (PNG, JPG, GIF, WebP, HEIC, SVG, `.icns`, …) with zoom, pan,
  and fit-to-window, instead of seeing them as raw bytes.
- **Markdown preview** — `.md` / `.markdown` files render as formatted documents (headings, **bold** /
  *italic*, lists, blockquotes, code blocks with syntax highlighting, tables, inline images, links),
  with a **Preview / Source** toggle.

## [0.1.3] - 2026-06-12

### Added
- **Drag to reorder tabs** — drag a tab left or right to rearrange it within a session.

### Fixed
- **Session status dots update live** — a session's working/idle dot no longer waits until you switch
  sessions to refresh.
- **Sessions resume on reopen** — projects whose path contains `_` or `.` now resume their Claude
  conversation instead of starting fresh.
- **New Claude tabs respect your default arguments** — the **+New Claude** button and the **Default**
  menu item now use the default args from Settings.

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
