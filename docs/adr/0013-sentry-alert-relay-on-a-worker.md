# ADR 0013 — The Sentry → Discord alert relay runs on a Cloudflare Worker

**Status:** proposed — becomes accepted at merge; the session that merges PR #233 writes the merge SHA and the
CODEOWNER date into this line (shape §5 step 6). SA shape: Fable,
`dev/handoffs/sa-shape-infra-221-sentry-discord-relay.fable.md` rev 2.9 (workspace file). Every review round on the
shape and on PR #233 — Astra rounds 1 and 2 on the shape, Sol rounds 1 and 2 on the code, the SA find round on the code and Astra's confirm round on it — and the owner's
decisions of 2026-10-18 are dispositioned item by item in that file's §7 and §8; the decisions below are the result,
not the history.
**Issue:** GoGo-Infra#221 (context #219, #208)
**Requirement authority:** owner decisions 2026-10-15 (#219: alerts go to Discord, one channel per project, every
environment, one notification per issue per 30 min), 2026-10-17 (this issue: scope, no source lines to Discord, three
existing channels, hostname — and "native action removed after acceptance", **reversed the next day**) and
2026-10-18 (the native action stays permanently beside the relay, D-7; exception `type` is a name position, D-5; the
20-character scrub floor stays for every project, D-11; `discord_unconfirmed` answers 200 and is not retried, D-4).
ADR-0011 D-7 (privacy addendum before real data) and D-9 (allowlists, not denylists). ADR-0004 (what belongs on a
Worker). `security.md` (logs carry no payloads).
`gogo-platform-sre` (symptom alerts reach a human).
**Basis:** GoGo-Infra `develop` `37c4dd7`.
**Amends:** ADR-0004's table of edge-native workloads (one row, below). ADR-0011 D-9 gains a third implementer.
ADR-0006 D3's notification path now has a relay in it.
**Out of scope:** screen/route tags on client events (GoGo-CMS#241, GoGo-MobileApp#341 — the relay forwards them
when they exist); the crash-free monitor's own notification (workflow 6168773 fires on a metric detector — no event,
nothing for the relay to add — and carries Sentry's native Discord action like the other three, D-7); anything about
PROD (D-2).

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
(a revoked URL), 5xx, timeout — is answered to Sentry as **502**; a 2xx whose saved message the relay could not read
is answered **200** and logged `discord_unconfirmed` (owner decision 2026-10-18, the end of this section).

Three refinements from the SA find round on the code (shape rev 2.5). A 2xx whose answer the relay could not read, or
that carried no message id, is logged `discord_unconfirmed`, apart from `discord_failed` (the request never
completed), because that message may well be in the channel and the acceptance run has to count it — rev 2.5 still
answered it 502; rev 2.7 answers it 200 (the end of this section). The project id is an integer by Sentry's docs, not by
capture: a decimal string is coerced before the closed-map lookup, and the acceptance matrix reads the relay's own
outcome per cell, so an `unknown_project` 204 — a success on Sentry's tab and silence in every channel — cannot pass as
delivered. And the parse/scrub/build segment before the Discord POST is not instrumented: its inputs are bounded (1 MiB
body, at most 400 characters per value, at most ten tag lines, eight frames) and the acceptance run records Sentry's
measured response time per cell; the 150 ms margin behind the 850 ms deadline stands or the deadline moves on that
number, not on an asserted figure.

