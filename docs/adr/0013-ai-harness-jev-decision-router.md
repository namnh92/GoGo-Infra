# ADR 0013 — AI Harness: deterministic policy first, JEV for the semantic residue

**Status:** proposed — 2026-10-22 (awaiting owner review; nothing here is live)
**Issue:** GoGo-Infra#241; backend counterpart GoGo-BE#709 (depends on this one)
**Basis:** GoGo-Infra `2149fdc` · GoGo-BE `068ffdd`
**Code:** `harness/` (this repository)

## Context

GoGo is built largely by Claude Code sessions driven from GitHub issues. The cost of that today
is interruptions: a session asks a person things it could have found in the repository, the
issues or a handoff, or that a safe, reversible default already answers. The opposite failure is
worse and rarer — a session doing something only a person may authorize. The owner asked for a
decision layer that reduces the first without loosening the second, using TypeSafe's Jev
("JEV") through OpenRouter.

### Assessment of what already exists (Phase A)

| Capability | Where it lives today | What it already solves |
| --- | --- | --- |
| Per-tool-call permission | Claude Code's own permission modes (default / acceptEdits / auto), sandboxing; no `.claude/settings.json` is committed in any GoGo repository | Whether one command or edit may run. **JEV is not added here** — it would cost a call per tool use and duplicate a mechanism that already exists. |
| Hooks / lifecycle | None configured in any repository | Nothing yet. Installing a hook changes a session's permission behaviour, so it is an owner action (below), not part of this change. |
| Rules and skills | Each repository's `CLAUDE.md`; the workspace skill set (`GOGO_ENGINEERING_SKILLS_AND_PLANS.md`, parent workspace, not in these repositories) | Project rules. The harness quotes them into `state` instead of restating them. |
| Issue-driven execution | GitHub issues with `P*`, `size:*`, `wbs`, `blocked-external` labels; branch `feature/GOGO-<n>-…`; Conventional Commits | Task intake. The harness's `TaskSummary` is built from an issue. |
| Handoffs | `dev/handoffs/*.md` in the parent workspace (ADR-0012a cites one) — not in any repository, so not reachable from a cloud session | Session continuity, on one machine. This ADR adds a committed handoff (`docs/handoffs/`) so it survives a machine change. |
| Review | `Claude Code Review` bot, `Claude Approvals` check, named SA review rounds, CODEOWNERS, one human approval | Review gates. The harness plans *which* review a change needs; it never approves or merges. |
| Retry policy | GoGo-BE `withResilience` for provider calls; nothing for agent loops | Provider retries. Agent repair loops had no bound — added here (D-6). |
| Budget | GoGo-BE cost registry for *product* providers; nothing for AI tooling spend | Product cost. AI spend had no ledger — added here (D-7). |
| CI | `validate.yml` here (terraform, gitleaks, shellcheck, workers), test/typecheck/lint/OpenAPI gates in GoGo-BE | Quality gates. Unchanged; the harness requires them, it does not replace them. |
| Secrets | SSM, `config/secrets.manifest.yml`, `scripts/secrets/exec-with.sh` for one-command credentials | Credential handling. The harness keys follow the `ci` + `consumer: pipeline` pattern of `sentry/mobile-auth-token`. |

Conclusion: deterministic rules and Claude Code's native permission system already decide most
of what a session may *do*. What nothing decides is the semantic part of *whether to ask*: is
this task clear, is the missing context discoverable, does a reversible default exist, is this
failure in scope. That residue is what JEV is for.

### Verification of the provider contract (2026-10-22)

`openrouter.ai` and `docs.typesafe.ai` were unreachable from the session that wrote this
(egress proxy refusal / DNS). The contract was verified from OpenRouter's own published skill,
`OpenRouterTeam/skills` → `skills/openrouter-decisions/references/decisions-api.md`, which cites
the OpenAPI page as source of truth, and TypeSafe's `typesafe-ai/skills` `SKILL.md`:

- `POST https://openrouter.ai/api/alpha/decisions`, `Authorization: Bearer $OPENROUTER_API_KEY`.
- Body `{ model, state, questions, session_id?, trace?, user?, provider? }`; question types
  `noul` (criteria optional, exactly `true`/`false`), `choice` (criteria map), `score` (ordered
  array, lowest first).
- Response `{ id, model, provider, answers, usage: { input_tokens, output_tokens, cost } }`;
  `noul` → `noul` (P(yes), no confidence); `choice` → `choice`, `probabilities?`, `confidence?`;
  `score` → `score`, `legend?`, `probabilities?`, `confidence?`. `usage.cost` is USD.
- Pricing (OpenRouter model page via search, 2026-10-22): $0.042 per 1M input tokens, output
  free, 262K context, `typesafe/jev-1.14` released 2026-10-14, one provider.

