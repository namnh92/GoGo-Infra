# GoGo-Infra — notes for Claude Code sessions

## GitHub identity: act as the agent App, never as the owner

Every write an agent session makes to GitHub — push, pull request, PR or issue comment, review
request — goes through the agent GitHub App (GoGo-Infra#250), so it is authored by `<app>[bot]`
and the owner can approve it:

```bash
./scripts/secrets/as-agent.sh -- git push -u origin <branch>
./scripts/secrets/as-agent.sh -- gh pr create --base develop --title "…" --body-file <file>
./scripts/secrets/as-agent.sh -- gh issue comment <n> --body-file <file>
```

- The command after `--` is `git` or `gh` itself, by name, with a builtin git subcommand or a gh
  command of gh's own: a shell, a script, `env`, a path to git, `git -C …`/`-c …`, a git alias
  or a gh alias/extension is refused before any token is minted. Run it from the checkout it
  concerns. (`docs/secrets.md` → *Using it* has the exact rules and the stated residual.)
- Read-only calls (`gh pr view`, `gh pr checks`, `gh issue list`, `gh api` GETs) may use the
  session's own login.
- Minting the token needs AWS credentials for the `ci` rows (on the owner's workstation:
  `AWS_PROFILE=gogo-bootstrap`). If it fails, stop and tell the owner. Do not fall back to the
  owner's `gh` login or git keychain: a pull request authored by the owner cannot be approved by
  the owner, and the code-owner gate on `develop` exists for exactly that.
- A session with no AWS access (e.g. a cloud session) may push its branch with the access it
  has, but does not open the pull request itself: it reports the branch and the prepared PR body
  so a session that can run `as-agent.sh` opens it.
- The App has no `workflows` permission, by design: GitHub rejects a push from it that
  creates or changes anything under `.github/workflows/`. Push such a branch with the session's
  own git access (the push author does not count as the PR author), then open the pull request
  with `as-agent.sh` as usual.
- Never print the token, write it to git config or a file, or put it in a remote URL.
- Never merge. Merging stays with the owner.

Details, creation and revocation: `docs/secrets.md` → *Agent GitHub App*.
