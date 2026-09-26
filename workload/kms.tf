# CMK for the data tier: RDS storage encryption and the backup vault. Rotation on.
# The same key family protects the live data and its backups, so one key controls
# access to both.
resource "aws_kms_key" "data" {
  #checkov:skip=CKV2_AWS_64:Default key policy (account-root) is sufficient for same-account RDS/backup service use.
  description             = "Prod data tier CMK (RDS + backup)"
  enable_key_rotation     = true
  deletion_window_in_days = 7
  tags                    = { Name = "prod-data-cmk" }
}

resource "aws_kms_alias" "data" {
  name          = "alias/prod-data"
  target_key_id = aws_kms_key.data.key_id
}

# Replica key in the DR region for the cross-region backup copy, which cannot use
# a key from another region.
resource "aws_kms_key" "data_dr" {
  #checkov:skip=CKV2_AWS_64:Default key policy (account-root) is sufficient for same-account backup use.
  provider                = aws.prod_dr
  description             = "Prod data tier CMK (DR region backup copies)"
  enable_key_rotation     = true
  deletion_window_in_days = 7
  tags                    = { Name = "prod-data-cmk-dr" }
}

resource "aws_kms_alias" "data_dr" {
  provider      = aws.prod_dr
  name          = "alias/prod-data-dr"
  target_key_id = aws_kms_key.data_dr.key_id
}