**Not verified** (and therefore not relied on): that `typesafe/jev-1.14` is served on
`/api/alpha/decisions` (the reference's examples use `jev-1.13`; the catalog query
`GET /api/v1/models?output_modalities=decisions` needs network access); the Decisions-specific
error table (the adapter uses OpenRouter's general one: 400/401/402/403/408/429/5xx); latency.
The first authorized live call must log the response `model` and settle the first point.
**Settled 2026-10-22** by the owner's authorized GoGo-BE eval run (157 Decisions calls, key
`gogo_be_dev`): the response named `typesafe/jev-1.14-20261014`, so `jev-1.14` is served on
`/api/alpha/decisions`; latency p50 579 ms / p95 688 ms, under this harness's 5 s default
timeout; every call reported `usage.cost` (none unknown). The error table is still unverified.

## Decision

**D-1 Roles.**

| Component | Responsible for | Never does |
| --- | --- | --- |
| Deterministic policy engine (`harness/src/policy`) | Whether an action may run without a person; reads facts only | Read a model answer |
| JEV Decision Router (`harness/src/router`) | Semantic judgments at checkpoints → `AUTO_EXECUTE` / `RESEARCH_AND_CONTINUE` / `HUMAN_APPROVAL` | Grant a permission, lift a gate, run a tool |
| Claude execution agent | Planning, implementation, debugging, tests, docs | Bypass the policy verdict |
| Human approval gates | Production, destructive data, secrets, permission policy, money, merges, irreversible operations | — |

The three outcomes are GoGo's vocabulary, not JEV output. The result at every checkpoint is the
**stricter** of the policy outcome and the JEV outcome: JEV can add caution, never remove it.

