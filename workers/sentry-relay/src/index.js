/**
 * Sentry → Discord alert relay (GoGo-Infra#221, ADR-0013).
 *
 * One route, POST https://<host>/hooks/sentry. Sentry's internal integration
 * `gogo-alert-relay` sends issue-alert webhooks here; the relay verifies the
 * HMAC signature, reduces the event to an allowlisted, scrubbed set of fields
 * (ADR-0011 D-9 applies to this relay exactly as it applies to a client), and
 * posts one embed to the project's Discord channel webhook — synchronously,
 * inside Sentry's 1 s reply budget.
 *
 * A Discord failure is answered to Sentry as 502 on purpose: a non-2xx lands
 * on the integration's Webhook Requests tab, which is the delivery detector.
 * It is the only one: Sentry's per-integration circuit breaker counts nothing
 * but its own 5 s hard timeout as an error
 * (`utils/sentry_apps/circuit_breaker.py:26-28`), so a 502 answered inside
 * the budget never trips it and its owner email never fires for this relay
 * (shape D-4/D-8, rev 2.5). That is also why Sentry's native Discord action
 * stays on every workflow next to this relay, permanently (owner decision
 * 2026-10-18, ADR-0013 D-7): two messages per issue — Sentry's sparse one
 * and this one — in exchange for an alert path that survives this Worker
 * dying silently. Do not "clean up" the duplicate. Sentry does retry the
 * webhook task on a 500/502, a soft timeout or a connection error — three
 * times, five minutes apart (`sentry_apps/tasks/sentry_apps.py`
 * `send_alert_webhook_v2`, `Retry(times=3, delay=300)`; shape rev 2.6) —
 * and not on 503, 504 or any 4xx. That retry is why `discord_unconfirmed`
 * answers 200 (owner decision 2026-10-18, shape rev 2.7 Q-8): Discord
 * answered 2xx and the relay could not read the saved message, which is
 * probably in the channel — a 502 was retried into up to four copies of it.
 * The owner's accepted cost: when Discord did not in fact save it, that
 * message is lost from the relay's side with no row on the tab and no retry;
 * the native message still arrives, and the `discord_unconfirmed` status
 * line in `wrangler tail` is the only trace (A-4 counts it). Every other
 * non-save answer stays 502 so the retry can deliver it (ACKNOWLEDGED below).
 * This Worker keeps no state and no queue.
 *
 * Every answer to Sentry is a bare status: `new Response(null, …)` and nothing
 * else. The response body would be the Worker's second egress — into Sentry's
 * own request log — and the no-payload-logging guard pins that it stays empty.
 *
 * Logging: `logStatus` below is the only function that may call console.*,
 * and it emits enums and regex-validated identifiers only — never a title, a
 * tag value, a frame, a header or any other payload fragment. The event
 * bodies this Worker holds in memory contain everything Sentry stored (user,
 * request, breadcrumbs, source context); none of it may reach a log. Workers
 * observability and Logpush stay off in Terraform; the status line exists for
 * `wrangler tail` during acceptance. scripts/ci/sentry-relay-no-payload-
 * logging.test.sh pins all of this.
 *
 * Deployment is Terraform's job (terraform/modules/cloudflare-sentry-relay,
 * PR-2 of GoGo-Infra#221) — a Worker wired up through the dashboard or a
 * stray `wrangler deploy` is configuration that exists in one place and no
 * repository. Secrets (SENTRY_CLIENT_SECRET, DISCORD_WEBHOOK_*) are put with
 * scripts/secrets/put-worker-secret.sh and carried across uploads by
 * keep_bindings; Terraform never holds a value.
 */

/**
 * Which Discord channel a project posts to. The ids are facts already
 * recorded in docs/accounts.md, not configuration: a binding for them would
 * be one more Cloudflare-owned value Terraform cannot diff (GoGo-Infra#172).
 * An unknown project is answered 204 and posts nowhere — never to a default
 * channel. Adding a project is a reviewed code change (shape D-7).
 */
const PROJECT_CHANNEL = {
  4512201628254209: { label: 'BE', binding: 'DISCORD_WEBHOOK_BE' },
  4512252504178688: { label: 'MOBILE', binding: 'DISCORD_WEBHOOK_MOBILE' },
  4512252504178689: { label: 'CMS', binding: 'DISCORD_WEBHOOK_CMS' },
}

/**
 * What a Discord channel webhook URL looks like. Readiness (shape D-4) wants
 * all three bindings present and well-formed before anything posts: a relay
 * with one channel missing must answer 503 for every request rather than
 * silently serve two projects and drop the third. The shape also pins the
 * only fetch destination this Worker is allowed (shape D-10, F-20).
 */
const WEBHOOK_SHAPE = /^https:\/\/discord\.com\/api\/webhooks\/[0-9]{17,20}\/[A-Za-z0-9_-]{60,80}$/

/** Largest request body an anonymous caller can make this Worker read. */
const MAX_BODY_BYTES = 1048576

/** One Discord attempt gets at most this long; Sentry's own budget is 1 s. */
const DISCORD_TIMEOUT_MS = 600

/**
 * Every Discord attempt — the first or the one 429 retry — is aborted at this
 * many ms after arrival, whatever its own timeout says, so the answer to
 * Sentry leaves with 150 ms of its 1 s to spare. It used to be an admission
 * line for the retry only: a retry admitted at 700 ms then ran its own 600 ms
 * and answered Sentry at 1300 ms, past the budget D-4 exists to respect
 * (Astra F-22).
 */
const DISCORD_DEADLINE_MS = 850

/**
 * A retry is admitted only when at least this much is left for its POST after
 * the wait. A retry with 30 ms to run can only time out, and would then be
 * logged discord_failed — misnaming a rate limit.
 */
const RETRY_MIN_WINDOW_MS = 100

/** Frames shown: the newest N of the thrown exception, newest first. */
const MAX_FRAMES = 8

/** Discord's embed limits, enforced here (shape D-6) — a field value, the whole embed. */
const FIELD_VALUE_MAX = 1024
const EMBED_TOTAL_MAX = 6000

/**
 * A frame path segment longer than the file column (120) can never be shown
 * whole, and cutting inside it before the scrub is the F-18 hole again — so an
 * over-long segment is dropped as a unit and shows as `…`. Three segments of
 * ≤ 120 joined are ≤ 362 < SCRUB_INPUT_CAP, so scrub() never slices a path
 * and the basename, the part that locates the defect, always survives (Sol
 * F-02 confirm round: three segments over 400 characters lost it).
 */
const FILE_SEGMENT_CAP = 120

/** Embed colour by level — the one place these literals are allowed. */
const LEVEL_COLOUR = {
  fatal: 0xd84f4a, // coral
  error: 0xd84f4a,
  warning: 0xd99028, // amber
  info: 0x746e68, // neutral
  debug: 0x746e68,
  unknown: 0x746e68,
}

