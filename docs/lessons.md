# Lessons

Every entry here cost a debugging round trip during the dev bootstrap. They are written as
symptom → cause → fix, because the symptom is what you will have when you arrive.

The recurring shape: **a broken check blamed a correct credential.** Five separate times, the
tooling reported a configuration problem that did not exist. Anything below that reads like
paranoia about diagnostics is the reason.

---

## 1. Shell portability

### `\s` is not whitespace on macOS

**Symptom** — `cloudflare_account_id` reached Terraform as the literal string
`cloudflare_account_id = "..."`. Separately, `preflight.sh` reported an empty `aws_account_id`
as `ok` for two commits.

**Cause** — BSD `sed` does not support the GNU `\s` shorthand. It does not error: the pattern
fails to match and `sed` prints the input unchanged. The value therefore came back non-empty and
every `[[ -n "$value" ]]` check passed.

**Fix** — POSIX classes (`[[:space:]]`) everywhere. And a stronger rule: **a parser that returns
its input on failure is worse than one that throws**, because every caller's validation then sees
a plausible value. `scripts/lib/config.sh` returns nothing on no-match, and
`scripts/lib/config.test.sh` pins that behaviour.

### Empty arrays are unbound on bash 3.2

**Symptom** — `tls_flag[@]: unbound variable`, then `FAIL responds to PING` against a healthy
Redis.

**Cause** — macOS ships bash 3.2, where `"${arr[@]}"` on an empty array trips `set -u`. The
script aborted mid-check and the surviving output read as a service failure.

**Fix** — do not expand a possibly-empty array. Wrapper functions, or guard with
`"${#arr[@]}"`, which is safe on an empty array. Only the expansion is not.

### An apostrophe in a comment inside `$( )`

**Symptom** — `syntax error near unexpected token '('`, reported seventy lines below the real
problem.

**Cause** — bash tracks quote state through comments inside command substitution. `caller's` left
an unmatched single quote.

**Fix** — no apostrophes in comments inside `$( )`. When a syntax error points somewhere
plausible but innocent, bisect with `head -n | bash -n`.

### `printf` cycles its format

**Symptom** — a list of missing credentials printed as
`put.sh ci terraform/read/x/terraform/read/y`.

**Cause** — `printf 'fmt %s/%s' "$env" "${arr[@]}"` reuses the format until the arguments run
out, pairing the environment with the first element and then the rest with each other.

**Fix** — loop.

### Merging stderr into stdout corrupts the verdict

**Symptom** — `FAIL responds to PING (Warning: Using a password with '-u' ... may not be safe.)`

**Cause** — `redis-cli` writes that warning to stderr whenever the URL carries a password, which
is always. Capturing `2>&1` made a successful probe return `Warning: ...\nPONG`.

**Fix** — the verdict reads stdout; the explanation reads stderr separately. Merge only when the
combined text is the answer, never when it is the input to a comparison.

### `curl -f` silences the error you were about to print

**Cause** — with `-f`, curl exits non-zero and returns an empty body on 4xx. In
`x="$(curl -f ...)"` under `set -e`, the assignment ends the script before the error branch runs.

**Fix** — capture the body and `%{http_code}` separately, then decide.

### A second `trap ... EXIT` replaces the first

**Cause** — traps do not stack. Registering a second EXIT handler silently drops the cleanup that
was removing `backend_override.tf`, after which every `terraform init` in that directory quietly
uses a local backend.

**Fix** — extend the existing handler. Also: `unset VAR` in an EXIT trap is theatre — an exported
variable dies with the process and never reached the parent shell.

---

## 2. Terraform and AWS

### `for_each` keys must be known at plan time

**Symptom** — `Invalid for_each argument` on a fresh account, at the first apply.

**Cause** — attachments were keyed `"<role>:<policy-arn>"`, and the ARNs come from resources
that do not exist yet.

**Fix** — key by static name (`"<role>:<policy-name>"`); the unknown ARN is only a value. Index
keys also satisfy Terraform and are worse: inserting a policy renumbers the rest, and Terraform
destroys and recreates them — for `aws_iam_role_policy_attachment`, a window where the role does
not hold the policy.

