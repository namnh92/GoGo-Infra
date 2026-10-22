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

**D-2 Provider modes.** `disabled` (default) · `mock` (fixtures, for tests) · `live`
(OpenRouter). Live needs `JEV_MODE=live` **and** `JEV_LIVE_AUTHORIZED=yes` **and** a key handed
to the process by `exec-with.sh`; an unknown mode is an error. The model id is pinned
(`typesafe/jev-1.14`), aliases (`~…`) are refused, the response `model` is logged.

**D-3 Hard approval boundaries.** `deploy_production`, `deploy_staging`, `infra_apply`,
`db_destructive`, `secret_rotate`, `permission_policy_change`, `billing_change`, `purchase`,
`merge_pr`, `push_protected_branch`, `force_push`, `external_irreversible`, and anything
unclassifiable (`unknown`). A human authorization written into a task lifts only the
`task_authorizable` set (`open_pr`, `comment_issue`, `ci_workflow_change`, `edit_out_of_scope`,
`paid_inference`). Editing `harness/src/policy/` is itself `permission_policy_change`.

**D-3a Shell commands are classified fail-closed** (owner decision 2026-10-22, after Sol rounds 1–3 on
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

**D-4 Checkpoints, not tool calls.** JEV is evaluated at: task intake (only when the rules do not
settle it), material scope change, unresolved ambiguity, repeated failure (from the second
attempt), review planning. Never before a file read or a shell command. Questions per checkpoint
are in `harness/src/router/questions.ts`; each is one judgment, with a no-match option where
nothing may fit.

**D-5 State.** A sanitized `TaskSummary` — title, description, acceptance criteria, open
questions, labels, paths (not contents), sources already searched, quoted rules — redacted for
credentials, capped at 8,000 characters. Identical context is answered from cache.

**D-6 Loop controls.** Three repair attempts per failure class, then escalate; the same error
signature twice in a row → change approach; eight attempts per task; ten JEV calls per task;
two hours wall clock; automation concurrency 1. All configurable, all deterministic, all win
over a JEV "retry". The counters and the decision cache are persisted per task under
`HARNESS_STATE_DIR`, because each CLI checkpoint is its own process, and one lockfile serialises
the whole checkpoint transaction (ledger + task counters are shared state). The decision cache is
keyed by provider mode and model, and disabled mode never reads it. Shell commands are
classified by their most restrictive segment; command substitution and output redirects are
`unknown` (gated).

**D-7 Billing separation and budgets.** Three accounts, never summed:
`claude_max` (interactive Claude Code, subscription, not metered in USD), `anthropic_api`
(headless automation, target $100/month with a $10 reserve), `openrouter_jev` (target $2/month).
Interactive sessions must not carry `ANTHROPIC_API_KEY` (`cli.ts billing --mode interactive`);
Anthropic automation is never routed through OpenRouter; the two keys are separate SSM rows.
The ledger counts an unknown cost at a per-call ceiling against the budget and reports it as
unknown — never $0. These are local targets; the provider-side caps are owner actions.

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
development agent.

## Owner actions (not done by this change)

1. Authorize, or not, paid JEV inference: create the OpenRouter key `gogo-ai-harness-dev` with a
   key-level credit limit ($2), then `put.sh dev ai-harness/openrouter-api-key`.
2. Create the Anthropic workspace for automation with a spend limit and auto top-up off before
   `put.sh dev ai-harness/anthropic-api-key`.
3. Decide whether to install the harness as a Claude Code hook (e.g. a `UserPromptSubmit` or
   `Stop` hook calling `cli.ts decide`). That edits `.claude/settings.json` — a permission-policy
   change this ADR deliberately does not make. `docs/ai-harness.md` has the proposed snippet.

## Consequences

- With JEV disabled (today), every checkpoint still returns an outcome from the deterministic
  rules; nothing depends on the provider being up, paid for, or right.
- A wrong JEV answer can cost an unnecessary question or an extra research step. It cannot run
  a gated action, because the gate is decided before JEV is asked and the combination is the
  stricter outcome.
- Two more `ci` rows to rotate (`ai-harness/*`), declared in the manifest.
- `harness/` is TypeScript run by Node's type stripping, no runtime dependencies; the compiler
  is a dev dependency for CI typecheck only.
