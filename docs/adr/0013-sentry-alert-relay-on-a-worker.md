# ADR 0013 — The Sentry → Discord alert relay runs on a Cloudflare Worker

**Status:** proposed — 2026-10-17 (SA shape: Fable, `dev/handoffs/sa-shape-infra-221-sentry-discord-relay.fable.md`
rev 2.3; Astra round 1 `changes-required` F-01…F-21, all dispositioned in §7 of that file; Astra's confirm round on
rev 2.2 `changes-required` F-22…F-27, dispositioned in §8 of that file — rev 2.3 answers it: the Discord deadline
under D-4, the frame marker pre-pass, the cut's whitespace and the name test under D-5; a delta confirm is pending.
Rev 2.2 answered Sol's confirm round on PR #233 — the scrub cut, frame segments, URL wrappers and the Tags field,
recorded under D-5/D-6 below)
**Issue:** GoGo-Infra#221 (context #219, #208)
**Requirement authority:** owner decisions 2026-10-15 (#219: alerts go to Discord, one channel per project, every
environment, one notification per issue per 30 min) and 2026-10-17 (this issue: scope, native action removed after
acceptance, no source lines to Discord, three existing channels, hostname). ADR-0011 D-7 (privacy addendum before
real data) and D-9 (allowlists, not denylists). ADR-0004 (what belongs on a Worker). `security.md` (logs carry no
payloads). `gogo-platform-sre` (symptom alerts reach a human).
**Basis:** GoGo-Infra `develop` `37c4dd7`.
**Amends:** ADR-0004's table of edge-native workloads (one row, below). ADR-0011 D-9 gains a third implementer.
ADR-0006 D3's notification path now has a relay in it.
**Out of scope:** screen/route tags on client events (GoGo-CMS#241, GoGo-MobileApp#341 — the relay forwards them
when they exist); the crash-free monitor's own notification (workflow 6168773 keeps Sentry's native Discord
action); anything about PROD (D-2).

## Context