### `AWS_REGION` outranks `AWS_DEFAULT_REGION`

**Symptom** — `InvalidRegionName ... 'ap-southeast-1' is not valid` from R2, immediately after
the credentials had been confirmed correct.

**Fix** — R2 accepts only `auto`. Set both variables and pass `--region auto`.

### `-migrate-state` needs `-force-copy` when input is disabled

**Symptom** — `Can't ask approval for state migration when interactive input is disabled`, after
a successful apply, leaving the environment created with its state on one laptop.

**Fix** — `-force-copy`. And check the prerequisites of the last step **before** the apply:
failing at the end is what puts state in that position.

### Backend credentials passed as `-backend-config` are written to disk

**Cause** — Terraform persists the resolved backend configuration into
`.terraform/terraform.tfstate` in plaintext. Credentials passed that way stay in the workspace.

**Fix** — a named profile (`profile = "r2-state"`), written 0600. Never export R2 keys as
`AWS_ACCESS_KEY_ID`: the AWS provider reads the same variables and will call AWS with Cloudflare
credentials.

### Bootstrap resources created imperatively collide later

**Cause** — the OIDC provider and roles created by a script are unmanaged; the first
`terraform apply` fails with `EntityAlreadyExists`, in CI, in front of whoever expects it least.

**Fix** — apply the real configuration with a temporary local backend and then
`init -migrate-state`, so Terraform owns them from creation. `import-existing.sh` covers accounts
already in the other state; after importing, `plan` must show zero destroy and zero replace.

### Scoping IAM by resource does not stop escalation

**Cause** — `iam:AttachRolePolicy` restricts which **role** is modified, not which **policy** is
attached. A role scoped to `role/gogo-*` can still be given `AdministratorAccess` and assumed.

**Fix** — three controls together: an `iam:PolicyARN` allowlist condition on attach/detach, an
`iam:PermissionsBoundary` condition on role creation, and a boundary that denies editing itself.
A ceiling its occupant can rewrite is not a ceiling.

### An explicit Deny beats every Allow

**Cause** — widening the apply role's `Deny` on `ssm:Get*` from
`/gogo/<env>/backend/*` to `/gogo/*` also blocks `ci/<env>/terraform/write/*`, which that role
must read to run `terraform init`. The failure surfaces at init, naming nothing useful.

**Fix** — keep such Denies narrow, and say why in a comment, or someone will "tighten" it.

### The OIDC subject is not the string in the documentation

**Symptom** — `Not authorized to perform sts:AssumeRoleWithWebIdentity`, with the role ARN and
audience correct in the log.

Everything checked out. The live trust policy matched Terraform state and read
`token.actions.githubusercontent.com:sub = repo:namnh92/GoGo-Infra:environment:dev`. The OIDC
provider had the right URL and client id. The workflow declared the environment. Four rounds of
verification, each confirming AWS was correct, and the call still failed.

**Cause** — GitHub issues the subject in an **immutable, id-based form**:

```
repo:namnh92@23242146/GoGo-Infra@1349240763:environment:dev
```

not the name-based form nearly every example shows. Nothing ever matched, and the error mentions
neither subjects nor the value it compared against.

**Fix** — numeric owner and repository ids in `config/global.tfvars`, and trust policies carrying
both forms. The id form is the stronger pin: ids survive a rename, and a repository recreated
with the same name cannot inherit them.

**The transferable part** — it was found by printing the claim instead of reasoning about it. A
throwaway workflow requested the token, decoded the payload and printed `sub`, `aud` and
`environment` only, never the token. None of the AWS-side checks could have found this, because
the wrong value was on the other side of the exchange.

When both ends verify and the call still fails, stop verifying and read what is on the wire.

### Opening a file for writing destroys it before the write is computed

**Symptom** — `docs/lessons.md` became a zero-byte file and was committed that way.

