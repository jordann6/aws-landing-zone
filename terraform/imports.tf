# Security Hub was enabled in the security account before this root managed it
# (default standards auto-subscribed), so a create fails with "Account is already
# subscribed". Adopt it instead. The id is the security account id, read from the
# accounts/ state, so no account id is committed. Requires enable_securityhub =
# true; safe to delete once applied.
import {
  to = aws_securityhub_account.security[0]
  id = local.security_account_id
}
