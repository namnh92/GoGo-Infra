# Handoff — TypeSafe Jev integration — AI Harness POC and GoGo-BE intent POC

- Task: `GoGo-Infra#241 + GoGo-BE#709` · Issue: namnh92/GoGo-Infra#241, namnh92/GoGo-BE#709 · Branch: `claude/admiring-keller-49eghr (GoGo-Infra, GoGo-BE)`
- Status: **awaiting_approval**
- Written: 2026-10-22T08:01:10.112Z

## Done
- Verified the Decisions API contract from OpenRouterTeam/skills (openrouter-decisions/references/decisions-api.md) and typesafe-ai/skills SKILL.md; openrouter.ai and docs.typesafe.ai were unreachable from the session (proxy 403 / DNS)
- GoGo-Infra 8dc25ac: harness/ (policy engine, JEV router, OpenRouter/mock/disabled providers, loop + budget controls, decision log, handoff renderer, CLI), ADR-0013 (proposed), docs/ai-harness.md, manifest rows ci ai-harness/{openrouter,anthropic}-api-key (names only), CI job
- GoGo-BE 6b11929: DecisionProviderPort + OpenRouterDecisionProvider, intent domain + service (disabled by default), 151 Vietnamese cases, pnpm eval:intent, openrouter planned in cost registry, ADR-0035 (proposed); no route, no OpenAPI change
- Issues created: namnh92/GoGo-Infra#241, namnh92/GoGo-BE#709

## Evidence
- harness: node --test test/*.test.ts → 53 pass, 0 fail; tsc --noEmit clean
- harness before fix: live-timeout test hung (AbortSignal.timeout is unref'd) → 11 cancelled; after explicit timer → 29/29, then 53/53
- Infra: manifest.test.sh, validate.test.sh (after probe fix; baseline passed, change failed '--declares' once), exec-with/pull/put tests, gitleaks 8.18.4 no leaks, workflow-auth + trigger checks pass
- GoGo-BE baseline unit: 178 files / 2266 tests pass; after: 181 files / 2448 tests pass
- GoGo-BE before fix: 'Hai Bà Trưng' parsed as party of 2, guardrail test caught 'budget' wording → fixed; typecheck (8 tasks), lint, prettier, check:boundaries, api:check (OpenAPI unchanged) pass
- GoGo-BE integration tests not run: no Docker daemon in the session; no DB, route or migration changed
- pnpm eval:intent (no model): fallback agreement category 0.464, occasion 0.583, inScope 0.887, needsClarification 0.709 — fallback only, not model quality
- No paid inference was made: no OpenRouter or Anthropic key exists in either repo, CI, or this session

## Decisions
- `intake (example, JEV disabled)` → **RESEARCH_AND_CONTINUE** (source: fallback; policy gates: none; fallback: disabled) — JEV disabled; deterministic: unresolved, sources not searched yet
- `intake (example, mock fixture)` → **RESEARCH_AND_CONTINUE** (source: jev; policy gates: none) — JEV: owner decision likely; search docs/issues/handoffs before asking

## Blockers
- Live JEV: owner must authorize paid inference and create the OpenRouter key with a credit limit (ADR-0013 Owner actions 1)
- Unverified until a live call: typesafe/jev-1.14 on /api/alpha/decisions, Decisions-specific error table, latency
- Anthropic API automation key + workspace spend limit (owner action 2)
- Installing a Claude Code hook is a permission-policy change (owner action 3)
- Both ADRs are proposed; thresholds are provisional until a live probe set runs

## Next
- Owner: review ADR-0013 (Infra) and ADR-0035 (BE); decide on PRs to develop
- After authorization: run the harness scenarios live as a probe set and set THRESHOLDS from observed numbers
- After authorization: INTENT_EVAL_MODE=live INTENT_EVAL_LIVE_AUTHORIZED=yes pnpm eval:intent (cap INTENT_EVAL_MAX_USD) and set INTENT_THRESHOLDS
- Wiring the intent service to an endpoint needs its own decision (DTO, backend key row, Zod config, instrumented registry entry)