**Cause** — `io.open(path, "w").write(s.replace(old, new))`. Python evaluates `io.open(..., "w")`
first, which truncates the file, and only then evaluates the argument. When the argument raised,
the file was already empty and nothing was written. The traceback pointed at the `replace`, so it
read as a failed edit rather than a destroyed file.

**Fix** — build the string, then open:

```python
result = s.replace(old, new)
io.open(path, "w").write(result)
```

Recovered with `git show <commit>:<path>`, which is only possible because the previous version was
committed. An edit script that truncates on failure is one uncommitted change away from losing
work outright.

### A bootstrap script run twice is not idempotent, it is amnesiac

**Symptom** — re-running `aws.sh dev` on a working environment: a `409 Conflict` creating an R2
bucket that already existed, and a real IAM policy left recorded only in a local state file that
the environment does not own.

**Cause** — the script starts from an empty local state on purpose; that is what makes a first
bootstrap possible before the remote backend is reachable. Run again after migration, it does not
read the remote state at all. It plans as if nothing exists.

"Idempotent" was the wrong word for it. Each individual step was idempotent; the script as a
whole was reading from the wrong place, so it could not know what already existed.

**Fix** — refuse when `.terraform/terraform.tfstate` reports the `s3` backend, and print the
`terraform apply` invocation to use instead. Recovery for the damage already done was
`terraform import` of the orphaned policy, after copying the stray state file somewhere safe.

### GitHub OIDC subjects

- A pull request's subject is `repo:<owner>/<repo>:pull_request` and **does not encode the base
  branch**. Splitting plan-dev from plan-prod is defence in depth, not an enforced boundary.
- When a job declares `environment:`, GitHub issues **only** the environment subject. Listing a
  `ref:` subject alongside it is not redundancy: it is a second trust path usable by any workflow
  on that branch that declares no environment.

### List order the API controls produces a permanent diff

**Symptom** — every plan showed two R2 lifecycle rules swapping places.

**Cause** — the API returns rules ordered by id; `rules` is a list.

**Fix** — sort by id before sending. Worth fixing rather than tolerating: a diff on every run is
how people learn to skim plan output, and skimmed plan output is where a real change hides.

Also: an R2 lifecycle configuration **cannot be destroyed by Terraform**. After `destroy`, check
the dashboard — a leftover rule attaches itself to the next bucket of the same name.

---

## 3. Provider credentials

### One credential, two variable names

**Symptom** — the operator exported the token, saw it confirmed as loaded, and watched the apply
send unauthenticated requests.

**Cause** — `bootstrap/terraform-state` read `TF_VAR_cloudflare_api_token` while
`terraform/environments/*` relied on `CLOUDFLARE_API_TOKEN`, which the provider reads natively.
Both were correct in isolation.

**Fix** — one name repo-wide. Bridging in one script would have left the trap in place for
`make plan`.

### Cloudflare has two token-verify endpoints

`/accounts/{id}/tokens/verify` for account-owned tokens, `/user/tokens/verify` for user-owned
ones. Checking only the user endpoint reports a perfectly good account token as invalid. Try the
account endpoint first, fall back, fail only when both reject.

### R2 shows three values and only two are S3 credentials

| Shown | What it is |
| --- | --- |
| Token value | Bearer token for the Cloudflare REST API — not an S3 credential |
| Access Key ID | 32 hex characters |
| Secret Access Key | 64 hex characters |

Storing the token value in `r2/access-key-id` fails as `InvalidAccessKeyId`, which reads like a
permissions problem and sends you to edit the token scope instead of the value. Create these under
**R2 → Manage R2 API Tokens**; tokens from *My Profile → API Tokens* produce no S3 credentials at
all.

### OneSignal: wrong endpoint, wrong credential class, two live auth generations

- `GET /apps/{id}` is **organization-scoped** and authenticates with the Organization API Key. A
  working app REST key checked against it reports as rejected. Use an app-scoped endpoint —
  `GET /notifications?app_id=…` — so the check tests the credential the backend will use.
- Two generations are live: `Authorization: Basic <key>` against `onesignal.com/api/v1` for older
  keys, `Authorization: Key <key>` against `api.onesignal.com` for newer ones.
