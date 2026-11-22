# Aurora PostgreSQL Serverless v2 — writer + 2 readers, one per AZ.
# Storage is replicated 6 ways across 3 AZs by design; compute failover to a
# reader takes ~30 s. Isolated data subnets: no route out of the VPC at all.

data "aws_rds_engine_version" "pg" {
  engine                 = "aurora-postgresql"
  parameter_group_family = "aurora-postgresql${var.aurora_major_version}"
  latest                 = true # newest minor of the major version
}

resource "aws_db_subnet_group" "this" {
  name       = "${local.n}-data"
  subnet_ids = local.subnet_ids["data"]
}

resource "aws_rds_cluster_parameter_group" "this" {
  name   = "${local.n}-pg${var.aurora_major_version}"
  family = "aurora-postgresql${var.aurora_major_version}"
  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }
  parameter {
    name  = "ssl_min_protocol_version" # TLS 1.3 end to end, including the database hop
    value = "TLSv1.3"
  }
  parameter {
    name  = "log_min_duration_statement"
    value = "500"
  }
  parameter {
    name  = "idle_in_transaction_session_timeout"
    value = "30000"
  }
}

resource "aws_rds_cluster" "this" {
  cluster_identifier                  = "${local.n}-${var.environment}"
  engine                              = "aurora-postgresql"
  engine_mode                         = "provisioned"
  engine_version                      = data.aws_rds_engine_version.pg.version
  database_name                       = "soge"
  master_username                     = "sogeadmin"
  manage_master_user_password         = true # generated + rotated by RDS, never in tfstate
  master_user_secret_kms_key_id       = aws_kms_key.this["secrets"].arn
  iam_database_authentication_enabled = true # the app authenticates with short-lived IAM tokens
  db_subnet_group_name                = aws_db_subnet_group.this.name
  vpc_security_group_ids              = [local.sg["db"]]
  db_cluster_parameter_group_name     = aws_rds_cluster_parameter_group.this.name
  storage_encrypted                   = true
  kms_key_id                          = aws_kms_key.this["data"].arn
  backup_retention_period             = 14
  preferred_backup_window             = "01:00-02:00"
  preferred_maintenance_window        = "sun:03:00-sun:04:00"
  copy_tags_to_snapshot               = true
  deletion_protection                 = var.deletion_protection
  skip_final_snapshot                 = !var.deletion_protection
  final_snapshot_identifier           = var.deletion_protection ? "${local.n}-${var.environment}-final" : null
  enabled_cloudwatch_logs_exports     = ["postgresql"]
  availability_zones                  = local.azs

  serverlessv2_scaling_configuration {
    min_capacity = var.aurora_min_acu
    max_capacity = var.aurora_max_acu
  }
  lifecycle { ignore_changes = [availability_zones, engine_version] }
}

resource "aws_rds_cluster_instance" "this" {
  count                                 = var.aurora_instance_count # writer + readers, one per AZ
  identifier                            = "${local.n}-${var.environment}-${count.index}"
  cluster_identifier                    = aws_rds_cluster.this.id
  instance_class                        = "db.serverless"
  engine                                = aws_rds_cluster.this.engine
  engine_version                        = aws_rds_cluster.this.engine_version
  availability_zone                     = local.azs[count.index]
  promotion_tier                        = count.index # deterministic failover order
  publicly_accessible                   = false
  auto_minor_version_upgrade            = true
  performance_insights_enabled          = true
  performance_insights_kms_key_id       = aws_kms_key.this["data"].arn
  performance_insights_retention_period = 7
  ca_cert_identifier                    = "rds-ca-ecc384-g1" # ECC CA; RDS rotates the server certificate automatically
}

# ---------------------------------------------------------- rates snapshot bucket
resource "aws_s3_bucket" "rates" {
  bucket_prefix = "${local.n}-r-"
  force_destroy = !var.deletion_protection
}

resource "aws_s3_bucket_public_access_block" "rates" {
  bucket                  = aws_s3_bucket.rates.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "rates" {
  bucket = aws_s3_bucket.rates.id
  rule { object_ownership = "BucketOwnerEnforced" }
}

resource "aws_s3_bucket_versioning" "rates" {
  bucket = aws_s3_bucket.rates.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "rates" {
  bucket = aws_s3_bucket.rates.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.this["rates"].arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_policy" "rates" {
  bucket = aws_s3_bucket.rates.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Deny statements: Principal "*" means "whoever calls", it grants nothing.
        Sid       = "TLSOnly"
        Effect    = "Deny"
        Principal = "*"
        Action    = ["s3:GetObject", "s3:PutObject", "s3:ListBucket", "s3:DeleteObject"]
        Resource  = [aws_s3_bucket.rates.arn, "${aws_s3_bucket.rates.arn}/rates/latest.json"]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      },
      {
        Sid       = "ReadOnlyThroughOurVpcEndpoint"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:GetObject"
        Resource  = "${aws_s3_bucket.rates.arn}/*"
        Condition = { StringNotEquals = { "aws:SourceVpce" = aws_vpc_endpoint.s3.id } }
      },
      {
        Sid       = "WriteOnlyByRatesSync"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.rates.arn}/*"
        Condition = { StringNotEquals = { "aws:PrincipalArn" = aws_iam_role.fn["rates_sync"].arn } }
      },
    ]
  })
}
