# AWS Backup with Vault Lock (WORM) and an opt-in cross-region copy. Vault Lock makes a
# recovery point immutable: within the retention window nobody, not even the
# account root, can delete or shorten it. That is the property that makes a backup
# a defense against ransomware rather than just against hardware failure.

resource "aws_backup_vault" "prod" {
  count       = var.enable_rds ? 1 : 0
  name        = "prod-data-vault"
  kms_key_arn = aws_kms_key.data[0].arn
  tags        = { Name = "prod-data-vault" }
}

# changeable_for_days keeps the lock adjustable for a short window so the demo can
# be torn down; production keeps the lock past its grace period for compliance-mode
# WORM. min_retention is the floor no recovery point can go below.
resource "aws_backup_vault_lock_configuration" "prod" {
  count               = var.enable_rds ? 1 : 0
  backup_vault_name   = aws_backup_vault.prod[0].name
  min_retention_days  = var.backup_min_retention_days
  max_retention_days  = var.backup_max_retention_days
  changeable_for_days = var.backup_changeable_after_days
}

resource "aws_backup_vault" "dr" {
  count       = var.enable_rds && var.enable_cross_region_backup ? 1 : 0
  provider    = aws.prod_dr
  name        = "prod-data-vault-dr"
  kms_key_arn = aws_kms_key.data_dr[0].arn
  tags        = { Name = "prod-data-vault-dr" }
}

data "aws_iam_policy_document" "backup_assume" {
  count = var.enable_rds ? 1 : 0
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["backup.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "backup" {
  count              = var.enable_rds ? 1 : 0
  name               = "prod-backup"
  assume_role_policy = data.aws_iam_policy_document.backup_assume[0].json
}

resource "aws_iam_role_policy_attachment" "backup" {
  count      = var.enable_rds ? 1 : 0
  role       = aws_iam_role.backup[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup"
}

resource "aws_backup_plan" "prod" {
  count = var.enable_rds ? 1 : 0
  name  = "prod-data"

  rule {
    rule_name         = "daily"
    target_vault_name = aws_backup_vault.prod[0].name
    schedule          = "cron(0 5 * * ? *)"
    start_window      = 60
    completion_window = 180

    lifecycle {
      delete_after = var.backup_max_retention_days
    }

    # Cross-region copy requires prior approval of the destination region.
    dynamic "copy_action" {
      for_each = var.enable_cross_region_backup ? [1] : []
      content {
        destination_vault_arn = aws_backup_vault.dr[0].arn
        lifecycle {
          delete_after = var.backup_max_retention_days
        }
      }
    }
  }
}

resource "aws_backup_selection" "prod" {
  count        = var.enable_rds ? 1 : 0
  name         = "prod-rds"
  iam_role_arn = aws_iam_role.backup[0].arn
  plan_id      = aws_backup_plan.prod[0].id
  resources    = [aws_db_instance.prod[0].arn]
}
