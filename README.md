<div align="center">

<img src="assets/icon.png" width="112" alt="Multee icon">

# Multee

**One window to run all your Claude Code sessions.**

[![Download](https://img.shields.io/github/v/release/Rudra370/multee?label=Download&color=2da44e)](https://github.com/Rudra370/multee/releases)
[![Platform](https://img.shields.io/badge/platform-macOS-111?logo=apple)](https://github.com/Rudra370/multee/releases)
[![App size](https://img.shields.io/badge/app%20size-under%206%20MB-2da44e)](#why-multee)

<img src="assets/hero.png" width="860" alt="Multee showing a syntax-highlighted file, a file tree, and two Claude Code sessions">

</div>

If you use **Claude Code** across more than one project — or run several sessions at once — Multee keeps
them all in a single, fast, native Mac app instead of a pile of terminal tabs. Open a project, start a
Claude session, and move between everything you're working on at a glance.

**Who it's for:** developers who live in Claude Code and want a calmer way to juggle multiple projects
and conversations side by side.

## Install

```sh
brew install --cask Rudra370/tap/multee
xattr -dr com.apple.quarantine "/Applications/Multee.app"
```

Then open **Multee** from your Applications folder.

> The second line is needed just once: the app isn't signed by a paid Apple Developer account yet, so
> macOS quarantines it on download. (You can also right-click the app → **Open** the first time.)

<details>
<summary><b>Update or uninstall</b></summary>

```sh
# update / reinstall
brew reinstall --cask Rudra370/tap/multee && xattr -dr com.apple.quarantine "/Applications/Multee.app"

# uninstall
brew uninstall --cask multee
```

</details>

## What you can do

- **Run many projects side by side** — each project is a session; switch between them instantly.
- **Tabs for everything** — Claude sessions, terminals, file viewers, and diffs, together in one window.
- **Know what needs you** — a colored dot per session shows whether Claude is working, waiting on you, or
  idle, with an optional sound and a menu-bar indicator when it finishes or needs attention.
- **Find & jump fast** — go to any file (⌘P), run any command (⌘⇧P), or search the whole project.
- **Browse & edit your code** — a git-aware file tree and a syntax-highlighted editor (~30 languages),
  with find/replace and format-on-save.
- **A terminal when you need one** — a quick terminal (⌃\`) with multiple shells, plus full terminal tabs.
- **Open any file** — images and icons (PNG/JPG/SVG/`.icns`) with zoom &amp; pan, and Markdown rendered as a
  formatted **preview** (headings, highlighted code, tables, inline images) with a source toggle.
- **Review &amp; ship** — stage, commit, discard, view diffs, and switch branches without leaving the app.
- **Pick up where you left off** — sessions, tabs, and Claude conversations come back when you reopen Multee.

## See it in action

### Many projects, one glance

<table>
  <tr>
    <td width="50%"><img src="assets/sessions.png" alt="Sessions sidebar with a colored status dot per project"></td>
    <td width="50%"><img src="assets/attention.png" alt="Menu-bar dropdown showing which session is working or waiting"></td>
  </tr>
  <tr>
    <td align="center"><b>Each project is a session — a dot shows working / waiting / idle</b></td>
    <td align="center"><b>The menu bar tells you who needs you, and jumps you there</b></td>
  </tr>
</table>

### Every kind of tab, in one window

<p align="center">
  <img src="assets/editor.png" width="880" alt="Editor with several tabs — Claude sessions, files — and a git-aware file tree"><br>
  <b>Claude sessions, terminals, files, and diffs together — syntax highlighting for ~30 languages</b>
</p>

### A terminal, your way

A quick terminal (⌃\`) with multiple shells you can add, switch, and pop out into a full tab — opened
however suits the moment.

<table>
  <tr>
    <td width="33%"><img src="assets/quick-floating.png" alt="Quick terminal as a floating window"></td>
    <td width="33%"><img src="assets/quick-centered.png" alt="Quick terminal as a centered overlay"></td>
    <td width="33%"><img src="assets/quick-bottom.png" alt="Quick terminal docked at the bottom of the editor"></td>
  </tr>
  <tr>
    <td align="center"><b>Floating window</b></td>
    <td align="center"><b>Centered overlay</b></td>
    <td align="center"><b>Bottom dock</b></td>
  </tr>
</table>

### Jump anywhere, fast

<table>
  <tr>
    <td width="50%"><img src="assets/palette.png" alt="Go to File quick-open, searching files by name"></td>
    <td width="50%"><img src="assets/commands.png" alt="Command palette listing actions like New Claude Session"></td>
  </tr>
  <tr>
    <td align="center"><b>Go to File — ⌘P</b></td>
    <td align="center"><b>Command Palette — ⌘⇧P</b></td>
  </tr>
</table>

<p align="center">
  <img src="assets/search.png" width="880" alt="Project-wide search results grouped by file"><br>
  <b>Search the whole project — with match-case, whole-word, and regex</b>
</p>

### From the status bar

<table>
  <tr>
    <td width="50%"><img src="assets/shortcuts.png" alt="Built-in keyboard shortcuts panel"></td>
    <td width="50%"><img src="assets/branch.png" alt="Branch menu: switch, create, or delete branches"></td>
  </tr>
  <tr>
    <td align="center"><b>Every shortcut, one keystroke away</b></td>
    <td align="center"><b>Create, switch &amp; delete git branches</b></td>
  </tr>
</table>

### Open any file

<table>
  <tr>
    <td width="50%"><img src="assets/markdown.png" alt="Markdown rendered preview with headings, a highlighted code block, and a table"></td>
    <td width="50%"><img src="assets/image-viewer.png" alt="Image viewer showing an icon with zoom and pan"></td>
  </tr>
  <tr>
    <td align="center"><b>Markdown, rendered</b></td>
    <td align="center"><b>Images, icons &amp; SVG — zoom &amp; pan</b></td>
  </tr>
</table>

### Review &amp; commit

<table>
  <tr>
    <td width="50%"><img src="assets/changes.png" alt="Git changes panel: stage, commit, discard"></td>
    <td width="50%"><img src="assets/diff.png" alt="Side-by-side diff view"></td>
  </tr>
  <tr>
    <td align="center"><b>Stage, commit &amp; discard</b></td>
    <td align="center"><b>Side-by-side diffs</b></td>
  </tr>
</table>

### Make it yours

<table>
  <tr>
    <td width="50%"><img src="assets/settings.png" alt="Settings: auto-launch Claude, default args, font size, quick-terminal placement"></td>
    <td width="50%"><img src="assets/formatters.png" alt="Formatters settings: format on save with Prettier, gofmt, rustfmt, Ruff, and more"></td>
  </tr>
  <tr>
    <td align="center"><b>Auto-launch, default args, font, quick-terminal placement</b></td>
    <td align="center"><b>Format on save with the tools you already use</b></td>
  </tr>
</table>

## Why Multee

- **Tiny.** The whole app is under 6 MB.
- **Fast and light.** Built natively for macOS (pure AppKit — no Electron, no bundled browser), so it
  sips memory and sits at near-zero CPU when you're not doing anything.
- **Feels like a Mac app.** Native menus, cursors, and windows that behave exactly the way you expect.

---

<sub>For developers: see **[CLAUDE.md](CLAUDE.md)** to build &amp; contribute, **[FEATURES.md](FEATURES.md)**
for how each feature works, and **[DECISIONS.md](DECISIONS.md)** for why it's built this way.</sub>