This is the ADR's least obvious decision, so the reason is recorded: a non-2xx is recorded on the integration's
*Webhook Requests* tab, with the response time Sentry measured (`utils/sentry_apps/webhooks.py:421-434`). **That tab
is the delivery detector, and it is the only one.** (The first draft also said "Sentry does not retry an issue-alert
webhook, so the message is lost either way" — wrong, see the end of this section.) The circuit breaker this ADR first
named as a second detector is not one for this relay:
`circuit_breaker_tracking` counts only Sentry's own 5 s hard timeout as an error — "if an app returns a say 500, in a
reasonable time that's okay" (`utils/sentry_apps/circuit_breaker.py:26-28`) — so a 502 answered inside the budget is a
*success* to it. It trips on 500 or more hard timeouts that are also half or more of the requests in a 10-minute
window, stays open 5 minutes and then recovers over 20 (`sentry-apps.webhook.circuit-breaker.config` in
`options/defaults.py`; `utils/circuit_breaker2.py`); while open, Sentry sends nothing and records nothing on the tab
(`webhooks.py:341-342`, before `buffer.add_request`); its email goes to one address, only on the hard-timeout request
that found it open, at most once a day (`webhooks.py:123-135,152,352-354`). None of that can happen to a relay that
answers within 850 ms. So the owner's notice of a broken relay is the tab, read by a person — and that is why Sentry's
native Discord action stays beside the relay permanently (D-7, owner decision 2026-10-18): the one alert path that
cannot fail with the relay. The alternative — acknowledge 202 and post in `ctx.waitUntil` — makes every failure after
the acknowledgement invisible even on the tab.

One more fact, read from the same source on 2026-10-18 and corrected here because the first draft had it backwards
(shape rev 2.6, Q-8): **Sentry does retry this webhook on a 502.** The workflow-engine `webhook` action enqueues
`send_alert_webhook_v2.delay(…)` (`sentry_apps/services/legacy_webhook/service.py:106`), a task declared
`Retry(times=3, delay=60 * 5, on=(RequestException, InnerTimeoutError), ignore=(ClientError, …))`
(`sentry_apps/tasks/sentry_apps.py:97,191-204`); `send_and_save_webhook_request` turns a 500 or 502 into
`requests.HTTPError` through `raise_for_status()` and re-raises it, as it re-raises a soft `Timeout` and a
`ConnectionError` (`utils/sentry_apps/webhooks.py:365-393,479-483`), while 503 (`ApiHostError`), 504 (`ApiTimeoutError`)
and every 4xx (`ClientError`, in the ignore list) end the task. So a relay 502 is retried three times, five minutes
apart; a 503, a 4xx and a 204 are final. Each action on a workflow is its own task
(`workflow_engine/processors/action.py:263-268`), so a relay failure never reaches the native action. Consequences: a
`rate_limited` or `discord_failed` message is usually delivered on a retry, so the loss D-10 states is smaller than
first written; a `webhook_rejected` 502 appears on the tab three more times; and a `discord_unconfirmed` 502 — Discord
answered 2xx, the relay could not read a message id, the message is probably in the channel — is retried into up to
four relay copies of one message. **Decided 2026-10-18 (shape rev 2.7, Q-8 = a), by the owner in session and ahead
of the acceptance count rev 2.6 had planned to decide it on: `discord_unconfirmed` answers 200.** No retry, no
duplicate. The cost is the owner's and is written here so that nobody later reads that 200 as a save: when the branch
is taken and Discord did *not* in fact save the message, the relay's message is lost — and the row Sentry keeps is a
**200 with no failure indication**, not an absent row (Astra F-44): the tab shows a success, so the only trace of the
loss is the relay's own `discord_unconfirmed` status line in `wrangler tail`, which A-4 correlates against the channel; the native message for that issue still arrives (D-7). What the retry does for each
answer that stays: `rate_limited` and `discord_failed` get another attempt five minutes later, which usually delivers;
`webhook_rejected` and `discord_redirect` repeat three more times on the tab until the webhook URL is fixed; a
`relay_error` 500 is retried the same way; 503, every 4xx and 204 are final. In code the map is one set,
`ACKNOWLEDGED = {posted, discord_unconfirmed}` → 200, every other `postToDiscord` outcome → 502. None of this changes
D-7: the retry is invisible to the breaker, so a dying relay makes four tab rows per issue and still emails no one.

**D-5 · What may leave Sentry is a closed list, scrubbed by value.** Project, `environment`, `release`, `level`,
issue title, `culprit`, rule name, the ten allowed tags, the thrown exception's type and first value line, the
newest 8 frames of that exception as `filename · function · line:col · in_app`, a fallback log message where
there is no exception, the event's Sentry URL, and `issue_id` / `event_id`. Every relayed string is **one line**:
Scrub V1 takes the first line of whatever it is handed, title included, and turns a run of control characters inside
that line into one space, never nothing — deleted, they spliced the two-line message `OTP send failed⏎0912345678` into
one word, the phone rule's left boundary saw a letter, and the number was published (rev 2.5, the P0 of the SA find
round; `title` had been the one field `firstLine()` was never applied to). Then every string passes Scrub V1 (email,
JWT, long token runs, invite paths `/r/ /l/ /invite/ /share-links/` in any letter case — the path rule and the frame
pre-pass were case-sensitive while the query rule was not, so `/R/<code>` was published (rev 2.5) — credential query
keys, coordinate pairs, phone numbers → labels) and a length cap; `transaction`, `route` and `screen` additionally get path-template
treatment, so an id in a path becomes `[id]`. The long-run rule is positional (rev 2.4). In **free text** — title,
culprit, the exception value, the fallback message, environment, rule, every other tag — a 20+ run with a digit,
`_` or `-` is a token and only a letters-only run survives, the rule every string had before Astra F-27. In a **name
position** — a frame's `filename` and `function`, the `transaction`/`route`/`screen` tags, and since 2026-10-18 the
exception `type` — a run survives when it
is a name: letters, or letter words joined by single `_`/`-`; a digit, a doubled or an edge separator is what marks it
random, the client redactor's own test (ADR-0011 D-9). So `get_notification_preferences` in a frame and a screen called
`NotificationSettings` leave intact while `user_1a2b3c4d5e6f7g8h` does not (rev 2.3; the earlier test took the
separator itself as evidence and printed `[token]` for the names an alert exists to carry). **Owner decision
2026-10-17:** rev 2.3 had applied that name test to every field, which let a digit-free secret with well-formed
separators through anywhere — P(no digit) for a 12-char share code 13.0 % (below the 20-char threshold, never caught
either way), a 22-char invite code 2.38 %, a 43-char session token 0.07 % — and the owner kept the exemption only where
a name is what the field carries, because a title, culprit, exception value or log message is where a user-typed or
attacker-influenced secret lands and holds no name worth that. Measured exactly, free text admits 1.04 % of 22-char
and 0.013 % of 43-char runs again (letters-only, as it always did) instead of 2.15 % / 0.059 %; a name position keeps
2.15 % / 0.059 %. The strict rule is the code's default; a name position opts in, so a field relayed later fails
toward redaction. Accepted: a 20+ snake/kebab *function* name in `culprit` prints `[token]` there and survives in the
frame line; a 20+ `SCREAMING_SNAKE` *error code* in an exception value or title — `PLACE_PROVIDER_UNAVAILABLE` — prints
`[token]` and appears in no frame (rev 2.5 corrects the earlier sentence, which was true only of the function-name
half). **Owner decision 2026-10-18:** the exception `type` is a name position. A type is a class name or an error code
by construction — `PLACE_PROVIDER_UNAVAILABLE`, `TypeError`, `com.foo.BarException` — and nothing puts a credential
there; rev 2.4 had made it strict by inheritance, not by decision, and so the one string that alert is about reached
Discord as `[token]`. The cost, accepted: one more field at the name-position floor (2.15 % / 0.059 % of digit-free,
well-formed random runs). The exception `value` stays strict — the owner was asked about `type` only, and `value` is
free text where a user-typed string lands — so the same code in the *value* is still `[token]`, with the `type` beside
it now carrying it. The regression asserts both halves through the serialised Discord body
(`workers/sentry-relay/test/worker.test.mjs`, suite "exception `type` is a name position").

