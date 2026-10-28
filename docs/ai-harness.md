# AI Harness — operating guide

Decision layer for Claude Code tasks: a deterministic policy engine, a JEV decision router
consulted only at checkpoints, loop and budget controls, a decision log and durable handoffs.
Why and where the boundaries are: [`adr/0013`](adr/0013-ai-harness-jev-decision-router.md).
Issue: GoGo-Infra#241.

**Advisory, not enforcement** (owner decision 2026-10-22, ADR-0013 D-1). The session that asks
also declares the actions and the human authorizations, and the harness cannot prove either
describes what the session will do. A decision says what the *stated* plan allows. Write actions
are re-classified from their target — placed in the checkout the working directory belongs to,
walked component by component (symlinks, hard links, `..`), and checked against the task scope
whatever kind was declared; every other kind is taken as declared and is unverified. Enforcement
stays with Claude Code's permission system, the sandbox and branch protection. Every `decide`
output carries an `advisory` field that says so.

## Run it

```bash
(cd harness && node --test test/*.test.ts)   # deterministic tests, no key, no network
(cd harness && pnpm install --ignore-workspace && pnpm typecheck)

# A checkpoint, deterministic only (the default — JEV disabled). Run `decide` from the
# directory the task's targets are spelled from — here the repo root; from `harness/` the
# fixture's `src/…` target would name `harness/src/…`, a protected path:
node harness/src/cli.ts decide --input harness/test/fixtures/task-ambiguous.json
# The same through fixtures (exercises the JEV mapping, says nothing about model quality):
JEV_MODE=mock node harness/src/cli.ts decide --input harness/test/fixtures/task-ambiguous.json \
  --fixture harness/test/fixtures/mock-intake.json

node harness/src/cli.ts status                     # budgets per account + decision metrics
node harness/src/cli.ts billing --mode interactive # refuses if ANTHROPIC_API_KEY is in this shell
```

Exit codes: `0` AUTO_EXECUTE · `10` RESEARCH_AND_CONTINUE · `20` HUMAN_APPROVAL · `2` usage or
configuration error. A summary that holds an invalid phone or email candidate (owner decision
2026-10-23, see the outbound data contract) is not a crash: `decide` returns the deterministic
fallback with `errorCategory: "invalid_data"`, `status` counts it under `errors`, and the exit code
is that outcome's.

### Live mode — only after the owner authorizes paid inference and the privacy review

Two separate owner steps come first: authorizing paid inference, and the privacy review + DPA
for the outbound data below (`ai-guardrails.md`). `JEV_PRIVACY_REVIEWED=yes` is the person
running the command stating that the second one is recorded on the issue; the harness cannot
check it, and refuses live mode without it.

```bash
JEV_MODE=live JEV_LIVE_AUTHORIZED=yes JEV_PRIVACY_REVIEWED=yes \
  ./scripts/secrets/exec-with.sh dev ai-harness/openrouter-api-key -- \
  node harness/src/cli.ts decide --input task.json
```

The key reaches that one process only. It is never in a `.env`, never exported in a shell,
never in a URL, never logged.

### Outbound data contract (what leaves the machine in live mode)

One request per JEV call, to OpenRouter, built by `sanitizeSummary` and the question set:

| Field | Content | Minimization |
| --- | --- | --- |
| `state.task.title`, `description`, `acceptance_criteria`, `open_questions` | Session-written summary of the issue | credentials, emails, phone numbers, coordinates, home-directory names replaced (formats below); capped |
| `state.task.labels`, `paths` | Short labels; repository-relative paths, never contents | same |
| `state.context_already_searched`, `project_rules` | Names of sources searched; short rule quotes | same |
| `state.failure` (repeated failure only) | failure class, attempt count, last error text | same — stack traces lose `/Users/<name>` |
| `state.scope_change` (scope change only) | one sentence | same |
| `questions` | Fixed text from `harness/src/router/questions.ts` | no task data |
| `session_id` | 16-hex digest of `taskId` | the task id itself is never sent |
| `model` | the pinned model id | — |

Minimization (`harness/src/runtime/sanitize.ts`) runs on each field in five steps over the
whitespace-collapsed text — the text that is sent (owner decision 2026-10-23: phone numbers and
email addresses are checked by regex; anything ambiguous is a data error, never a leak):

1. **Credentials and home directories** are replaced by shape (`[REDACTED]`, `~`); overlapping
   credential assignments (`token="password=…`) are all found and their spans unioned.
   **Labelled ids** are then set aside and restored unchanged at the end: a run of 8 or more digits
   right after `run `, `runs/`, `job/`, `jobs/`, `issuecomment-` or `#` (`LABELLED_ID`, owner
   decision 2026-10-23). A valid phone behind a label is still a phone; a bare or letter-glued run
   is not an id.
