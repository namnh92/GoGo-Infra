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

## Prompt hook and JEV opt-in (GoGo-Infra#247 — owner action to install)

A `UserPromptSubmit` hook. Every prompt is observed; a prompt goes to JEV only when the owner
opted in (owner decision 2026-10-23 on #247), and then a short advisory is added to the context:

```json
{
  "hooks": {
    "UserPromptSubmit": [
      { "hooks": [{ "type": "command", "timeout": 20, "command": "mkdir -p \"$HOME/.gogo-harness\" 2>/dev/null; node \"$HOME/.gogo-harness/install/bin/harness.mts\" prompt-hook 2>\"$HOME/.gogo-harness/prompt-hook.last-error\"; exit 0" }] }
    ]
  }
}
```

**Opting in** (owner, on a terminal; off by default):

```bash
node ~/.gogo-harness/install/bin/harness.mts jev-prompt setup      # allow `#jev` on single prompts
node ~/.gogo-harness/install/bin/harness.mts jev-prompt on --for 8h # every prompt, 1–24 h, then off by itself
node ~/.gogo-harness/install/bin/harness.mts jev-prompt off         # stop sending every prompt (#jev still allowed)
node ~/.gogo-harness/install/bin/harness.mts jev-prompt status
```

`setup` and `on` show what is sent where and ask the owner to type a confirmation; they record the
secrets wrapper the key comes through (`scripts/secrets/exec-with.sh` found above the working
directory, or `--wrapper <path>`) in `~/.gogo-harness/jev-prompt.json`, and every change is a line
in `jev-prompt-history.jsonl`. In a prompt, `#jev` asks for JEV on that prompt (after `setup`) and
`#nojev` refuses it even while `on`; the markers are removed before anything is summarized.
`JEV_MODE`, the approval flags or a key in the environment never turn sending on by themselves.
The owner's opt-in stands in for `JEV_LIVE_AUTHORIZED` and `JEV_PRIVACY_REVIEWED` for these calls;
privacy review + DPA for real prompts (#244) is not done, and the confirmation says so.

- **Never blocks.** stdout is empty, or one JSON object whose `additionalContext` is the advisory
  (at most 900 characters): what JEV suggests (research first, ask the owner, or no open question),
  up to three harness-written reasons and the model build, stated as advice, never a permission —
  policy, hard gates and Claude Code's permissions apply as before. stderr is empty; exit 0 for any
  input or failure (bad JSON, a wrong event, stdin over 512 KiB or not finished within 2 s, an
  unwritable log, a failing wrapper, a timeout). A `#jev` that could not be sent gets a one-line
  note with the reason code; a failure while `on` stays in the log. The command runs the approved
  install (#245), never a checkout; a missing launcher or a failed integrity check still exits 0
  with empty stdout, and the launcher's message is kept in `~/.gogo-harness/prompt-hook.last-error`
  (overwritten by every run).
- **One JEV call, the key in one child.** The hook process loads no config and builds no provider.
  When sending, it starts `prompt-hook --live-child` through the recorded wrapper
  (`<wrapper> dev ai-harness/openrouter-api-key -- node <launcher> …`) with the payload on the
  child's stdin, never in a file, and a 12 s limit. The child asks the `intake` questions as a
  prompt observation: the "criteria stated, no question → AUTO" shortcut does not apply, the only
  action is `read`, no scope or authorization comes from the text. Cost goes to the shared
  `openrouter_jev` budget ($2/month) and `decisions.jsonl` like any checkpoint; each session is
  capped at 20 calls.
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