- Every wrong credential returns the same "Access denied" text, so the API cannot tell you which
  one is wrong. The prefixes can: `os_v2_org_` is the Organization API Key (account-wide, cannot
  send for one app), `os_v2_app_` is the app key, a 36-character UUID is the App ID pasted from
  the field above.

### Tenjin has no "server API key"

There is an **SDK Key** per app — client config, shipped in the binary, and also what
server-to-server event posting authenticates with — and an **API Access Token** for the
Automation and Reporting APIs. A parameter named `tenjin/server-api-key` was invented here and
removed. Building a tracking URL is template composition, not an authenticated call.

**Do not mint a credential so a checklist turns green.** That creates a real secret, with a real
blast radius, guarding nothing.

### Cloudflare permissions are split across two scopes with similar names

**Symptom** — the worker script uploaded successfully, then `403 Forbidden` on
`POST /zones/<id>/workers/routes`. Adding "Workers Scripts: Edit" to the token had just fixed the
previous 403, so it looked like the same problem coming back.

**Cause** — Workers **Scripts** is an *account* permission; Workers **Routes** is a *zone*
permission. A token with every account permission still cannot attach a route. DNS is zone-scoped
too. The names are close enough that "I gave it Workers access" feels complete.

**Fix** — `verify_cloudflare_scopes` probes all four endpoints before Terraform runs, so one
message lists everything missing instead of one 403 per apply. Edit the existing token rather
than creating a new one: the value does not change, so nothing has to be re-stored in SSM.

That last detail matters more than it looks. Three rounds were spent on this token, and had each
fix meant a new token, each round would also have needed a `put.sh` and a re-run.

### A wildcard certificate covers one label, not a subtree

**Symptom** — DNS resolved to Cloudflare, worker routes were attached and correct, and every
request to `https://go.dev.gogo.id.vn/...` died with
`sslv3 alert handshake failure`. Nothing in the routing was wrong; nothing in the routing was
ever reached.

**Cause** — Cloudflare Universal SSL issues a certificate for the apex and `*.gogo.id.vn`. A
wildcard matches exactly **one** label, so `go.dev.gogo.id.vn` — three levels — is not covered.
The connection fails at the handshake, before HTTP exists, which is why no worker log and no
route configuration shows anything.

Covering it needs Advanced Certificate Manager, which is paid.

**Fix** — one label: `go-dev.gogo.id.vn`, `go-stag.gogo.id.vn`, `go.gogo.id.vn`. A hyphen instead
of a dot costs nothing and keeps free TLS. The remote-first spec had already written
`api-dev.<domain>` for the same reason; the hostname was chosen without noticing that.

**Worth generalising** — a TLS handshake failure means the request never became HTTP. Reading
application logs, route tables or worker code at that point is looking downstream of where the
failure is.

### Other provider facts worth not rediscovering

- **Upstash** Management API authenticates with account email + API key even when the console
  login is GitHub OAuth. Blocking commands (`BLPOP`) work on the TCP endpoint; the REST endpoint
  cannot serve BullMQ at all.
- **Neon** requires the `-pooler` endpoint once `api` and `worker` both run. A database created
  by hand has none of `postgis`, `pg_trgm`, `btree_gist` — the failure arrives much later as a
  migration error about an unknown type.
- **Google** API keys are 39 characters starting `AIza`. An OAuth client id or a service-account
  field stored in that slot passes every check that only tests for non-emptiness.

---

## 4. How to write the checks

Most of the entries above were found by a check, or caused by one. What made the difference:

**Verify before a long operation, not after.** A bad token surfacing after the IAM apply reads
like an IAM problem.

**Shape-check locally before spending a network call.** Lengths and prefixes identify a
misplaced credential without printing it, without billing, and without a round trip. Google keys
are deliberately never called — every Places or Routes request is billable, so a liveness check
would charge the project on every run.

**Never report a failure without a reason.** `FAIL R2 credentials can reach bucket ()` is worse
than no check. Quote what the provider said; it distinguishes causes that need different fixes.