2. **Tokens**: the text is split on whitespace and on `, ; ( ) [ ] < > " '`; trailing `. ? ! :` is
   dropped; `. - + @` never split a token. A token is a *candidate* when it holds an `@`, or is made
   of digits and phone separators with 8 or more digits (an ISO date or timestamp such as
   `2026-10-22T10:30:00Z` is plain, with at most nine fractional-second digits, so no phone fits). A phone written with spaces is the longest window of up to five
   tokens that matches `VN_PHONE`.
3. **Two anchored regexes** decide validity, nothing else: `VN_PHONE` and `EMAIL` (table below,
   unit-tested in `harness/test/pii-regex.test.ts`). A match → `[PHONE]` / `[EMAIL]`.
4. **One split**: a candidate that matches neither is tried as exactly two parts, phone + address or
   address + phone (`a@b.vn0912345678`); both valid → both replaced. Otherwise, and whenever digits
   are glued to an address that opens with digits (`0912 345 6781a@b.vn`), or a token ending in a digit
   stands right before a number (`x.ts+84 (0) 912 345 678`; an ISO date excepted), it is a **data error**:
   `sanitizeSummary` raises `InvalidSummaryData` (field names and reason codes, never the text),
   `decide` answers deterministically with `errorCategory: invalid_data`, and nothing leaves.
5. **Coordinates** by shape, then a **post-check** on what would be sent: any surviving `@` (a lone
   one or a `@@` diff hunk marker included), or a run of 8 or more digits — one `.`, `-` or space
   between digits — outside a placeholder, not an ISO date and not a labelled id, is a data error.
   Last, the **final check** reads the text exactly as it will be sent, ids restored: any numeric run
   that contains a valid Vietnamese number anywhere inside it (`10:30:09.12345678`, `run 10912345678`)
   is a data error, so no exemption can carry a phone across its edge. Id placeholders are
   private-use characters the input cannot supply; any in the input is dropped first. This holds the invariant whatever the
   steps above missed.

Text that is never sent (handoffs, a provider's error message) goes through `redact`, which does not
raise: there an invalid candidate is replaced by `[INVALID_DATA]`. A differential test keeps an
earlier implementation as a frozen oracle and checks, over every form the tests generate, that nothing
it removed is sent now (letters and digits; a data error satisfies it). `JEV_PRIVACY_REVIEWED`
attests to exactly this coverage:

| Data | Valid → replaced | Candidate but invalid → data error, not sent | Not seen (residual) |
| --- | --- | --- | --- |
| Credential | token shapes (`sk-or-v1-…`, `sk-ant-…`, `AKIA…`, `gh?_…`, `github_pat_…`, JWT, PEM), `Bearer …`, `key=value` / `"key": "value"` for password/secret/token/api-key names (quotes kept only when both are present), `scheme://user:pass@` | — | a secret under a name not in that list |
| Email | `EMAIL`: one `@`; local part of dot-separated atoms of letters, digits, `_ % + -` (no leading, trailing or doubled dot); domain labels of letters, digits and inner hyphens; at least one dot; a TLD of two or more letters | any other token with an `@` (`foo@bar`, `a@b.vn@c.vn`, `a..b@c.vn`, `deploy@host`, a handle `@namnh92`), or one glued to digits that no single split resolves | an address written as `name at domain`; `'` is a delimiter, so `o'neil@example.com` is read as `o'` + `neil@example.com` |
| Phone | `VN_PHONE`: mobile `0` + one of `3 5 7 8 9` + 8 digits; landline `0` + `2` + 9 digits; the leading `0` also as `84`, `+84` or `0084` with an optional trunk `0`; at most one `.`, `-` or space between any two digits; brackets around the prefix or a group are delimiters, so `(028) 3822 1234`, `(+84) 912 345 678`, `+84 (0) 912 345 678` are read. Up to five space-separated tokens form one number. The generator in `harness/test/review-sa-r1.test.ts` spells this claim out | a digit token with 8 or more digits that is not `VN_PHONE` (`091234567`, `0912345678028.3822.1234`, `8 4 912 345 678`, `+84 - 912 - 345 - 678`); a non-Vietnamese number (`+1 ( 415 ) 555-0133`, `+44 20 7946 0958`: not supported — its digits form an 8+ run); a number glued to a word or path such as `x0912345678`, `x.ts0912345678`), digits glued to an address that opens with digits, and any run of 8 or more digits the post-check still sees | fewer than 8 digits is a plain number (`0912345`, `pid 84`, `0.5`); a number followed by a separate short number stays as it is (`0912 345 678 901` → `[PHONE] 901`); `+ 84 912 345 678` is read as `84 912 345 678` with the `+` left over; digits written as words. Counts, versions, PR numbers and ISO dates pass unchanged; coordinates keep at most 7 decimals, more is an 8+ run |
| Coordinates | decimal pairs `lat, lon` with ≥ 3 decimals, not part of a dotted number on either side; a labeled value `lat`/`latitude`/`lng`/`lon`/`longitude` `=` or `:` a decimal. A pair glued to a phone (`10.7769, 106.70090912.345.678`) gives the phone its digits back | a pair followed by `.digit` that no split resolves | DMS (`10°46'37"N`), a bare pair separated by whitespace only, plus codes, geohashes, a place name |
| Home directory | `/Users/<name>`, `/home/<name>`, `C:\Users\<name>` | — | a user name elsewhere in a path or in prose |
| Prose | — | — | a person's name, a street, a place, an account id written as text |

