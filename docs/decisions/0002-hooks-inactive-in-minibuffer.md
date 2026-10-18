# 0002 — Pre/post-command hooks do nothing while the minibuffer is active

Date: 2026-10-18
Status: accepted

## Context

point-history detects edits and file visits by comparing state stored
in `pre-command-hook` with the state in `post-command-hook`. Commands
that read from the minibuffer (`query-replace`, anything run by `M-x`,
`consult-buffer`, `consult-line`) run nested commands for every key
typed into the minibuffer, and each nested command runs both hooks.
They overwrote the outer command's stored buffer and tick, so editing
commands run via `M-x` or `query-replace` never counted as edits, and
completion previews looked like buffer switches.

## Decision

Both hook functions return immediately while the minibuffer is active
(`minibuffer-depth` > 0 or an active minibuffer window). The outer
command's pre-command runs before the minibuffer opens and its
post-command after it closes, so the command is judged as a whole.

## Consequences

- Edits by commands that read arguments count; previews in
  `consult-buffer`/`consult-line` create no visit entries; the final
  choice of `consult-buffer` does.
- Edits made in other buffers while a minibuffer is open (recursive
  minibuffers) are not recorded.
- A non-minibuffer `recursive-edit` is not covered; see the backlog.
