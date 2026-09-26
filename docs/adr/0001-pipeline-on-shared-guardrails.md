# ADR-0001: CI on the shared guardrails, not a bespoke pipeline

- **Status:** accepted
- **Date:** 2026-09-26

## Context

This repo shipped with a bespoke `validate.yml` that ran `terraform fmt` and
`validate` and nothing else. A landing zone that governs an entire AWS
Organization cannot be gated by a formatter. It needs secret scanning, IaC
misconfiguration checks, policy-as-code, a destroy guard over stateful
resources, cost visibility, and a credentialed plan, and it needs the same gates
every other repo in the fleet already runs so a fix in one place lands
everywhere. The constraint that binds: this is one of three parallel landing
zones (AWS, Azure, GCP) that must read identically, maintained by one person, so
duplicated CI is a maintenance cost with no upside.

## Decision

Retire `validate.yml` and call the reusable workflows in
`jordann6/platform-guardrails`: `tf-ci.yml` for the credential-free static gates
(gitleaks full-history, fmt/validate, lockfile assertion, tflint, Checkov,
Trivy, conftest OPA), `tf-plan.yml` for the OIDC-authenticated plan + destroy
guard + cost diff, and `finops-gate.yml` for the CostCenter allocation and cost
threshold. The gated apply, manual destroy, and scheduled TTL guard were added
to `platform-guardrails` as `tf-apply.yml` and `tf-destroy.yml` (released as
`v1.3.0`) rather than built here, so the other two zones inherit them. CI
authenticates only with GitHub OIDC into two roles created by `bootstrap/`: a
read-scoped `gha-plan` and a write-scoped `gha-apply` reachable only from a
reviewer-gated environment. No static keys, and no standing permission to change
the org.

## Alternatives rejected

| Option | Why not |
| ------ | ------- |
| Keep the bespoke `validate.yml` | fmt/validate is not governance; no secret, policy, cost, or destroy gate, and it drifts from the other two zones |
| Build apply/destroy/TTL inside this repo | Three zones would each grow their own copy; the shared repo is the whole point of a fleet toolkit |
| A single all-powerful CI role | A read on a PR could then mint a token that mutates the org; splitting plan (read) from apply (write, environment-gated) is the JIT-to-prod control |
| Native accelerator (Control Tower / LZA) for CI too | LZA brings its own pipeline and opinions; this portfolio deliberately shows the hand-built controls. The bespoke-vs-LZA positioning is its own note (Phase 8) |

## Consequences

The credentialed workflows depend on `platform-guardrails@v1.3.0` and on the
`bootstrap/` roles existing, so they ship inert (placeholder ARNs, no
auto-firing triggers) until those are in place; the static gate is live
immediately. The write path is now bound to a GitHub environment, so an apply
cannot happen without a reviewer, which is deliberate friction. If the shared
workflows ever need a change this repo cannot wait for, that is the signal to
reconsider vendoring them; so far the fleet has not hit that.