Alerts for `gogo-be`, `gogo-cms` and `gogo-mobile` reach Discord today through Sentry's own Discord integration
(#219). The owner's verdict on those messages was that they are too sparse to act on: they carry no stack trace.
They cannot be made to. Sentry's Discord action takes exactly one data field, `tags` — read from the
`available-actions` schema on 2026-10-15 and again on 2026-10-17, when the org's available actions were `email`,
`discord` and `github`, with `discord`'s `dataSchema` properties being `['tags']` and nothing else. Adding tags is
the whole of what that path allows, and it was already done twice (#208 comments 6181998277, 6220437621).

What Sentry *will* send in full is an integration-platform webhook. An alertable internal integration with no UI
component appears in `available-actions` as action type `webhook`
(`workflow_engine/endpoints/organization_available_action_index.py:123-194`), and the handler for that type calls
`send_sentry_app_webhook(group_event, …, rule_label)`
(`notifications/notification_action/action_handler_registry/webhook_handler.py:54-79`) — the issue-alert webhook,
whose body carries `data.event` complete with `exception.values[].stacktrace.frames[]`, `tags`, `release`,
`environment`, `web_url` and `data.triggered_rule`.

"Complete" is the problem as much as the solution. That payload is everything Sentry stored: `user`, `request`,
`contexts`, `breadcrumbs`, and — for `gogo-cms`, which has `scrapeJavaScript` on — the source lines around each
frame. Discord is a destination GoGo has no DPA with (D-7 addendum 1, #208 comment 6181943660). So the question
this ADR answers is not "can we get a stack trace into Discord" but "what runs between the two, who can make it
post, and what is it allowed to carry".

## Decision

**D-1 · A Cloudflare Worker sits between Sentry and Discord.** `gogo-dev-sentry-relay`, one route,
`POST https://sentry-relay-dev.gogo.id.vn/hooks/sentry`. It verifies the HMAC signature, reduces the event to an
allowlisted and scrubbed set of fields, posts one Discord embed, and keeps nothing.

ADR-0004's test for edge-native work is: no state, no business rule, nothing that outlives the request. This
passes all three. The row added to that ADR's table:

| Workload | Why it is edge-native |
| --- | --- |
| Sentry → Discord alert relay | verify, scrub, reshape, forward; no origin, no state, no process beyond the request |

Not in GoGo-BE. The api is what most of these alerts are *about*, and on DEV it runs on the owner's workstation
behind a tunnel: an alert path that shares fate with the monitored process stops working exactly when it matters.
Not Sentry's legacy per-project "WebHooks" plugin either — it has no HMAC, and a relay that cannot authenticate
its caller is an open Discord poster.

**D-2 · One relay for the organisation, managed from the `dev` Terraform environment; PROD needs its own
decision.** Sentry is one organisation for every environment, so an integration has one webhook URL and the relay
is org-level by construction. It forwards every environment, as the owner chose for #219; `environment` is a field
in the message, not a deployment boundary. Before any PROD workload relies on this relay for alerting, a dated
owner decision amends this ADR with the shared-service policy: who may deploy it (a push to `develop` today), who
may read or rotate its credentials, what a DEV teardown does to PROD alerting, and whether it moves to a shared
Terraform environment. Until then it is a DEV-managed service that happens to see PROD-tagged events.

**D-3 · Authentication: HMAC over the raw body, fail closed, bounded before the body is read.** In order: wrong
method or path → 404; `Content-Length` absent, non-numeric or over 1 MiB → 413; `Sentry-Hook-Signature` not
exactly 64 lowercase hex → 401; no `SENTRY_CLIENT_SECRET` bound → 401; then `crypto.subtle.verify` over the raw
body bytes → mismatch 401. Nothing before the signature check allocates for an anonymous caller beyond the
length limit, and the body is never echoed or logged.

`Sentry-Hook-Timestamp` is **not** checked. It sits outside the signed material, so a freshness window on it
stops nobody who can sign and nothing for anyone who cannot. The consequence is accepted and named: whoever
captures one authentic signed request can replay it **without limit** while the secret it was signed with is
bound, re-posting that one message; Sentry's 30-minute throttle does not apply to replays. Containment is secret
rotation (D-8). Capture requires a TLS break or a Sentry-side leak, and the harm is a duplicate of a message
already sent.

**D-4 · The Discord POST is synchronous, and a failed post is a 502 to Sentry.** `?wait=true` so a 2xx carries the
saved message id; redirects refused; **every attempt ends by 850 ms from arrival** — its timeout is the smaller of
600 ms and what is left, and nothing is posted past that line; at most one retry, only on 429 and only when
`retry_after` leaves at least 100 ms for its POST before the deadline. (Rev 2.3: the 850 ms used to admit the retry's
*start* — admitted at 700 ms, it ran its own 600 ms and answered Sentry at 1300 ms; and a retry with 30 ms to run could
only time out, logged as a Discord failure rather than the rate limit it was.) Anything else — redirect, 401/403/404
(a revoked URL), 5xx, timeout, a 2xx with no message id — is answered to Sentry as **502**.

This is the ADR's least obvious decision, so the reason is recorded: Sentry does not retry an issue-alert webhook,
so the message is lost either way, but a non-2xx is recorded on the integration's *Webhook Requests* tab and feeds
Sentry's per-integration circuit breaker, which emails the owner organisation when it opens
(`utils/sentry_apps/webhooks.py:147,354`). That tab and that email are the delivery detector. The alternative —
acknowledge 202 and post in `ctx.waitUntil` — makes every failure after the acknowledgement invisible, which with
Sentry's native action removed (D-7) would mean an alert path that can stop working silently.

**D-5 · What may leave Sentry is a closed list, scrubbed by value.** Project, `environment`, `release`, `level`,
issue title, `culprit`, rule name, the ten allowed tags, the thrown exception's type and first value line, the
newest 8 frames of that exception as `filename · function · line:col · in_app`, a fallback log message where
there is no exception, the event's Sentry URL, and `issue_id` / `event_id`. Every string passes Scrub V1 (email,
JWT, long token runs, invite paths `/r/ /l/ /invite/ /share-links/`, credential query keys, coordinate pairs,
phone numbers → labels) and a length cap; `transaction`, `route` and `screen` additionally get path-template
treatment, so an id in a path becomes `[id]`. A long run is a token, and a long path segment an id, only when it is
**not a name** — letters, or letter words joined by single `_`/`-`; a digit, a doubled or an edge separator is what
marks it random, the client redactor's own test (ADR-0011 D-9). So `get_notification_preferences` and a screen called
`NotificationSettings` leave intact while `user_1a2b3c4d5e6f7g8h` does not (rev 2.3; the earlier test took the
separator itself as evidence and printed `[token]` for the names an alert exists to carry).

Never: `user`, `request`, `contexts`, `breadcrumbs`, `sdk`, `extra`, `modules`, `fingerprint`, `_meta`,
`mechanism.data`, `abs_path`, frame variables, and — owner decision 2026-10-17 — **no source lines**
(`context_line`, `pre_context`, `post_context`). `release` is exempt from the token-run rule alone, because a
release is the deploy SHA by contract (ADR-0012a D-1, ADR-0011 D-3) and would otherwise always print as `[token]`,
destroying the one field that says which deploy broke.

Field names do not make values safe, so the test oracle is the **serialised Discord request body**: each scrub
shape is driven through each permitted field — title, culprit, exception type and value, frame filename and
function, the fallback message, environment, release and every allowed tag — and the body must contain none of
them (`workers/sentry-relay/test/worker.test.mjs`). Scrub V1 has its own case file (`test/scrub-cases.json`).

Two ordering rules inside that are load-bearing, and both were wrong in the first draft. Control characters and
the query string come off a path **before** segments are classified, or `/plans/123<control>456` and
`/plans/123456?view=map` are not "a run of digits" and the bare id is published once the control is stripped. And
a frame's path is reduced to its last three segments **before** any length cap, or a long absolute path keeps
`/home/<user>/private/…` and loses the file name — publishing the one part nobody wanted and dropping the part
that locates the defect. Before even that, the segment after any `r`/`l`/`invite`/`share-links` segment is replaced
over the **whole** path: the tail cut had dropped the marker with the head, so `/r/AbCdEfGhIj/src/app.js` left as
`AbCdEfGhIj/src/app.js` with nothing for the credential-path rule to match (rev 2.3). A third rule came from the
confirm round: the scrubber reads at most the first 400 characters of a value (a bounded surface, since a signed
body may be 1 MiB), and that cut is **not a slice** — a
slice keeps a prefix, and an email, token or coordinate pair straddling character 400 survived as a fragment no
rule matches, inside the field cap once earlier runs had collapsed to labels. The cut trims trailing whitespace,
moves back to the last whitespace boundary, takes any comma-joined run with it (a coordinate pair is `lat, lng` — or
`lat , lng`, and with the cut in that whitespace a bare latitude once survived; rev 2.3), and is marked `…`; a
whitespace-free value over 400 characters therefore shows as `…`, never as a prefix. For the same reason a frame
path segment longer than the 120-character file column is dropped whole as `…` rather than cut: three such
segments stay under the scrubber's 400, so the basename always survives, and the joined path is still scrubbed
as one string because the credential-path rule needs `/r/<value>` across two segments.

The phone rule needs a non-alphanumeric boundary on **both** sides. Without the right one it redacts a release
SHA that merely begins with ten digits. The accepted consequence: a digit run glued to letters is treated as an
identifier, not a number (a run of 20 or more is still caught by the token rule).

**D-6 · The message is built to be inert.** `allowed_mentions: { parse: [] }` — an error title saying
`@everyone` pings nobody. Discord markdown escaped in every relayed string. Surviving URLs wrapped `<…>` so
nothing unfurls — case-insensitively, and a cap is never allowed to cut the closing `>` off, because half a
wrapper is a live link again. The wrapper is marked by the function that inserts it (a control-character pair
the scrub has already cleared from every input) and repaired only when a cap actually crossed one, keeping the
`…`; a bare `<` in an error message is text and stays. The Tags field, a join of per-tag lines, is fitted by whole
lines with a `… n tag(s) omitted` line, never cut inside a value. The one real link is the embed's URL, and only
when it points at this organisation's Sentry. No `flags: 4`: SUPPRESS_EMBEDS would drop the relay's own embed,
stack trace included. Every Discord limit is enforced by the relay with a visible `…`, never by Discord rejecting
the post — and the stack field meets its 1024 by **shortening each frame line from the left**, not by dropping
frames: a stack that silently shows four of eight reads as a four-frame stack. If even the shortest eight lines
will not fit, the block says how many frames it dropped — a path no event reaches at 1024 (eight 120-character
lines fence to 975), like the 6000-character total shrink (the component caps sum to about 3100); both are kept
as guards and tested directly with an injected limit. No buttons — a channel webhook cannot act on Sentry the way the native
integration's Resolve/Archive could; the link is the action.

**D-7 · Sentry's native Discord action is removed once the relay is accepted.** Owner decision 2026-10-17, for
the three issue workflows 6114982 / 6164951 / 6164950: one message per issue, the complete one. The crash-free
workflow 6168773 keeps the native action — it fires on a metric detector, where there is no event and so no stack
trace to add. Removal is gated on the acceptance matrix (A-3 in the shape): each workflow × each of the five
triggers, plus the BE metric detector, must be observed arriving as `event_alert` and producing a correlated
Discord message. A trigger that arrives as anything else is a notification the owner would lose, and blocks the
removal until the design has a path for it.

**D-8 · Four credentials, two different capabilities, two different leak responses.** `sentry-relay/client-secret`
and three `sentry-relay/discord-webhook-*`, all SecureString under `/gogo/ci/dev/`, consumer `pipeline`, put onto
the Worker with `scripts/secrets/put-worker-secret.sh` — SSM to stdin to wrangler, never a file, a variable or the
screen. Terraform records only *whether* the bindings exist and never a value (GoGo-Infra#172 arrangement,
`keep_bindings` + `inherit`).

The client secret lets its holder **forge** a signed request and make the relay post anything into all three
channels; a webhook URL lets its holder **post into that one channel directly**, with no account at all. So a
leaked URL is revoked at Discord — deleting the Worker changes nothing — while a leaked secret is regenerated in
Sentry, and if the binding cannot be replaced immediately the binding is deleted first, closing the forgery
window at the cost of real alerts. `docs/sentry-discord-relay.md` is the runbook.

Discord's execute URL carries its token by Discord's design. `security.md`'s "no tokens in URLs" is a rule about
GoGo's own URLs; this one is used as a fetch destination only, pinned to `https://discord.com/api/webhooks/`,
redirects refused, and never written to a log, an error, a fixture or an evidence file — `.gitleaks.toml` makes a
pasted URL fail CI.

**D-9 · The relay logs enums, and Workers observability stays off.** One logging function, emitting only
`{ outcome, resource, project, issue_id, event_id, discord_status }` — outcome/resource/project from fixed enums,
the two ids regex-validated and present only after the signature passed, the raw `Sentry-Hook-Resource` header
never stored. `observability.enabled = false` and `logpush = false` on the script. The status line exists for
`wrangler tail` during acceptance and nowhere else; two CI guards pin both halves.

**D-10 · No queue, no buffer, and the loss is stated.** Sentry's `frequency 30` is the per-issue dedupe. A
Discord failure or a 429 that cannot be honoured inside the budget is a dropped message and a 502 — a deploy that
mints many new issues in a minute will drop some, because a channel webhook allows roughly five requests every two
seconds. The issue stream in Sentry is the record; the channel is the notification. A queue would turn a visible
502 into an invisible backlog.

## Alternatives rejected

- **More tags on the native action** — the schema is `tags` and nothing else; no frames, ever.
- **Relay inside GoGo-BE** — shared fate with the monitored process; adds Discord as a BE provider adapter for
  something that is not product behaviour.
- **Sentry's legacy WebHooks plugin** — per-project, no HMAC, legacy payload.
- **A `*.workers.dev` URL instead of a zone host** — it would skip DNS and Terraform routes, and it would be the
  first exception to an invariant this repo tests for (`scripts/deploy/check-worker-subdomain.sh`): no GoGo Worker
  answers on workers.dev.
- **202 then `waitUntil`** — see D-4.
- **KV / Queues / Durable Object** for dedupe or retry — infrastructure for a volume Sentry already throttles.
- **Generalising `terraform/modules/cloudflare-worker`** — that module is share-link by name, README, tests and CI
  guard; blurring it would weaken the one guard pinning the #172 decision.
- **Subscribing the integration to `issue` / `error` resources** — delivers on every issue, outside the 30-minute
  throttle, without frames.
- **Vendoring the client redaction oracle** (`docs/adr/0011/redaction-cases.v1.json`) — it describes a client
  event, not a relay message; the relay ships its own case file.

## Consequences

- An alert in Discord now names a file and a line, so triage can start in the channel. The link into Sentry is
  still where the full event lives, and deliberately the only way to reach it.
- One more public endpoint exists, whose authentication is a single HMAC secret. Its compromise is a posting
  capability into three channels, not access to Sentry or to GoGo data.
- The relay is a fourth place that knows the three Sentry project ids; adding a project is a reviewed code change
  rather than configuration.
- Scrub V1 is pattern-based: a free-text secret matching no rule passes. The clients already scrub before send
  (ADR-0011 D-9) and the message is bounded to the fields in D-5, but this is a second line, not a first.
- Alert delivery now depends on Cloudflare's edge as well as Sentry and Discord. Detection of a failure depends on
  someone reading Sentry's Webhook Requests tab or its circuit-breaker email (D-4).
- Three PRs and two applies to get there (shape D-13): code and docs first with no Terraform path touched, then
  the module on the owner's apply order, then the provisioned flag. Nothing in this ADR is live until the last of
  them, and the issue stays open until the acceptance matrix is measured.
