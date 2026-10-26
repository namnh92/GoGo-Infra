# ADR 0014 — GoGo AI assistant: model, keys, budget, kill switch

**Status:** Proposed — 2026-10-26 (the owner approves, or changes the numbers, in the PR)
**Issue:** GoGo-Infra#257 (AI-INF-001); epic GoGo-MobileApp#377; backend GoGo-BE#713
**Authority:** the owner's decisions on GoGo-MobileApp#377, comment "Quyết định của owner
(2026-10-26)"; ADR-0013 owner action 6 ("if it serves a product feature, that feature needs its
own ADR") — this is that ADR.
**Leaves standing:** ADR-0013 in full (D-7, D-11); ADR-0009, extended by one surface (D-8).

## Context

GoGo AI is an in-app chat assistant: a signed-in user asks about GoGo (the "GoGo guide"
documents, published from the CMS — BE#713 `/v1/cms/assistant/documents*`) and about their own
plans, and gets a streamed Vietnamese answer, with actions the user confirms. GoGo-BE already
calls OpenRouter for one thing — JEV intent decisions, key `gogo_be_<env>`, row
`openrouter/api-key`, `consumer: seed`, nothing at runtime (GoGo-BE#709). A chat assistant is a
different cost shape: every turn is thousands of input tokens and hundreds of output tokens on a
frontier model, driven by users rather than by GoGo, and unbounded unless something bounds it.

Owner decisions this ADR implements, not re-opens:

1. Claude, through OpenRouter. The owner has created the DEV key: **`gogo_ai_anthropic_dev`**,
   Anthropic BYOK (OpenRouter routes Claude to GoGo's own Anthropic key).
2. The SSM row is declared by this repository first and `put.sh` runs **after** the manifest
   merges (the 2026-10-23 namespace drift is why).
3. Cost is capped twice: a credit limit on the OpenRouter key, and a per-user daily message limit
   in GoGo-BE. Concrete numbers are proposed here; the owner sets them.
4. Guests cannot use the assistant (the entry point invites them to sign in; the API answers
   401/403 to a guest session).
5. History is stored server-side per account for 90 days (BE#713).

### What was verified, and what was not

- Model ids and list prices were read from OpenRouter's public catalogue
  (`GET https://openrouter.ai/api/v1/models`, no key) on 2026-10-26: `anthropic/claude-sonnet-5.5`
  $2 / $10 per 1M input/output tokens, `anthropic/claude-haiku-5.5` $0.10 / $0.50,
  `anthropic/claude-opus-5.5` $4 / $20; all 1M context. Anthropic's first-party prices for the
  same models match.
- **Not measured:** Vietnamese answer quality and time-to-first-token for either model on GoGo
  prompts. No live call was made for this ADR. D-1's choice is a default to be confirmed by
  BE#713's eval, not a measured result.
- **Not verified:** whether the credit limit on a BYOK key counts the Anthropic charge or only
  OpenRouter's own fee. See D-4 — the design does not depend on the answer.
- **Measured fact on GoGo-BE `develop` (8828ccc):** the cost collector `openrouter_activity`
  files a key by name with `openRouterServiceFor()`; `gogo_ai_anthropic_*` matches no rule today
  and would land in `openrouter.other_keys`. No assistant metric exists in
  `libs/observability/src/metric-labels.ts`, and the collectors write Postgres rows, not
  Prometheus series.

## Decision

**D-1 Primary model: `anthropic/claude-sonnet-5.5`** (SSM `assistant/model`; owner may pick
another). The current Sonnet: the tier meant for interactive, everyday work, at half the Opus
price and with lower latency than Opus, which matters most for a streamed answer the user is
watching appear. Opus 5.5 doubles the cost for depth a guide-and-plans assistant does not need;
Haiku 5.5 is twenty times cheaper and is the first thing to try if BE#713's Vietnamese eval
shows it holds up — that switch is one `put.sh`, no code change. Request settings BE#713 should
start from: streaming on, thinking effort `low` (chat; thinking tokens are billed as output),
the stable system prompt and guide documents first with prompt caching on them, a `max_tokens`
cap per turn.

**D-2 Fallback model: `anthropic/claude-haiku-5.5`** (SSM `assistant/fallback-model`). Used
when the primary errors, times out before the first token, or is overloaded — never as a quiet
cost saver. Cheaper than the primary, so a fallback can never raise spend. Absent means no
fallback: the turn ends with the "unavailable" answer.

**D-3 One dedicated key per environment, named `gogo_ai_anthropic_<env>`.** DEV
`gogo_ai_anthropic_dev` exists; `gogo_ai_anthropic_staging` / `gogo_ai_anthropic_prod` are
created by the owner when those environments are. SSM `/gogo/<env>/backend/openrouter/assistant-api-key`
→ `OPENROUTER_ASSISTANT_API_KEY`, `SecureString`, `consumer: runtime` (the API serves the
assistant). It is **not** `openrouter/api-key` (decisions POC, `gogo_be_<env>`) and **not**
`ci:ai-harness/openrouter-api-key` (harness, `gogo_ai_harness_<env>`): three keys, three credit
limits, three spend lines (ADR-0013 D-7/D-11). `scripts/lib/manifest.test.sh` pins that the
variable is declared by exactly one row. No key ever reaches the app.

**D-4 Monthly ceiling, enforced in three places. Numbers proposed — the owner sets them.**

| Environment | Monthly cap (USD) | Roughly buys (Sonnet 5.5, D-1 assumptions) |
| --- | --- | --- |
| dev | **20** (proposed) | 1,000–2,000 turns: team testing and BE#713's eval |
| staging | **20** (proposed) | same — created with the environment |
| prod | **150** (proposed, revisit after two weeks of real traffic) | 7,500–15,000 turns |

Per-turn estimate behind it: ~6k input tokens (~4k system + guide, cacheable; ~2k history and
question) and ~500 output tokens ≈ **$0.010–0.02 per turn** on Sonnet 5.5 with caching
(~$0.001 on Haiku 5.5). An assumption to be replaced by BE#713's measured figure.

1. **OpenRouter key credit limit** = the cap, with monthly reset, set on `gogo_ai_anthropic_<env>`.
   If the key page offers counting BYOK usage in the limit, turn it on. If it does not, this limit
   caps only OpenRouter's fee on BYOK requests — which is why it is not the only stop.
2. **GoGo-BE** refuses new assistant turns at 100 % of `ASSISTANT_MONTHLY_MAX_USD`
   (SSM `budget/assistant-monthly-max-usd`), counting month-to-date spend from each response's
   reported cost (OpenRouter credits + BYOK upstream). Unset means refuse, the default-deny rule
   of the place-refresh budget (`docs/environments.md`).
3. **Anthropic workspace spend limit** on the Anthropic key OpenRouter uses for BYOK, auto
   top-up off. That key is configured once per OpenRouter account (as far as we know), so every
   BYOK Claude call on the account shares this limit — set it to at least the sum of the BYOK
   uses, and treat it as the last stop, not the budget.

**D-5 Per-user daily limit: 30 messages per signed-in account per UTC day** (proposed; SSM
`budget/assistant-user-daily-max-messages`). Enforced in GoGo-BE before any provider call.
Worst case one account ≈ $0.60/day on Sonnet 5.5. Unset means refuse, never unlimited. Refusals
are a fact in the response (`code`, `retryable: false`, reset time), not a composed sentence.

**D-6 Kill switch, no redeploy.** The authoritative switch is the environment-scoped
`assistant.enabled` row in `FEATURE_FLAGS`, changed and audited through the CMS — the
`place_refresh.enabled` pattern. SSM `flags/assistant` (`FLAG_ASSISTANT`) only seeds it at deploy
(proposed: `false` in prod until launch, `true` on DEV while testing). Off: the API answers
"unavailable" without calling OpenRouter; history stays readable. Hard stop, independent of
GoGo-BE: disable `gogo_ai_anthropic_<env>` in OpenRouter (401/402 → unavailable). The mobile
entry point has its own gate (GoGo-MobileApp#379); neither replaces the other. No assistant row
is `required` anywhere, so an environment without them deploys and the assistant is off.

**D-7 Cost Center: its own spend line.** The key family `gogo_ai_anthropic_*` is recorded beside
the others in the manifest comment at `openrouter/management-key`. GoGo-BE must file it:
`openRouterServiceFor()` gains `gogo_ai_anthropic_*` → **`openrouter.assistant`** (proposed id),
and the BYOK Claude charge of those keys → **`anthropic.assistant`** rather than the shared
`anthropic.claude_byok`. Until then the OpenRouter fee lands in `openrouter.other_keys` and the
Claude charge is mixed with other BYOK spend. A `cost_budgets` row (scope SERVICE
`openrouter.assistant`, amount = the cap) then gives the CMS Cost Center its existing ≥ 80 %
`warning` state in every environment, prod included. Feeds GoGo-BE#711's AI breakdown.

**D-8 Observability and the 80 % alert.** GoGo-BE#713 exports, closed label sets only (no user
id, no model id as free text, no prompt):

| Metric | Type | Labels |
| --- | --- | --- |
| `ai_assistant_requests_total` | counter | `outcome` = ok · error · fallback · refused_budget · refused_user_limit · disabled · unauthenticated |
| `ai_assistant_tokens_total` | counter | `direction` = input · output · cache_read · cache_write; `model_role` = primary · fallback |
| `ai_assistant_first_token_seconds` | histogram | `model_role` |
| `ai_assistant_response_seconds` | histogram | `model_role`, `outcome` |
| `ai_assistant_spend_month_usd` | gauge | — (UTC calendar month to date, OpenRouter credits + BYOK upstream) |
| `ai_assistant_budget_month_usd` | gauge | — (`ASSISTANT_MONTHLY_MAX_USD`; not exported when unset or ≤ 0) |

Grafana Unified Alerting gets one more surface on ADR-0009's terms (one file, one route, a
runbook, ships paused): `observability/local-grafana/grafana/provisioning/alerting/ai-assistant-rules.yaml`
— `ai-assistant-spend-80` (spend / budget ≥ 0.8, warning, absent gauge = NoData) and
`ai-assistant-spend-cap` (≥ 1, high), routed to the existing Telegram contact point by
`service=ai-assistant`, paused by its own `GOGO_AI_ALERTS_PAUSED` until the two gauges exist.
The LAN Grafana is DEV only (ADR-0007); prod's 80 % signal is D-7's Cost Center budget until
prod observability exists.

**D-9 Guests excluded.** A guest session gets 401/403 from `/v1/assistant/*` before any limit is
read or provider called. The per-user limit is keyed by account id; the `user` field sent to
OpenRouter, if any, is an opaque hash, never an email or a name.

**D-10 Retention: 90 days, server-side** — owned by GoGo-BE#713 (retention job; immediate
deletion on account deletion or a privacy request, through the privacy ledger). Prompts and
answers leave GoGo for OpenRouter and Anthropic: the owner confirms on the OpenRouter account
that prompt logging and training use are off before prod.

## Consequences

- Nothing turns on with this change. Every row is optional, the capability `ai_assistant` is
  `planned: [dev]` (so `validate.sh dev --strict --include-planned` lists what is missing), and
  the alert rules ship paused.
- An unset budget or user limit refuses rather than spends — the safe failure, and a visible
  one (`refused_budget` / `refused_user_limit`).
- Changing model, fallback or limits is `put.sh` + deploy, visible in SSM history; switching the
  assistant off is a CMS action, audited, with no deploy.

## Dependencies on GoGo-BE (not done here)

1. BE#713 reads `OPENROUTER_ASSISTANT_API_KEY`, `ASSISTANT_MODEL`, `ASSISTANT_FALLBACK_MODEL`,
   `ASSISTANT_MONTHLY_MAX_USD`, `ASSISTANT_USER_DAILY_MAX_MESSAGES`, `FLAG_ASSISTANT` and the
   `assistant.enabled` feature flag, with the semantics above.
2. BE#713 exports D-8's metrics — above all the two gauges the alert reads.
3. `openRouterServiceFor()` + the BYOK collector file `gogo_ai_anthropic_*` (D-7).
4. Measured Vietnamese quality and time-to-first-token for D-1/D-2, which may move the model.
