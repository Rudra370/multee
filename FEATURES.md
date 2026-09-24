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
Both the **tab chips** and the **SESSIONS rows** drag-to-reorder (`.multeeTab` / `.multeeSession`, an insertion
drop-line, a closed-hand cursor mid-drag); `AppModel.moveSession` reorders the array and the new order persists
(the snapshot saves sessions in array order). The session row's name is a plain label (not a button) so the whole
row distinguishes click-to-select from drag-to-reorder, mirroring the tab chip.

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

## Chat tab (native Claude UI) — `Chat/`, `UI/CenterViewController`, `UI/TabBarView`
A **Chat** tab is Claude Code rendered natively instead of in a terminal — a new tab kind (`TabKind.chat`)
*next to* the terminal Claude tab, not a replacement. New Chat: the tab-bar bubbles icon, File ▸ New Claude
Chat (**⌘⇧M**), or the palette. It runs the unmodified `claude` CLI in print mode over stream-json
(`claude -p --input-format stream-json --output-format stream-json --verbose --include-partial-messages
--permission-prompt-tool stdio`), one process per tab, spawned lazily when the tab is first shown and
killed with the tab/session/app (SIGTERM — Claude then stops the background tasks it started).
- **Transport** — `ClaudeStream`: JSON lines both ways, parsing off-main, writes on a serial queue,
  `SIGPIPE` ignored, exit reported only after stdout drains. Control requests: `initialize` (slash commands
  with descriptions, models, account), `interrupt`, `set_model`, `set_permission_mode`, `stop_task`,
  `get_context_usage`. Claude's `can_use_tool` requests become the prompt card.
- **Model** — `ChatSession` reduces stream events into `ChatItem`s (user, assistant markdown, tool calls
  with results, notices) and chrome state; `ChatStore` holds one per tab (the chat `TerminalStore`).
  Status/id/first-prompt route through the same closures as Claude-tab hooks (`ChatStore.onStatus` →
  `HookServer.onStatus`), so the status dot, "done" attention, notifications, tab naming and `--resume`
  id capture all just work.
- **Transcript** — `ChatTranscriptView`: a hand-rolled virtual list (prefix-sum offsets, binary-searched
  visible range, pooled rows). Every row height is measured *exactly* with the same TextKit 1 stack the row
  draws with (`ChatMeasurer`), so nothing is estimated and later corrected — the cause of scroll-up lag in
  long chats. Rows reconcile with the session by item id (`syncRows`), large batches render+measure
  off-main in parallel. Streaming updates only the changed row (~16/s), replacing just the tail of its text.
  Follows the bottom unless you scroll up (then a ↓ button). History: a resumed tab reads Claude's
  transcript tail (2 MB chunks) and loads earlier chunks when you reach the top.