Do not put customer or user data into a task summary; summarize the issue instead. Nothing else —
no file contents, no environment, no repository data — is sent.

## Input

`decide --input` takes a `RouterInput` (`harness/src/router/router.ts`):

| Field | Meaning |
| --- | --- |
| `taskId` | Issue reference, e.g. `GoGo-BE#709`. Used for grouping, not sent as meaning. |
| `checkpoint` | `intake` · `scope_change` · `ambiguity` · `repeated_failure` · `review_planning` |
| `summary` | `TaskSummary` — written by the session from the issue. Paths, never file contents. |
| `actions` | What the next step will do, as `ActionKind`s, declared by the caller and not verified. A write kind (`edit_in_scope`, `edit_out_of_scope`, `ci_workflow_change`, `update_handoff`, `write_test_evidence`) needs a `target` and is re-classified from it, whatever the label: no target, a symlink or a hard-linked file on the way, a `..` that leaves the checkout or goes through a directory that does not exist, an absolute path outside the checkout, or a working directory in no checkout → `unknown`; a protected path (`.claude/settings*.json`, `CODEOWNERS`, anything under `harness/`, prod Terraform; matched case-insensitively) → its gate; a workflow file → `ci_workflow_change`, **plus** `edit_out_of_scope` when it is outside `scope`; otherwise in or out of `scope` by path component — so a handoff or test-evidence write outside the scope needs the `edit_out_of_scope` authorization like any other edit. A declared `edit_out_of_scope` or `ci_workflow_change` keeps its own requirement even on an in-scope target. Non-write kinds (`test`, `commit`…) are taken as declared and are unverified. `classifyCommand` never returns an autonomous kind (ADR-0013 D-3b): every shell line gates, named when recognisable, `unknown` otherwise — declare the step's kind instead. |
| `scope` | Repository-relative path prefixes the task may edit, matched on component boundaries (`docs` covers `docs/x`, not `docs-x/`). Authored on the issue, so always relative to the checkout root, not to the working directory. Absent = nothing is in scope. |
| `repoRoot` | The directory the write targets are spelled from. Default: the CLI's working directory. The checkout root is the nearest ancestor with `.git` (a file in a worktree); relative targets are rebased onto it (`cd harness` + `src/cli.ts` → `harness/src/cli.ts`, protected), absolute targets must be spelled under it — the root as resolved, or the working directory's own spelling when that resolves to the same checkout (`/A/link → /B/sub` does not make `/A` a name for `/B`) — and each component is inspected in order. |
| `humanAuthorizations` | Kinds the issue author authorized explicitly (only `task_authorizable` ones count). |
| `failure` | `repeated_failure` only: `{ failureClass, signature }`. |

## Configuration

The last column is what the prompt hook (below) hands its live child: the child's environment is
an allowlist, and of this table only `passed` rows reach it from the owner's shell.

