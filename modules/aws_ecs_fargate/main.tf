terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

resource "aws_ecs_cluster" "this" {
  name = "${var.deployment_name}-ecs"

  setting {
    name  = "containerInsights"
    value = var.ecs_insights_enabled
  }
}

resource "aws_cloudwatch_log_group" "this" {
  name              = "${var.deployment_name}-ecs-log-group"
  retention_in_days = var.log_retention_in_days
}

resource "aws_db_subnet_group" "this" {
  name       = local.db_subnet_group_name
  subnet_ids = var.rds_subnet_ids
}

resource "aws_db_instance" "this" {
  identifier                   = "${var.deployment_name}-rds-instance"
  allocated_storage            = 80
  instance_class               = var.rds_instance_class
  engine                       = "postgres"
  engine_version               = var.rds_postgres_version
  db_name                      = "hammerhead_production"
  username                     = aws_secretsmanager_secret_version.rds_username.secret_string
  password                     = aws_secretsmanager_secret_version.rds_password.secret_string
  port                         = 5432
  publicly_accessible          = var.rds_publicly_accessible
  db_subnet_group_name         = local.db_subnet_group_name
  vpc_security_group_ids       = [aws_security_group.rds.id]
  performance_insights_enabled = var.rds_performance_insights_enabled

  skip_final_snapshot = true
  apply_immediately   = true

  depends_on = [
    aws_db_subnet_group.this
  ]
}

resource "aws_ecs_service" "retool" {
  name                               = "${var.deployment_name}-main-service"
  cluster                            = aws_ecs_cluster.this.id
  task_definition                    = aws_ecs_task_definition.retool.arn
  desired_count                      = var.ecs_service_count
  deployment_maximum_percent         = var.maximum_percent
  deployment_minimum_healthy_percent = var.minimum_healthy_percent
  health_check_grace_period_seconds  = var.alb_health_check_grace_period_seconds
  launch_type                        = "FARGATE"

  load_balancer {
    target_group_arn = aws_lb_target_group.https-sidecar.arn
    container_name   = "https-sidecar"
    container_port   = var.https_sidecar_task_container_port
  }

  network_configuration {
    subnets         = var.ecs_tasks_subnet_ids
    security_groups = [aws_security_group.ecs_tasks.id]
  }
}

resource "aws_ecs_task_definition" "retool" {
  family                   = "${var.deployment_name}-backend"
  requires_compatibilities = ["FARGATE"]
  network_mode             = var.ecs_task_network_mode
  cpu                      = var.ecs_task_cpu
  memory                   = var.ecs_task_memory
  task_role_arn            = aws_iam_role.task_role.arn
  execution_role_arn       = aws_iam_role.execution_role.arn
  container_definitions = jsonencode([
    {
      command = ["./docker_scripts/start_api.sh"],
      environment = toset(concat(
        local.environment_variables,
        [
          { name = "SERVICE_TYPE", value = "MAIN_BACKEND,DB_CONNECTOR" },
        ],
      )),
      secrets = [
        { name = "POSTGRES_USER", valueFrom = aws_secretsmanager_secret.rds_username.arn },
        { name = "POSTGRES_PASSWORD", valueFrom = aws_secretsmanager_secret.rds_password.arn },
        { name = "JWT_SECRET", valueFrom = aws_secretsmanager_secret.jwt_secret.arn },
        { name = "ENCRYPTION_KEY", valueFrom = aws_secretsmanager_secret.encryption_key.arn },
        { name = "LICENSE_KEY", valueFrom = aws_secretsmanager_secret.retool_license_key.arn },
      ],
      logConfiguration = {
        logDriver = var.retool_ecs_tasks_logdriver,
        options = {
          "awslogs-group" : aws_cloudwatch_log_group.this.name,
          "awslogs-region" : var.aws_region,
          "awslogs-stream-prefix" : "${var.retool_ecs_tasks_log_prefix}/backend"
        }
      },
      essential = true,
      image     = local.retool_image,
      name      = var.retool_task_container_name,
      portMappings = [
        {
          containerPort = var.retool_task_container_port
        }
      ],
    },
    {
      environment = [
        { name = "HTTPS_PORT", value = tostring(var.https_sidecar_task_container_port) },
        { name = "TARGET_HOST", value = "localhost" },
        { name = "TARGET_PORT", value = tostring(var.retool_task_container_port) },
      ],
      logConfiguration = {
        logDriver = var.retool_ecs_tasks_logdriver,
        options = {
          "awslogs-group" : aws_cloudwatch_log_group.this.name,
          "awslogs-region" : var.aws_region,
          "awslogs-stream-prefix" : "${var.retool_ecs_tasks_log_prefix}/https-sidecar",
        }
      },
      essential = true,
      image = var.ecs_https_sidecar_image,
      name = "https-sidecar",
      portMappings = [
        {
          containerPort = var.https_sidecar_task_container_port
        }
      ],
    },
  ])
}

resource "aws_ecs_service" "jobs_runner" {
  name            = "${var.deployment_name}-jobs-runner-service"
  cluster         = aws_ecs_cluster.this.id
  desired_count   = 1
  task_definition = aws_ecs_task_definition.retool_jobs_runner.arn
  launch_type     = "FARGATE"

  network_configuration {
    subnets         = var.ecs_tasks_subnet_ids
    security_groups = [aws_security_group.ecs_tasks.id]
  }
}

resource "aws_ecs_task_definition" "retool_jobs_runner" {
  family                   = "${var.deployment_name}-jobs-runner"
  requires_compatibilities = ["FARGATE"]
  network_mode             = var.ecs_task_network_mode
  cpu                      = var.ecs_task_cpu
  memory                   = var.ecs_task_memory
  task_role_arn            = aws_iam_role.task_role.arn
  execution_role_arn       = aws_iam_role.execution_role.arn
  container_definitions = jsonencode([
    {
      command = ["./docker_scripts/start_api.sh"],
      environment = toset(concat(
        local.environment_variables,
        [
          { name = "SERVICE_TYPE", value = "JOBS_RUNNER" },
        ],
      )),
      secrets = [
        { name = "POSTGRES_USER", valueFrom = aws_secretsmanager_secret.rds_username.arn },
        { name = "POSTGRES_PASSWORD", valueFrom = aws_secretsmanager_secret.rds_password.arn },
        { name = "JWT_SECRET", valueFrom = aws_secretsmanager_secret.jwt_secret.arn },
        { name = "ENCRYPTION_KEY", valueFrom = aws_secretsmanager_secret.encryption_key.arn },
        { name = "LICENSE_KEY", valueFrom = aws_secretsmanager_secret.retool_license_key.arn },
      ],
      logConfiguration = {
        logDriver = var.retool_ecs_tasks_logdriver,
        options = {
          "awslogs-group" : aws_cloudwatch_log_group.this.name,
          "awslogs-region" : var.aws_region,
          "awslogs-stream-prefix" : "${var.retool_ecs_tasks_log_prefix}/jobs"
        }
      },
      essential = true,
      image     = local.retool_image,
      name      = var.retool_task_container_name,
      portMappings = [
        {
          containerPort = var.retool_task_container_port
        }
      ]
    }
  ])
}
