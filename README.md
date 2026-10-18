# point-history

Back and forward navigation across Emacs buffers by the places where you
worked or read, not by every cursor move.

point-history remembers where you edited, copied or paused to read, and
lets you step back and forward through those places like the buttons of
a browser. Quick jumps do not fill the history, so it stays short.

- Records places by activity: edits, copies, reading pauses, file visits.
- Merges nearby places into one entry.
- Steps through the whole history, by file, or within the current file.
- Picks any place from a `completing-read` list.
- Keeps places of killed file buffers and reopens the file when you go
  there.

## Status

Version 0.2, early. The history is kept in memory only.

| Emacs | Status |
|---|---|
| 28.2, 30.2, 31.1 | tested (CI) |
| 28.1, 29.x | supported, untested |

## Quick start

Requirements: Emacs 30 or later for this snippet; for Emacs 28 and 29
see [Installation](#installation).

1. Add to your init file:

   ```elisp
   (use-package point-history
     :vc (:url "https://github.com/tohammer/point-history.el" :rev :newest)
     :bind (("M-<left>" . point-history-back)
            ("M-<right>" . point-history-forward))
     :config
     (point-history-mode 1))
   ```

2. Restart Emacs, edit a file, open another file and edit there.
3. Press `M-<left>`. Point returns to your first edit and the echo area
   shows the position in the history:

   ```
   Back 2/2
   ```

## Installation

### use-package with `:vc` (Emacs 30 and later)

```elisp
(use-package point-history
  :vc (:url "https://github.com/tohammer/point-history.el" :rev :newest)
  :config
  (point-history-mode 1))
```

Keep `:rev :newest`: without it, `:vc` installs the commit that last
changed the version number, which can be far behind.

### `package-vc-install` (Emacs 29 and later)

1. Run once:

   ```elisp
   (package-vc-install "https://github.com/tohammer/point-history.el")
   ```

2. Add to your init file:

   ```elisp
   (point-history-mode 1)
   ```

### Manual

1. Clone the repository:

   ```sh
   git clone https://github.com/tohammer/point-history.el /path/to/point-history.el
   ```

2. Add to your init file:

   ```elisp
   (add-to-list 'load-path "/path/to/point-history.el")
   (require 'point-history)
   (point-history-mode 1)
   ```

### Check the installation

Run `M-x point-history-back` right after startup. It shows:

```
No places recorded yet
```

## Usage

`point-history-mode` is a global minor mode. Turning it off stops
recording and keeps the history; turning it on again continues with it.

### Bind keys

The package binds no keys. Suggested bindings:

```elisp
(global-set-key (kbd "M-<left>") #'point-history-back)
(global-set-key (kbd "M-<right>") #'point-history-forward)
(global-set-key (kbd "M-S-<left>") #'point-history-back-file)
(global-set-key (kbd "M-S-<right>") #'point-history-forward-file)
```

### Go back to where you worked

1. Press `M-<left>` until you reach the place.
2. Optional: press `M-<right>` to go forward again. The place where you
   pressed `M-<left>` first is the newest stop.

If you start working at an older place, the places you went back over
are dropped, as in a browser.

### Jump to any place

1. Run `M-x point-history-list`.
2. Choose a place. Candidates are newest first and show the position in
   the history, buffer name, line number and line text:

   ```
   1 init.el:42: (setq point-history-size 200)
   ```

### Remember a place by hand

Run `M-x point-history-remember`. It records point at once, in any buffer
except the minibuffer, even in buffers that are not recorded otherwise.

### Commands

| Suggested key | Command | Action |
|---|---|---|
| `M-<left>` | `point-history-back` | Go to the next older place. |
| `M-<right>` | `point-history-forward` | Go to the next newer place. |
| `M-S-<left>` | `point-history-back-file` | Go to the newest place of the next older buffer, skipping the current buffer. |
| `M-S-<right>` | `point-history-forward-file` | Go to the newest place of the next newer buffer, skipping the current buffer. |
| | `point-history-back-in-file` | Go to the next older place in the current buffer. |
| | `point-history-forward-in-file` | Go to the next newer place in the current buffer. |
| | `point-history-list` | Choose a place with `completing-read` and go there. |
| | `point-history-remember` | Record point as a place now. |

All navigation commands move through the same history, so you can mix
them. When there is no target, a command changes nothing and shows one
of: `At oldest place`, `At newest place`, `No earlier file`,
`No later file`, `No earlier place in this file`,
`No later place in this file`.

### What gets recorded

A place is recorded when one of these happens in a file buffer:

- **Edit:** a command changes the buffer. Commands in
  `point-history-ignored-edit-commands` (such as `save-buffer`, so that
  format-on-save does not count) are skipped.
- **Copy:** you run a command in `point-history-activity-commands`
  (default `kill-ring-save`).
- **Reading pause:** Emacs is idle for `point-history-idle-delay`
  seconds; once per idle period.
- **File visit:** a command shows another file in the selected window.
  The first activity there replaces this entry. If you leave in less
  than `point-history-visit-min-stay` seconds without activity, the entry
  is dropped.

Moving the cursor, scrolling and the navigation commands record
nothing. Places within `point-history-distance` lines of each other in
the same buffer count as one: new activity there moves that entry to the
front instead of adding one. The history keeps `point-history-size`
entries and drops the oldest.

On the first navigation command after other commands, if point is away
from the current place, point is recorded as a stop, so that going
forward brings you back to it.

If you kill a file's buffer, its places stay. Going to one reopens the
file. If the file is gone, the entry is removed with
`point-history: removed <file>, file no longer exists` and navigation
continues with the next one.

## Configuration

Set options with `M-x customize-group RET point-history RET` or with
`setq` in your init file, for example:

```elisp
(setq point-history-size 200
      point-history-idle-delay 5)
```

| Option | Default | Description |
|---|---|---|
| `point-history-size` | `100` | Maximum number of entries. |
| `point-history-distance` | `10` | Lines within which two places count as the same place. |
| `point-history-idle-delay` | `2` | Seconds without input that count as reading; `nil` turns reading pauses off. A change takes effect when you turn the mode on again. |
| `point-history-activity-commands` | `(kill-ring-save)` | Commands that count as activity besides edits. |
| `point-history-ignored-edit-commands` | `(save-buffer save-some-buffers revert-buffer)` | Commands whose buffer changes do not count. |
| `point-history-record-file-visits` | `t` | Showing another file records a visit entry. |
| `point-history-visit-min-stay` | `1` | Seconds a visit without activity must last to be kept. |
| `point-history-file-buffers-only` | `t` | Record only buffers that visit a file. |
| `point-history-ignored-modes` | `(special-mode messages-buffer-mode git-commit-mode)` | Major modes never recorded, including derived modes. |
| `point-history-message` | `t` | Show the position after a move, e.g. `Back 3/42`. |

## Limitations

- The history is lost when Emacs exits.
- Changes made outside commands (process output, timers, auto-revert)
  are not recorded.
- Indirect buffers have no file, so they are not recorded by default.
  Workaround: set `point-history-file-buffers-only` to `nil`.
- Places in buffers without a file cannot be reached once the buffer is
  killed; navigation removes them.
- Edits made in a recursive edit inside a command (such as `C-r` in
  `query-replace`) are not recorded. Workaround: `M-x
  point-history-remember`.

## Troubleshooting

### Nothing is recorded in a buffer

The buffer does not visit a file, or its major mode is in
`point-history-ignored-modes`. Set `point-history-file-buffers-only` to
`nil` or remove the mode from the list; for a single place, use
`M-x point-history-remember`.

### The keys do nothing in some modes

Some major modes, such as `org-mode`, bind `M-<left>` and `M-<right>`
themselves. Bind point-history to other keys, or use `M-x` in those
buffers.

### `point-history: <error>` in the echo area

An error inside point-history's hooks was caught so that your command
still runs. Each distinct error is shown once. Report it with the steps
that caused it at
<https://github.com/tohammer/point-history.el/issues>.

## Development

`make all` byte-compiles the package (warnings are errors), runs checkdoc
and runs the ERT tests in `test/`. Design notes are in
[`docs/architecture.md`](docs/architecture.md).

## License

GPL-3.0-or-later; see [`LICENSE`](LICENSE).

## AI Disclaimer

This package was developed with the help of AI agents.