| Variable | Default | Meaning | Prompt-hook child |
| --- | --- | --- | --- |
| `JEV_MODE` | `disabled` | `disabled` · `mock` · `live` | set by the hook (`live`, after opt-in) |
| `JEV_LIVE_AUTHORIZED` | — | must be `yes` for `live` | set by the hook (the opt-in) |
| `JEV_MODEL` | `typesafe/jev-1.14` | pinned id; aliases refused | not passed (pinned, D-2) |
| `JEV_TIMEOUT_MS` | `5000` | 100…15000 | passed |
| `HARNESS_STATE_DIR` | `~/.gogo-harness` | ledger, decision log and per-task state `tasks/<task>-<hash>.json` (loop counters + decision cache, so limits hold across separate `decide` calls) — per machine, not committed | set by the hook (same directory) |
| `HARNESS_JEV_MONTHLY_USD` | `2` | local JEV target | passed |
| `HARNESS_ANTHROPIC_MONTHLY_USD` / `_RESERVE_USD` | `100` / `10` | local Anthropic API target | not passed (unused by the child) |
| `HARNESS_CONCURRENCY` | `1` | checkpoint serialization only; only `1` is accepted — `decide` holds `HARNESS_STATE_DIR/harness.lock` across load, limits, inference and save, so overlapping `decide` calls queue instead of losing counters or charges. The lock ends when `decide` returns: it does not limit how many Claude sessions or automation jobs run (not enforced here) | not passed (the child is one call) |
| `JEV_PRIVACY_REVIEWED` | — | must be `yes` for `live`: the privacy review + DPA for the outbound data contract are recorded | set by the hook (the opt-in) |
| `OPENROUTER_API_KEY` | — | from `exec-with.sh dev ai-harness/openrouter-api-key` | from the installed `exec-with.sh` only |

## Cost controls and monitoring

Three accounts, never summed (ADR-0013 D-7):

| Account | Billing | Local control | Provider-side control (owner) |
| --- | --- | --- | --- |
| `claude_max` | Max 5x subscription, interactive Claude Code | `billing --mode interactive` refuses an `ANTHROPIC_API_KEY` in the shell | — |
| `anthropic_api` | Anthropic API, headless automation | **not integrated**: the harness runs and records no Anthropic call, so it enforces no target; `status` reports `not_integrated`, usage UNKNOWN. The $100 target / $10 reserve are configured for when a recorder is approved | workspace spend limit, auto top-up off — the only cap today |
| `openrouter_jev` | OpenRouter, JEV decisions | $2 target; budget checked before every call | key-level credit limit |

Amounts: `reported` (provider `usage.cost`) > `estimated` > `unknown`. An unknown cost (timeout,
network error, 5xx) is counted at a per-call ceiling ($0.001 for JEV) against the budget and
shown as a count of unknown-cost calls, never as $0. A request that never left the process
(disabled, over budget, rejected 4xx) is `not_sent` — the one honest zero. Each live call is
reserved in the ledger, and counted against the task's call limit, on disk before it is sent;
a process killed in flight leaves that reservation as an unknown-cost call.

`status` prints, per provider and model build: requests, cache hits, fallbacks, latency
p50/p95 (nearest rank; `null` with no samples), input/output tokens when reported, reported
cost, unknown-cost calls, error categories, outcomes — and the budget state of each account.

The local ledger is the pre-call guard. The after-the-fact bill is GoGo-BE's Cost Center:
collector `openrouter_activity` (GoGo-BE#709) reads OpenRouter's `/keys` and `/activity` with a
management key (`backend/openrouter/management-key`, dev only) and files spend by key label —
`-` or `_` between words, read from the key's `name` (OpenRouter's `label` is a masked
preview of the key and is never used). Keys on the account after the split (2026-10-22):

