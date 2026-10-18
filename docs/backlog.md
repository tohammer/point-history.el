# Backlog

Open points only. Delete an item when it is done; git keeps the history.
Deferred review findings name their origin, the reason and when to revisit.

## Visit edge cases (from task 4 implementation, 2026-10-18)

- After `point-history-back` inside a freshly visited file, an edit there
  is recorded by rule 3 and the `visit` placeholder stays in the history
  as a stale `visit` entry (rule 2 only looks at the newest entry).
  Harmless but adds a near-useless entry. Revisit if it shows up in use.
- When a navigation command inserts a return entry before undoing a
  short visit, the entry restored from the near rule goes back one
  position too far forward. Only affects order in a rare sequence;
  revisit together with the item above.

## Recording gaps (from the review of the point-history spec implementation, 2026-10-18)

- Indirect buffers have no `buffer-file-name`, so with the default
  `point-history-file-buffers-only` nothing is recorded in them (e.g.
  org indirect subtree buffers). Deferred: needs a decision whether the
  base buffer's file should count. Revisit when someone uses indirect
  buffers with the package.
- Inside a non-minibuffer `recursive-edit` (e.g. `C-r` in
  `query-replace`), the inner commands' post-command clears the stored
  buffer, so the outer command's edits are not recorded. Deferred: rare,
  and a fix needs tracking `recursion-depth`. Revisit if reported.
