# Sentry → Discord alert relay — provisioning, rotation, rollback

ADR-0013 is the decision; GoGo-Infra#221 is the issue; the SA shape
(`dev/handoffs/sa-shape-infra-221-sentry-discord-relay.fable.md`, workspace file, not in this repository) carries
the reasoning behind each number here. This file is the runbook.

## What it is

Sentry's internal integration `gogo-alert-relay` is attached as an alert action to the three issue workflows. When
one fires, Sentry POSTs the whole stored event to `https://sentry-relay-dev.gogo.id.vn/hooks/sentry`. The
Cloudflare Worker `gogo-dev-sentry-relay` verifies the HMAC signature, keeps the allowlisted fields, scrubs every
value, and posts one Discord embed to that project's channel — inside Sentry's 1-second budget. Nothing is stored.

```
Sentry issue alert ──HMAC-signed POST──▶ gogo-dev-sentry-relay ──embed──▶ Discord channel
                                              │
                                              └─ 200 posted · 204 ignored/unknown project
                                                 401 bad signature · 413 too large · 400 malformed
                                                 503 not provisioned · 502 Discord failed / unconfirmed
                                                 500 relay error
```

A 502 is deliberate (ADR-0013 D-4): Sentry does not retry, so the message is lost either way, and the non-2xx is
what makes the failure visible on the integration's **Webhook Requests** tab. Reading that tab is how a broken relay
is noticed — and it is the only way: Sentry's circuit breaker counts only its own 5 s hard timeout as an error, so a
502 answered in time never trips it, and the owner email it would send on opening never fires for this relay. The
status line tells `discord_failed` (the request never completed) from `discord_unconfirmed` (Discord answered 2xx but
the answer carried no readable message id — that message may have been delivered); A-4 counts both.

## Where the values live, and where they do not

| SSM (`/gogo/ci/<env>/…`) | Worker binding | What the holder can do |
| --- | --- | --- |
| `sentry-relay/client-secret` | `SENTRY_CLIENT_SECRET` | forge a signed request → the relay posts anything into all three channels |
| `sentry-relay/discord-webhook-be` | `DISCORD_WEBHOOK_BE` | post into the BE channel directly, no account needed |
| `sentry-relay/discord-webhook-cms` | `DISCORD_WEBHOOK_CMS` | post into the CMS channel directly |
| `sentry-relay/discord-webhook-mobile` | `DISCORD_WEBHOOK_MOBILE` | post into the Mobile channel directly |