Never: `user`, `request`, `contexts`, `breadcrumbs`, `sdk`, `extra`, `modules`, `fingerprint`, `_meta`,
`mechanism.data`, `abs_path`, frame variables, and — owner decision 2026-10-17 — **no source lines**
(`context_line`, `pre_context`, `post_context`). In the `release` field and tag the token-run rule keeps a run only
when it is letters-only (the floor every field has) or a lowercase hex run of 7–40 characters — the shape a deploy SHA
has (ADR-0012a D-1 `gogo-be@<40-hex>`, ADR-0011 D-3 the CMS SHA; Mobile's `<bundle>@<version>+<build>` carries no 20+
run) — so `gogo-be@<sha>` prints whole, the one field that says which deploy broke, and a forged 22-character run does
not. The earlier exemption switched the rule off for the whole field and never checked the contract it cited; the DSN
is public and the field is hostile (rev 2.5).

Field names do not make values safe, so the test oracle is the **serialised Discord request body**: each scrub
shape is driven through each permitted field — title, culprit, exception type and value, frame filename and
function, the fallback message, environment, release and every allowed tag — and the body must contain none of
them (`workers/sentry-relay/test/worker.test.mjs`). Scrub V1 has its own case file (`test/scrub-cases.json`).

**The redaction pipeline has three phases and one invariant** (shape rev 2.8, owner decision 2026-10-18).
(1) *Bound*: NFC, line terminators kept as `\n`, every other control run neutralised, the input capped at a
whole-run edge. (2) *Redact*: every rule, on the whole bounded value. (3) *Shorten*: first line, path tail, length
caps, the stack ladder, the Discord limits. **No step in phase 3 can change what a phase-2 rule would have
matched.**

