#------------------------------------------------------------------------------
# S3 BUCKET - For access logs
#------------------------------------------------------------------------------
data "aws_elb_service_account" "default" {}

module "lb_logs_s3" {
  # If we enable S3 Logs for the ALB, but don't provide our own bucket, create one as part of this module
  count = var.enable_s3_logs && var.log_bucket_id == null ? 1 : 0

  source  = "cn-terraform/logs-s3-bucket/aws"
  version = "1.0.6"

  name_prefix                                    = "${var.name_prefix}-lb"
  aws_principals_identifiers                     = [data.aws_elb_service_account.default.arn]
  block_s3_bucket_public_access                  = var.block_s3_bucket_public_access
  enable_s3_bucket_server_side_encryption        = var.enable_s3_bucket_server_side_encryption
  s3_bucket_server_side_encryption_sse_algorithm = var.s3_bucket_server_side_encryption_sse_algorithm
  s3_bucket_server_side_encryption_key           = var.s3_bucket_server_side_encryption_key

  tags = var.tags
}

#------------------------------------------------------------------------------
# APPLICATION LOAD BALANCER
#------------------------------------------------------------------------------
resource "random_string" "lb_name" {
  count   = var.use_random_name_for_lb ? 1 : 0
  length  = 32
  numeric = true
  special = false
}

resource "aws_lb" "lb" {
  name = var.use_random_name_for_lb ? random_string.lb_name[0].result : substr("${var.name_prefix}-lb", 0, 31)

  internal                         = var.internal
  load_balancer_type               = "application"
  drop_invalid_header_fields       = var.drop_invalid_header_fields
  subnets                          = var.internal ? var.private_subnets : var.public_subnets
  idle_timeout                     = var.idle_timeout
  enable_deletion_protection       = var.enable_deletion_protection
  enable_cross_zone_load_balancing = var.enable_cross_zone_load_balancing
  enable_http2                     = var.enable_http2
  ip_address_type                  = var.ip_address_type
  security_groups = compact(
    concat(var.security_groups, [aws_security_group.lb_access_sg.id]),
  )

  dynamic "access_logs" {
    for_each = var.enable_s3_logs ? [1] : []
    content {
      bucket  = var.log_bucket_id == null ? module.lb_logs_s3[0].s3_bucket_id : var.log_bucket_id
      enabled = var.enable_s3_logs
      prefix  = var.access_logs_prefix
    }
  }

  tags = merge(
    var.tags,
    {
      Name = "${var.name_prefix}-lb"
    },
  )
}

resource "aws_wafv2_web_acl_association" "waf_association" {
  count        = var.waf_web_acl_arn != "" ? 1 : 0
  resource_arn = aws_lb.lb.arn
  web_acl_arn  = var.waf_web_acl_arn
}

