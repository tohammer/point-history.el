# 0001 — Record navigation history by activity, in a new package point-history

Date: 2026-10-17
Status: accepted

## Context

The author's earlier `global-point-undo.el` provides M-left/M-right back/forward
navigation. It records a position on every command that leaves the current
line, keeps an unbounded list of integer positions and buffer objects
(drifting positions, killed buffers kept alive), and its reopen of killed
buffers is broken. The history fills up with every line passed while
navigating, so going back is slow and noisy.

Alternatives examined:

- **dogears** (used before): a deduplicated list of places with a
  completion UI, not a back/forward stack. It records the destination of
  a jump, not the origin; `cl-pushnew` keeps entries out of chronological
  order; its hooks and idle timer mutate the list while navigating; each
  record is expensive (bookmark record, `which-function`, O(n²) dedup).
- **gumshoe** (MELPA, v4.0): distance-based recording with global and
  filtered back/forward. It creates an overlay on every command and never
  deletes the unused ones (measured: 500 small moves left 500 overlays for
  5 entries), does line counting on every command, ships debug `message`
  calls, and needs a modal backtracking mode.
- **better-jumper** (used by Doom Emacs): markers and bounded rings, but only
  per window or per buffer, only on explicitly instrumented commands, and
  every jump also calls `push-mark`.
- **Distance-based recording** in a rewrite (record when more than N
  lines from the last entry): still records places merely passed through
  during fast navigation.

## Decision

Write a new public package `point-history` that records a place only where
something happened: an edit, a copy, or staying idle long enough to read
(2 s by default). Activity near the newest entry moves that entry instead
of adding one; activity near an older entry moves that entry to the front.
Entering another file adds a placeholder entry that the first activity in
that file replaces and that is dropped again when the file is left within
1 s. Navigation itself never records.

## Consequences

- The history holds few, meaningful places; fast jump chains leave no
  trail. A place glanced at for less than the idle delay is not recorded;
  `point-history-remember` covers that case.
- Per-command cost is a buffer-tick comparison and a buffer comparison;
  the real work happens only when an entry is recorded.
- The ordering is "last activity at a distinct place", not a strict
  chronological browser history; revisits move entries instead of adding
  duplicates.
- point-history replaces `global-point-undo.el`.
