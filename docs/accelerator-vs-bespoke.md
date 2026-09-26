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
