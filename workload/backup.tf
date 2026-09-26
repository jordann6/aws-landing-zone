# AWS Backup with Vault Lock (WORM) and a cross-region copy. Vault Lock makes a
# recovery point immutable: within the retention window nobody, not even the
# account root, can delete or shorten it. That is the property that makes a backup
# a defense against ransomware rather than just against hardware failure.

resource "aws_backup_vault" "prod" {
  name        = "prod-data-vault"
  kms_key_arn = aws_kms_key.data.arn
  tags        = { Name = "prod-data-vault" }
}

# changeable_for_days keeps the lock adjustable for a short window so the demo can
# be torn down; production sets it to 0 for immediate, irreversible compliance-mode
# WORM. min_retention is the floor no recovery point can go below.
resource "aws_backup_vault_lock_configuration" "prod" {
  backup_vault_name   = aws_backup_vault.prod.name
  min_retention_days  = var.backup_min_retention_days
  max_retention_days  = var.backup_max_retention_days
  changeable_for_days = var.backup_changeable_after_days
}

resource "aws_backup_vault" "dr" {
  provider    = aws.prod_dr
  name        = "prod-data-vault-dr"
  kms_key_arn = aws_kms_key.data_dr.arn
  tags        = { Name = "prod-data-vault-dr" }
}

data "aws_iam_policy_document" "backup_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["backup.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "backup" {
  name               = "prod-backup"
  assume_role_policy = data.aws_iam_policy_document.backup_assume.json
}

resource "aws_iam_role_policy_attachment" "backup" {
  role       = aws_iam_role.backup.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup"
}

resource "aws_backup_plan" "prod" {
  name = "prod-data"

  rule {
    rule_name         = "daily"
    target_vault_name = aws_backup_vault.prod.name
    schedule          = "cron(0 5 * * ? *)"
    start_window      = 60
    completion_window = 180

    lifecycle {
      delete_after = var.backup_max_retention_days
    }

    # Cross-region copy to the DR vault.
    copy_action {
      destination_vault_arn = aws_backup_vault.dr.arn
      lifecycle {
        delete_after = var.backup_max_retention_days
      }
    }
  }
}

resource "aws_backup_selection" "prod" {
  name         = "prod-rds"
  iam_role_arn = aws_iam_role.backup.arn
  plan_id      = aws_backup_plan.prod.id
  resources    = [aws_db_instance.prod.arn]
}
