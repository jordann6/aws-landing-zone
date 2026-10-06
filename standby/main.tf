data "aws_caller_identity" "current" {
  provider = aws.primary
}

# ---------------------------------------------------------------------------
# Shared database credentials, replicated to the standby region so the
# standby app tier keeps working when the primary region is down.
# ---------------------------------------------------------------------------

resource "random_password" "db" {
  length  = 24
  special = false
}

resource "aws_secretsmanager_secret" "db" {
  provider = aws.primary
  #checkov:skip=CKV2_AWS_57:Automatic rotation is out of scope for the DR proof; the credential is generated per deploy and destroyed with it.

  name                           = "${local.name}-db-credentials"
  description                    = "Master credentials for the ${local.name} PostgreSQL instances"
  kms_key_id                     = aws_kms_key.primary.arn
  recovery_window_in_days        = 0
  force_overwrite_replica_secret = true

  replica {
    region     = var.secondary_region
    kms_key_id = aws_kms_replica_key.secondary.arn
  }
}

resource "aws_secretsmanager_secret_version" "db" {
  provider = aws.primary

  secret_id = aws_secretsmanager_secret.db.id
  secret_string = jsonencode({
    username = var.db_username
    password = random_password.db.result
  })
}

# ---------------------------------------------------------------------------
# Networking, one minimal VPC per region. No IGW and no NAT gateway, the
# Lambdas only need RDS plus a Secrets Manager interface endpoint.
# ---------------------------------------------------------------------------

module "network_primary" {
  source = "./modules/network"
  providers = {
    aws = aws.primary
  }

  name_prefix = "${local.name}-primary"
  vpc_cidr    = "10.10.0.0/16"
}

module "network_secondary" {
  source = "./modules/network"
  providers = {
    aws = aws.secondary
  }

  name_prefix = "${local.name}-secondary"
  vpc_cidr    = "10.20.0.0/16"
}

# ---------------------------------------------------------------------------
# Data tier: primary PostgreSQL in the primary region, cross-region read
# replica in the standby region. The failover Lambda promotes the replica.
# ---------------------------------------------------------------------------

module "db_primary" {
  source = "./modules/database"
  providers = {
    aws = aws.primary
  }

  name_prefix          = "${local.name}-primary"
  instance_class       = var.db_instance_class
  db_name              = var.db_name
  username             = var.db_username
  password             = random_password.db.result
  kms_key_arn          = aws_kms_key.primary.arn
  db_subnet_group_name = module.network_primary.db_subnet_group_name
  security_group_id    = module.network_primary.rds_security_group_id
}

module "db_replica" {
  source = "./modules/database"
  providers = {
    aws = aws.secondary
  }

  name_prefix          = "${local.name}-replica"
  instance_class       = var.db_instance_class
  replicate_source_db  = module.db_primary.arn
  kms_key_arn          = aws_kms_replica_key.secondary.arn
  db_subnet_group_name = module.network_secondary.db_subnet_group_name
  security_group_id    = module.network_secondary.rds_security_group_id
}

# ---------------------------------------------------------------------------
# App tier: identical Lambda + HTTP API in both regions. Run
# scripts/package.sh before terraform plan to produce build/api.
# ---------------------------------------------------------------------------

data "archive_file" "api" {
  type        = "zip"
  source_dir  = "${path.module}/build/api"
  output_path = "${path.module}/build/api.zip"
}

data "archive_file" "failover" {
  type        = "zip"
  source_file = "${path.module}/app/failover/handler.py"
  output_path = "${path.module}/build/failover.zip"
}

module "app_primary" {
  source = "./modules/app"
  providers = {
    aws = aws.primary
  }

  name_prefix       = "${local.name}-primary"
  region_role       = "primary"
  lambda_zip        = data.archive_file.api.output_path
  lambda_zip_hash   = data.archive_file.api.output_base64sha256
  db_host           = module.db_primary.address
  db_name           = var.db_name
  db_username       = var.db_username
  secret_arn        = aws_secretsmanager_secret.db.arn
  kms_key_arn       = aws_kms_key.primary.arn
  subnet_ids        = module.network_primary.private_subnet_ids
  security_group_id = module.network_primary.lambda_security_group_id
}

module "app_secondary" {
  source = "./modules/app"
  providers = {
    aws = aws.secondary
  }

  name_prefix       = "${local.name}-secondary"
  region_role       = "secondary"
  lambda_zip        = data.archive_file.api.output_path
  lambda_zip_hash   = data.archive_file.api.output_base64sha256
  db_host           = module.db_replica.address
  db_name           = var.db_name
  db_username       = var.db_username
  secret_arn        = local.secret_arn_secondary
  kms_key_arn       = aws_kms_replica_key.secondary.arn
  subnet_ids        = module.network_secondary.private_subnet_ids
  security_group_id = module.network_secondary.lambda_security_group_id

  depends_on = [aws_secretsmanager_secret.db, aws_kms_replica_key.secondary]
}

# ---------------------------------------------------------------------------
# DNS failover: health-checked PRIMARY record and a SECONDARY record that
# Route 53 serves automatically when the primary health check fails.
# ---------------------------------------------------------------------------

module "dns" {
  source = "./modules/dns"
  providers = {
    aws = aws.primary
  }

  domain_name    = var.domain_name
  primary_fqdn   = module.app_primary.api_domain
  secondary_fqdn = module.app_secondary.api_domain
}

# ---------------------------------------------------------------------------
# Failover manager: CloudWatch alarm on the health check (us-east-1 only)
# feeds EventBridge cross-region into the standby region, where a Lambda
# promotes the read replica and notifies via SNS.
# ---------------------------------------------------------------------------

module "failover" {
  source = "./modules/failover"
  providers = {
    aws.primary   = aws.primary
    aws.secondary = aws.secondary
  }

  name_prefix        = local.name
  account_id         = data.aws_caller_identity.current.account_id
  secondary_region   = var.secondary_region
  health_check_id    = module.dns.primary_health_check_id
  replica_identifier = module.db_replica.identifier
  replica_arn        = module.db_replica.arn
  lambda_zip         = data.archive_file.failover.output_path
  lambda_zip_hash    = data.archive_file.failover.output_base64sha256
  notification_email = var.notification_email
}
