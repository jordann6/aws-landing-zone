# Multi-region CMK: the same key material in both regions, so the encrypted
# cross-region replica and the replicated secret decrypt in us-west-2 with no
# re-encryption through a third party. A replica key is its own resource with
# its own policy and its own deletion window.
resource "aws_kms_key" "primary" {
  provider = aws.primary
  #checkov:skip=CKV2_AWS_64:Default key policy (account-root) is sufficient for same-account RDS and Secrets Manager use.
  description             = "Standby data tier multi-region CMK (primary)"
  multi_region            = true
  enable_key_rotation     = true
  deletion_window_in_days = 7
  tags                    = { Name = "${local.name}-data-mrk" }
}

resource "aws_kms_alias" "primary" {
  provider      = aws.primary
  name          = "alias/${local.name}-data"
  target_key_id = aws_kms_key.primary.key_id
}

resource "aws_kms_replica_key" "secondary" {
  provider = aws.secondary
  #checkov:skip=CKV2_AWS_64:Default key policy (account-root) is sufficient for same-account RDS and Secrets Manager use.
  description             = "Standby data tier multi-region CMK (replica)"
  primary_key_arn         = aws_kms_key.primary.arn
  deletion_window_in_days = 7
  tags                    = { Name = "${local.name}-data-mrk-replica" }
}

resource "aws_kms_alias" "secondary" {
  provider      = aws.secondary
  name          = "alias/${local.name}-data"
  target_key_id = aws_kms_replica_key.secondary.key_id
}
