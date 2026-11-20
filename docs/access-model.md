# Human access model

How people get into this org. No human has an IAM user. Every human is a member of
an Identity Center group, and a group is bound to a permission set in a specific
account. Access is therefore a group membership plus a short-lived session, never
a standing key. One exception is the automation identity: Terraform runs from a
workstation as a single management-account IAM user, `terraform-user`, with one
long-lived access key (created 2025-02-13), no console login and no MFA. CI uses
OIDC roles instead. That key is a known gap, tracked for retirement. In production
the groups are synced from an external IdP over
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

## External identity provider (production design)

In this repo the seven persona groups live in Identity Center's built-in identity
store, so the matrix above is real and testable without a second system. In
production the source of truth is the company IdP (Entra ID or Okta). Identity
Center stops owning people and groups and keeps owning only what it should,
which is permission sets and which group gets which set in which account. No
Managed AD or AD Connector is needed for this.

### How it fits together

1. **Sign-in (SAML 2.0).** Identity Center's identity source is set to "External
   identity provider". Entra uses the gallery app "AWS IAM Identity Center"; Okta
   has the equivalent app. Identity Center supplies its ACS URL and issuer, the
   IdP supplies its metadata. MFA, device posture and sign-in risk are enforced
   by the IdP before AWS ever sees the user.
2. **Provisioning (SCIM).** Identity Center's automatic provisioning gives a SCIM
   endpoint and a bearer token, which go into the IdP app. Only users and groups
   assigned to that app are pushed. Entra syncs on a cycle of roughly 40 minutes
   (on demand for a single user), so a joiner or leaver lands in AWS within one
   cycle, and a leaver loses AWS access as soon as the IdP disables them because
   sign-in fails at the IdP regardless of sync.
3. **Authorization (unchanged).** The permission sets, session lengths, boundaries
   and account assignments in `terraform/identity.tf` stay exactly as they are.
   An account assignment binds a permission set to a group id; the only
   difference is that the group now arrives over SCIM instead of being created
   by Terraform.

### Group to permission set mapping

One IdP group per persona, named with a prefix so AWS-bound groups are obvious in
the IdP. The persona and account columns come straight from `identity.tf`.

| IdP group (synced over SCIM) | Identity Center permission set | Session | Accounts |
|---|---|---|---|
| `AWS-LZ-admin` | admin (AdministratorAccess) | 1h | management, prod (JIT) |
| `AWS-LZ-platform-eng` | platform-eng (PowerUserAccess, boundary) | 4h | dev, test |
| `AWS-LZ-junior-eng` | junior-eng (ReadOnlyAccess, boundary) | 4h | dev |
| `AWS-LZ-manager` | manager (ViewOnlyAccess) | 2h | dev, test, prod |
| `AWS-LZ-finops` | finops (Billing) | 2h | management |
| `AWS-LZ-security` | security (SecurityAudit) | 2h | security, dev, test, prod |
| none, see break-glass below | break-glass (AdministratorAccess) | 1h | management (sealed) |

Just-in-time admin moves into the IdP as well. With Entra ID P2, Privileged
Identity Management for Groups makes `AWS-LZ-admin` membership eligible rather
than active, so an engineer activates it for an hour with a reason and an
approval, then Identity Center's own 1-hour session applies on top. Okta's
equivalent is an access request workflow on the group. The demo Azure tenant is
Entra ID Free, which has neither Conditional Access nor PIM, so that part stays
a design.

### Break-glass cannot depend on the IdP

When the identity source is external, Identity Center users from the built-in
store can no longer sign in. A break-glass path that runs through Identity
Center therefore fails in exactly the outage it exists for, an IdP or SAML
failure. Production break-glass sits outside Identity Center: the management
account root user with a hardware MFA key held in a safe, plus one IAM role
whose trust requires that MFA, both alarmed on use by the existing root-activity
EventBridge rule. The `break-glass` permission set here models the sealed,
alarmed, short-session shape of it, not the IdP-independence.

### Cutting over from this repo's identity store

SCIM creates new groups with new group ids; it does not adopt the groups
Terraform made. That is why the IdP groups carry their own `AWS-LZ-` names
instead of reusing `admin`, `platform-eng` and the rest. The cutover is a
replacement of each account assignment's principal, done through the gate.

1. Create the `AWS-LZ-*` groups in the IdP, assign them to the AWS app, and let
   SCIM push them.
2. In `identity.tf`, look the synced groups up with an `aws_identitystore_group`
   data source by display name and point `aws_ssoadmin_account_assignment`
   `principal_id` at them. The plan replaces every assignment (old group out,
   SCIM group in) and changes no permission set. Apply it through the gated
   governance pipeline while the old groups still exist, so nobody loses access
   mid-change.
3. Add `removed` blocks with `lifecycle { destroy = false }` for
   `aws_identitystore_group.persona`, `aws_identitystore_user.operator` and its
   membership, then delete those leftovers by hand once nothing references them.
   The operator becomes an IdP user in `AWS-LZ-admin`.
4. Switch the identity source to the external IdP and sign in once per persona to
   confirm each lands in the right accounts with the right session length.
5. Rotate the SCIM bearer token before it expires (Identity Center tokens are
   valid for one year) and alarm on provisioning errors in the IdP.

## Which CIS control each row satisfies

| Design choice | CIS control |
|---|---|
| No human IAM users, federated groups only (external IdP over SAML + SCIM in production) | 1.10 for humans. 1.12 is not met while the `terraform-user` key exists |
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
