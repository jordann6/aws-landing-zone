# Security Hub was enabled in the security account before this root managed it
# (default standards auto-subscribed), so a create fails with "Account is already
# subscribed". Adopt it instead. The id is the security account id, read from the
# accounts/ state, so no account id is committed. Requires enable_securityhub =
# true; safe to delete once applied.
import {
  to = aws_securityhub_account.security[0]
  id = local.security_account_id
}

# The Firewall Manager admin association. The first gated apply (run
# 44813975517, 2026-11-20) got InvalidOperationException from AssociateAdminAccount,
# most likely because FMS trusted access and its service-linked role had been
# created moments before. A retry by hand a few minutes later succeeded
# (RoleStatus READY), so this adopts that association instead of re-creating it.
import {
  to = aws_fms_admin_account.security
  id = local.security_account_id
}
