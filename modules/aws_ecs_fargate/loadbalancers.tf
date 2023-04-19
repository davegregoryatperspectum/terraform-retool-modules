resource "aws_lb" "this" {
  name         = "${var.deployment_name}-alb"
  idle_timeout = var.alb_idle_timeout

  security_groups = [aws_security_group.alb.id]
  subnets         = var.alb_subnet_ids
}

resource "aws_lb_listener" "this" {
  load_balancer_arn = aws_lb.this.arn
  port              = var.retool_alb_ingress_port
  protocol          = var.aws_lb_listener_protocol
  ssl_policy        = var.alb_listener_ssl_policy
  certificate_arn   = var.alb_listener_certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.https-sidecar.arn
  }
}

resource "aws_lb_target_group" "https-sidecar" {
  name                 = "${var.deployment_name}-sidecar"
  vpc_id               = var.vpc_id
  deregistration_delay = 30
  port                 = var.https_sidecar_task_container_port
  protocol             = var.aws_alb_target_group_protocol
  target_type          = "ip"


  health_check {
    interval            = 10
    path                = "/api/checkHealth"
    protocol            = var.aws_alb_target_group_protocol
    timeout             = 5
    healthy_threshold   = 3
    unhealthy_threshold = 2
  }

  lifecycle {
    create_before_destroy = true
  }
}