SSM is the source of truth. Cloudflare holds a copy as a Worker secret and keeps no readable history of it.
**Terraform never receives any of them**: the module emits the four bindings as the Workers API's `inherit` type in
the upload that *creates* the script, gated by `sentry_relay_secrets_provisioned`, and `keep_bindings =
["secret_text", "secret_key"]` carries them across every later upload (GoGo-Infra#172). So no value is in the
configuration, the plan, the state file, or any log either produces — the same arrangement as
`docs/share-link-edge-auth.md`.

The flag is bookkeeping. The Worker decides at runtime: all three Discord bindings must be present and match
`https://discord.com/api/webhooks/<17-20 digits>/<60-80 chars>`, or it answers **503 to everything**. A relay
serving two channels and silently dropping the third is not an alert path.

## Provisioning

Three pull requests and two applies, in this order (ADR-0013 D-10; the reason is that
`terraform-apply-dev.yml` applies on every push to `develop` that touches `terraform/**` or `config/*.tfvars`):

**PR-1 — code, CI, manifest, docs.** No Terraform path touched, so merging it applies nothing. The capability
`sentry_discord_relay` is declared `planned: [dev]`, which is what keeps `validate.sh dev --strict` green while
the four values do not exist.

**PR-2 — the module and the hostname** (needs the owner's apply order). `sentry_relay_host =
"sentry-relay-dev.gogo.id.vn"`, `sentry_relay_secrets_provisioned = false`, plus the relay's `workers/sentry-relay/**`
entry in the two terraform workflows' `paths:`. The plan on that PR must show **exactly** four resources added —
script, workers.dev subdomain setting, route, DNS record — and nothing else. Any other line is drift outside the
order: stop and ask. Merging applies.

Then, at the console, in this order:

```bash
# 1. Sentry → Settings → Developer Settings → Create New Integration → Internal
#      name              gogo-alert-relay
#      Webhook URL       https://sentry-relay-dev.gogo.id.vn/hooks/sentry
#      Alert Rule Action ON
#      Permissions       none
#      Webhooks          none   (a resource subscription would deliver every issue,
#                                outside the 30-minute throttle and without frames)
#    Save. Sentry sends an `installation` webhook immediately; the relay has no
#    secret yet, so it answers 401. That is expected and harmless.
#
# 2. Copy the Client Secret from the integration page straight onto stdin:
./scripts/secrets/put.sh dev sentry-relay/client-secret

# 3. Discord: each of the three channels → Edit Channel → Integrations →
#    Webhooks → New Webhook → name "Sentry relay" → Copy Webhook URL.
#    Paste only here — never into a note, a chat message, or a file:
./scripts/secrets/put.sh dev sentry-relay/discord-webhook-be
./scripts/secrets/put.sh dev sentry-relay/discord-webhook-cms
./scripts/secrets/put.sh dev sentry-relay/discord-webhook-mobile

# 4. Put all four onto the Worker, straight from SSM:
for row in client-secret discord-webhook-be discord-webhook-cms discord-webhook-mobile; do
  case "$row" in
    client-secret)         binding=SENTRY_CLIENT_SECRET ;;
    discord-webhook-be)     binding=DISCORD_WEBHOOK_BE ;;
    discord-webhook-cms)    binding=DISCORD_WEBHOOK_CMS ;;
    discord-webhook-mobile) binding=DISCORD_WEBHOOK_MOBILE ;;
  esac
  ./scripts/secrets/put-worker-secret.sh dev "sentry-relay/${row}" "$binding" gogo-dev-sentry-relay
done
```

**The D-7 privacy gate, before anything real flows (ADR-0013 D-11).** The owner posts the addendum — number 5
(`dev/test-evidence/sentry-discord-relay/d7-addendum-5.md`) — as a comment on GoGo-Infra#208 and accepts it, with
the date. Nothing reaches Discord until a workflow carries the relay's action, and that action is added only after
that comment exists (ADR-0011 D-7; addenda 1–4 are #208 comments 6181943660, 6181998277, 6209622583, 6220437621).

**PR-3 — the flag and the capability.** `sentry_relay_secrets_provisioned = true`, capability to
`enabled: [dev]`. The plan must be `0/0/0` on resources — bindings are ignored on an existing script, so this
only makes the tfvars tell the truth.

**Then attach the action** in the owner's signed-in Sentry tab, per workflow (6114982 BE, 6164951 CMS, 6164950
Mobile), with `X-CSRFToken` from the `sc` cookie as in #219:

```jsonc
{ "type": "webhook",
  "config": { "target_identifier": "<the integration slug>", "target_display": null, "target_type": null },
  "data": {} }
```

A PUT recreates action ids, so read each workflow back afterwards and record the new ids in `docs/accounts.md`.
`POST …/test-fire-actions/` on each one is the first end-to-end proof.

## Acceptance (the issue closes on these)

A-1 unauthenticated requests — missing header, bad hex, wrong signature, oversized `Content-Length`, GET — are
refused and post nothing · A-2 the D-7 comment id, dated before the first action was saved, then one test-fire
message per channel with frames, each with the relay's outcome read from `wrangler tail` (`posted`; an
`unknown_project` fails the fire) · **A-3 the matrix**: each of the three workflows × the five triggers (new issue,
new high-priority, escalated, regression, reappeared), plus BE metric detector 10634455 — sixteen cells, each
with a distinct probe issue so the 30-minute throttle cannot mask one, recording the resource that arrived and the
relay's own outcome from `wrangler tail` (a cell that logs `unknown_project` fails, whatever Sentry's tab shows), the
relay's status code and response time from the Webhook Requests tab, and the correlated Discord message within 60 s ·
A-4 every request 2xx on the Webhook Requests tab except the deliberate failures, the response time per cell recorded
against the 850 ms deadline, `posted` / `discord_failed` / `discord_unconfirmed` counted, and `wrangler tail` showing
status lines only · A-5 no source line,
no `user`/`request`/`breadcrumbs` in a delivered message · A-6 a hostile title renders escaped, pings nobody,
unfurls nothing, and the stack is still visible · A-7 `check-worker-subdomain.sh gogo-dev-sentry-relay` → `false,
false`, and the script's settings read back with `observability.enabled = false`, `logpush = false` · A-8 the flag
and capability flipped only after all four secrets are on the Worker · A-9 the native `discord` action removed
from the three issue workflows, 6168773 untouched · **A-10 a forced failure**: delete the CMS webhook in Discord,
probe gogo-cms, see the relay answer 502 on the Webhook Requests tab, recreate, re-put, probe again, see 200.

A-3 gates A-9: a trigger that does not arrive as `event_alert`, or produces no message, is a notification that
would be lost once the native action is gone. So does one written acknowledgement from the owner: that the Webhook
Requests tab, read by a person, is the only notice of a broken relay (ADR-0013 D-4) — nothing emails anyone.

## Rotation

Both kinds rotate without downtime in the Worker, but they differ in what the gap costs.

**A Discord webhook URL** — delete the webhook in Discord (the old URL dies at once), create a new one, then:

```bash
./scripts/secrets/put.sh dev sentry-relay/discord-webhook-<project>
./scripts/secrets/put-worker-secret.sh dev sentry-relay/discord-webhook-<project> \
    DISCORD_WEBHOOK_<PROJECT> gogo-dev-sentry-relay
```

Between the two the relay answers 502 for that project — visible in Sentry, and the alerts in that window are
lost.

**The client secret** — regenerate it in Sentry, then `put.sh` + `put-worker-secret.sh`. Sentry signs with the new
secret immediately, so every real alert is 401 until the binding is replaced; forged requests signed with the
**old** secret keep working until then. If the leak is known and the replacement cannot follow within minutes,
delete the binding first (below), accept the lost alerts, and re-put when ready.

`./scripts/secrets/get.sh dev sentry-relay/<row>` shows version and modified time without printing the value.

## Rollback and compromise

Four cases, four answers. None of them is "revert the commit": the Worker's secrets, Sentry's action and
Discord's webhooks are live state.

1. **A Discord webhook URL leaked.** The holder can post into that channel directly; deleting the Worker changes
   nothing. **Revoke at Discord** — delete that webhook — then rotate as above.
2. **The client secret leaked.** The holder can make the relay post anything into all three channels. Regenerate
   in Sentry and replace the binding; if that cannot be immediate,
   `pnpm exec wrangler secret delete SENTRY_CLIENT_SECRET --name gogo-dev-sentry-relay` first — the relay then
   refuses everything (`no_secret`), which closes the forgery window and stops real alerts too.
3. **Stop the relay, keep the credentials.** In the owner's Sentry tab, remove the `webhook` action from the three
   issue workflows and restore the native `discord` action. The sparse message returns; nothing else changes.
4. **Tear it down.** Set `sentry_relay_host = ""` → the plan shows the script, the workers.dev subdomain setting,
   the route **and** the DNS record being destroyed together (they all live inside the counted module, which is
   why none of them is in the root `dns_records` map) → apply. Then delete the integration in Sentry, delete the
   three Discord webhooks, `./scripts/secrets/delete.sh dev sentry-relay/<row>` for all four, and set the
   capability back to `planned`. Flipping `sentry_relay_secrets_provisioned` alone removes nothing: Terraform
   ignores bindings on an existing script (GoGo-Infra#172).

## What the relay never does

- It never logs the payload. One logging function emits
  `{ outcome, resource, project, issue_id, event_id, discord_status }` — fixed enums plus two regex-validated
  Sentry ids, and the ids only after the signature passed. `observability.enabled = false` and `logpush = false`
  keep even that out of Cloudflare's stores; it is there for `wrangler tail` during acceptance.
  `scripts/ci/sentry-relay-no-payload-logging.test.sh` fails CI if a `console.` call appears anywhere else, if
  that function starts reading the event, or if a call site passes anything but an enum member.
- It never sends source lines, `user`, `request`, `contexts`, `breadcrumbs`, `abs_path`, frame variables, or a tag
  outside the allowlist. The unit test asserts on the serialised Discord body, not on the code path.
- It never answers Sentry with a body. Every response is `new Response(null, …)` — a body would be a second egress,
  into Sentry's own request log — and the same CI guard refuses a Worker whose response carries one.
- It never follows a redirect from Discord, and never posts anywhere but
  `https://discord.com/api/webhooks/…`.
- It never retries more than once, and only on a 429 that actually carried a delay. An absent or blank
  `Retry-After` is not zero: being told nothing is not permission to retry immediately.
- It never answers Sentry by throwing. Reading the body, verifying the signature, decoding, parsing and the relay
  itself all sit inside one boundary that turns an unexpected failure into a logged 500.
- It never reads the request body before deciding on method, path, length and signature shape — the tests prove
  this with a body reader that throws if it is touched, not by checking a status code.

## Not yet true

As of 2026-10-17 nothing above is deployed: PR-1 ships the Worker's code, its tests and this runbook. The module,
the hostname, the integration, the Discord webhooks and the four SSM rows do not exist yet, so no environment
holds a value, the capability is `planned`, and Sentry's native Discord action is still the only path to the
channels. `scripts/ci/sentry-relay-bindings.test.sh` prints a skip with that reason until the module lands, while
still proving itself against an inline fixture on every CI run; it skips only while no module directory exists and
nothing under `terraform/` or `config/*.tfvars` names the relay — either without a readable `main.tf` fails.
