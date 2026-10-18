# point-history

Back/forward navigation across buffers by the places where you actually
worked or read, not by every cursor move. point-history remembers where
you edited, copied or paused to read, and lets you step back and forward
through those places like the buttons of a browser. Quick jumps do not
fill the history, so it stays short and meaningful.

## How it records

point-history records a place only when something happens there
("activity"):

- **Edits**: a command you run changes the buffer. Commands listed in
  `point-history-ignored-edit-commands` (such as `save-buffer`, so that
  format-on-save does not count) are skipped, and so are changes made
  outside commands (process output, timers, auto-revert).
- **Copies**: commands in `point-history-activity-commands`
  (default `kill-ring-save`).
- **Reading pauses**: Emacs is idle for `point-history-idle-delay`
  seconds. This counts once per idle period. Set it to nil to turn it off.
- **File visits**: when a command takes you to another file, a placeholder
  entry is added. The first activity in that file replaces the placeholder.
  If you leave the file again in less than `point-history-visit-min-stay`
  seconds without any activity, the placeholder is dropped.

Moving the cursor, scrolling or jumping around without stopping records
nothing.

Places that are near each other (within `point-history-distance` lines in
the same buffer) count as one place: new activity there moves the existing
entry instead of adding another one. The history holds at most
`point-history-size` entries; the oldest is dropped first.

Navigation commands never record anything themselves. When you go back
from a place that is not in the history, point-history first remembers
where you were (the return point), so going forward brings you back
there and on to the newer places. If you go back a few steps and then
start working somewhere new, the places you went back over (the forward
history) are dropped, as in a browser.

### Ordering

The history is ordered by the last activity at each distinct place, not
strictly chronologically. If you work again near an older entry, that
entry moves to the front instead of being duplicated.

## Installation

point-history requires Emacs 28.1 or later.

### Manual

Clone the repository and add it to your `load-path`:

```sh
git clone https://github.com/tohammer/point-history.el /path/to/point-history.el
```

```elisp
(add-to-list 'load-path "/path/to/point-history.el")
(require 'point-history)
```

### use-package with :vc (Emacs 30 and later)

```elisp
(use-package point-history
  :vc (:url "https://github.com/tohammer/point-history.el")
  :config
  (point-history-mode 1))
```

## Usage

Enable the global minor mode:

```elisp
(point-history-mode 1)
```

Disabling the mode removes its hooks and timer; the history is kept, so
enabling it again continues with it.

The package binds no keys. Suggested bindings:

```elisp
(global-set-key (kbd "M-<left>") #'point-history-back)
(global-set-key (kbd "M-<right>") #'point-history-forward)
(global-set-key (kbd "M-S-<left>") #'point-history-back-file)
(global-set-key (kbd "M-S-<right>") #'point-history-forward-file)
```

On Emacs 29 and later you can use `keymap-global-set` instead, for
example `(keymap-global-set "M-<left>" #'point-history-back)`.

Some major modes, such as `org-mode`, bind these keys locally. They keep
their own commands there; use `M-x` or other keys for point-history in
such buffers.

## Commands

| Command | Description |
|---|---|
| `point-history-back` | Go to the next older place. At the oldest: `At oldest place`. |
| `point-history-forward` | Go to the next newer place. At the newest: `At newest place`. |
| `point-history-back-file` | Go to the newest place of the next older run of entries in a different buffer. |
| `point-history-forward-file` | Go to the newest place of the next newer run of entries in a different buffer. |
| `point-history-back-in-file` | Go to the next older place in the current buffer. |
| `point-history-forward-in-file` | Go to the next newer place in the current buffer. |
| `point-history-list` | Choose a place from the whole history with `completing-read` (buffer name, line number and line text) and jump to it. |
| `point-history-remember` | Record point as activity right now, regardless of idle time. |

All navigation commands move the same position in the history, so they
can be mixed. If a buffer was killed, its entries are kept; navigating to
one reopens the file at the remembered position. If the file is gone, the
entry is removed and navigation continues to the next one.

## Options

All options are in the `point-history` customization group.

| Option | Default | Meaning |
|---|---|---|
| `point-history-size` | `100` | Maximum number of entries. |
| `point-history-distance` | `10` | Lines within which two places count as the same place. |
| `point-history-idle-delay` | `2` | Seconds without input that count as reading; nil disables. A change takes effect when the mode is enabled again. |
| `point-history-activity-commands` | `(kill-ring-save)` | Commands that count as activity besides edits. |
| `point-history-ignored-edit-commands` | `(save-buffer save-some-buffers revert-buffer)` | Commands whose buffer changes are not activity. |
| `point-history-record-file-visits` | `t` | Entering another file adds a placeholder entry. |
| `point-history-visit-min-stay` | `1` | Seconds a file visit must last to be kept. |
| `point-history-file-buffers-only` | `t` | Only record buffers that visit a file. |
| `point-history-ignored-modes` | `(special-mode messages-buffer-mode git-commit-mode)` | Major modes that are never recorded (derived modes included). |
| `point-history-message` | `t` | Echo the position after a move, e.g. `Back 3/42`. |

## Development

`make all` byte-compiles the package (warnings are errors), runs
checkdoc and runs the ERT tests.

## AI Disclaimer

This package was developed with the help of AI agents.