const OUTCOMES = new Set([
  'posted',
  'discord_failed',
  'discord_unconfirmed',
  'discord_redirect',
  'webhook_rejected',
  'rate_limited',
  'unknown_project',
  'ignored',
  'bad_signature',
  'no_secret',
  'not_provisioned',
  'malformed',
  'relay_error',
  'too_large',
  'not_found',
])
/**
 * Outcomes Sentry hears as 200, final. Everything else postToDiscord returns
 * is a 502 that Sentry's task retries three times, five minutes apart (shape
 * D-4, rev 2.7): `rate_limited` and `discord_failed` usually self-heal on
 * that retry; `webhook_rejected` and `discord_redirect` repeat on the tab
 * until the URL is fixed. A `relay_error` 500 is retried the same way.
 */
const ACKNOWLEDGED = new Set(['posted', 'discord_unconfirmed'])
const RESOURCES = new Set(['event_alert', 'installation', 'other'])
const PROJECTS = new Set(['BE', 'CMS', 'MOBILE', 'unknown'])

/**
 * The one logging function (shape D-9). Enums and validated identifiers only;
 * a value outside its enum is replaced, never printed. The two id parameters
 * are already regex-validated at the call site and are passed only after the
 * signature check succeeded.
 */
function logStatus(outcome, resource, project, issueId, eventId, discordStatus) {
  console.log(
    JSON.stringify({
      outcome: OUTCOMES.has(outcome) ? outcome : 'relay_error',
      resource: RESOURCES.has(resource) ? resource : 'other',
      project: PROJECTS.has(project) ? project : 'unknown',
      issue_id: issueId ?? null,
      event_id: eventId ?? null,
      discord_status: Number.isInteger(discordStatus) ? discordStatus : null,
    }),
  )
}

/** The raw header never travels further than this normalisation (F-04). */
function normalizeResource(header) {
  if (header === 'event_alert') return 'event_alert'
  if (header === 'installation') return 'installation'
  return 'other'
}

/* ───────────────────────── scrub (shape D-5, Scrub V1) ───────────────────── */

/**
 * Every relayed field is capped at 300 characters or fewer, so scrubbing more
 * than this is wasted work on a surface an attacker controls: a signed body may
 * be up to 1 MiB, and an unbounded alternation over it is where a Worker's CPU
 * budget goes (Sol F-05). Cut first, then scrub, then cap.
 *
 * The cut is a slice, and a slice keeps a prefix: an email, token or
 * coordinate pair straddling character 400 survived as a fragment no rule
 * matches, and once earlier runs had collapsed to labels that fragment sat
 * inside the field cap and was published (Sol F-18). So the cut moves back to
 * a boundary no rule spans: whitespace — except that a run joined to the cut
 * by a comma goes with it, because a coordinate pair is `lat, lng`. Nothing
 * partial survives; the remainder shows as `…` (shape D-6, a visible cut).
 * Accepted consequence: a whitespace-free value over 400 characters becomes
 * `…`, not a 400-character prefix.
 */
const SCRUB_INPUT_CAP = 400
// Disjoint classes (`[^\s,]`, `\s`, `,`), so the parse is unique and linear;
// `\S+` inside the starred group would be exponential on `a,a,a,…,a X`.
const RE_TRAILING_UNIT = /(?:[^\s,]+\s*,\s*)*[^\s,]*$/
/**
 * The two halves a boundary proof joins (neutraliseControls, cutAtLineBoundary):
 * the text a phase-2 rule could have matched on ONE line up to the boundary,
 * and from it. A unit is a run, or runs joined by commas with horizontal
 * whitespace around them — RE_GEO's shape — plus the horizontal whitespace
 * touching the boundary, so `10.762622 <LF>, 106.660172` joins back to the
 * pair it is. A bare run was too narrow: the rev 2.8 proof joined `1` and
 * `06.660172` out of `10.762622, 1<SOH>06.660172`, matched nothing, and
 * published both halves (found in rev 2.9). Same disjoint classes as
 * RE_TRAILING_UNIT, so no exponential path; neither crosses a line
 * terminator, exactly as RE_GEO no longer does.
 */
const RE_LEFT_UNIT = /(?:[^\s,]+[^\S\n]*,[^\S\n]*)*[^\s,]*[^\S\n]*$/
const RE_RIGHT_UNIT = /^[^\S\n]*[^\s,]*(?:[^\S\n]*,[^\S\n]*[^\s,]+)*/

/**
 * The first SCRUB_INPUT_CAP characters, cut back to a run boundary, marked.
 * Trailing whitespace comes off BEFORE the trailing unit is dropped: when the
 * cut fell in the whitespace of `10.762622 , 106.660172`, the slice ended in a
 * space, the strip found no unit to drop, and the bare latitude left as a
 * fragment the geo rule never sees (Astra F-24a). Accepted: a complete run
 * that was followed by whitespace at the cut goes too — the cut cannot tell a
 * finished word from the first half of a pair.
 */
function cutAtRunBoundary(s) {
  return `${s.slice(0, SCRUB_INPUT_CAP).trimEnd().replace(RE_TRAILING_UNIT, '').trimEnd()}…`
}

// Bounded quantifiers, for the same reason. An unbounded local part followed by
// a single `@` and no dot is the classic quadratic case.
const RE_EMAIL = /[^\s@<>()]{1,64}@[^\s@<>()]{1,64}\.[a-z]{2,24}/gi
const RE_JWT = /eyJ[\w-]{1,512}\.[\w-]{1,512}\.[\w-]{1,512}/g
// A long base64url-ish run. Which runs survive it depends on the position
// (RE_RANDOM_MARK, RE_NAME below). Still aggressive on purpose: a hashed
// bundle name carries a digit and goes everywhere.
const RE_TOKEN_RUN = /[A-Za-z0-9_-]{20,}/g
/**
 * The strict test, and the default: a 20+ run with a digit, an underscore or
 * a hyphen is a token; a letters-only run survives, as it has since Scrub V1.
 * This is the rule every relayed string had before Astra F-27, restored for
 * free text by owner decision 2026-10-17 (shape D-5, rev 2.4).
 */
const RE_RANDOM_MARK = /[0-9_-]/
const isPlainWord = (run) => !RE_RANDOM_MARK.test(run)
/**
 * The name test, applied ONLY in a name position — a frame's `filename` and
 * `function`, the path-template tags `transaction` / `route` / `screen`
 * (scrubPathTemplate), and the exception `type` (owner decision 2026-10-18;
 * see headline()). What makes a run a name rather than a token: letters
 * only, or letter words joined by single `_` or `-`. A digit is the evidence
 * of randomness — the client redactor's own test is "a letter and a digit"
 * (ADR-0011 D-9) — and a doubled or edge separator is not how a human writes
 * a name. The strict test treated `get_notification_preferences` and
 * `sentry-discord-relay-worker` as random and printed `[token]` for exactly
 * the names an alert exists to carry (Astra F-27).
 *
 * What the exemption admits, in a name position only: a secret of 20+
 * characters with no digit and well-formed separators — ≈ 2.2 % of 22-char
 * and ≈ 0.06 % of 43-char random base64url, none of hex — on top of the
 * letters-only runs the strict test already admits; and in a path template,
 * any 16+ segment that is a name, letters-only included (the old segment test
 * had no digit condition) — bounded there because all three clients send
 * templates (`[param]`, `:param`, Nest patterns) whose ids are UUIDs or
 * numbers. Free text — title, culprit, the exception value, the fallback
 * message, environment, rule, every other tag — is where a user-typed or
 * attacker-influenced secret actually lands and carries no name worth that,
 * so it keeps the strict test; a relayed field added later is strict unless
 * its scrub call deliberately passes `names: true`. An edge separator still
 * fails the name test, so the leading-underscore private convention
 * (`_handleNotificationPress`, 20+) stays `[token]` in every position.
 */