#------------------------------------------------------------------------------
# ACCESS CONTROL TO APPLICATION LOAD BALANCER
#------------------------------------------------------------------------------
resource "aws_security_group" "lb_access_sg" {
  name        = "${var.name_prefix}-lb-access-sg"
  description = "Controls access to the Load Balancer"
  vpc_id      = var.vpc_id
  egress {
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = merge(
    var.tags,
    {
      Name = "${var.name_prefix}-lb-access-sg"
    },
  )
}

resource "aws_security_group_rule" "ingress_through_http" {
  for_each          = var.http_ports
  security_group_id = aws_security_group.lb_access_sg.id
  type              = "ingress"
  from_port         = each.value.listener_port
  to_port           = each.value.listener_port
  protocol          = "tcp"
  cidr_blocks       = var.http_ingress_cidr_blocks
  prefix_list_ids   = var.http_ingress_prefix_list_ids
}

resource "aws_security_group_rule" "ingress_through_https" {
  for_each          = var.https_ports
  security_group_id = aws_security_group.lb_access_sg.id
  type              = "ingress"
  from_port         = each.value.listener_port
  to_port           = each.value.listener_port
  protocol          = "tcp"
  cidr_blocks       = var.https_ingress_cidr_blocks
  prefix_list_ids   = var.https_ingress_prefix_list_ids
}

#------------------------------------------------------------------------------
# AWS LOAD BALANCER - Target Groups
#------------------------------------------------------------------------------
resource "aws_lb_target_group" "lb_http_tgs" {
  for_each = {
    for name, config in var.http_ports : name => config
    if lookup(config, "type", "") == "" || lookup(config, "type", "") == "forward"
  }
  name                          = "${var.name_prefix}-${each.key}-http-${each.value.target_group_port}"
  port                          = each.value.target_group_port
  protocol                      = lookup(each.value, "target_group_protocol", "HTTP")
  vpc_id                        = var.vpc_id
  deregistration_delay          = var.deregistration_delay
  slow_start                    = var.slow_start
  load_balancing_algorithm_type = var.load_balancing_algorithm_type
  dynamic "stickiness" {
    for_each = var.stickiness == null ? [] : [var.stickiness]
    content {
      type            = stickiness.value.type
      cookie_duration = stickiness.value.cookie_duration
      enabled         = stickiness.value.enabled
    }
  }
  health_check {
    enabled             = var.target_group_health_check_enabled
    interval            = var.target_group_health_check_interval
    path                = var.target_group_health_check_path
    protocol            = lookup(each.value, "target_group_protocol", "HTTP")
    timeout             = var.target_group_health_check_timeout
    healthy_threshold   = var.target_group_health_check_healthy_threshold
    unhealthy_threshold = var.target_group_health_check_unhealthy_threshold
    matcher             = var.target_group_health_check_matcher
  }
  target_type = "ip"
  tags = merge(
    var.tags,
    {
      Name = "${var.name_prefix}-${each.key}-http-${each.value.target_group_port}"
    },
  )
  lifecycle {
    create_before_destroy = true
  }
  depends_on = [aws_lb.lb]
}

resource "aws_lb_target_group" "lb_https_tgs" {
  for_each = {
    for name, config in var.https_ports : name => config
    if lookup(config, "type", "") == "" || lookup(config, "type", "") == "forward"
  }
  name                          = "${var.name_prefix}-${each.key}-https-${each.value.target_group_port}"
  port                          = each.value.target_group_port
  protocol                      = lookup(each.value, "target_group_protocol", "HTTPS")
  vpc_id                        = var.vpc_id
  deregistration_delay          = var.deregistration_delay
  slow_start                    = var.slow_start
  load_balancing_algorithm_type = var.load_balancing_algorithm_type
  dynamic "stickiness" {
    for_each = var.stickiness == null ? [] : [var.stickiness]
    content {
      type            = stickiness.value.type
      cookie_duration = stickiness.value.cookie_duration
      enabled         = stickiness.value.enabled
    }
  }
  health_check {
    enabled             = var.target_group_health_check_enabled
    interval            = var.target_group_health_check_interval
    path                = var.target_group_health_check_path
    protocol            = lookup(each.value, "target_group_protocol", "HTTPS")
    timeout             = var.target_group_health_check_timeout
    healthy_threshold   = var.target_group_health_check_healthy_threshold
    unhealthy_threshold = var.target_group_health_check_unhealthy_threshold
    matcher             = var.target_group_health_check_matcher
  }
  target_type = "ip"
  tags = merge(
    var.tags,
    {
      Name = "${var.name_prefix}-${each.key}-https-${each.value.target_group_port}"
    },
  )
  lifecycle {
    create_before_destroy = true
  }
  depends_on = [aws_lb.lb]
}

#------------------------------------------------------------------------------
# AWS LOAD BALANCER - Listeners
#------------------------------------------------------------------------------
resource "aws_lb_listener" "lb_http_listeners" {
  for_each          = var.http_ports
  load_balancer_arn = aws_lb.lb.arn
  port              = each.value.listener_port
  protocol          = "HTTP"

  dynamic "default_action" {
    for_each = lookup(each.value, "type", "") == "redirect" ? [1] : []
    content {
      type = "redirect"

      redirect {
        host        = lookup(each.value, "host", "#{host}")
        path        = lookup(each.value, "path", "/#{path}")
        port        = lookup(each.value, "port", "#{port}")
        protocol    = lookup(each.value, "protocol", "#{protocol}")
        query       = lookup(each.value, "query", "#{query}")
        status_code = lookup(each.value, "status_code", "HTTP_301")
      }
    }
  }

  dynamic "default_action" {
    for_each = lookup(each.value, "type", "") == "fixed-response" ? [1] : []
    content {
      type = "fixed-response"

      fixed_response {
        content_type = lookup(each.value, "content_type", "text/plain")
        message_body = lookup(each.value, "message_body", "Fixed response content")
        status_code  = lookup(each.value, "status_code", "200")
      }
    }
  }

  # We fallback to using forward type action if type is not defined
  dynamic "default_action" {
    for_each = (lookup(each.value, "type", "") == "" || lookup(each.value, "type", "") == "forward") ? [1] : []
    content {
      target_group_arn = aws_lb_target_group.lb_http_tgs[each.key].arn
      type             = "forward"
    }
  }

  dynamic "lifecycle" {
    for_each = (lookup(each.value, "type", "") == "" || lookup(each.value, "type", "") == "forward") ? [1] : []
    replace_triggered_by {
      target_group_id = aws_lb_target_group.lb_http_tgs[each.key].id
    }
  }

  tags = var.tags
}

resource "aws_lb_listener" "lb_https_listeners" {
  for_each          = var.https_ports
  load_balancer_arn = aws_lb.lb.arn
  port              = each.value.listener_port
  protocol          = "HTTPS"
  ssl_policy        = var.ssl_policy
  certificate_arn   = var.default_certificate_arn

  dynamic "default_action" {
    for_each = lookup(each.value, "type", "") == "redirect" ? [1] : []
    content {
      type = "redirect"

      redirect {
        host        = lookup(each.value, "host", "#{host}")
        path        = lookup(each.value, "path", "/#{path}")
        port        = lookup(each.value, "port", "#{port}")
        protocol    = lookup(each.value, "protocol", "#{protocol}")
        query       = lookup(each.value, "query", "#{query}")
        status_code = lookup(each.value, "status_code", "HTTP_301")
      }
    }
  }

  dynamic "default_action" {
    for_each = lookup(each.value, "type", "") == "fixed-response" ? [1] : []
    content {
      type = "fixed-response"

      fixed_response {
        content_type = lookup(each.value, "content_type", "text/plain")
        message_body = lookup(each.value, "message_body", "Fixed response content")
        status_code  = lookup(each.value, "status_code", "200")
      }
    }
  }

  # We fallback to using forward type action if type is not defined
  dynamic "default_action" {
    for_each = (lookup(each.value, "type", "") == "" || lookup(each.value, "type", "") == "forward") ? [1] : []
    content {
      target_group_arn = aws_lb_target_group.lb_https_tgs[each.key].arn
      type             = "forward"
    }
  }

  dynamic "lifecycle" {
    for_each = (lookup(each.value, "type", "") == "" || lookup(each.value, "type", "") == "forward") ? [1] : []
    replace_triggered_by {
      target_group_id = aws_lb_target_group.lb_https_tgs[each.key].id
    }
  }

  tags = var.tags
}

locals {
  list_maps_listener_certificate_arns = flatten([
    for cert_arn in var.additional_certificates_arn_for_https_listeners : [
      for index, listener in aws_lb_listener.lb_https_listeners : {
        name            = "listener-${index}-${listener.protocol}-${listener.port}"
        listener_arn    = listener.arn
        certificate_arn = cert_arn
      }
    ]
  ])

  map_listener_certificate_arns = {
    for obj in local.list_maps_listener_certificate_arns : obj.name => {
      listener_arn    = obj.listener_arn,
      certificate_arn = obj.certificate_arn
    }
  }
}

resource "aws_lb_listener_certificate" "additional_certificates_for_https_listeners" {
  for_each        = local.map_listener_certificate_arns
  listener_arn    = each.value.listener_arn
  certificate_arn = each.value.certificate_arn
}
