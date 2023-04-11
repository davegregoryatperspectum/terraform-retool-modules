locals {
  environment_variables = concat(
    var.additional_env_vars,
    [
      { name = "COOKIE_INSECURE", value = var.cookie_insecure },
      { name = "FORCE_DEPLOYMENT", value = tostring(var.force_deployment) },
      { name = "NODE_ENV", value = var.node_env },
      { name = "POSTGRES_DB", value = "hammerhead_production" },
      { name = "POSTGRES_HOST", value = aws_db_instance.this.address },
      { name = "POSTGRES_SSL_ENABLED", value = "true" },
      { name = "POSTGRES_PORT", value = "5432" },
    ]
  )

  db_subnet_group_name = "${var.deployment_name}-subnet-group"
  retool_image         = var.ecs_retool_image

  retool_jwt_secret = {
    password = aws_secretsmanager_secret_version.jwt_secret
  }
  retool_encryption_key_secret = {
    password = random_string.encryption_key.result
  }
  retool_rds_secret = {
    username = "retool"
    password = aws_secretsmanager_secret.rds_password
  }
}