const RE_NAME = /^[A-Za-z]+(?:[_-][A-Za-z]+)*$/
const isName = (run) => RE_NAME.test(run)
// The same vocabulary as the client redactor (ADR-0011 D-9): these path
// segments and query keys are always credentials.
const CRED_MARKERS = new Set(['r', 'l', 'invite', 'share-links'])
// The invite screen itself is `src/app/r/[inviteCode].tsx`: the segment after
// the marker is expo-router's placeholder — letters only inside the brackets,
// so no code can wear it (ADR-0011 D-9, oracle C-24) — and it is the basename
// of exactly the frames an invite-code bug produces. Kept, with its extension.
const RE_ROUTE_PARAM = /^\[[A-Za-z]+\](?:\.[A-Za-z0-9]+)?$/
// Case-insensitive, like the query rule next to it and the webhook-URL guard's
// host match: `/R/AbCdEfGhIj` and `/INVITE/AbCdEfGhIj` were published while
// `?CODE=AbCdEfGhIj` was redacted — ten characters, below the token rule, so
// nothing else caught them (SA F-32).
const RE_CRED_PATH = /(\/(?:r|l|invite|share-links)\/)[A-Za-z0-9_-]+/gi
const RE_CRED_QUERY = /([?&](?:code|invite|token|slug|guest|lat|lng|latitude|longitude)=)[^&#\s]*/gi
// Horizontal whitespace only around the comma: `\s*` spanned a line break,
// so `10.762622,<LF>106.660172 Alice Nguyen` became `[geo] Alice Nguyen` —
// the label swallowed the one boundary phase 3 cuts on, and a name from line
// two was published (Astra F-46, P0). A pair split by a line break is settled
// by the phase-3 proof instead, like every other split secret (rev 2.9).
const RE_GEO = /-?\d{1,3}\.\d{3,}[^\S\n]*,[^\S\n]*-?\d{1,3}\.\d{3,}/g
// Boundaries on both sides. Without the left one the rule fires on ten digits
// inside a 40-hex release SHA; without a non-alphanumeric right boundary it
// still fires on a SHA that merely *starts* with them (Sol F-17) — the digits
// of `gogo-be@0123456789abcdef…` are not a phone number.
const RE_PHONE = /(?<![A-Za-z0-9])(?:\+84|0)\d{9,10}(?![A-Za-z0-9])/g
/**
 * C0 and C1 controls plus DEL. A run of them becomes ONE SPACE, never nothing:
 * deleting them spliced the neighbours together, so a two-line message
 * `OTP send failed<LF>0912345678` became the one word
 * `OTP send failed0912345678`, the phone rule's left boundary saw a letter,
 * and the number was published — eleven digits, below the token rule, so no
 * other rule saw it either (SA F-28, P0). A control character is a boundary,
 * the same boundary the whitespace it usually is already makes; the halves of
 * a run split by one are two runs, exactly as if split by a space.
 */
const RE_CONTROL_RUN = /[\u0000-\u001F\u007F-\u009F]+/g
/**
 * Phase 1 keeps line terminators and collapses every OTHER control run.
 *
 * A line terminator is the boundary phase 3 cuts on, and no phase-2 rule may
 * cross one (RE_GEO used to; F-46). Collapsing it to a space in phase 1
 * (which `RE_CONTROL_RUN` would do, since LF is a control character) would
 * leave phase 3 nothing to cut on and publish line 2 whole. Every other
 * control run becomes a single space — a separator, never a deletion:
 * deleting them glued two lines into one word and destroyed the phone rule's
 * left boundary (SA F-28).
 */
const RE_LINE_BREAK_RUN = /[\n\r\u0085\u2028\u2029]+/g
const RE_OTHER_CONTROL_RUN = /[\u0000-\u0009\u000B\u000C\u000E-\u001F\u007F-\u0084\u0086-\u009F]+/g
/**
 * Every line terminator, not just LF. A value whose second line is separated by
 * a bare CR (or U+2028, which JSON carries literally) would otherwise reach
 * Discord whole when only its first line was meant to (Sol F-04).
 */
const RE_LINE_BREAK = /[\n\r\u0085\u2028\u2029]/
/**
 * A path-template segment that carries a control or a line terminator is not
 * a segment any router produced: it is replaced whole, not joined and not
 * cut. Joining `123<NUL>456` into `123456` was Sol F-01's fix and is the
 * splice F-28 names; cutting at the terminator would publish `123`, a
 * fragment (the F-18 class). Fail toward redaction instead.
 */
const RE_HOSTILE_SEGMENT = /[\u0000-\u001F\u007F-\u009F\u2028\u2029]/
/**
 * A hex run of a SHA's length. The one shape the `release` position admits
 * past the token rule: a release is `gogo-be@<40-hex>` (ADR-0012a D-1), the
 * CMS deployed SHA (ADR-0011 D-3) or Mobile's `<bundle>@<version>+<build>`,
 * which carries no 20+ run at all. The exemption used to switch the rule off
 * for the whole field, so a forged release — the DSN is public — carried any
 * 22-character run through untested (SA F-33).
 */
const RE_HEX_SHA = /^[0-9a-f]{7,40}$/
const isPlainWordOrSha = (run) => isPlainWord(run) || RE_HEX_SHA.test(run)

/** The first line of a value, under every line-terminator convention. */
export function firstLine(value) {
  return String(value).split(RE_LINE_BREAK)[0]
}

/**
 * Scrub V1. Applied to every relayed string, and every relayed string is ONE
 * LINE: the first line is taken here, before anything else, so no caller can
 * forget it — `title` had been forgotten, and a message-event title carries
 * the whole logged text, both lines of it (SA F-28). Two options, both
 * opt-in, both narrowing the token-run rule only — every other rule and the
 * caps always apply: `release` admits a hex run of a SHA's length (RE_HEX_SHA;
 * rev 2.1 exempted the field from the rule outright, rev 2.5 narrows it to
 * the shape a release has); `names` marks a name position, where a run that
 * is a name survives (RE_NAME) instead of only a letters-only run
 * (RE_RANDOM_MARK). The default is the strict test, so a field someone relays
 * later fails toward redaction (rev 2.4).
 */
export function scrub(value, { release = false, names = false } = {}) {
  // ── phase 1 · bound ──────────────────────────────────────────────────────
  // Normalise, cap at a whole-unit edge, then turn every control run into a
  // boundary. A boundary leaves only inside a label, with every character it
  // separated (rev 2.9, F-45).
  const bounded = boundInput(value, { release, names })

  // ── phase 2 · redact, on the whole bounded value ─────────────────────────
  const redacted = redactAll(bounded, { release, names })

  // ── phase 3 · shorten ────────────────────────────────────────────────────
  // Only now, and only ever after phase 2. The caps in text(), frameLine() and
  // the stack ladder are phase 3 too, which is why they all run on scrub()'s
  // output and never before it.
  return cutAtLineBoundary(redacted, { release, names })
}

/**
 * Phase 3's one cut, and the one place the phase boundary is not enough on its
 * own.
 *
 * Only the first line of a value is relayed. A line break is also a boundary
 * no phase-2 rule reaches across — `RE_EMAIL`, `RE_JWT`, `RE_TOKEN_RUN` and
 * `RE_PHONE` exclude whitespace, and `RE_GEO` stops at a terminator since
 * rev 2.9 — so cutting there can leave the first half of a secret behind,
 * which is the F-18 class arriving at a different boundary: `mail
 * alice@exam<LF>ple.com` published `alice@exam`, and `key
 * Ab12Cd34Ef<LF>56Gh78Ij90` published `Ab12Cd34Ef`.
 *
 * So the cut proves itself (straddle() below): join the units on either side
 * of the break and put the join through phase 2 with a probe at the join
 * point. If a redaction straddled it, the break was interrupting one secret,
 * and the trailing unit leaves with the cut, marked `…`. What it must NOT
 * emit is the redacted join: a character of line two that no rule matched
 * would ride along (`alice@exam<LF>ple.com,foo` → `[email],foo`), and line
 * two never leaves. Two plain words either side of a break — the ordinary
 * case — are untouched, which is why this is not the 400-cap's blunt rule.
 */
function cutAtLineBoundary(redacted, opts) {
  const at = redacted.search(RE_LINE_BREAK)
  if (at === -1) return redacted
  const head = redacted.slice(0, at)
  const left = head.match(RE_LEFT_UNIT)[0]
  const right = redacted.slice(at + 1).match(RE_RIGHT_UNIT)[0]
  if (straddle(left, right, opts) !== null) {
    return `${head.slice(0, head.length - left.length)}…`
  }
  return head
}

/**
 * The boundary proof phase 1 and phase 3 share: were the units either side
 * of a boundary one secret? The join goes through phase 2 with a probe at the
 * join point, and the answer is yes only when a redaction STRADDLED it — the
 * match began before the join point and ended after it, and the replacement
 * differs from the match (a kept run is not a redaction). Returns the
 * redacted join on yes, null on no.
 *
 * "The join redacts" was the rev 2.8 test, and it was wrong: a query-key
 * redaction elsewhere in `0912345678<SOH>x?token=a` authorised deleting the
 * separator, the phone lost the right boundary that was protecting it, and
 * `0912345678x?token=[redacted]` was published (Astra F-45, P0). With the
 * probe, that join has no straddling match, the separator stays, and phase 2
 * sees `[phone] x?token=[redacted]`.
 */
function straddle(left, right, opts) {
  if (!/\S/.test(left) || !/\S/.test(right)) return null
  const probe = { at: left.length, straddled: false }
  const redacted = redactAll(left + right, opts, probe)
  return probe.straddled ? redacted : null
}

/**
 * Phase 1. The cap is a ceiling against an unbounded scan over a 1 MiB
 * attacker-controlled body (Sol F-05), and it drops whole units — a cut that
 * left a fragment behind published a partial email (Sol F-18).
 *
 * The cap comes BEFORE the control proof (rev 2.9, Astra F-47): the proof
 * used to run over the whole body, re-matching the growing output once per
 * control run — 20,000 runs took 1.2 s, and a signed body under 1 MiB carries
 * 500,000 — on the path D-4 budgets at one second. Everything ahead of the
 * cap is one native pass (NFC, the terminator fold, the slice), so the proof
 * now sees at most SCRUB_INPUT_CAP characters whatever the body holds. A
 * control run counts toward the cap before it collapses, so a control-heavy
 * value is cut shorter than it would have been — whole units still, marked;
 * the unit regex treats a control as part of its run, since it is not `\s`.
 */
function boundInput(value, opts) {
  const normalised = String(value).normalize('NFC').replace(RE_LINE_BREAK_RUN, '\n')
  const capped = normalised.length > SCRUB_INPUT_CAP ? cutAtRunBoundary(normalised) : normalised
  return neutraliseControls(capped, opts)
}

/**
 * Turn each control run into a separating space — after proving that the
 * units it separates were not one secret.
 *
 * The naive replacement is the same defect as the naive cut, at a third
 * boundary: `10.762622, 1<SOH>06.660172` became `10.762622, 1 06.660172`, and
 * `RE_GEO` cannot match across the space, so both halves were published; a
 * filename `alice.smith@<SOH>gmail.com` published `alice.smith@`. Deleting the
 * control instead was SA F-28 (it glued two lines and killed the phone rule's
 * left boundary), so neither "remove" nor "replace" is safe on its own.
 *
 * So the proof straddle() shares with `cutAtLineBoundary`, on units (the
 * rev 2.8 proof joined bare runs, which is why the coordinate case above was
 * still published — `1` + `06.660172` matches nothing). On a straddle the
 * redacted join replaces the pair: the control vanishes INSIDE a label, and
 * every character it separated is inside that label, so no rule is left
 * wanting the boundary. Otherwise the space, because the units really are
 * two things — and a redaction elsewhere in the join is phase 2's business,
 * with the boundary intact (F-45).
 *
 * Linear in practice: the input is at most SCRUB_INPUT_CAP characters plus
 * labels (boundInput caps first — F-47), so the trailing-unit search over
 * `out` is bounded by the cap, not by the body.
 */
function neutraliseControls(s, opts) {
  const parts = s.split(RE_OTHER_CONTROL_RUN)
  if (parts.length === 1) return s
  let out = parts[0]
  for (let i = 1; i < parts.length; i += 1) {
    const part = parts[i]
    const left = out.match(RE_LEFT_UNIT)[0]
    const right = part.match(RE_RIGHT_UNIT)[0]
    const proven = straddle(left, right, opts)
    if (proven !== null) {
      out = out.slice(0, out.length - left.length) + proven + part.slice(right.length)
    } else {
      out = `${out} ${part}`
    }
  }
  return out
}

/**
 * Phase 2. Every rule, in this order, on the whole bounded value.
 *
 * The order inside the phase matters only where one rule's label could hide
 * another's input: the credential-path and query rules replace a *value* after
 * a marker, so they run after the shape rules that would otherwise claim it.
 *
 * With a `probe` ({ at }) it also answers straddle()'s question: did a
 * redaction cover the character position `at` from both sides? Offsets inside
 * one rule's pass are in that pass's coordinates, so the test is made against
 * the probe as it stands, the length shift of every match that ended at or
 * before it is summed, and the probe moves after the pass. A replacement equal
 * to its match (a kept run) is not a redaction and moves nothing.
 */
function redactAll(bounded, { release, names }, probe = null) {
  const keep = release ? isPlainWordOrSha : names ? isName : isPlainWord
  const rules = [
    [RE_EMAIL, () => '[email]'],
    [RE_JWT, () => '[token]'],
    [RE_TOKEN_RUN, (run) => (keep(run) ? run : '[token]')],
    [RE_CRED_PATH, (match, marker) => `${marker}[redacted]`],
    [RE_CRED_QUERY, (match, key) => `${key}[redacted]`],
    [RE_GEO, () => '[geo]'],
    [RE_PHONE, () => '[phone]'],
  ]
  let s = bounded
  for (const [re, label] of rules) {
    let shift = 0
    s = s.replace(re, (match, ...rest) => {
      // rest = [group…, offset, string]: the offset is always second from last.
      const out = label(match, rest[0])
      if (probe !== null && out !== match) {
        const start = rest[rest.length - 2]
        const end = start + match.length
        if (start < probe.at && probe.at < end) probe.straddled = true
        else if (end <= probe.at) shift += out.length - match.length
      }
      return out
    })
    if (probe !== null) probe.at += shift
  }
  return s
}


/**
 * Path-template rule for transaction / route / screen tags: a segment that is
 * a UUID, a ≥16-char base64url run that is not a name, or a pure number of
 * ≥6 digits is an id. A screen called `NotificationSettings` is a name, not
 * an id (Astra F-27; RE_NAME above). These three tags are name positions
 * end to end: the joined template is scrubbed with `names: true` too, or a
 * 20+ kebab segment the segment test kept would be eaten by the run rule.
 *
 * The query/fragment comes off BEFORE classification (Sol F-01): `123456?view=map`
 * is not literally a run of digits, so it would survive classification and
 * then be published as the bare id. The query is dropped rather than relayed:
 * it is not part of a route template, and in a transaction name it is exactly
 * where ids and codes live. A segment carrying a control character or a line
 * terminator is classified `[id]` whole (RE_HOSTILE_SEGMENT): Sol F-01's first
 * fix joined `123<NUL>456` into `123456` by deleting the control, which is
 * the splice SA F-28 names, and a space there would read `123 456` as a kept
 * segment. Nothing hostile survives to the joined scrub, so its first-line
 * cut has nothing to cut.
 */
export function scrubPathTemplate(value) {
  const path = String(value).normalize('NFC').split(/[?#]/)[0]
  const templated = path
    .split('/')
    .map((seg) => {
      if (RE_HOSTILE_SEGMENT.test(seg)) return '[id]'
      if (/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(seg)) return '[id]'
      if (/^[A-Za-z0-9_-]{16,}$/.test(seg) && !isName(seg)) return '[id]'
      if (/^\d{6,}$/.test(seg)) return '[id]'
      return seg
    })
    .join('/')
  return scrub(templated, { names: true })
}

/* ─────────────────── embed building (shape D-5 table, D-6) ───────────────── */

/** Discord-markdown escape; allowed_mentions kills pings, this kills markup. */
export function escapeMarkdown(s) {
  return String(s).replace(/[\\*_~`|>[\]@]/g, '\\$&')
}

/**
 * Any URL that survived the scrub renders inert: `<…>` suppresses Discord's
 * preview. Case-insensitive — `HTTPS://` is a URL to Discord too (Sol F-06).
 *
 * The wrapper is inserted as a control-character pair and turned into `<…>`
 * only in capWrapped(): scrub() removed every control character before this
 * point, so the pair cannot collide with the text. Inferring a wrapper from a
 * bare `<` did — `count < limit for room` read as a truncated URL and lost
 * its suffix when nothing had been cut, without the `…` a cut owes (Sol F-19).
 */
const WRAP_OPEN = '\u0001'
const WRAP_CLOSE = '\u0002'
function wrapUrls(s) {
  return s.replace(/https?:\/\/[^\s<>]+/gi, `${WRAP_OPEN}$&${WRAP_CLOSE}`)
}

function truncate(s, max) {
  return s.length <= max ? s : `${s.slice(0, max - 1)}…`
}

/**
 * A cap applied after wrapping can cut the closing `>` off, which turns an
 * inert URL back into a link Discord unfurls (Sol F-06). So: wrap, cap, and
 * only if the cap crossed a wrapper this function inserted, drop that one
 * wrapper and keep the `…`. A URL-only value over its cap therefore leaves as
 * `…` — visible, and nothing Discord can unfurl.
 */
function capWrapped(s, max) {
  let cut = truncate(s, max)
  if (s.length > max) {
    const open = cut.lastIndexOf(WRAP_OPEN)
    if (open > cut.lastIndexOf(WRAP_CLOSE)) cut = `${cut.slice(0, open)}…`
  }
  return cut.replace(/\u0001/g, '<').replace(/\u0002/g, '>')
}

/** A typed string read: anything but a string becomes the fallback (F-07). */
function str(value, fallback = '') {
  return typeof value === 'string' ? value : fallback
}

/** Scrubbed, escaped, URL-wrapped, then capped without breaking a wrapper. */
function text(value, cap, opts) {
  return capWrapped(wrapUrls(escapeMarkdown(scrub(str(value), opts))), cap)
}

const TAG_ALLOWLIST = new Set([
  'environment',
  'release',
  'level',
  'handled',
  'transaction',
  'browser.name',
  'os.name',
  'device.family',
  'screen',
  'route',
])
const PATH_TEMPLATE_TAGS = new Set(['transaction', 'route', 'screen'])

/**
 * `tags` arrives as [[k, v], …]; an object is tolerated, anything else is
 * empty. One line per allowlisted key, the last value wins, in the order the
 * keys first appeared — so the list is at most TAG_ALLOWLIST.size lines by
 * construction, and the dedupe runs on the raw values BEFORE any scrub. A
 * signed body carrying `environment` forty thousand times fits inside the
 * 1 MiB limit; it used to produce forty thousand scrubbed lines and a fitting
 * loop that rebuilt the join once per dropped line (SA F-34).
 */
function allowedTags(raw) {
  const pairs = Array.isArray(raw)
    ? raw.filter((p) => Array.isArray(p) && p.length >= 2)
    : raw && typeof raw === 'object'
      ? Object.entries(raw)
      : []
  const last = new Map()
  for (const [k, v] of pairs) {
    if (typeof k !== 'string' || !TAG_ALLOWLIST.has(k) || typeof v !== 'string') continue
    last.set(k, v)
  }
  const out = []
  for (const [k, v] of last) {
    const scrubbed = PATH_TEMPLATE_TAGS.has(k) ? scrubPathTemplate(v) : scrub(v, { release: k === 'release' })
    out.push(`${k}=${capWrapped(wrapUrls(escapeMarkdown(scrubbed)), 120)}`)
  }
  return out
}

/**
 * A frame line for the Stack code block. Backticks would end the fence, so
 * they are dropped rather than escaped (markdown escaping does not work
 * inside a code block). filename: strip query/fragment, drop scheme + host,
 * redact the segment after any credential marker, keep the last three path
 * segments, scrub the joined path, cap — the shape's order (D-5, rev 2.3).
 */
function frameLine(frame) {
  const f = frame && typeof frame === 'object' ? frame : {}
  // Order matters, and it used to be wrong (Sol F-02/F-03): capping before
  // taking the tail keeps the *leading* directories — `/home/alice/private/…`
  // published the user's home path and cut the file name off, which is the
  // opposite of both intents. And the scheme match was case-sensitive, so
  // `HTTPS://internal.host/src/app.js` kept its host.
  // `split` rather than `.replace(/[?#].*$/, '')`: `.` stops at a line
  // terminator and `$` is end-of-input only, so a filename of many `?` with a
  // terminator after them backtracked once per `?` before the segment cap —
  // 80,000 of them took 9.5 s (the F-47 class, rev 2.9). The path rule next
  // door already strips the same way.
  const all = str(f.filename)
    .split(/[?#]/)[0]
    .replace(/^(?:file|https?):\/\/[^/]*/i, '')
    .split('/')
    .filter(Boolean)
  // The credential-path rule runs over the WHOLE path, segment by segment,
  // before the tail is taken: with the marker further out than the kept
  // three, `/r/AbCdEfGhIj/src/app.js` became `AbCdEfGhIj/src/app.js`, the rule
  // had no `/r/` to match, and ten letters are below the token rule — the
  // code was published (Astra F-23). The segment after a marker is a
  // credential whatever it contains, unless it is a route-template
  // placeholder (RE_ROUTE_PARAM). The full path is never handed to scrub(),
  // whose 400-character cut would eat it; this loop is linear.
  for (let i = 0; i + 1 < all.length; i += 1) {
    // Case-folded: `/INVITE/<code>` is the same marker (SA F-32).
    if (CRED_MARKERS.has(all[i].toLowerCase()) && !RE_ROUTE_PARAM.test(all[i + 1])) all[i + 1] = '[redacted]'
  }
  const segments = all.slice(-3).map((seg) => (seg.length > FILE_SEGMENT_CAP ? '…' : seg))
  // Scrubbed as one string: the credential-path rule needs `/r/<value>` across
  // two segments, so a per-segment scrub would miss it. The leading slash is
  // restored for the same rule's sake — taking the last three segments drops
  // it, and `r/AbCdEfGhIj/file.ts` then matched no rule at all, publishing an
  // invite code that `/r/AbCdEfGhIj/file.ts` would have redacted.
  let file = scrub(`/${segments.join('/')}`, { names: true }).replace(/^\//, '')
  // Left-truncate — after the scrub, so this cut can only split a label or a
  // run no rule matched; the basename is the part that locates the defect.
  if (file.length > 120) file = `…${file.slice(-119)}`
  // A frame's file and function are the two name positions of a frame line
  // (rev 2.4): `get_notification_preferences` is what the line exists to say.
  const fn = truncate(scrub(str(f.function, '?'), { names: true }), 80)
  const line = Number.isInteger(f.lineno) ? `:${f.lineno}` : ''
  const col = Number.isInteger(f.colno) ? `:${f.colno}` : ''
  const mark = f.in_app === true ? '▸' : '·'
  return `${mark} ${file}${line}${col}  ${fn}`.replace(/`/g, "'")
}

/**
 * The newest MAX_FRAMES frames of the thrown (last) exception, newest first.
 *
 * Discord's 1024-character field limit is met by shortening lines, not by
 * quietly dropping frames: a stack that silently shows four of eight reads as
 * a four-frame stack, and the reader has no way to know (Sol F-07). Frames are
 * shortened from the left, so the file name and line survive. Only if the
 * eight shortest possible lines still do not fit does it drop from the oldest
 * end, and then it says so in the block.
 *
 * At Discord's 1024 that never happens: eight 120-character lines fence to
 * 975, so the ladder ends at 120 and the omission path is unreachable through
 * buildEmbed(). It exists for a MAX_FRAMES or limit change, and `limit` is a
 * parameter so the test can reach it directly (Sol F-14).
 */
export function stackBlock(event, limit = FIELD_VALUE_MAX) {
  const values = Array.isArray(event.exception?.values) ? event.exception.values : []
  const thrown = values.length ? values[values.length - 1] : null
  const frames = Array.isArray(thrown?.stacktrace?.frames) ? thrown.stacktrace.frames : []
  if (!frames.length) return null

  const newest = frames.slice(-MAX_FRAMES).reverse()
  const fence = (lines) => `\`\`\`\n${lines.join('\n')}\n\`\`\``
  const shorten = (line, per) => (line.length <= per ? line : `${line.slice(0, 2)}…${line.slice(-(per - 3))}`)

  for (const per of [200, 150, 120, 96, 72, 56, 40]) {
    const lines = newest.map((f) => shorten(frameLine(f), per))
    const block = fence(lines)
    if (block.length <= limit) return block
  }

  // Nothing fits at the floor: drop from the oldest end, visibly.
  const lines = newest.map((f) => shorten(frameLine(f), 40))
  while (lines.length > 1) {
    const dropped = newest.length - lines.length + 1
    const marked = [...lines.slice(0, -1), `… ${dropped} older frame(s) omitted`]
    const block = fence(marked)
    if (block.length <= limit) return block
    lines.pop()
  }
  const only = fence([shorten(frameLine(newest[0]), 40), `… ${newest.length - 1} older frame(s) omitted`])
  return only.length <= limit ? only : null
}

/**
 * The Tags value is a join of lines each already capped without breaking a
 * wrapper; the generic field cap cut through one anyway, in the join (Sol
 * F-06). So the field is fitted by whole lines and says how many it left out.
 * One line is at most 134 characters, so at least one always fits; and there
 * are at most TAG_ALLOWLIST.size lines (allowedTags dedupes by key), so the
 * rebuild-per-dropped-line loop below is bounded by a constant (SA F-34).
 */
function joinTagLines(lines, limit = FIELD_VALUE_MAX) {
  for (let kept = lines.length; kept >= 0; kept -= 1) {
    const shown = kept === lines.length ? lines : [...lines.slice(0, kept), `… ${lines.length - kept} tag(s) omitted`]
    const value = shown.join('\n')
    if (value.length <= limit) return value
  }
  return ''
}

/**
 * Fields are blanked to `…` in this order once the description is at its
 * floor: the ones a reader can recover from the Sentry link first, the ones
 * that say which deploy and where last.
 */
const FIELD_DROP_ORDER = ['Tags', 'Stack', 'Rule', 'Release', 'Environment']

/**
 * Discord's 6000-character total is ours to enforce, not Discord's to reject:
 * shrink the description first, it is the only free-text block; when it is
 * down to `…` and the total is still over, blank field values in
 * FIELD_DROP_ORDER, each to `…`. The floor alone could not always fasten the
 * belt — it returned an over-limit embed, Discord answered 400 and the relay
 * reported `discord_failed`, while ADR-0013 said Discord never rejects for
 * size (SA F-41). With every field at `…` the total is the title, the footer
 * and the field names: under 400, so this always terminates under the limit.
 * Through buildEmbed() the component caps sum to about 3100, so this is a
 * guard that no event reaches; `max` is a parameter so the test can (Sol F-14).
 */
export function fitTotal(embed, max = EMBED_TOTAL_MAX) {
  const total = () =>
    (embed.title?.length ?? 0) +
    (embed.description?.length ?? 0) +
    (embed.footer?.text.length ?? 0) +
    embed.fields.reduce((n, f) => n + f.name.length + f.value.length, 0)
  if (total() > max) {
    embed.description = truncate(embed.description, Math.max(1, embed.description.length - (total() - max)))
  }
  for (const name of FIELD_DROP_ORDER) {
    if (total() <= max) break
    const field = embed.fields.find((f) => f.name === name && f.value !== '…')
    if (field) field.value = '…'
  }
  return embed
}

/**
 * The thrown exception's type and value, or the log message. Every value is
 * one line: scrub() takes the first line of whatever it is handed.
 *
 * `type` is a name position (owner decision 2026-10-18, shape rev 2.6 Q-7):
 * a type is a class name or an error code by construction —
 * `PLACE_PROVIDER_UNAVAILABLE`, `TypeError`, `com.foo.BarException` — and
 * nothing puts a credential there; strict, it printed `[token]` for exactly
 * the code an alert is about (SA F-39). The cost is one more field at the
 * name-position floor. `value` stays strict: it is free text where a
 * user-typed string lands, and the owner was asked about `type` only.
 */
function headline(event) {
  const values = Array.isArray(event.exception?.values) ? event.exception.values : []
  const thrown = values.length ? values[values.length - 1] : null
  if (thrown && typeof thrown === 'object') {
    const type = text(thrown.type, 80, { names: true })
    const value = text(thrown.value, 200)
    if (type || value) return `${type}${type && value ? ': ' : ''}${value}`
  }
  const message = str(event.logentry?.formatted) || str(event.logentry?.message) || str(event.message)
  if (message) return `message: ${text(message, 300)}`
  return ''
}

/** Only a link into our own Sentry org leaves as embed.url (shape D-5). */
function sentryUrl(event) {
  const url = str(event.web_url)
  if (url.startsWith('https://gogo-vn.sentry.io/') || url.startsWith('https://sentry.io/organizations/gogo-vn/'))
    return url
  return null
}

const LEVELS = new Set(['fatal', 'error', 'warning', 'info', 'debug'])

export function buildEmbed(event, triggeredRule, projectLabel) {
  const rawLevel = str(event.level).toLowerCase()
  const level = LEVELS.has(rawLevel) ? rawLevel : 'unknown'

  const embed = {
    title: truncate(`[${projectLabel}] ${level} · ${text(event.title, 200)}`, 256),
    description: truncate([text(event.culprit, 200), headline(event)].filter(Boolean).join('\n'), 4096),
    color: LEVEL_COLOUR[level],
    fields: [],
    footer: null,
    url: sentryUrl(event),
  }
  // The generic cap is the D-6 belt; every value below is already within it
  // by construction (Tags by whole lines, Stack by its ladder).
  const field = (name, value, inline = true) => {
    if (value) embed.fields.push({ name, value: truncate(value, FIELD_VALUE_MAX), inline })
  }
  field('Environment', text(event.environment, 64))
  field('Release', text(event.release, 100, { release: true }))
  field('Rule', text(triggeredRule, 100))
  field('Tags', joinTagLines(allowedTags(event.tags)))
  const stack = stackBlock(event)
  field('Stack', stack, false)

  const issueId = idString(event.issue_id, /^[0-9]{1,20}$/)
  const eventId = idString(event.event_id, /^[0-9a-f]{32}$/)
  const footer = [issueId && `issue ${issueId}`, eventId && `event ${eventId}`].filter(Boolean).join(' · ')
  if (footer) embed.footer = { text: footer }
  if (!embed.url) delete embed.url
  if (!embed.footer) delete embed.footer

  fitTotal(embed)
  return { issueId, eventId, embed }
}

/** An id leaves only when it matches its shape exactly (D-5, D-9). */
function idString(value, re) {
  const s = typeof value === 'number' && Number.isInteger(value) ? String(value) : str(value)
  return re.test(s) ? s : null
}

/* ───────────────────── Discord delivery (shape D-4, D-8) ─────────────────── */

async function retryAfterMs(response) {
  try {
    const body = await response.json()
    if (typeof body?.retry_after === 'number' && body.retry_after >= 0) return Math.ceil(body.retry_after * 1000)
  } catch {
    // fall through to the header
  }
  // `Number(null)` is 0, which turned an absent header into "retry immediately"
  // — an unauthorised second request straight back into a rate limit (Sol
  // F-08). Absent or blank means: we were not told, so do not retry.
  const header = response.headers.get('Retry-After')
  if (header === null || header.trim() === '') return null
  const seconds = Number(header)
  return Number.isFinite(seconds) && seconds >= 0 ? Math.ceil(seconds * 1000) : null
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms))

/**
 * One POST, `?wait=true` so a 2xx carries the saved message (F-08), redirects
 * refused (F-20), at most one 429 retry (F-17). Everything else is a drop that
 * the caller answers to Sentry as 502 (F-06) — with one exception.
 *
 * Two outcomes are kept apart for A-4 (SA F-31) and, since shape rev 2.7,
 * answered differently: a request that never completed (`discord_failed` —
 * thrown fetch, timeout, deadline passed, or a status Discord answered that is
 * not a save) is a 502 Sentry retries; a request that completed with a 2xx
 * whose answer could not be read or carried no message id
 * (`discord_unconfirmed`) is a 200 — the message is probably in the channel
 * and a retry would duplicate it (Q-8, owner decision 2026-10-18). A-4 checks
 * each `discord_unconfirmed` line against the channel; the one with no
 * message beside it is the loss the owner accepted.
 *
 * The deadline is absolute (Astra F-22): every attempt's timeout is the
 * smaller of DISCORD_TIMEOUT_MS and what is left before t0 +
 * DISCORD_DEADLINE_MS, and the retry is admitted only when the wait leaves
 * RETRY_MIN_WINDOW_MS for it. Reading the 429 body for `retry_after` runs
 * under the first attempt's signal and the clock is read after it, so that
 * time is inside the budget too.
 */
export async function postToDiscord(webhookUrl, body, t0) {
  const deadline = t0 + DISCORD_DEADLINE_MS
  const remaining = () => deadline - Date.now()
  const attempt = async () =>
    fetch(`${webhookUrl}?wait=true`, {
      method: 'POST',
      redirect: 'manual',
      headers: { 'content-type': 'application/json' },
      body,
      signal: AbortSignal.timeout(Math.max(0, Math.min(DISCORD_TIMEOUT_MS, remaining()))),
    })

  // Past the deadline nothing is posted: a request that cannot complete in
  // time is one Discord may still save while Sentry hears 502.
  if (remaining() <= 0) return { outcome: 'discord_failed', status: null }
  let response
  try {
    response = await attempt()
  } catch {
    return { outcome: 'discord_failed', status: null }
  }
  if (response.status === 429) {
    const waitMs = await retryAfterMs(response)
    if (waitMs === null || waitMs + RETRY_MIN_WINDOW_MS > remaining()) {
      return { outcome: 'rate_limited', status: 429 }
    }
    await sleep(waitMs)
    try {
      response = await attempt()
    } catch {
      return { outcome: 'discord_failed', status: null }
    }
    if (response.status === 429) return { outcome: 'rate_limited', status: 429 }
  }
  if (response.status >= 300 && response.status < 400) return { outcome: 'discord_redirect', status: response.status }
  if (response.status === 401 || response.status === 403 || response.status === 404)
    return { outcome: 'webhook_rejected', status: response.status }
  if (response.ok) {
    let message = null
    try {
      message = await response.json()
    } catch {
      message = null
    }
    if (message && typeof message.id === 'string' && /^[0-9]+$/.test(message.id))
      return { outcome: 'posted', status: response.status }
    return { outcome: 'discord_unconfirmed', status: response.status }
  }
  return { outcome: 'discord_failed', status: response.status }
}

/* ─────────────────────── authentication (shape D-3) ──────────────────────── */

async function signatureValid(secret, signatureHex, bodyBytes) {
  const key = await crypto.subtle.importKey(
    'raw',
    new TextEncoder().encode(secret),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['verify'],
  )
  const signature = new Uint8Array(32)
  for (let i = 0; i < 32; i += 1) signature[i] = parseInt(signatureHex.slice(i * 2, i * 2 + 2), 16)
  // crypto.subtle.verify is constant-time by construction; never compare hex
  // strings, and never compute the expected digest to print or log.
  return crypto.subtle.verify('HMAC', key, signature, bodyBytes)
}

/* ────────────────────────────── the handler ──────────────────────────────── */

/** Everything after a valid signature; thrown errors become relay_error 500. */
async function relay(parsed, resource, env, t0) {
  // Readiness is all-or-none (F-12): one missing or misshapen channel means
  // the relay answers 503 for every request instead of half-posting. The
  // Terraform flag is bookkeeping; this check is what decides.
  for (const { binding } of Object.values(PROJECT_CHANNEL)) {
    if (typeof env[binding] !== 'string' || !WEBHOOK_SHAPE.test(env[binding])) {
      logStatus('not_provisioned', resource, 'unknown', null, null, null)
      return new Response(null, { status: 503 })
    }
  }

  if (resource !== 'event_alert') {
    // `installation` arrives when the integration is created; anything else
    // is a subscription nobody configured. Authentic, so acknowledged.
    logStatus('ignored', resource, 'unknown', null, null, null)
    return new Response(null, { status: 204 })
  }

  const data = parsed?.data && typeof parsed.data === 'object' ? parsed.data : {}
  const event = data.event && typeof data.event === 'object' ? data.event : {}
  // The project id's type is read from Sentry's docs, not captured. If it ever
  // arrives as the string "4512201628254209", an integer-only check sends
  // every alert down the unknown_project branch: 204 to Sentry, a success on
  // its tab, nothing in any channel, and nothing to notice it by (SA F-37). A
  // decimal string is coerced; the lookup is still the closed map, keyed by
  // its own properties only.
  const projectKey = Number.isInteger(event.project)
    ? String(event.project)
    : typeof event.project === 'string' && /^[0-9]{1,20}$/.test(event.project)
      ? event.project
      : null
  const channel = projectKey !== null && Object.hasOwn(PROJECT_CHANNEL, projectKey) ? PROJECT_CHANNEL[projectKey] : undefined
  if (!channel) {
    logStatus('unknown_project', resource, 'unknown', null, null, null)
    return new Response(null, { status: 204 })
  }
  const projectLabel = channel.label

  const { issueId: safeIssueId, eventId: safeEventId, embed } = buildEmbed(event, data.triggered_rule, projectLabel)

  // allowed_mentions with an empty parse list: an error message must not
  // ping @everyone or a role, whatever its text says (F-05 fix kept the
  // embed — no SUPPRESS_EMBEDS flag, it would drop ours too).
  const body = JSON.stringify({ embeds: [embed], allowed_mentions: { parse: [] } })

  const { outcome, status } = await postToDiscord(env[channel.binding], body, t0)
  const discordStatus = status
  logStatus(outcome, resource, projectLabel, safeIssueId, safeEventId, discordStatus)
  return new Response(null, { status: ACKNOWLEDGED.has(outcome) ? 200 : 502 })
}

export default {
  async fetch(request, env) {
    const t0 = Date.now()
    const resource = normalizeResource(request.headers.get('Sentry-Hook-Resource'))

    // Shape D-3, in order, nothing reads the body until step 5.
    const url = new URL(request.url)
    if (request.method !== 'POST' || url.pathname !== '/hooks/sentry') {
      logStatus('not_found', resource, 'unknown', null, null, null)
      return new Response(null, { status: 404 })
    }
    const length = request.headers.get('Content-Length')
    if (length === null || !/^[0-9]+$/.test(length) || Number(length) > MAX_BODY_BYTES) {
      logStatus('too_large', resource, 'unknown', null, null, null)
      return new Response(null, { status: 413 })
    }
    const signatureHex = request.headers.get('Sentry-Hook-Signature')
    if (!signatureHex || !/^[0-9a-f]{64}$/.test(signatureHex)) {
      logStatus('bad_signature', resource, 'unknown', null, null, null)
      return new Response(null, { status: 401 })
    }
    if (typeof env.SENTRY_CLIENT_SECRET !== 'string' || env.SENTRY_CLIENT_SECRET === '') {
      logStatus('no_secret', resource, 'unknown', null, null, null)
      return new Response(null, { status: 401 })
    }

    // One boundary around everything that can throw (Sol F-09): reading the
    // body, WebCrypto key import and verification, decoding, parsing, and the
    // relay itself. A throw escaping the handler is an uncontrolled response
    // with no status line, on the one path Sentry uses to decide whether this
    // integration still works.
    try {
      const bodyBytes = await request.arrayBuffer()
      if (
        bodyBytes.byteLength > MAX_BODY_BYTES ||
        !(await signatureValid(env.SENTRY_CLIENT_SECRET, signatureHex, bodyBytes))
      ) {
        logStatus('bad_signature', resource, 'unknown', null, null, null)
        return new Response(null, { status: 401 })
      }

      let parsed
      try {
        parsed = JSON.parse(new TextDecoder().decode(bodyBytes))
      } catch {
        logStatus('malformed', resource, 'unknown', null, null, null)
        return new Response(null, { status: 400 })
      }

      return await relay(parsed, resource, env, t0)
    } catch {
      logStatus('relay_error', resource, 'unknown', null, null, null)
      return new Response(null, { status: 500 })
    }
  },
}
