# AI Harness — operating guide

Decision layer for Claude Code tasks: a deterministic policy engine, a JEV decision router
consulted only at checkpoints, loop and budget controls, a decision log and durable handoffs.
Why and where the boundaries are: [`adr/0013`](adr/0013-ai-harness-jev-decision-router.md).
Issue: GoGo-Infra#241.

## Run it

```bash
cd harness
node --test test/*.test.ts                 # 69 deterministic tests, no key, no network
pnpm install --ignore-workspace && pnpm typecheck

# A checkpoint, deterministic only (the default — JEV disabled):
node src/cli.ts decide --input test/fixtures/task-ambiguous.json
# The same through fixtures (exercises the JEV mapping, says nothing about model quality):
JEV_MODE=mock node src/cli.ts decide --input test/fixtures/task-ambiguous.json \
  --fixture test/fixtures/mock-intake.json

node src/cli.ts status                     # budgets per account + decision metrics
node src/cli.ts billing --mode interactive # refuses if ANTHROPIC_API_KEY is in this shell
```

Exit codes: `0` AUTO_EXECUTE · `10` RESEARCH_AND_CONTINUE · `20` HUMAN_APPROVAL · `2` usage or
configuration error.

### Live mode — only after the owner authorizes paid inference

```bash
JEV_MODE=live JEV_LIVE_AUTHORIZED=yes \
  ./scripts/secrets/exec-with.sh dev ai-harness/openrouter-api-key -- \
  node harness/src/cli.ts decide --input task.json
```

The key reaches that one process only. It is never in a `.env`, never exported in a shell,
never in a URL, never logged.

## Input

`decide --input` takes a `RouterInput` (`harness/src/router/router.ts`):

| Field | Meaning |
| --- | --- |
| `taskId` | Issue reference, e.g. `GoGo-BE#709`. Used for grouping, not sent as meaning. |
| `checkpoint` | `intake` · `scope_change` · `ambiguity` · `repeated_failure` · `review_planning` |
| `summary` | `TaskSummary` — written by the session from the issue. Paths, never file contents. |
| `actions` | What the next step will do, as `ActionKind`s. `classifyCommand` / `classifyEdit` map a command or a path. |
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
| `HARNESS_CONCURRENCY` | `1` | automation concurrency |
| `OPENROUTER_API_KEY` | — | from `exec-with.sh dev ai-harness/openrouter-api-key` |

## Cost controls and monitoring

Three accounts, never summed (ADR-0013 D-7):

| Account | Billing | Local control | Provider-side control (owner) |
| --- | --- | --- | --- |
| `claude_max` | Max 5x subscription, interactive Claude Code | `billing --mode interactive` refuses an `ANTHROPIC_API_KEY` in the shell | — |
| `anthropic_api` | Anthropic API, headless automation | $100 target, $10 reserve, stops at $90 committed | workspace spend limit, auto top-up off |
| `openrouter_jev` | OpenRouter, JEV decisions | $2 target; budget checked before every call | key-level credit limit |

Amounts: `reported` (provider `usage.cost`) > `estimated` > `unknown`. An unknown cost (timeout,
network error, 5xx) is counted at a per-call ceiling ($0.001 for JEV) against the budget and
shown as a count of unknown-cost calls, never as $0. A request that never left the process
(disabled, over budget, rejected 4xx) is `not_sent` — the one honest zero.

`status` prints, per provider and model build: requests, cache hits, fallbacks, latency
p50/p95 (nearest rank; `null` with no samples), input/output tokens when reported, reported
cost, unknown-cost calls, error categories, outcomes — and the budget state of each account.

These are separate from GoGo-BE's Cost Center: the harness is development tooling, not a
product provider. GoGo-BE registers `openrouter` as a planned provider for its own runtime use
(GoGo-BE#709) with its own key.

## Proposed Claude Code hook (owner action — not installed)

Installing this edits `.claude/settings.json`, a permission-policy change. Proposed shape, for
the owner to adopt or not:

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
