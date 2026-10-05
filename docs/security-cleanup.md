# Separate security cleanup

The landing-zone network and reference workload have been torn down and verified.
LLM gateway integration is cancelled. No gateway deployment, replacement provider
keys, provider admin setup or scanner deployment is required for this cleanup.
Preserve the prepared Phase B source work in the sibling checkouts.

## Retired gateway state history

The explicitly authorized cleanup deleted 20 obsolete versions of the exact
retired gateway Terraform state object. Thirteen of those versions contained
previously preserved credentials. A fresh preview now reports zero obsolete
versions, and the latest clean state version is unchanged. Historical versions are separate from the landing-zone
states; cleanup never targets account, governance, observability or unrelated
state objects.

The existing helper checks bucket versioning, rejects secret material in current
state, filters the exact object key on every page and retains its latest version.
Execution holds the Terraform S3 lock and stops if the current state changes.
Seven safety tests passed, including read-only preview, exact-key deletion,
concurrent-state change, lock contention and dirty-state rejection.

State-history cleanup is complete. Recheck it with this read-only command:

```bash
python3 /Users/jordannelson/Desktop/llm-gateway/scripts/secrets.py prune-history
```

The authorized command below has already completed; it is recorded for audit
and does not need to be repeated:

```bash
python3 /Users/jordannelson/Desktop/llm-gateway/scripts/secrets.py prune-history --execute
```

Post-execution preview and an independent metadata check confirmed zero obsolete
versions and retention of the exact latest clean state.
Keep the latest clean state and backend buckets. Do not apply any old gateway
Terraform plans or recreate secret containers to perform history cleanup.

## Scope and remaining security work

Deleting old state versions does not revoke a credential or remove copies in
local artifacts. The old provider credentials remain preserved privately and
have not been retired by this cleanup. Credential retirement is separate from
landing-zone completion; do not claim it is complete or make it a prerequisite
for recreating an application that has been cancelled.

A scoped local exposure inventory is stored privately under
`~/.config/landing-zone/phaseB-cleanup/`. It excludes dependency/build directories,
git objects, symlinks, large files and unrelated projects. Preserve source changes;
review only obsolete credential-bearing artifacts for deletion, with separate
operator authorization. Never paste credential values into chat or commit them.

The prepared metadata roles and ninety-day scanner monitoring remain unapplied
and unproven live. They are separate future security integration work, not a
required deployment for retiring old state snapshots. No commit, push or merge
was performed during cleanup.
