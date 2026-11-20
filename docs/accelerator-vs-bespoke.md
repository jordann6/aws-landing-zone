# Bespoke Terraform vs the AWS accelerator

This zone is built from hand-written Terraform modules rather than AWS Control
Tower or the Landing Zone Accelerator (LZA). That is a deliberate choice, and
this note records the reasoning so it reads as a decision, not an omission.

## What the accelerator would give

AWS Control Tower plus the Landing Zone Accelerator would stand up most of what
is here (an org with guardrails, a log-archive and audit account, CloudTrail,
Config, Security Hub, an Identity Center baseline) from a configuration file,
with AWS maintaining the underlying CloudFormation. For a real organization that
is usually the right call: it is supported, it tracks new AWS best practices
automatically, and it removes a large surface of undifferentiated work.

## Why bespoke here

The purpose of this repo is to demonstrate that I understand the controls, not
that I can fill in an accelerator's config file. Hand-writing the SCPs, the KMS
key policy scoped to the CloudTrail service, the Object-Lock bucket, the
delegated-admin wiring for GuardDuty and Security Hub, and the centralized
inspection routing means every control is visible and explained in code review,
rather than generated behind a managed abstraction. When an interviewer asks why
the region-lockdown SCP exempts `sts` and `cloudfront`, the answer is in
`policies/region-lockdown.json.tftpl`, not inside a black box.

Three concrete reasons the bespoke build fits this context:

1. **Legibility.** Each guardrail is a small, readable resource with a comment
   explaining what it prevents. That is the whole deliverable here.
2. **Cost and teardown control.** The whole zone is deploy/demo/destroy under a
   few dollars, with the hourly inspection layer isolated in its own root so it
   comes up only for its demo. An accelerator is built to stay standing.
3. **Portability of the pattern.** The same shape is built three times (AWS,
   Azure, GCP) from one design document. Writing each by hand makes the parity
   between the three explicit; each cloud's native accelerator would hide it
   behind three different abstractions.

## What production would change

In a real org I would put Control Tower and LZA at the base and keep only the
genuinely custom pieces (bespoke SCPs, the inspection VPC design, the paved-road
workload modules) as additions on top. The bespoke build here is the teaching
version; it is not an argument against the accelerator where the accelerator's
maintenance burden is worth paying.

## Account vending here, and Account Factory in production

Every member account is one entry in `local.accounts` in `accounts/accounts.tf`
(name, OU, gated, enabled). A new account is a one-line pull request. CI plans it
on the PR, and after merge `apply-governance.yml` pauses on the `org-apply`
environment, so a reviewer approves exactly one `aws_organizations_account` before
it exists. The key doubles as the account name and the email alias
(`+<key>@`), so they cannot drift apart. `prevent_destroy` and
`close_on_deletion = false` mean deleting a line cannot close an account; that
takes the Suspended OU and a CloseAccount from the management account.

The 2026-11-20 refactor from one block per account to this map used `moved`
blocks and planned as 8 moves with 0 to add, change or destroy. Turning on the
designed-but-off `cicd` entry plans exactly one new account.

| This repo | Control Tower Account Factory / AFT |
|---|---|
| One map entry in `local.accounts` | One `account_request` module call in the AFT account-request repo |
| PR plan in `guardrails.yml`, gated apply on `org-apply` | AFT's CodePipeline picks up the request; review happens in the PR to that repo |
| OU from the map entry; SCPs inherited from the OU | Managed OU registered in Control Tower; guardrails (controls) inherited |
| Baseline per account comes from separate roots (bootstrap CI roles, governance, StackSets in Step 5) | AFT global and account customizations (Terraform) plus provisioning customizations (Step Functions) run on every new account |
| `OrganizationAccountAccessRole` created by Organizations | `AWSControlTowerExecution` created by Control Tower |
| Account retirement is a manual move to Suspended, then CloseAccount | Same pattern; Control Tower unmanages, then the account is closed |

What production would change is the same answer as above. AFT would own the
request pipeline, account baselining and drift, which removes the map, the
`moved` history and the per-account bootstrap modules from this repo. The
review shape is the one thing worth keeping as is, where a new account is a
diff someone approves before it exists.
