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

- The command after `--` is one of an allowlist of concrete forms: `git push <remote> …` (the
  remote by name, of this checkout, on github.com), `gh pr create|comment|edit|view|list|checks`,
  `gh issue create|comment|edit|close|reopen|view|list`, `gh run view|list`, `gh repo view`,
  `gh api <relative path>`. Every option must be in that form's table; anything else — a shell,
  a script, `env`, a path to git, `git -C …`/`-c …`, any other git subcommand or alias, a gh
  alias/extension, `gh pr merge`/`review`, `-R HOST/OWNER/REPO`, `--hostname`, a URL where a
  number belongs, `-w`/`-e` — is refused before any token is minted, and gh is pinned to
  github.com. Run it from the checkout it concerns. (`docs/secrets.md` → *Using it* has the
  tables and the stated residuals; a new form is one table line plus a test, never a wider rule.)
- The command runs in an environment the wrapper builds: your global/system git and gh config,
  `~/.netrc`, hooks and push signing are not loaded (proxy/CA only via the environment), and the
  gh forms have no git transport — push with the `git push` form first. Residual: programs on
  your `PATH` or named in this checkout's own config still run as you, with the token.
- Read-only calls (`gh pr view`, `gh pr checks`, `gh issue list`, `gh api` GETs) may use the
  session's own login.
- Minting the token needs AWS credentials for the `tools` rows, `/gogo/tools/` (GoGo-Infra#294;
  on the owner's workstation: `AWS_PROFILE=gogobootstrap`). If it fails, stop and tell the owner. Do not fall back to the
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
