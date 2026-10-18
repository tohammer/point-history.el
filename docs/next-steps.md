# Next steps

Forward-looking only. Remove an item when it is done; move its lessons to
architecture.md or an ADR.

## Next

1. Task 8 of `docs/specs/2026-10-17-point-history.md`: after the user
   confirms, create the public repo `tohammer/point-history.el`, push
   `master` (merge branch `point-history` first), set up branch
   protection as in `CLAUDE.md`, watch CI on 28.2/30.2/31.1. Then set the
   spec to `Status: implemented`.
2. Manual checks from the spec in a real session: xref jump chain then
   M-left; consult-buffer/consult-line previews create no visits; org
   keeps its M-arrow bindings; `point-history-list` under vertico.

## Watch out for

- Only Emacs 31.1 was run locally; 28.2 and 30.2 are first exercised by
  CI. Window-start restore and visibility were only tested with stubs.
- The local default branch is `master`; there is no remote yet.
