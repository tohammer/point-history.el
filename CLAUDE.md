## Development workflow

This project uses the devflow plugin. Docs live in `docs/`:
architecture.md, specs/, decisions/, backlog.md, next-steps.md.
Start a session by reading `docs/next-steps.md`.

## Package rules

This package is public. Keep it free of private information:

- No company names, hostnames, internal URLs, real usernames or personal
  paths in source files, README, docs or commit messages; use placeholders
  like `/path/to/...`.
- Author field and commit email: `tohammer@users.noreply.github.com`.
- No `Co-authored-by: Copilot` trailers.
- The README ends with an **AI Disclaimer** section stating the package
  was developed with the help of AI agents.
- Leave `Version:` unchanged unless the user asks for a bump.
- Before pushing, check `git log --format="%ae"` (only the noreply
  address) and grep the files for the patterns above.

## Changes via pull request with CI

GitHub repo: `tohammer/point-history.el`. CI runs `make all` in GitHub
Actions (`.github/workflows/test.yml`) on Emacs 28.2, 30.2 and 31.1.

1. Work on a branch, run `make all` locally.
2. Push the branch and open a PR with `gh pr create`.
3. Merge only after all CI jobs pass (`gh pr checks --watch`); never push
   directly to `master`.

`master` has branch protection: pull request required (zero approvals),
applies to admins, no force pushes or deletion. Required status checks
are `test (28.2)`, `test (30.2)`, `test (31.1)`. When the Emacs matrix in
`test.yml` changes, update them too:

```bash
gh api repos/tohammer/point-history.el/branches/master/protection -q '.required_status_checks.contexts'
gh api -X PUT repos/tohammer/point-history.el/branches/master/protection/required_status_checks/contexts \
  -f 'contexts[]=test (28.2)' -f 'contexts[]=test (30.2)' -f 'contexts[]=test (31.1)'
```

The first push to `master` (initial publish) happens before branch
protection is set up.
