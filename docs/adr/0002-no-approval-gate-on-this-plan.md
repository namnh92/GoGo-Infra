# ADR 0002 — The approval gate does not exist on this plan

**Status:** accepted — no approval gate, by decision rather than by billing
**Date:** 2026-08-29
**Issues:** INF-016, INF-027

## Context

Two controls in ADR 0001 and in the security spec are enforced by GitHub, not by our code:

1. A production **approval gate**, via required reviewers on the `production` environment.
2. **Branch protection** on `master` and `develop`, with CODEOWNER review on
   `.github/workflows/**` — which ADR 0001 argues is a security control, not process hygiene,
   because OIDC-to-SSM makes the workflow file the authorization boundary.

Neither is available. `GoGo-Infra` is private on a free plan, and GitHub returns:

```
Failed to create the environment protection rule.
Please ensure the billing plan supports the required reviewers protection rule.   (422)

Upgrade to GitHub Pro or make this repository public to enable this feature.      (403)
```

## Decision

Record the gap rather than paper over it, and take the mitigations that are actually available.

**Environments are still created** — `dev`, `staging`, `production`. They carry no protection
rules, but they still do the job the trust policies depend on: a job that references an
environment causes GitHub to issue the subject `repo:<owner>/<repo>:environment:<name>`, which is
what pins each IAM role. That part of the model is unaffected.

**Production apply is dispatch-only.** `terraform-apply-prod.yml` no longer triggers on a push to
`master`. Without an approval gate, applying on merge would mean any merge changes production
infrastructure with nothing in between. Requiring a person to start the run is weaker than an
approval and is what remains.

**`dev` is limited to the `develop` branch** through a deployment branch policy, which the free
plan does allow.

**CODEOWNERS stays, and is advisory.** Do not read `.github/CODEOWNERS` as an enforced control
until branch protection exists.

## What this leaves exposed

Anyone who can push to `master` can change the workflow files, and through them reach whatever
the apply and deploy roles can reach. The permissions boundary and the read/write credential
split still cap the blast radius — a plan role holds no write-capable credential, and the apply
role cannot escalate through IAM — but the human control is missing.

That is acceptable while the repository has one committer. It stops being acceptable the moment a
second person has push access, which is the trigger to revisit this.

## After the plan upgrade

The account moved to a paid plan the same day. Half the gap closed.

**Branch protection now works**, and is configured:

| | `develop` | `master` |
| --- | --- | --- |
| Required status checks | shellcheck, gitleaks, terraform fmt/validate/tflint | same |
| Strict (branch must be current) | yes | yes |
| Pull request required | no | no |
| Force push / deletion | blocked | blocked |
| Linear history | — | required |

Green CI is the whole gate. Nothing merges with a failing `terraform validate`, a shellcheck
error or a gitleaks hit, and history cannot be rewritten or a branch deleted.

**Required reviewers on environments still fails**, with the same 422 — that rule is a Team
feature, not a Pro one.

**Human review was then dropped entirely, deliberately.** Not because it is unavailable — the
branch-level approval was available on this plan — but because it was decided that green CI is a
sufficient gate at this size. Neither branch requires a pull request.

What that costs, stated plainly rather than left implied: ADR 0001 argues that OIDC-to-SSM makes
`.github/workflows/**` an authorization boundary, and review on it a security control. With no
review anywhere, `.github/CODEOWNERS` is documentation. Whoever can push to a protected branch
can change what the apply and deploy roles reach, and the only thing between that change and
production credentials is CI passing — which the same commit can also change.

That is the actual shape of the residual risk, and it is why the controls below matter more here
than they would in a repository with reviewers.

What still contains it, none of which depends on a human looking: the permissions boundary, the
split between read-only plan credentials and write-capable apply credentials, path-scoped SSM
policies, and the CI checks that reject `pull_request_target` and secret-shaped values in config.
Those are enforced in AWS and in Cloudflare, not in GitHub, so a workflow edit cannot lift
them — it can only reach what the roles already allow.

`enforce_admins` is **false** on both branches. The rules bind anyone who is not an admin and
are honest about not binding the one person who is.

Both of these — no approvals, admins exempt — are reasonable for a single committer and stop
being reasonable at two. That is the revisit trigger below, and it is the same one.

## Options to close it

| Option | Cost | Gets |
| --- | --- | --- |
| GitHub Pro | a few dollars a month | branch protection on private repos |
| GitHub Team | more | required reviewers on environments, plus rulesets |
| Make the repository public | none in money | both, and publishes the infrastructure layout |

Making it public is not free of consequence: this repository names account ids, resource layouts
and SSM paths. None of those are secrets, and none should be load-bearing for security — but
publishing them is a decision, not a shortcut.

## Revisit when

- a second person gets push access to `GoGo-Infra`, or
- the first production deploy is scheduled,

whichever comes first.