That invariant is written here because its absence produced the same defect five times, each fix creating the next:
`slice(0, 400)` before the replacements published a partial email; the 120-character cap before the path tail kept
`/home/<user>/private/…` and dropped the file name; deleting control characters glued two lines and destroyed the
phone rule's left boundary, publishing a phone number; `firstLine()` before the coordinate rule published a
latitude; and `firstLine()` through a token published `alice@exam`. Four reviewers found them one at a time. A
property-style test now covers the class: every sentinel shape against every boundary a shortening step cuts on,
asserted on the serialised Discord request body.

Two boundaries cannot be settled by ordering alone — a line break and a control run are where a phase-2 rule cannot
reach, since the email, JWT, token-run and phone patterns all exclude whitespace. Each therefore proves itself:
join the runs either side (over comma-linked units, so a coordinate pair joins back to the pair it is), put the
join back through phase 2, and act on the answer. If it redacts, the boundary was interrupting one secret and
**both sides** are replaced — the boundary itself stays, because removing it published a phone number whose right
boundary was the separator, and let a coordinate label swallow the line break so a name from line two was
published (both P0, found in review). `RE_GEO` takes horizontal whitespace only for the same reason: no phase-2
rule may cross the one boundary the shortening phase cuts on. The proof's lookback is bounded at 2 048 characters,
above the longest left half any rule can match, because scanning the whole value per boundary was quadratic and
measurable.

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
as guards and tested directly with an injected limit. The total shrink cuts the description first and, when that is
down to `…`, blanks field values to `…` in a stated order — Tags, Stack, Rule, Release, Environment — so it always ends
under the limit; the description floor alone could return an over-limit embed, which Discord refused with a 400 the
relay then reported as a Discord failure (rev 2.5). No buttons — a channel webhook cannot act on Sentry the way the native
integration's Resolve/Archive could; the link is the action.

**D-7 · Sentry's native Discord action stays on every workflow, permanently; the relay is an addition, never the
only path.** Owner decision 2026-10-18, reversing 2026-10-17's "removed once the relay is accepted" for the three issue
workflows 6114982 / 6164951 / 6164950 (the crash-free workflow 6168773 was always keeping it — a metric detector has no
event and no stack trace to add). The reason is D-4's finding, and it is written here so that nobody later "cleans up"
the duplicate: Sentry's circuit breaker records an error only on its own 5-second hard timeout — "if an app returns a
say 500, in a reasonable time that's okay" (`utils/sentry_apps/circuit_breaker.py:26-28`) — so a relay that dies
answering 502s inside its deadline is a *success* to Sentry: the breaker never opens, the owner's email never arrives,
and the *Webhook Requests* tab shows the 502s only to a person who happens to read it. Remove the native action and
the alert path can stop silently. Keep it and the sparse message is the one alert that cannot fail with the relay —
and a native message with no relay message beside it is a per-issue tell of a broken relay, visible in the channel.

The price, accepted by the owner: **two messages per issue in each channel** — Sentry's sparse one (tags only, from
the Discord integration) and the relay's complete one (frames, from the channel webhook, the only one with the
`issue <id> · event <id>` footer). They come from different authors and different rate-limit buckets; `frequency 30`
throttles both together, since it is per workflow. Each workflow's `webhook` action is added **next to** the existing
`discord` action, and the read-back after that PUT — which recreates action ids — is what proves native survived it
(shape A-9, inverted from the 2026-10-17 text). The acceptance matrix (A-3) still runs each workflow × each of the
five triggers plus the BE metric detector; a trigger that does not arrive as `event_alert` is now a relay gap to
record and design for, not a notification the owner loses. The forced-failure cell (A-10) measures the fallback
itself: the native message for the probe arrives while the relay answers 502. The acknowledgement that rev 2.5 had
gated removal on is withdrawn — there is no removal to gate.

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
never stored. `outcome` tells `discord_failed` (the request never completed, a 502) from `discord_unconfirmed` (it
completed with a 2xx the relay could not read as a save, a 200 since 2026-10-18), so the acceptance run can check each
unconfirmed 200 against the channel — the only measurement of the loss D-4 accepts (rev 2.5, rev 2.7).
`observability.enabled = false` and `logpush = false` on the script. The status line exists for
`wrangler tail` during acceptance and nowhere else; two CI guards pin both halves. The relay's answer to Sentry is a
bare status: every `new Response(` passes `null`, pinned by the logging guard with its own mutations — the response
body would be a second egress, into Sentry's request log, that no privacy addendum covers (rev 2.5). The bindings
guard, until the module lands, skips only while no module directory exists and nothing under `terraform/` or
`config/*.tfvars` names the relay; either of those without a readable `main.tf` fails, so the skip cannot be mistaken
for a module that landed under another name (rev 2.5).

