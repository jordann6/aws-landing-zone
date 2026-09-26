# Human access model

How people get into this org. There are no IAM users. Every human is a member of
an Identity Center group, and a group is bound to a permission set in a specific
account. Access is therefore a group membership plus a short-lived session, never
a standing key. In production the groups are synced from an external IdP over
SCIM; here they are created in the built-in identity store (`identity.tf`) so the
matrix below is real.

## Personas (permission sets)

| Persona | Policy | Session | Boundary | Intent |
|---|---|---|---|---|
| admin | AdministratorAccess | 1h | none | Platform owners. Short session so admin is not left open |
| platform-eng | PowerUserAccess | 4h | PowerUserAccess | Senior engineers, capped below admin (no IAM/org changes) |
| junior-eng | ReadOnlyAccess | 4h | PowerUserAccess | Read plus limited compute, hard-capped |
| manager | ViewOnlyAccess | 2h | none | Visibility without change |
| finops | Billing | 2h | none | Cost and billing, no infrastructure |
| security | SecurityAudit | 2h | none | Audit-level read across accounts |
| break-glass | AdministratorAccess | 1h | none | Sealed emergency access, alarmed on use |

## Persona by scope (representative)

The assignment matrix in `identity.tf`. Prod is deliberately sparse: no standing
write. A change to prod is an admin elevation into a 1-hour session, which is the
just-in-time control, backed in CI by the reviewer-gated apply.

| Persona | mgmt | security | dev | test | prod | sandbox |
|---|---|---|---|---|---|---|
| admin | yes | | | | yes (JIT) | |
| platform-eng | | | yes | yes | | |
| junior-eng | | | yes | | | |
| manager | | | yes | yes | yes | |
| finops | yes | | | | | |
| security | | yes | yes | yes | yes | |
| break-glass | yes (sealed) | | | | | |

## Which CIS control each row satisfies

| Design choice | CIS control |
|---|---|
| No IAM users, federated groups only | 1.10, 1.12 (no long-lived user credentials) |
| Permissions boundaries on the engineer personas | 1.16 (no unconstrained `*:*` grant) |
| Short `session_duration`, shortest on admin/break-glass | 1.12 (credentials are not long-lived) |
| No standing prod write; admin is JIT | Least privilege / separation of duties |
| Root blocked in members, alarmed in management | 1.7 (avoid root), 4.x (alarm on root use) |

## Root account hardening

What Terraform enforces: a strict password policy
(`aws_iam_account_password_policy.strict`) and an EventBridge rule on any root
sign-in or API call that publishes to the `security-alerts` SNS topic
(`root-hardening.tf`).

What is a one-time manual action, because no API can perform it, and what the
alarm above exists to keep honest:

1. Enable a hardware MFA device on the management account root.
2. Delete any root access keys.
3. Store the root credentials sealed, used only for the few tasks that require
   root (for example closing the account).

The `deny-root-user` SCP blocks the root user in every member account, so this
manual hardening is only needed on the management account, which is SCP-exempt by
design.
