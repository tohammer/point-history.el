# point-history: back/forward navigation by activity

Status: approved
Date: 2026-10-17

## Purpose

`point-history` is a public Emacs package that lets the user go back and forward between the places
where they actually worked or read, across buffers, with M-left/M-right,
and jump between files with M-S-left/M-S-right. Quick navigation must not
fill the history. Success: after jumping around without stopping, one
M-left returns to the last place where something happened; the history
stays short and meaningful; ordinary commands cost close to nothing.

It replaces the author's older `global-point-undo.el`. Background and
rejected alternatives (dogears, gumshoe, better-jumper, distance-based
recording): [ADR 0001](../decisions/0001-activity-based-recording.md).

## Scope

In:

- Global minor mode `point-history-mode` with activity-based recording,
  file-visit placeholders and one global history.
- Commands: back/forward, back/forward by file, back/forward within the
  current file, a completion list of the history, manual remember.
- Public repo `tohammer/point-history.el` with tests and CI (rules in
  `CLAUDE.md`).

Out:

- Per-window histories, persistence across Emacs sessions, merging with
  better-jumper's jump list, consult preview in the list command (plain
  `completing-read`, which vertico displays), key bindings defined by the
  package itself, overriding org-mode/markdown-mode bindings of
  M-arrow/M-S-arrow, installing the package into a particular Emacs
  configuration (done in that configuration's own repo).

## Design

### Terms

- **Entry**: a remembered place: a marker, the file name of its buffer
  (if any), a window-start marker, and a kind: `activity`, `visit` or
  `return`.
- **History**: the entries, newest first, at most `point-history-size`.
  When it is full, the oldest entry is dropped.
- **Index**: the entry the user is currently at while navigating; 0 when
  not navigating.
- **Near**: two places are near when they are in the same buffer and at
  most `point-history-distance` lines apart.
- **Recordable buffer**: not a minibuffer, major mode not derived from one
  in `point-history-ignored-modes`, and visiting a file unless
  `point-history-file-buffers-only` is nil.

### User options

| Option | Default | Meaning |
|---|---|---|
| `point-history-size` | 100 | Maximum number of entries |
| `point-history-distance` | 10 | Lines within which two places count as the same place |
| `point-history-idle-delay` | 2 | Seconds without input that count as reading; nil disables |
| `point-history-activity-commands` | `(kill-ring-save)` | Commands that count as activity besides edits |
| `point-history-ignored-edit-commands` | `(save-buffer save-some-buffers revert-buffer)` | Commands whose buffer changes are not activity (format-on-save, revert) |
| `point-history-record-file-visits` | t | Entering another file adds a placeholder entry |
| `point-history-visit-min-stay` | 1 | Seconds a visit must last to be kept |
| `point-history-file-buffers-only` | t | Only record file-visiting buffers |
| `point-history-ignored-modes` | `(special-mode messages-buffer-mode git-commit-mode)` | Major modes never recorded (derived modes included) |
| `point-history-message` | t | Echo the position after a move, e.g. `Back 3/42` |

### Recording

Activity, in a recordable buffer shown in the selected window:

1. **Edit**: a command run by the user changes the current buffer
   (buffer modification tick differs before and after the command), and
   the command is not in `point-history-ignored-edit-commands`. The edit
   counts only if the command ends in the buffer it started in; otherwise
   it is at most a file visit (e.g. an `auto-insert` template in a newly
   visited file, or a keyboard macro that edits and switches buffers).
   Changes made outside commands (process output, timers, auto-revert)
   are not activity.
2. **Copy**: a command in `point-history-activity-commands` runs.
3. **Reading**: Emacs is idle for `point-history-idle-delay` seconds.
   Counts once per idle period.

When activity happens at point P:

1. If P is near the **current entry** (index), that entry moves to P and
   becomes kind `activity`. The order and the forward history do not
   change.
2. Else, if the newest entry is a `visit` entry in the same buffer, that
   entry moves to P and becomes `activity` (the placeholder is replaced,
   however far apart they are).
3. Else a new place is recorded: entries newer than the index (the
   forward history) are dropped, the index becomes 0, an entry near P
   anywhere in the remaining history is removed, and a new `activity`
   entry at P is put at the front.

While navigating (see below), reading idle time at the place navigated to
does not record. Navigation commands themselves never count as activity.

### File visits

When `point-history-record-file-visits` is non-nil and a command (not a
point-history command, and not while the minibuffer is active, so completion previews do not count) leaves the
selected window showing a different recordable file buffer than before
the command:

- Rule 3 of Recording applies with kind `visit` at point.
- If the user leaves that buffer again (the selected window shows another
  buffer after a later command) less than `point-history-visit-min-stay`
  seconds after the visit and without activity in it, the visit is undone:
  the new entry is removed and an entry removed by the near rule is put
  back where it was. The forward history dropped by the visit is not
  restored.

### Navigation

Navigation moves the index and shows the entry in the selected window
(switching buffer there; `pop-to-buffer` if the window is dedicated). If
the target position is not visible in the window, the remembered window
start is restored; if it is visible, the view does not scroll. With
`point-history-message`, the echo area shows the direction and
`<index+1>/<length>`.

- **Return point**: on the first navigation command after a non-navigation
  command, if point is not near the current entry (the one at the index),
  a `return` entry at point is inserted just before the current entry
  (newer than it) and the index points at the `return` entry; the command
  then moves from there. Nothing is dropped, so forward navigation comes
  back to the `return` entry and on to the newer entries. When not
  navigating (index 0) this puts the `return` entry at the front. A
  `return` entry turns into `activity` by rule 1 when activity happens
  near it.
- **Navigating state** lasts from a navigation command until a later
  command moves point so that it is no longer near the current entry, or
  shows another buffer. While navigating, idle time does not record. When
  the navigating state ends, the index stays where it is; only activity
  (rule 3) resets it to 0.
- **Killed buffers**: when a buffer is killed, its entries keep the file
  name and the position at kill time. Navigating to such an entry opens
  the file and goes to that position (clamped to the buffer size). If the
  file no longer exists, or the entry has no file, the entry is removed,
  a message names it, and navigation continues to the next entry in the
  same direction.

Commands (no keys bound by the package):

| Command | Behaviour |
|---|---|
| `point-history-back` | Go to the entry after the index (the next older one, after the return point rule has been applied). At the oldest: message `At oldest place`, nothing moves |
| `point-history-forward` | Go to the next newer entry. At the newest: `At newest place` |
| `point-history-back-file` | Go to the next older entry whose buffer differs from the current buffer. When the next older run of entries belongs to one buffer, land on its newest entry, i.e. the first one found. At the end: `No earlier file` |
| `point-history-forward-file` | Go to the next newer run of entries in a different buffer and land on its newest entry. At the end: `No later file` |
| `point-history-back-in-file` | Go to the next older entry in the current buffer. At the end: `No earlier place in this file` |
| `point-history-forward-in-file` | Go to the next newer entry in the current buffer. At the end: `No later place in this file` |
| `point-history-list` | `completing-read` over the history in history order (no re-sorting); each candidate shows buffer name, line number and the trimmed line text; selecting one sets the index there and navigates to it |
| `point-history-remember` | Record point as activity now (rules 1–3), regardless of idle time; works in any buffer that is not a minibuffer |

All filtered commands move the same index, so they can be mixed.

### Package layout

`point-history.el` (single file,
`lexical-binding`, `Package-Requires: ((emacs "28.1"))`, `Version: 0.1`,
author `Tobias Hammer <tohammer@users.noreply.github.com>`, GPL-3.0),
`test/point-history-test.el` (ERT), `Makefile` with `all: compile checkdoc
test` (byte-compile with warnings as errors), `.github/workflows/test.yml`
with the Emacs matrix 28.2, 30.2, 31.1, `README.md` ending with an AI
Disclaimer section, `LICENSE`, `.gitignore`. The README shows how to
enable the mode and the suggested key bindings (`M-left` back, `M-right`
forward, `M-S-left` back-file, `M-S-right` forward-file). No private
information (see `CLAUDE.md`).


## Error handling

- Entry buffer killed: handled as described under Navigation (reopen or
  remove and continue).
- Entry position beyond the end of a shrunken buffer: clamped to
  `point-max`.
- Errors inside the hooks or the idle timer must never break the user's
  command: hook and timer bodies catch errors, show them once with
  `message` and continue; the mode stays on.
- Navigation with an empty history: `No places recorded yet`.
- Disabling `point-history-mode` removes all hooks and the timer; the
  history is kept, so re-enabling continues with it.

## Testing

Automated (ERT, `make all`, in CI on all three Emacs versions). Tests
drive the package the way the command loop does: set `this-command`, run
the pre- and post-command functions around the action, and call the idle
function directly instead of waiting. Files are created in a temporary
directory. Cases:

- Cursor moves of any distance without pausing record nothing.
- An edit records; further edits within the distance move the same entry;
  an edit beyond the distance adds an entry.
- An ignored edit command (`save-buffer` with a buffer change) and a
  change outside a command record nothing; a command that edits and ends
  in another buffer records no edit.
- A copy command records; idle records once per idle period.
- Activity near an older entry moves that entry to the front (no
  duplicate).
- The history never exceeds `point-history-size`.
- Ignored modes, non-file buffers and the minibuffer are not recorded.
- Back/forward order, the return point, messages at both ends; after
  navigating back, a small move near the current entry followed by back
  adds no return entry and drops nothing; moving away and then back
  inserts the return entry before the current entry and drops nothing;
  the
  navigating state (idle at the target does not record; editing there
  moves the entry without reordering), and forward history dropped by a
  new place but not by activity near the current entry.
- File visit: placeholder created, replaced by the first activity in that
  file, removed when leaving before the minimum stay, kept after it.
- By-file and in-file commands, including the end messages and mixing
  with plain back/forward.
- Killed buffer reopened at its position; deleted file skipped with
  navigation continuing.
- Window start restored only when the target is not visible (batch
  Emacs does no redisplay, so the test stubs `pos-visible-in-window-p`).
- Mode off removes hooks and timer.

Manual checks in a real Emacs session with the suggested bindings:

- M-left after an xref jump chain returns to the last place of activity;
  consult-buffer and consult-line previews do not create visit entries.
- M-arrow and M-S-arrow in org-mode still do org's commands.
- `point-history-list` displays and jumps correctly under vertico.

## Tasks

- [x] 1. Package skeleton on a branch:
  header, empty `point-history-mode`, user options, Makefile, CI
  workflow, `.gitignore`, LICENSE, README skeleton with AI Disclaimer,
  one smoke test. *Done when* `make all` passes locally with Emacs 31
  and the file has no private information.
- [x] 2. History and recording: entries, recordable-buffer check, edit,
  copy and idle activity, rules 1–3, size limit, error-catching hooks,
  mode on/off. *Done when* the recording tests listed under Testing pass
  in `make all`.
- [x] 3. Navigation: back/forward, return point, navigating state, window
  start, killed buffers and missing files, messages. *Done when* the
  navigation tests pass in `make all`.
- [x] 4. File visits: placeholders, replacement by first activity, undo
  on short stay. *Done when* the file-visit tests pass in `make all`.
- [ ] 5. Filtered navigation: back/forward by file and within file.
  *Done when* the by-file and in-file tests pass in `make all`.
- [ ] 6. `point-history-list` and `point-history-remember`. *Done when*
  tests for selecting from the list (by stubbing `completing-read`) and
  for remember pass in `make all`.
- [ ] 7. README: behaviour, options, commands, suggested bindings,
  installation. *Done when* every option and command in the code is in
  the README and the README contains no private information.
- [ ] 8. Publish: after the user confirms, create the public GitHub repo
  `tohammer/point-history.el`, push `master` with the work, set up branch
  protection as described in `CLAUDE.md` (required checks
  `test (28.2)`, `test (30.2)`, `test (31.1)`). *Done when* CI is green
  on `master`, `git log --format="%ae"` shows only the noreply address,
  and a direct push to `master` is rejected.

Tasks 2–6 change the same file and run in order. Task 7 can run in
parallel with tasks 4–6.
