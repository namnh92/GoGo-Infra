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
configuration error.

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

Minimization is pattern matching (`harness/src/runtime/sanitize.ts`), and `JEV_PRIVACY_REVIEWED`
attests to exactly this coverage:

| Data | Caught | Not caught (residual — keep it out of the summary) |
| --- | --- | --- |
| Email | `local@domain.tld` | an address written as `name at domain` |
| Phone | Vietnamese national `0…` / `+84…` (9–11 digits, spaces, dots or dashes); international `+<country code>` followed by 7–13 digits with spaces, dots, dashes or parentheses | a national number without `+` outside Viet Nam (`(415) 555-0133`, `020 7946 0958`); extensions written as words |
| Coordinates | decimal pairs `lat, lon` with ≥ 3 decimals; a labeled value `lat`/`latitude`/`lng`/`lon`/`longitude` `=` or `:` a decimal | DMS (`10°46'37"N`), a bare pair separated by whitespace only, plus codes, geohashes, a place name |
| Home directory | `/Users/<name>`, `/home/<name>`, `C:\Users\<name>` | a user name elsewhere in a path or in prose |
| Prose | — | a person's name, a street, a place, an account id written as text |

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
| `repoRoot` | The directory the write targets are spelled from. Default: the CLI's working directory. The checkout root is the nearest ancestor with `.git` (a file in a worktree); relative targets are rebased onto it (`cd harness` + `src/cli.ts` → `harness/src/cli.ts`, protected), absolute targets must be spelled under it, and each component is inspected in order. |
| `humanAuthorizations` | Kinds the issue author authorized explicitly (only `task_authorizable` ones count). |
| `failure` | `repeated_failure` only: `{ failureClass, signature }`. |

## Configuration

| Variable | Default | Meaning |
| --- | --- | --- |
| `JEV_MODE` | `disabled` | `disabled` · `mock` · `live` |
| `JEV_LIVE_AUTHORIZED` | — | must be `yes` for `live` |
| `JEV_MODEL` | `typesafe/jev-1.14` | pinned id; aliases refused |
| `JEV_TIMEOUT_MS` | `5000` | 100…15000 |
| `HARNESS_STATE_DIR` | `~/.gogo-harness` | ledger, decision log and per-task state `tasks/<task>-<hash>.json` (loop counters + decision cache, so limits hold across separate `decide` calls) — per machine, not committed |
| `HARNESS_JEV_MONTHLY_USD` | `2` | local JEV target |
| `HARNESS_ANTHROPIC_MONTHLY_USD` / `_RESERVE_USD` | `100` / `10` | local Anthropic API target |
| `HARNESS_CONCURRENCY` | `1` | checkpoint serialization only; only `1` is accepted — `decide` holds `HARNESS_STATE_DIR/harness.lock` across load, limits, inference and save, so overlapping `decide` calls queue instead of losing counters or charges. The lock ends when `decide` returns: it does not limit how many Claude sessions or automation jobs run (not enforced here) |
| `JEV_PRIVACY_REVIEWED` | — | must be `yes` for `live`: the privacy review + DPA for the outbound data contract are recorded |
| `OPENROUTER_API_KEY` | — | from `exec-with.sh dev ai-harness/openrouter-api-key` |

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

## Proposed Claude Code hook (owner action — not installed)

Installing this edits `.claude/settings.json`, a permission-policy change. Proposed shape, for
the owner to adopt or not. It runs the harness from an editable checkout; running an approved,
pinned copy outside the worktree is tracked separately (ADR-0013 D-3, A-F-03):

```json
{
  "hooks": {
    "Stop": [
      { "hooks": [{ "type": "command", "command": "node \"$CLAUDE_PROJECT_DIR\"/../GoGo-Infra/harness/src/cli.ts status >/dev/null" }] }
    ]
  }
}
```

The checkpoint call itself (`decide`) is made by the session at intake and on failures, as the
workflow in ADR-0013 D-4 describes; a per-tool-call hook is deliberately not proposed.
