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
