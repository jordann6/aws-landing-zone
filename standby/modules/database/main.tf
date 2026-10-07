locals {
  is_replica = var.replicate_source_db != null
}

resource "aws_db_instance" "this" {
  #checkov:skip=CKV_AWS_293:Deletion protection is off by design; deploy, prove, destroy.
  #checkov:skip=CKV_AWS_157:Single-AZ standby: the replica is the DR copy, the primary is a demo database.
  #checkov:skip=CKV_AWS_118:Enhanced monitoring adds a role and cost; out of scope for the timed proof.
  #checkov:skip=CKV_AWS_129:RDS log exports create log groups that outlive the instance; skipped to keep teardown clean.
  #checkov:skip=CKV_AWS_353:Performance Insights is out of scope for the proof.
  #checkov:skip=CKV_AWS_133:A cross-region replica cannot carry its own backup retention until it is promoted.
  identifier     = "${var.name_prefix}-postgres"
  instance_class = var.instance_class

  # Engine, storage, and credentials are inherited from the source when this
  # is a cross-region replica, so they must stay unset in that case.
  engine            = local.is_replica ? null : "postgres"
  engine_version    = local.is_replica ? null : var.engine_version
  allocated_storage = local.is_replica ? null : 20
  storage_type      = local.is_replica ? null : "gp3"
  db_name           = local.is_replica ? null : var.db_name
  username          = local.is_replica ? null : var.username
  password          = local.is_replica ? null : var.password

  replicate_source_db = var.replicate_source_db

  # A cross-region replica of an encrypted source must name a key in its own
  # region. Both regions use the multi-region CMK from kms.tf.
  storage_encrypted = true
  kms_key_id        = var.kms_key_arn

  db_subnet_group_name   = var.db_subnet_group_name
  vpc_security_group_ids = [var.security_group_id]
  publicly_accessible    = false
  multi_az               = false

  # The source needs backups enabled for cross-region replication to work.
  backup_retention_period = local.is_replica ? 0 : 1

  # Destroy-safe on purpose: this stack exists to be torn down cleanly.
  skip_final_snapshot        = true
  deletion_protection        = false
  delete_automated_backups   = true
  apply_immediately          = true
  auto_minor_version_upgrade = true
  copy_tags_to_snapshot      = true

  tags = {
    Name = "${var.name_prefix}-postgres"
  }
}