**Never say "run this other command to find out."** The information is one variable away and
withholding it costs a round trip every time.

**Separate blocking from informational.** `complete.sh` reported a finished bootstrap as broken
because runtime secrets that nothing had created yet were counted as failures. A check that cries
wolf gets ignored, and the one that matters gets ignored with it.

**List optional items too.** Reporting only what an environment requires made a prod-only
parameter invisible in dev, so it read as an omission rather than a scope decision.

**Confirm, do not warn-and-write.** `put.sh` used to warn about an undeclared path and write it
anyway. A typo then creates a parameter nothing reads, nothing validates and nobody rotates,
while the real one stays empty.

**Guard scripts that provision.** `neon.sh` and `upstash.sh` create and overwrite. Run against an
environment already configured by hand, they would orphan the first resource — still billing —
and point the environment at an empty one.

**A diagnostic must not disturb what it diagnoses.** The R2 check runs in a subshell with its own
credentials; exporting them would replace the AWS session the rest of the script depends on.

**Make silent promotion impossible.** An unsuffixed value in `bootstrap.env` belongs to one
environment. Without `UNSUFFIXED_VALUES_BELONG_TO`, a later `setup-env.sh prod` would copy the dev
OneSignal App ID into the prod namespace, and the first sign would be a production push arriving
on a development handset.

## Checks that pass without checking

**Turn the acceptance sentence into a test.** `docs/accounts.md` claimed "no automation depends
on OAuth" for weeks. It happened to be true, but only because nobody had broken it — nothing
would have noticed the first personal access token added to a workflow.
`scripts/ci/check-workflow-auth.sh` now fails the build for it.

**A checker nobody has watched turn red is a green light.** Both new checks ship with a test that
feeds them the shape they claim to catch. The first version of `check-workflow-auth.sh` flagged
the comment in `tf-setup/action.yml` that *warns against* putting R2 credentials in
`AWS_ACCESS_KEY_ID` — a check that fails on the warning rather than the mistake gets silenced,
taking the real check with it. Match on the assignment, strip comments first.

**A capturing group changes what a scanner reports.** `gogo-postgres-url` was written
`postgres(ql)?://…`, so gitleaks reported group 1 — the string `ql` — as the Secret. Allowlist
regexes match against the Secret, which made the rule impossible to allowlist, and would have
made a genuine finding useless: the report would name `ql` instead of the password that leaked.
Use `(?:…)` unless the group is the secret.

**A scanner can be green on the branch nobody reads and dead on the branch under review.** The
gitleaks *action* calls `GET /repos/{o}/{r}/pulls/{n}/commits` on a `pull_request` event. Under
`permissions: contents: read` that returns 403 and the action crashes — so it passed on pushes to
`develop` and failed on every PR, and the PR failure looked like a leak. Running the binary needs
no token, no rate limit and no deprecated runtime, and executes the same command as `make scan`.

**Pin the version and verify the bytes.** A pinned version with no checksum still runs whatever
arrives at that URL. Retry too: the first install died on `curl: (35) Recv failure: Connection
reset by peer` against a URL that was correct and reachable, and a red build on an unrelated PR
teaches people to re-run until green.

**An allowlist entry is how a scanner gets switched off.** Added to silence one false positive,
then quietly covering the real thing. `scripts/ci/gitleaks-rules.test.sh` asserts both directions
— literal credentials still caught, interpolated and placeholder forms not — so the next edit has
to keep both true.

**Fake credentials in a test file are still credential-shaped.** Writing fixture literals into
`gitleaks-rules.test.sh` made the scanner flag its own test, correctly. Generating them at run
time is better than a path exemption, which is the same failure this file keeps describing, and
better than a fingerprint ignore, which stops matching the moment the line moves.

**Run the check after staging, not before.** The repo scan came back clean and was reported clean
— it had run before the offending file was committed. `gitleaks detect` reads git history, so a
literal removed in a later commit is still there; the branch had to be rewritten.