**D-10 · No queue, no buffer of our own, and the loss is stated.** Sentry's `frequency 30` is the per-issue dedupe. A
Discord failure or a 429 that cannot be honoured inside the budget is a 502 — and Sentry's own task retries that 502
three times at five-minute spacing (D-4, corrected 2026-10-18), so a deploy that mints many new issues in a minute,
against a channel webhook that allows roughly five requests every two seconds, will see 502s that mostly deliver a few
minutes late rather than never. The issue stream in Sentry is the record; the channel is the notification. A queue of
our own would turn a visible 502 into an invisible backlog, and Sentry's retry is the buffer that already exists. The
accepted loss includes the channel, not only individual messages: a webhook that is gone or a Worker that is broken
drops every **relay** message for that project until a person reads the tab (D-4; rev 2.5) — the stack traces, not
the alerts, because the native action still posts (D-7). The one message the retry never carries is the
`discord_unconfirmed` one — answered 200 so that a probable save is not posted four times (owner decision 2026-10-18,
D-4) — so the loss also includes, behind a 200 row carrying no failure indication, the rare unconfirmed message
Discord did not in fact save; its
`discord_unconfirmed` status line is the only trace.

**D-11 · The privacy addendum is accepted before the first `webhook` action exists.** ADR-0011 D-7 requires a dated
owner acceptance on GoGo-Infra#208 before real data reaches a new destination or processor. For this relay that is
**D-7 addendum 5** (`dev/test-evidence/sentry-discord-relay/d7-addendum-5.md`, a workspace file; addenda 1–4 are #208
comments 6181943660, 6181998277, 6209622583, 6220437621). The comment is posted and accepted before the relay's
`webhook` action is saved on any workflow — nothing real can reach the relay until an action carries it — and A-2
records the comment id and checks its date against the action's. The addendum states the scrub floor as it is: in free
text a letters-only run of 20+ passes, in a name position (the exception `type` included, since 2026-10-18) a
name-shaped run of 20+ passes, nothing under 20 characters is tested by the run rule at all, and for `gogo-be` the
relay is the first line for free text (Consequences). **Owner decision 2026-10-18:** that 20-character floor stays
for every project, `gogo-be` included — ADR-0011 D-9's "6+ with a letter and a digit" rule was not imported, because
its accepted false positives (`node18`, `es2020`, `utf8mb4`, `sha256`, a short SHA) would print `[token]` in BE
alerts. So, plainly: for `gogo-be` free text the relay tests nothing under 20 characters, and a 12-character room
share code in an exception message is published unless it sits behind `/r/`, `/l/`, `/invite/`, `/share-links/` or a
credential query key. The addendum says so in those words; the risk is owner-accepted with that date.

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
- Scrub V1 is pattern-based: a free-text secret matching no rule passes, and nothing under 20 characters is tested by
  the run rule. For `gogo-cms` and `gogo-mobile` the client redactor runs first (ADR-0011 D-9: emails, JWTs, invite
  paths, coordinates, any 6+ run with a letter and a digit), so the relay is a second line there. For `gogo-be` it is
  the **first** line for free text: the api's `beforeSend` rebuilds `event.request` and redacts coordinate-shaped values
  only (`GoGo-BE/apps/api/src/sentry.ts`, `libs/observability/src/telemetry-redaction.ts`) and never touches `message`,
  an exception value, the title or a tag; Sentry's server-side rules on `gogo-be` are the scrubber defaults,
  `scrubIPAddresses` and `$user.geo.**` (`docs/accounts.md`), none of them a token or invite-code rule. The owner kept
  the 20-character floor there rather than import the client's 6+ rule and its accepted false positives (`node18`,
  `es2020`, a short SHA would print `[token]`) — decided 2026-10-18, D-11: a 12-character room share code in a BE
  exception message is published unless a marker or query-key rule catches it.
- Stack-trace delivery now depends on Cloudflare's edge as well as Sentry and Discord; the alert itself does not,
  because the native action stays (D-7). Each issue posts twice in its channel. Detection of a relay failure depends
  on someone reading Sentry's Webhook Requests tab, or noticing a native message with no relay message beside it;
  the circuit-breaker email never fires for this relay, and Sentry's retries of a 502 do not change that (D-4).
- Three PRs and two applies to get there (shape D-13): code and docs first with no Terraform path touched, then
  the module on the owner's apply order, then the provisioned flag. Nothing in this ADR is live until the last of
  them, and the issue stays open until the acceptance matrix is measured.