| Name | Used by | Cost Center service |
| --- | --- | --- |
| `gogo_ai_harness_dev` | JEV for the harness | `openrouter.dev_tooling` |
| `gogo-claude-dev` | Claude through BYOK (GoGo's own Anthropic key) | `openrouter.claude_byok` (OpenRouter fee) + `anthropic.claude_byok` (Claude charge) |

The BE POC's key, when created, is `gogo_be_<env>` → `openrouter.decisions`. A key named
`gogo_jev_<env>` (one key for both, the state before the split) is filed as
`openrouter.jev_shared`, neither harness nor product. Any other name lands in
`openrouter.other_keys`. Nothing is summed across services.

## Installed copy (hooks and automation)

`node harness/src/cli.ts` above runs the checkout: that is the development and CI entry point.
Hooks and automation run an approved install outside every checkout instead, so an edit in a
worktree never changes the verdicts the session receives (ADR-0013 D-3, GoGo-Infra#245):

```
~/.gogo-harness/install/          (--install-dir / $HARNESS_INSTALL_DIR for prepare.ts; separate from ledger/logs)
  versions/<full-sha>/MANIFEST    schema 2: sha256 and exec bit of every file of the version
  versions/<full-sha>/harness/    the commit's harness/, read-only
  versions/<full-sha>/scripts/    the JEV send closure (D6): scripts/secrets/exec-with.sh,
  versions/<full-sha>/config/       scripts/secrets/common.sh, scripts/lib/manifest.py, config/secrets.manifest.yml
  ACTIVE                          { sha, manifestDigest } of the running version
  history.jsonl                   journal: an `intent` and an `activated` record per activation
  bin/harness.mts                 bootstrap: launcher.ts of the first installed commit, placed once by the owner
  bin/harness                     launch boundary (POSIX sh), written by the first activation, never rewritten
  quarantine/                     a broken ACTIVE or a damaged journal, kept as found
```

**First install** (owner, once per machine, on a terminal). Fill the four slots — `<sha>` the full
SHA of a `develop` commit, `<node>` the absolute path of the Node to run the harness with (22.18
or later; it is written into `bin/harness` and stays, D3), `<root>` e.g.
`$HOME/.gogo-harness/install`, `<approval>` the link to the owner approval — and paste the block.
Every step runs with an empty environment: git without system or global config, only `https`, no
redirects, no credential helper; Node without `NODE_OPTIONS`. It clones `develop` from GitHub,
checks the commit is on it, places that commit's `harness/src/install/launcher.ts` as
`bin/harness.mts` (refusing if one is there), then runs its `activate`. Prepare the commit first
(below) with `--install-dir <root>`. `harness/test/install.test.ts` runs this exact block.

```sh
/usr/bin/env -i PATH=/usr/bin:/bin HOME="$HOME" /bin/sh -euc '
sha="<sha>"
node="<node>"
root="<root>"
approval="<approval>"
g() {
  env -i PATH=/usr/bin:/bin HOME="$tmp" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0 \
    git -c protocol.allow=never -c protocol.https.allow=always -c http.followRedirects=false -c credential.helper= "$@"
}
tmp=$(mktemp -d)
g clone --quiet --bare --branch develop --single-branch https://github.com/namnh92/GoGo-Infra.git "$tmp/src.git"
g --git-dir="$tmp/src.git" merge-base --is-ancestor "$sha" develop
mkdir -p "$root/bin"
test ! -e "$root/bin/harness.mts"
new=$(mktemp "$root/bin/.harness.mts.XXXXXX")
g --git-dir="$tmp/src.git" cat-file blob "$sha:harness/src/install/launcher.ts" >"$new"
chmod 555 "$new"
mv "$new" "$root/bin/harness.mts"
rm -rf "$tmp"
env -i PATH=/usr/bin:/bin HOME="$HOME" "$node" "$root/bin/harness.mts" activate "$sha" --approval "$approval"
'
```

This first download is the trust anchor (trust on first use over HTTPS to GitHub): nothing the
block fetches can vouch for itself. To check it out of band, compare
`git hash-object <root>/bin/harness.mts` with the blob id GitHub shows for
`harness/src/install/launcher.ts` at `<sha>` (`git rev-parse <sha>:harness/src/install/launcher.ts`
in any clone).

```bash
# 1. Prepare (anyone; changes nothing that runs, proves nothing). Reads the commit's Git objects
#    in --repo (default: the working directory) — no fetch, no working tree —, writes harness/ and
#    the four closure files to staging, runs the commit's own tests against those bytes, and
#    publishes read-only. There is no --remote or --branch.
node harness/src/install/prepare.ts <commit> [--repo DIR] [--install-dir DIR]

# 2. Activate or roll back (owner, on a terminal):
~/.gogo-harness/install/bin/harness activate <full-sha> --approval <link to the approval>

# 3. Use. Same commands and exit codes as cli.ts:
~/.gogo-harness/install/bin/harness decide --input task.json
~/.gogo-harness/install/bin/harness install-verify     # { sha, manifestDigest } or exit 2
```

**Activation proves provenance.** Before the owner is asked, `activate` fetches `develop` from
`https://github.com/namnh92/GoGo-Infra.git` (constant; no option changes it) into a private
temporary repository with the same sanitized git, requires the commit to be an ancestor of it,
and requires every installed file to be that commit's blob with the same exec bit — same path
set, and the `MANIFEST` exactly what those files give. A commit on another branch, a version
edited after prepare, or a git configuration (`insteadOf`, `GIT_DIR`, a git shim moving
`FETCH_HEAD`) pointing elsewhere is refused. Then the owner sees old → new SHA, `MANIFEST` digest,
provenance and approval, and types `<old-sha12|none|broken> <new-sha12> <digest12>`.

**Offline rollback (D2).** Without network, `activate` accepts only a version this journal
records as `activated` with the same `MANIFEST` digest; the plan shows `provenance: recorded
<time>`. A version never activated here, a different digest, a damaged journal, or an activation
that has an `intent` but no `activated` record (interrupted after the switch) needs the network.

**ACTIVE is the only switch.** Activation takes `activate.lock` (a link there is refused), and
after confirmation: quarantines a damaged journal and starts a new one, writes `bin/harness` if
absent, quarantines a broken `ACTIVE`, appends `intent`, replaces `ACTIVE` by rename, appends
`activated`, and releases the lock (a lock replaced meanwhile is left, with a warning).

Interrupted before the `ACTIVE` rename, activation changes nothing that runs: the previous
`ACTIVE` stays selected (a broken one already moved to `quarantine/` leaves none), the journal
holds at most an `intent`, and running the same `activate` again completes it. After the
`ACTIVE` rename, before `activated`, the new version stays selected and runs without completed
journal evidence; the previous one is not kept. Re-running `activate` for it needs online
provenance (it was never recorded `activated`) and then appends `activated`; offline, only a
version the journal records as `activated` can be selected again (GoGo-Infra#253 S4-03).
`node <root>/bin/harness.mts activate …` under `env -i` (the block's last line) works even
without `bin/harness`. A process killed during activation leaves `activate.lock`: compare `ACTIVE`
with the last journal records, then remove it.

`activate` and `install-verify` are the bootstrap's own code whatever `ACTIVE` says: no version's
code takes part in replacing a version. Every other command reads `ACTIVE` once, checks the
`MANIFEST` digest against it and every file against the `MANIFEST` (missing, extra, changed,
wrong exec bit, linked, hard-linked, a `.git` anywhere), and only then imports that version's
`cli.ts`. Any mismatch exits `2` with `harness install: …` — no decision, no provider call, no
fallback to a checkout, no `HARNESS_DEV` bypass. The bootstrap anywhere but `<root>/bin/` refuses
to run; so does an install whose real path is inside a git checkout or worktree, or that has a
symbolic link or a `.git` entry anywhere on the way to a file it reads.

**Broken `ACTIVE`.** A file that is not a valid record, or a symbolic link, is shown with its
evidence (sha256, or where the link points — never followed), the confirmation starts with
`broken`, and after confirmation it is moved to `quarantine/` unchanged. Recover with
`bin/harness activate <sha> …` of a known version. A directory, fifo, socket or device at
`ACTIVE` is not something an activation leaves behind: `activate` refuses (`remove it by hand`);
remove it, then activate.

**Launch boundary.** Hooks call `bin/harness`, never `node …/harness.mts`: it clears
`NODE_OPTIONS`, `NODE_PATH`, `NODE_COMPILE_CACHE` and `NODE_REPL_EXTERNAL_MODULE` before Node
starts (a `--import` or `--require` there runs before any check), runs the Node path written at
the first activation, finds `harness.mts` beside itself, and keeps the caller's working
directory. The bootstrap also exits 2 when it sees a preload flag, but that is a diagnostic: the
preloaded code has already run by then.

**Limits.** This stops checkout edits from taking effect, the harness from approving its own
change, and an unmerged commit from being activated. It does not stop the same OS user from
rewriting payload, `MANIFEST`, `ACTIVE`, journal and bootstrap together, or from swapping a
directory or file between verification and import; the journal is not tamper evidence against
that user. `git`, `bash`, `python3` and `aws` as found on `PATH` (the closure scripts run
`python3 -I`), and the Node in `bin/harness`, are trusted like the rest of the machine. Provenance
fetches need direct HTTPS to GitHub: the environment is wiped, so a proxy or a private CA is not
supported. Changing Node, or a bootstrap fix, is a new first install. That boundary is Claude
Code's sandbox and permissions on writes outside the workspace. A declared write to the install
is a hard gate anyway: it is outside the checkout, so the policy engine classifies it `unknown`.

## Proposed Claude Code hook (owner action — not installed)

Installing this edits `.claude/settings.json`, a permission-policy change. Proposed shape, for
the owner to adopt or not. It runs the installed copy above, never the checkout:

```json
{
  "hooks": {
    "Stop": [
      { "hooks": [{ "type": "command", "command": "\"$HOME\"/.gogo-harness/install/bin/harness status >/dev/null" }] }
    ]
  }
}
```

The checkpoint call itself (`decide`) is made by the session at intake and on failures, as the
workflow in ADR-0013 D-4 describes; a per-tool-call hook is deliberately not proposed.

## Prompt hook and JEV opt-in (GoGo-Infra#247 — owner action to install)

A `UserPromptSubmit` hook. Every prompt is observed; a prompt goes to JEV only when the owner
opted in (owner decision 2026-10-23 on #247), and then a short advisory is added to the context:

```json
{
  "hooks": {
    "UserPromptSubmit": [
      { "hooks": [{ "type": "command", "timeout": 20, "command": "mkdir -p \"$HOME/.gogo-harness\" 2>/dev/null; \"$HOME/.gogo-harness/install/bin/harness\" prompt-hook 2>\"$HOME/.gogo-harness/prompt-hook.last-error\"; exit 0" }] }
    ]
  }
}
```

**Opting in** (owner, on a terminal; off by default):

```bash
~/.gogo-harness/install/bin/harness jev-prompt setup      # allow `#jev` on single prompts
~/.gogo-harness/install/bin/harness jev-prompt on --for 8h # every prompt, 1–24 h, then off by itself
~/.gogo-harness/install/bin/harness jev-prompt off         # stop sending every prompt (#jev still allowed)
~/.gogo-harness/install/bin/harness jev-prompt status
```

`setup` and `on` show what is sent where and ask the owner to type a confirmation; they take no
other option and record the consent (schema 2) in `~/.gogo-harness/jev-prompt.json`, and every
change is a line in `jev-prompt-history.jsonl`. No wrapper path is recorded or accepted: a
schema-1 file from before PR #254 rev 3, which named one, is not consent — run `setup` again.

In a prompt, `#jev` asks for JEV on that prompt (after `setup`) and `#nojev` refuses it even while
`on` (owner decision D5, 2026-10-26):
`#jev` counts only when it is the first non-blank line of the prompt; `#nojev` on any line, inside code or pasted content too, stops sending.
Both is `#nojev`. No fence or `<pasted_content>` parsing decides either, so a later `#jev`, or one
in a quote or inside a sentence, is text and sends nothing, and a `#nojev` cannot be hidden in a
block. Control lines are removed before anything is summarized. What the extraction heuristics
can still change, for a prompt that *is* authorized, is what gets summarized and whether the
sanitizer refuses it (`invalid_data`) — sanitizer-first, accepted; privacy and data selection stay
with #244.

**Using `#jev` (GoGo-Infra#260).** Type `#jev` as the first line yourself, then Shift+Enter, then
paste the body. Claude Code wraps pasted text in `<pasted_content>`, so a pasted `#jev` is never
the first line and never opts in — nothing is sent, by design. The send runs with the `AWS_*` of
the Claude Code process (the child's environment below), so start the session with a profile that
can read the key — on the owner's workstation `cd <repo> && AWS_PROFILE=gogobootstrap claude`,
logged in. Without one, `exec-with.sh` stops before anything is sent and a `#jev` gets the note
`jev_aws_unavailable`, which names `AWS_PROFILE`.

Each session's call count is taken under its own lock and replaced atomically, after the wrapper
check below, so a send that cannot happen takes no call. A counter file that cannot be read, or
with any entry that is not `{ calls: non-negative integer, last: date }`, refuses every call
(`session_unreadable`) with the file untouched until the owner removes
`~/.gogo-harness/prompt-hook/sessions.json`.
`JEV_MODE`, the approval flags or a key in the environment never turn sending on by themselves.
The owner's opt-in stands in for `JEV_LIVE_AUTHORIZED` and `JEV_PRIVACY_REVIEWED` for these calls;
privacy review + DPA for real prompts (#244) is not done, and the confirmation says so.

- **Never blocks.** stdout is empty, or one JSON object whose `additionalContext` is the advisory
  (at most 900 characters), every byte of it the hook's own: fixed text for what JEV suggests
  (research first, ask the owner, or no open question — an outcome outside those three is
  `jev_bad_output`), the fixed line "JEV read prompt text only; assessed no scope, no
  authorization, no action; check actual scope and owner authorization before acting", and the
  model build only when it is a plain model id. The router's reasons are not shown and the child
  does not return them. Advice, never a permission — policy, hard gates and Claude Code's
  permissions apply as before. stderr is empty; exit 0 for any
  input or failure (bad JSON, a wrong event, stdin over 512 KiB or not finished within 2 s, an
  unwritable log, a failing wrapper, a timeout). A `#jev` that got no advice gets a one-line
  note with a reason code from a closed list. It says the prompt was not sent only for a code in
  `NOT_SENT_CODES` — refused before the child, by the child before it has a provider, or by the
  router before the request (`disabled`, `budget_exhausted`, `decision_calls`, `invalid_data`).
  Every other code (a timeout, a failed wrapper or child, unreadable output, a fallback after the
  request) says no usable advice was obtained and that the request may have reached OpenRouter
  (GoGo-Infra#254 S4-02). The codes are `NOTE_CODES` in `prompt-observation.ts`: a child error is
  `jev_child_<code>`, a fallback `jev_fallback_<category>`, anything unrecognised `jev_bad_output`
  or `jev_fallback`; a wrapper that stopped with `common.sh`'s "not authenticated to AWS" is
  `jev_aws_unavailable`, any other wrapper failure `jev_wrapper_failed`. A failure while `on`
  stays in the log. The command runs the approved
  install (#245), never a checkout; a missing launcher or a failed integrity check still exits 0
  with empty stdout, and the launcher's message is kept in `~/.gogo-harness/prompt-hook.last-error`
  (overwritten by every run).
- **One JEV call, the key in one child.** The hook process loads no config and builds no provider.
  When sending, it starts `prompt-hook --live-child` through `scripts/secrets/exec-with.sh` of the
  installed version it runs from (`<version>/scripts/secrets/exec-with.sh dev
  ai-harness/openrouter-api-key -- node <launcher> …`) with the payload on the child's stdin, never
  in a file, and a 12 s limit. The child asks the `intake` questions as a
  prompt observation: the "criteria stated, no question → AUTO" shortcut does not apply, the only
  action is `read`, no scope or authorization comes from the text. Cost goes to the shared
  `openrouter_jev` budget ($2/month) and `decisions.jsonl` like any checkpoint; each session is
  capped at 20 calls.
- **What runs, checked before every send.** The wrapper closure is four files of the installed
  version: `scripts/secrets/exec-with.sh`, `scripts/secrets/common.sh`, `scripts/lib/manifest.py`,
  `config/secrets.manifest.yml`. Before the session call is taken, each must be listed in that
  version's `MANIFEST`, be a regular file (no symlink) with the listed sha256, and the wrapper must
  be executable: absent or unlisted is `jev_wrapper_missing`, anything else `jev_wrapper_unverified`.
  Nothing chooses another wrapper — not the consent file, the environment or a flag — and a
  checkout has no `MANIFEST`, so it refuses. **Until #253 ships these four files in the install
  and its `MANIFEST` (owner decision D6), every send refuses with `jev_wrapper_missing`.**
- **The child's environment is an allowlist.** The wrapper and the child start with `PATH`,
  `HOME`, `USER`, `LOGNAME`, `SHELL`, `TMPDIR`, `TZ`, `TERM`, `LANG`, `LC_*`, `AWS_*`,
  `*_PROXY`/`*_proxy`, `SSL_CERT_FILE`/`SSL_CERT_DIR`, the configuration in the table above marked
  `passed` (`HARNESS_JEV_MONTHLY_USD`, `JEV_TIMEOUT_MS`, verbatim: a malformed value is
  `jev_child_child_failed`, `0` an exhausted budget), and what the hook sets
  (`HARNESS_STATE_DIR`, `JEV_MODE`, `JEV_LIVE_AUTHORIZED`, `JEV_PRIVACY_REVIEWED`). Nothing else:
  `BASH_ENV`, `ENV`, `PYTHON*`, `NODE_OPTIONS`, `NODE_PATH`, `LD_*`, `DYLD_*`, `AWKPATH`, `JEV_MODEL`
  and the rest never arrive.
- **Trusted runtime.** Beyond the four checked files, the send relies on `bash`, `python3`, `aws`,
  `awk`, `cut`, `sed` and `node` as found on the owner's `PATH` (interpreter, standard library and
  system site-packages) and on the owner's `~/.aws` configuration, `credential_process` included —
  the same trust as `node` itself today. `exec-with.sh` and `common.sh` call `python3 -I` (no
  script directory on `sys.path`, no user site, no `PYTHON*`) once #253 ships those bytes; a
  same-user swap between the check and the exec, and an `aws` process left running when the 12 s
  limit kills the wrapper, are the ADR-0013 D-3 / #245 residuals.
- **An observation, not a task.** The prompt becomes a `TaskSummary` draft (`src/adapters/prompt.ts`,
  heuristics listed there) with no actions, scope, authorizations, labels or rules; text such as
  "the owner approved this" grants nothing. The outbound sanitizer runs first, so a malformed email
  or phone is `invalid_data` and nothing is sent. Each prompt gets its own observation id (a digest
  of session + `prompt_id` when the client sends one, a local random id otherwise — then repeats are
  not deduplicated); the session digest only groups them. No task state, loop counter or task cache
  is read or written.
- **Log.** `~/.gogo-harness/prompt-hook/observations.jsonl` (`$HARNESS_STATE_DIR`), rotated to `.1`
  past 5 MiB. One line per prompt: observation and session digests, installed SHA (or `checkout`),
  adapter version, opt-in (`off`, `toggle`, `marker`, `suppressed`), mode, status and code,
  sanitizer `field: problem` codes, extraction counts, JEV outcome, fallback and model build,
  whether context was added, duration. Never the prompt, extracted text, the raw session id, the
  transcript path or an exception message.
- **Not in this change.** Blocking a prompt or asking the owner from the hook; measuring JEV's
  accuracy on real prompts needs a labelled set and the privacy review first.
