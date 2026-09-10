# Share-link edge auth token — provisioning, rotation, rollback

INF-070 / GoGo-BE SEC-004. The token that lets the API believe the visitor
address the share-link Worker forwards.

## Where the value lives, and where it does not

| Place | Holds the token? |
| --- | --- |
| AWS SSM `share-link/worker-auth-token` (SecureString, per environment) | **yes — the source of truth** |
| The API process environment, rendered by `render-env.sh` | yes, at runtime |
| A Cloudflare Worker secret binding named `EDGE_AUTH_TOKEN` | yes, write-only |
| Terraform configuration, plan, or state | **no** |
| `config/*.tfvars`, this repository, any log line | **no** |

Terraform is told only *whether* a binding by that name exists
(`share_edge_auth_token_provisioned`), and carries it across script updates with
the Workers API's `inherit` type. It never receives the value, so the value
cannot appear in a plan, in the state file, or in the output of either.

The alternative considered and rejected was a `secret_text` binding fed by a
Terraform variable. `sensitive = true` hides such a value from CLI output and
not from the state file, and state lives in a bucket more than one role can
read. A Secrets Store binding (`secrets_store_secret`) would also keep the value
out of state and is the better long-term answer; it is **open beta**, and this
is an authentication credential, so it is not the one to pilot it on.

## Provisioning

Order matters, and only one order works.

```sh
# 1. generate a token — at least 32 characters; the API refuses shorter at boot
openssl rand -base64 48 | tr -d '\n=' | cut -c1-48

# 2. store it (this is the source of truth; do not keep the terminal copy)
./scripts/secrets/put.sh dev share-link/worker-auth-token

# 3. put it on the Worker, straight from SSM — never through a file,
#    an environment variable, or the screen
./scripts/secrets/put-worker-secret.sh dev share-link/worker-auth-token \
  EDGE_AUTH_TOKEN gogo-dev-share-link

# 4. only now: flip the flag and apply
#    config/dev.tfvars → share_edge_auth_token_provisioned = true
terraform -chdir=terraform/environments/dev apply
```

**Step 3 before step 4, always.** `inherit` on a script with no such binding is
an error, so applying first fails. And between 3 and 4 there is a window where
an unrelated `terraform apply` would *remove* the binding, because Terraform
emits it only when the flag says it exists. Keep the two adjacent, and never
leave the flag false once the secret exists.

The API side needs no separate step: `SHARE_LINK_EDGE_AUTH_TOKEN` is rendered
from the same SSM row by `render-env.sh` on the next deploy.

## Rotation

The API compares against exactly one value, so a rotation is briefly visible: a
Worker presenting the old token has its forwarded address ignored, and the rate
limit falls back to the connecting address. Nothing breaks — links resolve
normally throughout — the limit is just coarser for the length of the window.

```sh
./scripts/secrets/put.sh dev share-link/worker-auth-token          # new value
./scripts/secrets/put-worker-secret.sh dev share-link/worker-auth-token \
  EDGE_AUTH_TOKEN gogo-dev-share-link                              # Worker first
# then redeploy the API so render-env.sh picks up the new row
```

**Worker first, API second.** In that order the window is "the API has the old
token, the Worker has the new one" — mismatched, so addresses are ignored and
the limit is coarse. In the other order the window is identical in effect, so
either is survivable; Worker-first is the convention because the Worker is the
faster of the two to change back.

No Terraform run is involved in a rotation. The flag is already true, the
binding name has not changed, and `inherit` keeps whatever the Worker holds.

## Rollback

Three failures, three answers:

1. **Wrong value pushed to the Worker.** Re-run step 3 with the SSM value; the
   Worker binding is overwritten in place. Cloudflare keeps no readable history
   of it, which is why SSM and not the Worker is the source of truth.
2. **Wrong value in SSM.** `./scripts/secrets/get.sh <env> share-link/worker-auth-token`
   shows version and modified time without printing the value; SSM keeps prior
   versions, so an operator can restore one and re-run step 3.
3. **The feature needs to be switched off entirely.** Set
   `share_edge_auth_token_provisioned = false`, apply — the binding is dropped,
   the Worker stops sending edge headers, and the API returns to keying the
   share-link limit on the connecting address. This is the pre-SEC-004 behaviour
   and it is safe: no error, no dropped clicks, just a coarser limit. Optionally
   `wrangler secret delete EDGE_AUTH_TOKEN --name <worker>` afterwards to remove
   the value.

Nothing here rolls back by reverting a commit alone: the Worker binding is live
state, not configuration.

## Log redaction

- **API.** `req.headers["x-gogo-edge-auth"]` is in `REDACT_PATHS`. The
  `onRequest` hook also *deletes* both edge headers from every request before
  anything else reads it, so redaction is the second line, not the first.
- **Worker.** The token is only ever read out of `env` and passed to `fetch`. It
  is never logged, never included in an error body, and never returned to a
  visitor — a resolve failure answers `upstream_unavailable` with the upstream
  error string, which cannot contain a request header.
- **This script.** The value goes SSM → pipe → wrangler. It is not printed, not
  written to disk and not exported, so it cannot be recovered from `ps`, a shell
  history, or a CI log. `scripts/secrets/put-worker-secret.test.sh` asserts all
  three.
- **gitleaks** scans the repository on every PR; there is nothing here for it to
  find, because no file holds the value.

## Unavoidable residual risks

Stated rather than implied, because each is someone's judgement to accept:

1. **Cloudflare holds the value.** A Worker secret is readable by anyone with
   write access to the account's Workers, through the dashboard's edit path and
   through the API. Account access is therefore equivalent to token access.
   Cloudflare access is already governed by INF-024; this adds one more thing
   behind that door.
2. **The API process environment holds it.** Anything that can read
   `/proc/<pid>/environ` on the API host, or a core dump, can read the token.
   That is true of every value `render-env.sh` renders and is not specific to
   this one.
3. **SSM readers hold it.** Every role with `ssm:GetParameter` on
   `/gogo/<env>/backend/*` can read it — the deploy role and the operators who
   run these scripts. That is the intended blast radius and the reason the row
   is a SecureString.
4. **State is clean, but not by accident.** The moment someone adds a
   `secret_text` binding or a `sensitive` variable carrying a real value, the
   token is in the state file and stays in its version history.
   `put-worker-secret.test.sh` asserts that no Terraform file assigns a value to
   an edge auth token and that no binding is `type = "secret_text"`, so the
   regression fails a test rather than being noticed later.
5. **A rotation window is coarse, never closed.** There is no dual-token
   acceptance. Adding one would mean the API accepting two secrets at once,
   which is more surface for a limit that degrades gracefully anyway. Revisit
   only if the coarse window ever proves to matter.

## Not yet true

No environment holds a token, so none of the above has run anywhere yet. The
manifest row is still optional everywhere.

What changed (GoGo-Infra#153): this used to say the Worker never calls the API,
because `api_origin` was empty. DEV's edge does call it now —
`API_ORIGIN` is set in Cloudflare and Terraform carries the binding with
`inherit` rather than holding a copy. The resolve endpoint is `@Public()`, so
the edge works without a token; what the token buys is client-IP forwarding, and
without it every visitor shares one rate-limit bucket at the API. That makes
putting the token the next thing to do on DEV, not a thing blocked on something
else.
