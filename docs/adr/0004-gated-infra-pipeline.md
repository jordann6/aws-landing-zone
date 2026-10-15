# ADR-0004: A gated CI pipeline for the hourly roots

- **Status:** accepted
- **Date:** 2026-10-15 (proposed and accepted the same day, after the live proof
  below)

## Context

Until now the static half of CI was live on every root (fmt, validate, gitleaks,
Checkov, Trivy, conftest OPA, and an Infracost threshold), but every network,
workload and delivery apply or destroy was run by hand from an operator laptop.
The credentialed plan was commented out, and `apply.yml` and `destroy.yml` were
dispatch-only stubs for the governance root. release-guard already ships an app
pipeline with a verifier, a lock, rollback and an audited override; the
infrastructure underneath it had no equivalent.

The design follows the six-step Terraform pipeline a candidate sketched in a
recorded platform-engineering interview
([video](https://youtu.be/6o5CfeDQkX0), 23:47 to 25:18), used here as a
baseline to meet and exceed. He says at 22:32 that he does not usually build app
pipelines, so it is a starting sketch, not a reference design.

Constraints that bind:

- The hourly stack costs about $1.16 per hour, so nothing may build it by
  accident, and a teardown must prove nothing billable survived.
- The roots assume into member accounts (network 711419314020, prod
  660360494975). The only role there was `OrganizationAccountAccessRole`, which
  is admin, so letting the plan role assume it would make "read-only" admin.
- The callable workflows in platform-guardrails replay a saved plan. Input
  variables and data sources are frozen into that plan, so a provider role chosen
  at plan time is the role the apply replays with.
- The roots had required variables fed from gitignored `phase-c.tfvars.json`
  files, which CI does not have.
- The repository emits immutable OIDC subjects
  (`repo:jordann6@196278615/aws-landing-zone@1285534963:...`). The bootstrap trust
  policies matched the plain `repo:jordann6/aws-landing-zone:...` form, so the CI
  roles could never have been assumed. Nothing noticed because nothing credentialed
  ever ran.
- One maintainer, the same reviewer on every gate.

## Decision

Walk the six steps, with these choices:

| Step (video) | Decision |
| ------------ | -------- |
| 1. Identity, target environments, permissions | Two management roles (`gha-plan`, `gha-apply`, bootstrap/) chain into a matching pair in each member account (bootstrap/member-roles.tf). Member `gha-plan` is `ReadOnlyAccess` minus data-plane reads; member `gha-apply` is `AdministratorAccess` minus long-lived credentials, tampering with the CI and break-glass roles, and leaving the Organization. Each member role trusts exactly one management role. Trust policies use the immutable subject. |
| 2. Runner | GitHub-hosted. No step needs the private EKS API (the roots use only the AWS and TLS providers), the same reasoning as release-guard ADR-0008. |
| 3. Install Terraform, check out | Inside the platform-guardrails callables, SHA-pinned with `guardrails_ref`. |
| 4. init, fmt, plan | fmt and validate on every PR (tf-ci). A credentialed plan on every PR for network, and for workload and delivery when their upstream state is live. |
| 5. Code analysis, secrets | Checkov, Trivy and conftest OPA cover the IaC side; gitleaks is the TruffleHog equivalent. Wiz is a commercial CSPM and is not used. LLM review is out of scope. |
| 6. Apply | On merge to main, in order network, workload, delivery, each behind the `prod-apply` environment. Destroy is dispatch-only, in reverse order, behind `destroy`. |

Supporting decisions:

- **Stage-specific member role through an ephemeral variable.** platform-guardrails
  v1.7.0 exports `TF_VAR_ci_stage` (`plan`, `apply`, `destroy`) in each
  credentialed job. Each root declares `ci_stage` as `ephemeral` (ci.tf), so it is
  not stored in the saved plan, and the gated apply job's own value is the one the
  provider sees when it replays the reviewed plan. Proven locally before adoption:
  a plan made with one role name, applied with another, assumed the apply-time
  name. Unset (an operator's machine), it falls back to
  `OrganizationAccountAccessRole`, so local runs are unchanged.
- **Inputs from upstream state.** Account ids come from the accounts state, the
  Transit Gateway id from the network state, the Organization ARN from the accounts
  state; owner and cost_center take defaults. An explicitly set variable still wins,
  so `phase-c.tfvars.json` keeps working. No guardrails change was needed for this.
- **Desired state as a repo variable.** `HOURLY_STACK_ENABLED` gates the apply
  workflow, so a merge while the stack is down never asks for approval to build it.
- **The EBS encryption default** is owned by the Workloads OU declarative policy
  and protected by an SCP. The workload root now carries a
  `removed { lifecycle { destroy = false } }` block instead of a manual
  `terraform state rm` before every destroy.
- **No `-target` anywhere in CI.** It stays an incident tool for an operator.
- **Proof target:** the full network, workload and delivery stack through CI, not
  a sandbox root, so the write role is shown building EKS, RDS, the firewall and
  the Transit Gateway.

### Beyond the video

1. **Split identities.** He described one pipeline identity. Here the plan
   identity is read-only in every account it touches and is the only one a pull
   request can reach; the write identity exists only inside a reviewer-gated
   environment, and IAM (not the workflow file) enforces that pairing.
2. **The reviewed plan is the applied plan.** tf-apply saves the plan as an
   artifact and the gated job replays that file. The ephemeral stage variable is
   what makes this work across accounts.
3. **Gated destroy with a post-destroy hourly check**, plus an hourly TTL guard
   that alarms while anything billable stands. He never mentioned teardown. The
   TTL guard is a backstop, not the control: see the live proof below.
4. **Cost gate on PRs.** Infracost fails a PR that adds more than $50 a month to a
   root unless it is labelled `cost-approved`.
5. **Second plan must be empty.** After the apply, every root is planned again and
   the run fails if anything would change. That catches a perpetual diff (the
   uppercase-label question at 29:55) on the day it is introduced.

## Live proof (2026-10-15)

The full network, workload and delivery stack was built, replanned and destroyed
through CI, with every gate approved by the reviewer.

| Step | Run | Result |
| ---- | --- | ------ |
| PR plan, network, member read-only role | [38814376834](https://github.com/jordann6/aws-landing-zone/actions/runs/38814376834) | 50 to add, `ci_stage=plan`, guardrails at v1.7.0 |
| First apply on merge | [38816177507](https://github.com/jordann6/aws-landing-zone/actions/runs/38816177507) | Defect 1 (below): every apply skipped, nothing built, failed safe |
| First dispatched apply | [38817053686](https://github.com/jordann6/aws-landing-zone/actions/runs/38817053686) | Defect 2 (below): 47 of 50 network resources created, then `ResourceAlreadyExistsException` |
| PR plan, network and workload | [38818372823](https://github.com/jordann6/aws-landing-zone/actions/runs/38818372823) | network 3 to add; workload 116 to add, Transit Gateway id read from network state |
| Gated apply on merge of #24 | [38819114516](https://github.com/jordann6/aws-landing-zone/actions/runs/38819114516) | network 3 added (18s), workload 116 added (28m00s: EKS 12m56s, RDS 14m27s), delivery 30 added (45s), three replans, **Second plan is empty: passed** |
| Gated destroy | [38823023368](https://github.com/jordann6/aws-landing-zone/actions/runs/38823023368) | delivery 28s, workload 15m05s, network 4m52s; post-destroy hourly check passed on each |
| TTL guard, after teardown | [38825882685](https://github.com/jordann6/aws-landing-zone/actions/runs/38825882685) | network and workload state empty, green |

After the destroy, `terraform state list` was empty for all three roots and the
v1.7.1 hourly guard exited 0 on each. A live sweep of both member accounts found
no VPC, NAT gateway, Elastic IP, Transit Gateway, firewall, endpoint, instance,
volume, EKS cluster, RDS instance, load balancer, backup vault or customer KMS
key, and no `/vpc/` log group in either account. The prod backup vault held 0
recovery points before the destroy, which finished more than five hours ahead of
the 05:00 UTC backup window. The hourly stack billed for about 1 hour 15 minutes.

Two real defects surfaced on the first live runs, and both failed safe:

1. **The setup-terraform wrapper hid `-detailed-exitcode`.** The wrapper (on by
   default) reports exit code 2 as 0, so v1.7.0's `has_changes` was always false
   and every gated apply was skipped. Network planned 50 and applied nothing;
   workload then failed on an empty network state. platform-guardrails v1.7.1
   turns the wrapper off in the plan steps and adds a self-test that asserts codes
   2 and 0 come through (#23 pins it here).
2. **The hub flow-log role re-created its own log group after a destroy.** Flow
   Logs delivery kept writing after that day's manual teardown and, holding
   `logs:CreateLogGroup`, re-created `/vpc/hub-flow` outside Terraform. The next
   apply hit `ResourceAlreadyExistsException` with 47 of 50 resources built. #24
   drops `logs:CreateLogGroup` from the role; the empty stray group was deleted.
   After the CI destroy above, `/vpc/hub-flow` did not reappear.

One assumption did not hold: the TTL guard (cron `17 * * * *`) never fired on
schedule while the stack was up. GitHub delays or drops scheduled runs,
especially for newly added workflows, so an hourly alarm that depends on the
GitHub scheduler is best effort. The gated destroy and its post-destroy check
are the control that protected the spend. An AWS-side backstop (a Budgets action
or an EventBridge schedule in the management account) is the follow-up if the
stack is ever left up unattended.

## Alternatives rejected

| Option | Why not |
| ------ | ------- |
| Let `gha-plan` assume `OrganizationAccountAccessRole` | The read-only plan role becomes admin in both member accounts, reachable from any pull request. |
| One member CI role with permissions decided by the caller | IAM has no condition key that exposes the previous hop of a role chain, and session tags or source identity would have to be set by Terraform config, which is frozen into the plan. |
| Re-plan in the apply job and compare with the reviewed plan | Weaker than replaying the saved file, and a comparison that tolerates unknowns or timestamps invites false passes. |
| A non-ephemeral role variable, or one derived from `aws_caller_identity` | Both are frozen into the saved plan, so the apply would replay with the read-only role and fail. |
| Pass var-files into the callables (platform-guardrails input) | Every caller would need secret-free var plumbing, and the values already live in state. Reading state keeps one source of truth. |
| A small sandbox root as the live proof | About $0, but it proves only that the write role can write a tag. The full stack proves the roles against what this repo actually builds. |
| Self-hosted runners | Nothing needs private network reach, so they add patching and isolation work for no step (release-guard ADR-0008). |

## Consequences

- Terraform 1.10 or later is now required for network, workload and delivery
  (ephemeral variables). CI runs 1.11.3.
- Applying the stack costs a reviewer approval per changed root, and a teardown
  costs three. That friction is the control.
- The release-guard deployment contract is not published by CI: the jobs hold
  management-account credentials and the parameter lives in SSM in the prod
  account. Publishing stays an operator step while release-guard's
  `DELIVERY_ENABLED` is false. Revisit by managing the contract as an
  `aws_ssm_parameter` in the delivery root.
- A role-chained session lasts at most one hour, so an apply or destroy of one
  root must finish inside it. The workload root (EKS, its node group and RDS) is
  the longest: 28 minutes to apply and 15 to destroy in the live proof. Revisit
  if a root ever approaches the limit.
- The workload backup plan runs daily at 05:00 UTC into a Vault Lock vault with a
  7-day minimum retention. A stack still up at that hour gets a recovery point the
  destroy cannot remove, so a CI bring-up and teardown should finish before then.
- The governance root and the persistent roots (accounts/, bootstrap/,
  observability/) stay operator-applied. bootstrap in particular holds the CI
  identities, so CI must never be able to rewrite its own trust.
- Both environments (`prod-apply`, `destroy`) now accept deployments from `main`
  only, on top of the workflows refusing non-main refs and gha-plan trusting only
  main and pull requests. main still has no ruleset requiring the static and plan
  checks; that is the remaining durable version of the control.
