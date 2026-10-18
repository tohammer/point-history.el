# Architecture

This document describes the system as it is now.

## Overview

`point-history` is a single-file Emacs package (`point-history.el`,
Emacs 28.1+) with a global minor mode that records places of activity
and commands that navigate them. Tests are in `test/point-history-test.el`
(ERT); `make all` byte-compiles (warnings as errors), runs checkdoc and
the tests; CI runs it on Emacs 28.2, 30.2 and 31.1.

## Components

The file is split into `;;;;` sections:

| Section | Responsibility | Depends on |
|---------|----------------|------------|
| History | Entry struct (marker, file, window-start marker, kind, positions and buffer name saved at kill time), `point-history--entries` (newest first), `--index`, recording rules 1–3 (`--activity`, `--record-new`), near check, size limit | — |
| Recording | Recordable-buffer check, error-catching macro, pre/post-command hooks, edit/copy detection, navigating-state check, idle timer body | History |
| File visits | Visit placeholders and the pending-visit record that undoes a short stay | History, Recording |
| Killed buffers | `kill-buffer-hook` saves positions; `find-file-hook` and navigation reattach detached entries; removal of unusable entries | History |
| Navigation | Return-point rule, search with predicate, showing an entry, the generic `--navigate` command body | History, Killed buffers |
| Filters | Predicates and run adjustment for the by-file and in-file commands | Navigation |
| List and remember | `point-history-list` (`completing-read` in history order), `point-history-remember` | Navigation, History |
| Mode | `point-history-mode` adds/removes four hooks and the idle timer; the history survives off/on | all |

## How it fits together

- **Per command** the pre-command hook stores the current buffer, its
  `buffer-chars-modified-tick` and the selected window's buffer; the
  post-command hook compares them. A changed tick in the same buffer is
  an edit, a changed window buffer may be a file visit. Nothing else
  runs per command except the near check while navigating, which is
  bounded to `point-history-distance` lines.
- **Recording** goes through `point-history--activity` (rules 1–3) or,
  for visits, `point-history--record-new` (rule 3). The entry removed by
  the near rule is kept in `point-history--near-removed` so a short
  visit can put it back.
- **Navigation commands** carry the symbol property
  `point-history-navigation`; they never record activity. Each runs
  `point-history--navigate`: apply the return point (which may insert a
  `return` entry), search, go to the target, and undo the return entry
  if nothing was found (`--settle-return-point`).
- **Navigating state** (`point-history--navigating`) suppresses idle
  recording and ends when point leaves the current entry; the index
  stays until activity at a new place resets it.

## Lessons

- Hooks do nothing while the minibuffer is active. Commands typed into
  the minibuffer run their own pre/post-command hooks and would
  otherwise overwrite what the outer command (`query-replace`, `M-x`,
  `consult-buffer`) stored. See ADR 0002.
- Use `buffer-chars-modified-tick`, not `buffer-modified-tick`: the
  latter also changes on text-property changes such as fontification.
- Markers of dropped entries must be released (`set-marker nil`); live
  markers slow down every edit in their buffer.
- Line counting must widen (narrowing clamps `goto-char`) and be bounded
  (`forward-line` by the distance), or it is wrong in narrowed buffers
  and slow in large ones.
- `set-window-start` needs NOFORCE when restoring a remembered start,
  otherwise redisplay moves point off the target.
- Batch Emacs does no redisplay: window-visibility tests stub
  `pos-visible-in-window-p`; tests drive commands by calling the pre-
  and post-command functions around the action with `this-command` bound.
- Emacs 31 turned off checkdoc's imperative-verb check by default
  (`checkdoc-verb-check-experimental-flag`), while 28 and 30 still run
  it; the Makefile enables it so local runs match CI.