- **Jump rail** — `ChatJumpRail`: one thin line per message you sent, evenly spaced up from the transcript's
  bottom-left corner (newest lowest, squeezed closer when they don't fit), the one you're reading brighter —
  the last one starting above 40% down the view, or on screen at the bottom, or the one you just jumped to.
  Hovering (0.15 s) opens `ChatJumpList` beside it (fades in while sliding out from the rail, 0.14 s; fades out in
  0.08 s). **⌘J** (View ▸ Jump to Message) opens it with keyboard focus — ↑↓ (home/end) move a selection that
  starts on the message you're reading, ⏎ jumps there, esc or ⌘J closes; focus returns to where it was. A
  hover-opened list leaves focus alone., the transcript's full height on a slightly see-through
  background: a one-line preview of each, the rows level with the lines; a row or a line glides that message
  to 35% down the view (0.35 s; a long way off it snaps to a screen short first; instant under Reduce Motion)
  and blinks its bubble blue twice over ~2 s. While it's open the transcript's text drops its I-beam (see CLAUDE.md). Shown from two messages
  up; covers the messages loaded so far (earlier history loads as you scroll up).
- **Image preview** — click a picture in a sent message, or a thumbnail above the box, and it opens in **Quick
  Look** (full size, zoom, share / Open in Preview; ←→ between that message's images; space or esc closes); a
  hand cursor over them. The transcript keeps only thumbnails, so the full images live in `ChatImageCache`
  (Multee's Caches folder, `chat-images/`, named by content hash — a reopened chat writes each image once from
  the transcript's base64; files untouched for 30 days are cleared).
- **Voice** — `ChatVoice`: **fn⌃** (press both, let go; dropped if another key joins, so fn⌃← still tiles) or
  the mic left of send starts dictation, again stops it. The words stream into the box at the caret (replacing a
  selection) as they're heard and are sent only on ⏎ — ⏎ while listening stops and sends once the last words
  land; typing or esc stops listening (esc then doesn't also stop Claude). Stopped while still connecting, what
  you'd said is sent once the connection opens; an input-device change (AirPods connecting) ends the dictation,
  keeping the words. The box has no undo while words stream in; once they've landed they are one
  ⌘Z. Mic: grey idle, amber connecting (~1.4 s, the audio meanwhile is kept), pulsing red
  listening. Uses Claude Code's own speech-to-text (the `voice_stream` WebSocket, claude.ai login from the Keychain
  via `/usr/bin/security`) — see D43. Errors land in the transcript as a red "Voice: …" line.
- **Suggested next message** — like the terminal UI, after a reply the empty box shows Claude's guess at what you'll
  type next, greyed with a "⇥ tab" hint; **Tab** puts it in the box (to send or edit), typing hides it, and it's
  dropped as soon as anything is sent, rewound, or the process stops. Claude's own `--prompt-suggestions`
  (`prompt_suggestion` event, a small cache-reusing request per turn). Claude decides when to stay quiet: not before
  its 2nd reply, not in plan mode or near usage limits, not after an error; the terminal's "Prompt suggestions"
  setting (`promptSuggestionEnabled: false`) turns it off here too.
- **Folding replies** — hovering one of your messages shows a ▾ in its bubble's top-right: it folds away
  everything Claude did in reply (text, tools, thinking) down to a "▸ Show Claude's reply" stub; ⌥-click folds
  or unfolds every reply at once, so a long chat reads as the list of what you asked. Folded rows stay in the
  list with no height and are never mounted (ids, history, rewind untouched); the message you clicked keeps its
  place on screen, and the rest slides there (0.25 s layer transforms from each row's old screen position;
  revealed rows fade in once the slide ends; off under Reduce Motion). A reply still arriving under a folded message stays folded. Per tab, not saved.
- **Rendering** — `ChatRender`/`ChatMarkdown`: headings, lists, task lists, quotes, tables, rules, inline
  code/bold/italic/links (bare `http(s)://` addresses too, except inside `code`; a click opens the browser),
  fenced code with the TextMate highlighter. Tool rows mimic the terminal UI:
  `Tool(summary)` + a `⎿` preview (4 lines, "show more"), Edit as a red/green diff, Write/Read line
  counts, TodoWrite checklist, Agent rows with the subagent's step count + latest action and a cleaned
  report, background shells as a one-liner. Rows are selectable text; "Copy Message" in the context menu.
- **The chat's own questions** — rewind what, turning bypass on (first time; defaults to No, and declining
  from ⇧⇥ moves on to the next mode so the cycle isn't stuck in front of it), "Other model…"
  — use the same card and keys as Claude's prompts (`ChatLocalCard`, neutral border), never a modal alert.
- **Prompt card** (`ChatPromptPanel`) — fully keyboard-driven, like the terminal UI: every choice is a
  numbered row (`ChatChoiceRow`) under a ❯ cursor — ↑/↓ move, ⏎ confirms, 1–9 pick, esc denies/skips, and
  typing letters goes straight into the card's text row. Permissions: Yes / "Yes, and always allow <rule>"
  (or "allow all edits this session") / "No, and tell Claude what to do differently" (a text row).
  AskUserQuestion: one question at a time (tabs ☐/☑ per question, ←/→ or tab to switch), single-select picks
  (shown `Label ✓` when you come back) and moves on; multi-select toggles with ⏎, space or the number (as in
  the terminal UI) and ends in a Next / Submit row; a "Type something…" row (joins multi-select picks), then a
  Submit step that reviews the answers (a lone question submits directly).
  ExitPlanMode: the plan (page up/down scrolls it) + "Yes, and auto-accept edits" / "Yes, and manually
  approve edits" / "No, keep planning — …" (text row).
- **Images** — paste or drop one into the box (⌘V from a screenshot, an image file from Finder): it joins a
  **thumbnail strip above the text** (`ChatAttachmentStrip`, 44pt tiles numbered by position; hover shows a ×
  to remove it — or backspace with the caret at the very start of the box takes the last one — a click opens
  Quick Look) and rides along as an image block ahead of the text (`ChatImage`
  scales it to 1568px on the long side, PNG, or JPEG when that would be heavy). The text stays plain — no
  markers (D44); an image alone is a message too. esc esc clears text and images; a queued message taken back
  brings its images back to the strip. The sent message shows the **picture** — a 200pt thumbnail drawn as a
  text attachment, rebuilt from the transcript when the chat is reopened (older messages' `[Image #n]` text is
  stripped when drawn). A pasted
  non-image file inserts its path instead. Clipboard managers work too — their temp file (odd extension or
  none) is read for what it is, and raw single-type bytes are accepted. The box claims the image pasteboard
  types so ⌘V is even *offered*: AppKit greys out Edit ▸ Paste — and swallows the key — when a plain-text
  view says it reads nothing on the clipboard, which made an image-only clipboard a silent no-op.
- **Input** (`ChatInputView`) — ⏎ send, ⇧⏎/⌥⏎ newline, esc stops Claude (esc esc throws away what you
  typed, images and all; on an empty box it offers rewind),
  ⇧⇥ cycles mode, ↑/↓ history;
  `/` completion (all commands incl. skills, with argument hints + descriptions; after a space mid-message, skills
  only, matched by prefix — print mode sends a mid-text `/skill` as plain text and Claude picks it up with its Skill
  tool; which commands are skills is learned from `init` and remembered across chats) and `@` file completion
  (`git ls-files`). Messages sent while Claude works queue above the box — **held by Multee**, not Claude, and sent one per
  turn as each turn ends (esc'd ones too), so each gets its own answer; Claude would merge everything in its own
  queue into one message. The trade: no steering a running turn mid-task — esc, then send.
  **Edit a queued message** (the terminal UI's select mode): ↑ from the box's first line highlights the newest
  queued one, ↑/↓ move, ⏎ takes it back into the box (above any draft, images renumbered after the draft's), esc
  leaves. Claude never saw it, so nothing needs withdrawing. `/model` opens the model menu, `/tasks` the tasks panel, `/context` the context popover;
  the chat's own commands (below) join `/` completion; commands needing the terminal UI (`/permissions`,
  `/hooks`, `/login`…) explain themselves instead.
- **Status line** (`ChatFooterView`) — permission mode (click or ⇧⇥: ask → accept edits → plan → auto (models
  that support it) → bypass; chats launch with `--allow-dangerously-skip-permissions`, and turning bypass on
  asks once per install), model ▾ (the models, **effort** low…max for the picked model, fast
  mode with its real availability, "Other model…"), live context meter — a bar going blue → yellow → red as it fills, exact % in the tooltip (click → Claude's own breakdown), 5h / 7d
  usage with reset countdowns (kept across launches), background tasks (shells, agents, ports), cost,
  **Remote Control** (antenna; green while on — open/copy the session link, stop), and **Open in Terminal**.
  No folder, branch or resume button: Multee's bottom bar shows the first two, and `/resume` does the third. Model and effort picks are saved on the tab (`--model` / `--effort`).
- **Compacting** — while Claude compacts (`/compact`, or on its own mid-reply) the activity line reads
  "Compacting conversation… · 12s · usually about 15s · esc to stop". No progress bar: print mode reports only the
  start and end of a compaction (the terminal UI's bar is a time curve, not measured progress). The "usually" hint
  is the median time of past compactions within 2× of this size on the same model (`CompactTiming`, last 30 kept in
  defaults as `multee.chat.compactTimes`); it appears once two such have been timed.
- **Code blocks** get a copy icon in their top-right corner (a green ✓ for a moment after copying);
  consecutive blocks stay separate (a spacer line — TextKit merges adjacent equal text blocks).
- **Rewind** (`/rewind`, esc esc) — pick one of your messages — a skill or custom `/command` Claude answered counts,
  a built-in one like `/compact` doesn't (a compaction done since Claude last started doesn't
  stop it; one from before a restart does — oldest at the top,
  the latest at the bottom and selected, as in the terminal UI); a dry run
  (`rewind_files`) shows which files changed since then — the picker stays up as "Checking what changed…"
  while Claude answers, so the keyboard never drops back into the message box mid-flight and esc still
  cancels (a reply to a cancelled or superseded ask is dropped) — then a card (not a modal) asks: restore code and
  conversation / conversation / code / never mind. The conversation rewind is Claude's `rewind_conversation` (cut in place, the message goes
  back into the box to edit); code comes from Claude's file checkpoints (print mode keeps them only with
  `CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING`, which chats set). Each sent message carries its own id so
  the chat can name it. History (`ChatHistory`) shows only the transcript's **live branch** — the one Claude
  resumes — so undone and retracted messages stay hidden after a reopen.
- **Fork** (`/fork [name]`, or the ⑂ on a chat tab chip) — a new chat tab on a copy of the conversation
  (`--resume <id> --fork-session`), named "<title> (fork)" or the given name; Claude keeps the name
  (`rename_session` → `custom-title`, which tab titles now prefer).
- **`/plan`** — plan mode (with a note); `/plan <task>` also sends the task; `/plan open` (or `/plan` while
  planning) opens the session's plan file (`get_plan`) in an editor tab.
- **`/btw <question>`** — a side question answered in a card above the box from the conversation's context
  (`side_question`), not added to it; works while Claude is busy, follow-ups see earlier answers, esc/×
  dismisses (an unanswered one is cancelled).
- **`!` shell mode** — `!git status` runs in your `$SHELL` in the chat's folder (the box turns pink); the row
  shows `! command` + output (red with "[exit code N]" on failure; esc stops it; stopped after 120 s). The
  command and output then join Claude's context as the terminal UI records them (`<bash-input>` /
  `<bash-stdout>` messages sent with `shouldQuery: false` — no model call, no "working"), also mid-turn.
- **`/copy [n]`** — Claude's last (or n-th latest) reply to the clipboard. **`/export [file]`** — the whole
  conversation (unloaded history included) as Markdown, to `file` or via a save panel. **`/memory`** — pick
  project / user / local / auto memory; opens it in an editor tab (created if new).
- **Resume** (`ChatResume`, `/resume`) — this folder's past conversations (title, age, size),
  searchable; ⏎ switches this tab to the picked one with its history. **Remote Control** (`/remote-control`,
  `/rc`, `/remote-control off`) — print mode doesn't offer the command, so the chat drives Claude's
  `remote_control` control request; the session link shows as a clickable notice. `/effort <level>` and
  `/fast` map to the same settings as the menu.
- **Background tasks** (`ChatTasksPanel`) — every `run_in_background` shell and async agent: status,
  elapsed time, listening ports (found under the task's process tree, click to open), live log tail, Stop.
  "Clear finished" drops the ended ones; past 10 tasks that happens by itself (running ones always stay).
- **Switching** — right-click a Claude/chat tab ▸ "Open as Chat" / "Open in Terminal UI" (or the status-line
  button / palette) converts the tab in place, same conversation (`Session.switchClaudeUI`).
- **Folder trust** (`ChatTrust`) — print mode skips Claude's "trust this folder?" prompt, so a chat asks
  first unless Claude already trusts that exact folder. The "Trust folder & start" button takes keyboard focus
  when the prompt appears (white ring; space or ⏎ accepts), then focus moves to the message box.
- **Crash/exit** — "Claude stopped (…) — Restart resumes this conversation" with a Restart button.
**Verified (harness, live `claude` 2.1.278):** tool calls/markdown/streaming; permission allow / deny with
feedback / always-allow (rule written to settings.local.json); questions (single, multi-select, two
questions); plan approval → mode switch → edits without prompts; interrupt (incl. during a pending prompt);
queued messages; crash → Restart resumes; restore on relaunch with history; switch chat ↔ terminal both
ways; two background servers with correct per-task ports, live log, Stop one; `/compact` `/cost` `/resume`;
`/` and `@` completion; trust gate; tab/session/app close kills the process and its servers. Performance on
a 200 MB / 14,333-message transcript: 25,942-frame scroll, **0 height jumps**, p50 0.9 ms / p99 6.6 ms / max
15 ms; streaming a ~600-word reply costs ~1.5 CPU-s (a terminal tab: ~1.6 CPU-s); idle 0% CPU.
Also verified: a real ⇧⇥ key event cycles every mode (incl. the one-time bypass confirmation, and bypass
really skips prompts); effort set + persisted on Sonnet; auto mode accepted on Sonnet; Copy puts the exact
code on the clipboard; resume switches conversation with history and context; Remote Control on (link) and off.
Bypass card: from ⇧⇥ "No, skip it" (and esc) continue the cycle past bypass; from the mode menu "No" changes nothing.
Rewind: code + conversation (file back to its earlier content; Claude's own recall matches the cut), conversation
only, code only, to the oldest of several messages, past a `!` command, with a message sent while `!` ran, in a
reopened chat, no-file-changes dialog, cancel, while working (refused), a message queued mid-turn, esc esc,
after `/compact` (only newer messages offered), survives reopen and relaunch. Fork: `/fork name` keeps its name
after the first turn (custom title in the fork's transcript), ⑂ default name, own id. `/copy` (+ n too large),
`/export` to a file and via the save path (full history of an 18 MB transcript in 0.3 s), `/memory` creates and
opens CLAUDE.md; all three in an empty chat. History branch walk: 8 real transcripts (to 200 MB), chunked
reads identical to one full read.
Plan / btw / shell (live, Haiku): `/plan` → mode + note, "No plan yet", `/plan <task>` → plan card, `/plan open`
opens the plan file; `/btw` answers (PELICAN), follow-up uses history, answers while Claude works, never enters
the conversation; `!` output / failure with exit code / esc stop / empty `!` / first message of a chat / run
mid-turn (Claude then quotes it) / reopened history keeps output and status / not sent to a conversation the
tab switched to.
Transcript stays on the bottom when a card opens below it and after it closes (gap to bottom 0 both times).
Prompt cards by real key events only: two-question card (space/↓/3 toggles, walk into and type in the text row, ↑
out, ⏎ next, ↓⏎ pick, ← back with the pick kept, → Submit step, ⏎ → Claude got "Apple, Cherry, kiwi" / "Blue");
permission (3 + typed reason → denied with it; ↓↑⏎ allow; esc deny; typing letters goes to the reason row);
plan (3 + feedback → revised plan; 2 → approved, mode back to ask); single question typed answer ("mango").
Images: a copied image and an image file both paste as `[Image #n]` and Claude read them back ("1 red, 2 blue");
a 3000×2000 PNG is scaled down; deleting the marker drops the image (the saved message keeps text only); plain
text still pastes as text; a reopened chat shows the markers once; a clipboard manager's shapes (file without
extension, `.dat` file, raw bytes under one type) all attach, while a text file still inserts its path. Drag-and-drop shares that code path (the
sandbox blocks synthetic drags, so it isn't harness-tested). An image-only clipboard now enables Edit ▸ Paste
(`dumpPasteEnabled` → `enabled=true matched=public.png`, `false` before) and pastes through the menu's own
route (`chatMenuPaste`); ←/→ step over a marker (caret 11 → 10 → 0 → 10, never inside), typing beside it
leaves it intact, one backspace (or ⌦) clears `[Image #1]` whole, numbering restarts after it, and a
marker no image claims is stripped before sending (typed `[Image #9]` never reached Claude; the real image
did). A sent image draws as a 200×150 thumbnail in its bubble and comes back the same after the conversation
is closed and reopened from the transcript (`dumpChat` → `items[].images`). (The marker behaviour above was
replaced by the thumbnail strip, D44 — verified since: paste 2 → strip, preview #2, × removes one, text + image
and image-only sends, reopen, esc esc clears.)
**Not supported yet:** Claude's own `/permissions` `/hooks` editors (use Open in Terminal).

## Terminal — `Terminal/`
`TerminalStore` caches one SwiftTerm PTY view per tab id (process survives tab/session switches).
Login-shell PATH via `Env.bootstrap`. Claude launches with `--settings <hooks>` + env; a shared
scroll monitor routes wheel/trackpad events (incl. alt-buffer SGR forwarding) to the terminal under
the cursor. Claude `--resume <cid>` only when its transcript still exists on disk. The launch exe/args/env
live in one `launchSpec(for:cwd:)`. **Continue/resume flags are dropped for folders Claude has never seen**
(`hasConversation(forCwd:)` checks `~/.claude/projects/<encoded cwd>` for any `.jsonl`) so a default like
`--continue` starts a *fresh* session on a brand-new project instead of failing with "no conversation to
continue"; it's kept when the folder has history. A wrong encoding guess only ever means "launch fresh".

**Closing a tab ends what it was running.** `terminate()` alone sends `SIGTERM`, which an interactive shell
and Claude both ignore, so closed tabs used to leave their shells (and Claude's `node`/MCP children) running
for days, each still holding a leaked pseudo-terminal. `ProcessEnd` hangs up on the child's whole process
group, kills a survivor after 1.5 s and reaps it, and `applicationWillTerminate` does the same for every
open PTY so nothing is handed to launchd. Verified: three tabs opened and closed return the app's open-PTY
count to baseline with no survivor and no `<defunct>`; a Claude tab takes its MCP server with it; quitting
with three tabs open leaves nothing. See DECISIONS D40.

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

**Files panel on/off (⌘B / Settings)** — the whole FILES panel (Files / Changes / Search) can be hidden,
leaving a **sessions-only sidebar** for people who juggle projects and never browse files here. Off is not
just a hidden view: the `RepoStore` is never created, so that session has **no FSEvents watcher and no git
poll at all**; the status bar's branch (normally bridged from the poller) comes from one `Git.branch` call
per repo instead. ⌘⇧F / "Find in Files…" opens a project-search **tab** rather than no-op'ing, ⌘P go-to-file
is unaffected (it reads `Git.repoFiles` directly), and the SESSIONS collapse chevron hides (there is nothing
to collapse into) while keeping the preference for when the panel returns. The sidebar width is remembered
**per mode** (~320pt with files, ~260 without) — see D30.

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
Document moved to **⇧⌥F** to free the shortcut) — or, when the **Files panel is off** (⌘B), opens/activates a
search **tab** instead and focuses it through `SearchTabFocus.focusActive`, which `CenterViewController` owns
because it knows which of several search tabs is actually mounted. The sidebar panel has an **Open-as-Tab** button (⬈, sidebar
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
rendered content, freed on close. A pragmatic slice of **raw HTML** is handled for GitHub-README style
files: `<img>` renders as an image (honoring `width`/`alt`), `<div align="…">` aligns the blocks inside
(so a centered header renders centered), and other structural tags (`<details>`/`<summary>`/`<div>`) are
stripped to their text rather than shown as literal markup. Markdown autolinks (`<https://…>`) are left
untouched (only specific HTML tags trigger this path).

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

**New Claude / New Terminal shortcuts (`NewItemHook`).** File-menu commands, backed by one hook enum so
the menu items, the key monitor, and the harness share an implementation: **New Claude Session (⌘⇧C)** opens a
Claude tab with the default args; **New Claude with Args… (⌘⌥C)** pops the tab bar's existing preset menu
(Default / `--continue` / `--resume` / `--dangerously-skip-permissions`) via `TabBarHook.popClaudeArgsMenu` —
one source of presets, anchored to the ▾ button; **New Claude Chat (⌘⇧M)** opens a native chat tab (see Chat
tab); **New Terminal (⌃⇧`)** is context-aware — it adds a shell to
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
reachable** (`AppModel.dockerAvailable`); clicking it — or **⌘D** (View ▸ Toggle Docker Panel, grayed when
the daemon is down) — toggles the dock (`DockerHook.toggle`). The dock is
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
API; a top banner offers Homebrew self-update or Download. **Install now** refreshes **only the cask's own tap**
(`git fetch`+`reset` on `$(brew --repository Rudra370/tap)`) — never a global `brew update`, so an unrelated/slow
tap can't hang the update — then runs `HOMEBREW_NO_AUTO_UPDATE=1 NONINTERACTIVE=1 brew upgrade --cask --force …`
(no Y/N prompt) in an in-app terminal, opening a bare home-folder session if nothing is open. The network steps
are bounded by a portable `perl alarm` timeout (30s fetch / 180s upgrade; macOS has no `timeout`). The command
writes exactly one marker — `.done` on success → **auto-relaunch** (`watchForCompletion` polls, then `relaunch()`)
or `.fail` on any failure/timeout/cancel → the banner flips to **"Update failed — Retry"** instead of spinning
forever. See DECISIONS D29.
**Auto-check** (release builds only, `startAutoCheck`): checks ~3s after launch, then every 6h, plus a
throttled re-check (≥1h since last) on app reactivation — so a session left open for days still sees a
release published mid-session. **"Later" snoozes** that version for 24h (`dismissBanner` → `snoozeVersion` +
`snoozeUntil`, persisted in `UserDefaults` so quitting/reopening within the window doesn't re-pop it); once
the snooze expires the next periodic check re-surfaces the banner (`isSnoozed` gates `dismissed`). A genuinely
newer version is never snoozed. Skips background checks while an install is mid-flight. A check only counts
as "up to date" on a clean 2xx + parseable tag; a **failed** request (offline, timeout, rate-limit) shows a
*"Couldn't check for updates"* alert on a manual check and stays silent for background checks (next cycle
retries) — it no longer masquerades as "up to date."
Installing runs a visible shell chain in an "Update" tab (`Updates.updateCommand`, dumpable via the harness's
`dumpUpdateCmd`): refresh **only our tap** → `brew fetch --cask` → `brew upgrade --cask --force` → clear
quarantine → write a marker. Each brew step gets a **600s** alarm as a freeze backstop, and the fetch-first
split keeps a slow download from starving the upgrade; a step killed by its alarm writes a `.timeout` marker
so the banner says *"Update timed out — slow connection"* rather than blaming GitHub. See D29 (why we scope to
our tap and feed it a non-TTY stdin) and D31 (why 180s was killing working updates).

## Motion / animations — `UI/Motion`
Shared motion vocabulary (durations, curves, one Reduce-Motion gate) used app-wide; animates only GPU-composited
layer properties, never per-frame layout. **Bottom dock** slides open/closed (`slideY`, sized once so terminals
reflow once; close also empties the shared dock via `finalizeDockClose`). **Centered overlays** (Quick Ask,
centered quick terminal, the ⌘P **command palette**, the **session-ended** card) present/dismiss with a scrim fade
+ box scale 0.96↔1 (`presentOverlay`/`dismissOverlay`).
**Docker rows** crossfade their hover background/icon tint; **icon buttons** (`PointerButton`) scale to 0.92 while
pressed. **Tab bar** has a `selectionPill` that slides to the active chip on switch (jumps on add/remove/reorder;
the active chip is transparent so the pill is its sole highlight). The **Docker action peek overlay** fades + pops
in/out. The **SESSIONS panel** collapse/expand glides the sidebar divider (`Motion.drive` — safe per-frame here,
no terminal in either pane). The **Docker status dot** crossfades green-fill↔grey-ring when a service flips state:
`renderServices` reuses rows in place on a same-shape re-render (the usual live-event case) so the dot can animate,
falling back to a full rebuild on any structural change. The sidebar **Files/Changes/Search** swap fades the incoming
pane in (`Motion.fadeIn`). Reduce Motion → everything instant. See DECISIONS D28 (why transforms, not layout; the
shared-dock empty-on-close contract; the layer-backing/KVC gotchas). Hover/press/slide *feel* is HID-verified —
the harness can't synthesize mouse.

## Deferred (v0.1.1 polish)
Motion intentionally NOT done: **tab-chip / session-row insert + removal** animation — the tab bar
and session list rebuild from scratch on every model update, so an entrance animation gets cut off mid-flight and a
close has no surviving view to animate; making either work needs reusing views across renders (a keyed diff, like the
Docker rows) — not worth it for a subtle effect. Also the **update-banner** slide (it sits above the workspace, so
animating its height reflows the workspace/terminals every frame — the dock's trap). None are functional blockers.
