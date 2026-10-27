# Handoff — JEV harness: install, prompt hook, acceptance on the owner's machine

- Task: `GoGo-Infra#241` (track) · Issues: #245, #247, #250, #257, #260 · Branch: `develop`
- Status: **done for this session; follow-ups below**
- Written: 2026-10-27
- GitHub handoff: namnh92/GoGo-Infra#241 issuecomment-6439771047

## Done
- Merged: #253 (`3925472`, install outside the checkout), #254 (`187c3a4`, prompt hook + JEV
  opt-in), #256 (`50fd459`, `as-agent.sh` constructed environment), #261 (`6acedfc`,
  `AS_AGENT_REQUIRE_GH=1` in CI), #262 (`54ba68f`, hook runs through `bin/harness`), #263
  (`329d481`, AWS profile `gogobootstrap`), #259 (`3327b5b`, ADR-0014 GoGo AI assistant, revised
  after Sol + Astra round 1).
- `CLAUDE.md` agent identity in BE#716, Mobile#388, CMS#257, FE#15 (all merged).
- `require_code_owner_reviews` on GoGo-Infra `develop` (1 approval, dismiss stale; required
  checks, `strict`, `enforce_admins:false` unchanged). Bot PRs show `REVIEW_REQUIRED` until the
  owner approves. BE/Mobile/CMS/FE do not have it yet.
- Installed copy `329d481` activated on the owner's machine (`~/.gogo-harness/install`, Node
  `/opt/homebrew/bin/node` 25.9.0), prompt hook installed, `jev-prompt setup` done.
- Closed #245 and #247 (owner decision). Opened CMS#259 (stale "credentials are not frozen"
  comments, P3).

## Evidence
- #245 issuecomment-6439387578: prepare; first install (provenance develop, TTY confirmation);
  `install-verify`; `git hash-object bin/harness.mts` = `launcher.ts@329d481` = `a7e40dd…`;
  a `throw` in the checkout's `router.ts` fails the checkout (exit 1) while the installed copy
  returns the same bytes (exit 10); a `NODE_OPTIONS=--import` marker runs under plain node and not
  through `bin/harness`.
- #247 issuecomment-6439389413: typed `#jev` → `source: jev`, `typesafe/jev-1.14-20261014`,
  1372 ms, 1153/227 tokens, $0.000048, advisory injected; logs hold digests and counts only.

## Findings that change how `#jev` is used
- **Type `#jev`; do not paste it.** Claude Code wraps pasted text in `<pasted_content>`, so a
  pasted `#jev` is never line 1 and nothing is sent (by design, shape #254 I1). Type `#jev`,
  Shift+Enter, then paste the body. `#nojev` anywhere, pasted or not, suppresses.
- **Start the session with `AWS_PROFILE=gogobootstrap`.** The hook passes `AWS_*` from the
  Claude Code process; with no profile, `exec-with.sh` stops and the record says
  `jev_wrapper_failed` (nothing sent). `cd <repo> && AWS_PROFILE=gogobootstrap claude`, SSO
  logged in.
- `#244` (privacy) is not done: `#jev` only on prompts without real user data or secrets.

## Next
1. **#260 tech debt** (issuecomment-6424764506 + issuecomment-6439391545): #254 S4-02, #256
   S4-02/S4-04, #253 S4-02; docs "type `#jev`", a distinct code for missing AWS, watch
   `invalid_data`, Node version drift through the Homebrew symlink.
2. **#257 / ADR-0014** (owner): OpenRouter credit limit on `gogo_ai_anthropic_dev`, then
   `put.sh` the 6 dev rows per `docs/environments.md`. The assistant goes on only after the
   Launch gate is recorded on GoGo-BE#713.
3. **#250** (owner): close, or first enable the code-owner gate on BE/Mobile/CMS/FE.
4. **CMS#259** (P3): fix three comments, add a test for the switch-on state, check cms-dev.
5. Waiting: #248 (3 owner answers on shape v2), #258 (separate OS user). Not started: #243,
   #244, #246.

## Next session prompt
Start the session with `AWS_PROFILE=gogobootstrap claude` in `GoGo-Infra`. Type `#jev`,
Shift+Enter, then paste:

```text
Repo GoGo-Infra, base develop (fetch first; say which SHA you used). Work issue #260 (JEV harness tech debt), one small PR per item, in this order, stopping at each owner gate:
1. docs/ai-harness.md + the jev-prompt setup consent text: say `#jev` must be typed as the first line (pasted text is wrapped in <pasted_content> and never opts in) and that the Claude Code session needs AWS_PROFILE for sends.
2. A distinct hook code when exec-with.sh fails for lack of AWS credentials (today: jev_wrapper_failed), surfaced in the #jev note.
3. #254 S4-02: the note must not say "not sent" when the failure came after the request.
Read first: CLAUDE.md, docs/handoffs/2026-10-27-jev-harness-trial.md, issue #260 and its comments, docs/ai-harness.md. FAIL-before test for each change, harness typecheck + node --test, push and open PRs through ./scripts/secrets/as-agent.sh. Do not merge, do not activate an install, do not edit ~/.claude/settings.json or hooks. Report in Vietnamese.
```
