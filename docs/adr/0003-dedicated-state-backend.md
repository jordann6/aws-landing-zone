# ADR-0003: Dedicated state backend instead of the shared bucket

- **Status:** accepted
- **Date:** 2026-10-06

## Context

Every root in this repo kept its state in `tf-state-jordprojs`, a bucket created
by hand and shared with six other projects. It was versioned and blocked public
access, but it was not in Terraform, used SSE-S3 rather than a customer-managed
key, had no bucket policy (TLS was not enforced), no lifecycle rule, and nothing
stopped it being deleted. This repo governs an entire AWS Organization: its state
holds every account id, SCP, Identity Center assignment and the CI role ARNs.
The backend for that state should be held to the same standard the landing zone
enforces on everything else, and that standard has to be visible in code. The
keys also still carried the pre-rename name (`aws-scp-governance/`).

## Decision

`bootstrap/state_backend.tf` owns a dedicated bucket
(`jordann6-aws-landing-zone-tfstate`, no account id in the name) and a CMK with
rotation. Every backend block and every `terraform_remote_state` read points at
it, under `aws-landing-zone/` keys, with `kms_key_id` set so no write falls back
to SSE-S3. State is copied with `scripts/migrate-state-backend.sh`, which
compares resource counts per root and never deletes the legacy objects.

## Alternatives rejected

| Option | Why not |
| ------ | ------- |
| Harden `tf-state-jordprojs` in place | Six other projects depend on it. A KMS default, bucket policy or import into this repo's Terraform changes their backend too, and puts their state under this repo's prevent_destroy. |
| Import the shared bucket into this repo | Same blast radius, and this repo would then own a bucket it does not exclusively use. |
| HCP Terraform or another remote backend | Adds a third-party dependency and a second auth path for a single-operator lab; S3 with `use_lockfile` already gives locking. |
| Partial backend config (gitignored `backend.hcl`) | Bucket and alias names are not secrets: the bucket blocks public access, enforces TLS, and needs IAM plus the CMK to read. Hiding them would add a CI secret and break the self-describing roots. |

## Consequences

- Five controls, each in code: `prevent_destroy` on the bucket and key,
  versioning with bounded history (20 noncurrent versions, 90 days), SSE-KMS on
  the CMK with bucket keys, all public access blocks plus a TLS 1.2 bucket policy
  that also refuses SSE-S3 uploads, and `use_lockfile` locking.
- Bootstrap stores its state in the bucket it creates. The first apply runs
  against the legacy bucket through a temporary override, then migrates. A rebuild
  from zero repeats that order.
- About $1/month for the CMK.
- The legacy objects are the rollback only until the first apply on the new
  backend. After that they are stale and must not be used.
- During the cutover the CI roles can reach both buckets. Drop the legacy grant
  (`legacy_state_bucket = ""`) once no open branch points at the old backend.
- Revisit if this account gains a second region worth replicating state into
  (cross-region replication is skipped today with a written reason).
