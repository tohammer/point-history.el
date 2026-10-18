# Next steps

Forward-looking only. Remove an item when it is done; move its lessons to
architecture.md or an ADR.

## Next

1. Use the package day to day; turn whatever feels wrong into a backlog
   item or a `/devflow:debug` session. Open items are in `docs/backlog.md`.

## Watch out for

- `master` is protected: every change goes through a pull request with
  green CI on 28.2, 30.2 and 31.1 (see `CLAUDE.md`).
- Window-start restore and visibility are only tested with stubs; check
  them by hand when touching `point-history--show-entry`.