**Outcomes are advisory** (owner decision 2026-10-22, PR #242 A-F-01). `RouterInput.actions` and
`humanAuthorizations` are declared by the session that asks; the harness has no trusted adapter
that binds a declaration to the operation that follows, so a decision says what the stated plan
allows, not what the session may do. Every decision carries an `advisory` field saying so. What
the harness can check it re-derives: a write action (`edit_in_scope`, `edit_out_of_scope`,
`ci_workflow_change`, `update_handoff`, `write_test_evidence`) needs a target and is classified
from that target, whatever kind was declared. The target is placed in the checkout the working
directory belongs to (the nearest `.git`; A-F-03 — a symlinked spelling of that directory counts
only when it resolves to the same checkout, A-F-09), walked component by component in filesystem
order — a `..` is stepped, not collapsed first (A-F-02) — then one normalized spelling serves the
protected-path match and the scope check alike (A-F-01), and it is checked against the task scope: no
target, a symbolic link or hard-linked file on the way, a path that leaves the checkout, or a
working directory in no checkout is `unknown`; a protected path is its gate; a workflow file
outside the scope needs `ci_workflow_change` **and** `edit_out_of_scope`; any other write outside
the scope, a handoff or test-evidence write included, needs `edit_out_of_scope` (A-F-01). The
required set is the union of the declared and the derived boundaries, never the looser one.
Protected paths match case-insensitively; scope matches on path components. The other kinds
(`test`, `commit`, …) are taken as declared and unverified — consistent with D-3b, which leaves
no shell inference to check them against. Enforcement stays with Claude Code's permission system,
the sandbox and branch protection; a trusted adapter is future work, not this POC.

**D-2 Provider modes.** `disabled` (default) · `mock` (fixtures, for tests) · `live`
(OpenRouter). Live needs `JEV_MODE=live` **and** `JEV_LIVE_AUTHORIZED=yes` **and**
`JEV_PRIVACY_REVIEWED=yes` (the privacy review + DPA for the outbound data contract in
`docs/ai-harness.md` are recorded — `ai-guardrails.md`, PR #242 A-F-04; a person's statement the
harness cannot check) **and** a key handed to the process by `exec-with.sh`; an unknown mode is an error. The model id is pinned
(`typesafe/jev-1.14`), aliases (`~…`) are refused, the response `model` is logged.

**D-3 Hard approval boundaries.** `deploy_production`, `deploy_staging`, `infra_apply`,
`db_destructive`, `secret_rotate`, `permission_policy_change`, `billing_change`, `purchase`,
`merge_pr`, `push_protected_branch`, `force_push`, `external_irreversible`, and anything
unclassifiable (`unknown`). A human authorization written into a task lifts only the
`task_authorizable` set (`open_pr`, `comment_issue`, `ci_workflow_change`, `edit_out_of_scope`,
`paid_inference`). Editing anything under `harness/` is itself `permission_policy_change`: the
router, the CLI and the tests define what a policy verdict means as much as `src/policy/` does
(owner decision 2026-10-22, PR #242 A-F-03). The path is read relative to the checkout root, not
to the working directory, so `cd harness` and `src/cli.ts` is still `harness/src/cli.ts`. That
stops the harness from authorizing its own edit; it does not stop an edit made outside a
checkpoint, because the harness runs from the editable checkout. Running an approved, pinned copy
outside the worktree is GoGo-Infra#245.

**D-3a Shell commands are classified fail-closed** — *superseded by D-3b the same day; kept as the record of what was tried.* (owner decision 2026-10-22, after Sol rounds 1–3 on
PR #242 found six P1 bypasses in the regex classifier — every one a shell form nobody anticipated, every one
failing open into autonomy). `harness/src/policy/shell.ts` tokenizes like a shell, refuses syntax it does not
model (substitution, backticks, escapes, unquoted `$`, parentheses, input redirects, background `&`, output
redirects other than `/dev/null`), splits on `&&` `||` `;` `|` newline outside quotes, and classifies every
segment against an argument-aware allowlist (e.g. `find` without `-delete`/`-exec*`/`-ok*`/`-fprint*`, `git
branch` listing flags only, `git push [-u] origin <branch>` exactly, `sed -n '<n>,<m>p'` only). The line's kind
is the strictest segment's — no early return. Anything not allowlisted is `unknown` (hard gate); gated commands
are recognised only to give the question a name. `curl` and `claude -p` are never inferred as `paid_inference`
— that kind comes only from an action the task declares. Edit paths are normalised before scope checks, so
`harness/../docs/x` is out of a `harness/` scope. Consequence: a gap in the allowlist costs one extra question,
never an unapproved action. Q3 of the SA review (allowlist vs permission files vs dropping classification) is
answered for the POC by this decision; Astra may still revisit it.

**D-3b No shell line is autonomous** (owner decision 2026-10-22, after PR #242 review r4). The D-3a allowlist
still let write and exec forms through as `read`/`test`: `sed -n 1p -e '1e …'` and `git fetch --upload-pack=…`
ran any command inline, `sed -n 1p -i <path>` and `node --test --test-reporter-destination=<path>` rewrote any
file (the policy engine, workflows, prod Terraform included), `git push origin @` pushed `main` as a feature
branch, and `rg --hostname-bin` ran a program. Every allowlisted tool has flags nobody listed, so argument
checks fail open one level down — the fourth round with the same failure. `classifyCommand` therefore no
longer infers autonomy: every shell line is a hard gate, named when recognisable (`merge_pr`, `infra_apply`,
`push_protected_branch`, …) so the owner's question says what it is, `unknown` otherwise. `shell.ts` is
removed. Autonomy comes only from an action kind the step declares in `RouterInput.actions` (`test`,
`commit`, `push_feature_branch`…) and from `classifyEdit` for paths. Cost: an autonomous run that wants to
run a shell command asks first; for the POC that is the intended trade.

**D-4 Checkpoints, not tool calls.** JEV is evaluated at: task intake (only when the rules do not
settle it), material scope change, unresolved ambiguity, repeated failure (from the second
attempt), review planning. Never before a file read or a shell command. Questions per checkpoint
are in `harness/src/router/questions.ts`; each is one judgment, with a no-match option where
nothing may fit.

**D-5 State.** A sanitized `TaskSummary` — title, description, acceptance criteria, open
questions, labels, paths (not contents), sources already searched, quoted rules — redacted for
credentials and minimized for personal data (emails; Vietnamese phone numbers in every common
spelling — `0…`, `+84`, `84`, `0084`, trunk `0`, separators of up to five spaces, dots, dashes,
parentheses or brackets between any two digits, replaced whole; decimal
coordinate pairs and `lat=`/`lng=` labeled values; home-directory names; PR #242 A-F-04 — matched
on the whitespace-collapsed text that is sent), capped at 8,000 characters. The provider's
`session_id` is a digest of the task id, never the id. Not caught by pattern, and therefore part
of what the privacy review in D-2 attests to: prose names, streets and places; non-Vietnamese
phone numbers, which are not supported and not minimized (owner decision 2026-10-22); DMS or
whitespace-only coordinate pairs. The full outbound contract, with the caught/not-caught table, is
in `docs/ai-harness.md`. Identical context is answered from cache.

**D-6 Loop controls.** Three repair attempts per failure class, then escalate; the same error
signature twice in a row → change approach; eight attempts per task; ten JEV calls per task;
two hours wall clock; checkpoint concurrency 1. All configurable, all deterministic, all win
over a JEV "retry". The counters and the decision cache are persisted per task under
`HARNESS_STATE_DIR`, because each CLI checkpoint is its own process, and one lockfile serialises
the whole checkpoint transaction (ledger + task counters are shared state). That is checkpoint
serialization: the lock ends when `decide` returns, so it does not limit how many sessions or
automation jobs run — execution-level concurrency is not enforced here (PR #242 A-F-08). A live
JEV call is reserved in the ledger and counted against the task's call limit on disk before the
request leaves; a process killed in flight leaves an unknown-cost call, never a lost one (A-F-05).
The decision cache is keyed by provider mode and model, and disabled mode never reads it. Shell
commands: D-3b.

**D-7 Billing separation and budgets.** Three accounts, never summed:
`claude_max` (interactive Claude Code, subscription, not metered in USD), `anthropic_api`
(headless automation, target $100/month with a $10 reserve), `openrouter_jev` (target $2/month).
Interactive sessions must not carry `ANTHROPIC_API_KEY` (`cli.ts billing --mode interactive`);
Anthropic automation is never routed through OpenRouter; the two keys are separate SSM rows.
The ledger counts an unknown cost at a per-call ceiling against the budget and reports it as
unknown — never $0. These are local targets; the provider-side caps are owner actions.
`anthropic_api` is **not integrated** (PR #242 A-F-08): nothing in the harness runs or records an
Anthropic call, so the $100/$10 target is configuration only, `status` reports
`not_integrated` and usage UNKNOWN, and the Anthropic workspace spend limit is the only cap until
an integration is separately approved.

**D-8 Observability.** One JSONL record per checkpoint: provider, model build, decision types,
latency, tokens, cost + status, error category, fallback, cache hit, outcome, source — and a hash
of the state, never the state. `cli.ts status` prints p50/p95, request/fallback counts, error
categories and budget status per account.

**D-9 Handoffs.** `harness/src/runtime/handoff.ts` renders a redacted handoff (done, evidence,
decisions with their source, blockers, next). Durable copies are committed under
`docs/handoffs/`; the workspace `dev/handoffs/` convention continues where it is reachable.

**D-10 Thresholds are provisional.** The router's gates (`THRESHOLDS` in `router.ts`) are the
official starting points tightened toward caution, not numbers probed on GoGo tasks. Before live
mode is used for real decisions, a probe set (the harness scenarios as real summaries) is run
live and each threshold is set from observed probabilities. Mock results say nothing about
model quality.

**D-11 Isolation from GoGo-BE.** The backend's JEV use (GoGo-BE#709) has its own adapter, its
own SSM row under `backend`, its own budget line in the cost registry. No code is shared across
repositories and nothing in GoGo-BE can invoke the harness, so production traffic cannot start a
development agent. **Drift found and closed (2026-10-22):** one OpenRouter key, `gogo_jev_dev`,
served both the harness and the backend POC (one credit limit, one spend line). The owner split
it the same day: the harness key is now `gogo_ai_harness_dev`; the backend POC gets its own
`gogo_be_dev` when its key is created.

## Owner actions (not done by this change)

1. Authorize, or not, paid JEV inference: create the OpenRouter key `gogo_ai_harness_dev` with a
   key-level credit limit ($2), then `put.sh dev ai-harness/openrouter-api-key`.
2. Create the Anthropic workspace for automation with a spend limit and auto top-up off before
   `put.sh dev ai-harness/anthropic-api-key`.
3. Decide whether to install the harness as a Claude Code hook (e.g. a `UserPromptSubmit` or
   `Stop` hook calling `cli.ts decide`). That edits `.claude/settings.json` — a permission-policy
   change this ADR deliberately does not make. `docs/ai-harness.md` has the proposed snippet.

4. For the Cost Center to see actual OpenRouter spend: create an OpenRouter management key
   and `put.sh dev openrouter/management-key` (GoGo-BE#709 collector `openrouter_activity`).
   Keys are filed by `name` (`-` or `_`): `gogo_jev_*` → `openrouter.jev_shared`,
   `gogo_claude_*` → `openrouter.claude_byok` (+ the Claude charge on provider `anthropic`),
   `gogo_ai_harness_*` → `openrouter.dev_tooling`, `gogo_be_*` → `openrouter.decisions`.
5. ~~Split `gogo_jev_dev`~~ — done 2026-10-22 (`gogo_ai_harness_dev`); create `gogo_be_dev`
   with its own credit limit when the backend POC is authorized to call live.
6. Decide on `gogo_claude_dev`: it routes Anthropic calls through OpenRouter (BYOK), which
   D-7 rules out for harness automation. If it serves a product feature (customer-facing
   text), that feature needs its own ADR; the Anthropic workspace spend limit still caps it.

## Consequences

- With JEV disabled (today), every checkpoint still returns an outcome from the deterministic
  rules; nothing depends on the provider being up, paid for, or right.
- A wrong JEV answer can cost an unnecessary question or an extra research step. It cannot run
  a gated action, because the gate is decided before JEV is asked and the combination is the
  stricter outcome.
- Two more `ci` rows to rotate (`ai-harness/*`), declared in the manifest.
- `harness/` is TypeScript run by Node's type stripping, no runtime dependencies; the compiler
  is a dev dependency for CI typecheck only.