**Do not fill a register from the git author.** `docs/accounts.md` leaves every owner column
blank on purpose. Guessing who holds an account produces a register that reads complete and is
wrong, which is worse than the blank. Every row having one owner and no backup is the finding.

**Derive the offboarding list, do not write it.** "Rotate every credential they could have read"
is unactionable at the moment it is needed. `scripts/ops/offboard-checklist.sh` generates the
paths from `secrets.manifest.yml`, so parameters added later appear without anyone remembering —
and it says *regenerate* for the auth signing secrets, which have no provider console to visit.

**Read access proves nothing about write access.** The Cloudflare token answered
`GET /accounts/{id}/access/apps` with 200, which was taken as "the token can do Access". The
apply then failed on `POST /accounts/{id}/access/policies` with `403 auth.forbidden`. Probe the
verb the work actually needs.

**A partial apply leaves the half that succeeded.** The failed CMS apply created
`cms-dev.gogo.id.vn` bound to the Worker and then failed on the Access policy — the hostname
without the guard, which is the ordering the module explicitly refuses. It was destroyed rather
than left "until the token is fixed". Check what landed after every failed apply; Terraform does
not roll back.

**"Input missing" must not compute to "delete the resource".** The CMS build artifact is
gitignored, so a runner without it would plan an empty deploy — and on an environment that
already has the Worker in state, an empty deploy is a destroy. `terraform-apply-dev` runs
automatically on pushes to `develop`, so that plan would have executed. A resource precondition
now fails the plan with the command to run. Verified by moving the build aside: `0 to destroy`,
then a readable error. Whenever a `count` or a `for_each` depends on something that can simply be
absent, work out what absence plans as before trusting it.

**`content_sha256` is what makes a code change a diff.** Without it Terraform compares the
`content_file` path, which never changes between builds, so a rebuilt bundle deploys nothing and
reports success — the deploy equivalent of a green check that checked nothing.

**Set the workers.dev subdomain, do not inherit it.** Cloudflare Access binds to a custom domain.
A Worker that also answers on `*.workers.dev` serves the same admin console on a hostname Access
never sees, and nothing in the Terraform files says so. `cloudflare_workers_script_subdomain`
with `enabled = false` is the difference between "guarded" and "guarded at one of its two doors".

**Read the runtime date from the source that owns it.** `compatibility_date`,
`not_found_handling` and `run_worker_first` live in GoGo-CMS's `wrangler.jsonc`. Copying them into
tfvars makes two truths that drift, and the symptom of that drift is a Workers runtime behaviour
change nobody traces back to a config file.

**Branch from the base, not from wherever you are standing.** `feature/GOGO-37-dev-deploy-inputs`
was cut while the CMS branch was checked out, so PR #49 — titled "host key pinning" — carried the
entire CMS hosting module and its tfvars into `develop`. Nobody reviewing that PR was looking for
them. `git checkout -b` inherits the current HEAD silently; `git checkout -b <new> develop` says
what it means.

**A merge is an unattended apply.** `terraform-apply-dev` runs on pushes to `develop` touching
`terraform/**` or `config/**`. The smuggled tfvars made it create `cms-dev.gogo.id.vn`, fail on
the Access policy it has no permission for, and leave an admin console on the open internet for
about ten minutes. Terraform does not roll back the half that succeeded, and there is nobody
watching a merge. Every guard that depends on a human running apply and reading the error is not
a guard.

**Disarm at the value, not only in the module.** The module refuses to create a hostname without
an Access list, which is right and was not enough: the tfvars supplied one. `config/dev.tfvars`
now carries the settings commented out with the reason, so turning it on is one deliberate edit
after `make cf-scopes` says the token can create the policy.

**`200` with an empty list can be a permission denial.** A Cloudflare token without
`Access: Apps and Policies · Read` answers `GET /access/policies` with `success: true` and zero
results — while the write token sees two — and only returns 403 on `GET /access/policies/{id}`.
`check-cf-token-scopes.sh` probed the list, reported the read token healthy, and `plan (dev)`
failed on exactly the call it had not made. Probe the request the tool actually issues, and treat
an empty collection as a question rather than an answer.
