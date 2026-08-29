# ADR 0002 — The approval gate does not exist on this plan

**Status:** accepted, with a review trigger
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
