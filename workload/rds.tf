# Small managed PostgreSQL, Multi-AZ, proven on a timed run. Multi-AZ gives the
# active-passive failover the design calls for: a synchronous standby in the
# second AZ that AWS promotes on failure. make test forces that promotion and
# checks the AZ flips.
#
# No password lives in Terraform state: manage_master_user_password hands
# credential generation and rotation to RDS via Secrets Manager, rooted in the
# data CMK. That is the sanctioned secrets path from the design.

resource "aws_db_subnet_group" "data" {
  count      = var.enable_rds ? 1 : 0
  name       = "prod-data"
  subnet_ids = local.data_subnet_ids
  tags       = { Name = "prod-data" }
}

resource "aws_db_instance" "prod" {
  count = var.enable_rds ? 1 : 0
  #checkov:skip=CKV_AWS_293:Deletion protection is off by design; the deploy/demo/destroy posture requires teardown.
  #checkov:skip=CKV_AWS_118:Enhanced monitoring adds a role and cost; out of scope for the timed demo.
  #checkov:skip=CKV2_AWS_30:Full query logging is a production parameter-group setting; log exports are enabled below.
  identifier     = "prod-postgres"
  engine         = "postgres"
  engine_version = var.db_engine_version
  instance_class = var.db_instance_class

  allocated_storage = 20
  storage_type      = "gp3"
  storage_encrypted = true
  kms_key_id        = aws_kms_key.data[0].arn

  db_name  = "app"
  username = "appadmin"

  # RDS-managed master credential in Secrets Manager, encrypted with the CMK.
  manage_master_user_password   = true
  master_user_secret_kms_key_id = aws_kms_key.data[0].key_id

  multi_az               = true
  db_subnet_group_name   = aws_db_subnet_group.data[0].name
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = false

  backup_retention_period    = 7
  auto_minor_version_upgrade = true
  deletion_protection        = false # deploy/demo/destroy posture
  skip_final_snapshot        = true
  copy_tags_to_snapshot      = true

  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]

  performance_insights_enabled    = true
  performance_insights_kms_key_id = aws_kms_key.data[0].arn

  # Belt and braces: an encrypted, private, IAM-auth-capable instance.
  iam_database_authentication_enabled = true

  tags = { Name = "prod-postgres" }
}
