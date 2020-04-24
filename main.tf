# ---------------------------------------------------------------------------------------------------------------------
# PROVIDER
# ---------------------------------------------------------------------------------------------------------------------
provider "aws" {
  profile = var.profile
  region  = var.region
}

# ---------------------------------------------------------------------------------------------------------------------
# APPLICATION LOAD BALANCER
# ---------------------------------------------------------------------------------------------------------------------
resource "aws_lb" "lb" {
  name                             = "${var.name_preffix}-lb"
  internal                         = var.internal
  load_balancer_type               = "application"
  drop_invalid_header_fields       = var.drop_invalid_header_fields
  subnets                          = var.internal ? var.private_subnets : var.public_subnets
  idle_timeout                     = var.idle_timeout
  enable_deletion_protection       = var.enable_deletion_protection
  enable_cross_zone_load_balancing = var.enable_cross_zone_load_balancing
  enable_http2                     = var.enable_http2
  ip_address_type                  = var.ip_address_type
  security_groups    = compact(
    concat(var.security_groups, [aws_security_group.lb_access_sg.id]),
  )
  dynamic "access_logs" {
    for_each = var.access_logs == null ? [] : [var.access_logs]
    content {
      bucket  = access_logs.value.bucket
      prefix  = access_logs.value.prefix
      enabled = access_logs.value.enabled
    }
  }
  tags = {
    Name = "${var.name_preffix}-lb"
  }
}

# ---------------------------------------------------------------------------------------------------------------------
# ACCESS CONTROL TO APPLICATION LOAD BALANCER
# ---------------------------------------------------------------------------------------------------------------------
resource "aws_security_group" "lb_access_sg" {
  name        = "${var.name_preffix}-lb-access-sg"
  description = "Controls access to the Load Balancer"
  vpc_id      = var.vpc_id
  egress {
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = {
    Name = "${var.name_preffix}-lb-access-sg"
  }
}

resource "aws_security_group_rule" "ingress_through_http" {
  count             = var.enable_http ? length(var.http_ports) : 0
  security_group_id = aws_security_group.lb_access_sg.id
  type              = "ingress"
  from_port         = element(var.http_ports, count.index)
  to_port           = element(var.http_ports, count.index)
  protocol          = "tcp"
  cidr_blocks       = var.http_ingress_cidr_blocks
  prefix_list_ids   = var.http_ingress_prefix_list_ids
}

resource "aws_security_group_rule" "ingress_through_https" {
  count             = var.enable_https ? length(var.https_ports) : 0
  security_group_id = aws_security_group.lb_access_sg.id
  type              = "ingress"
  from_port         = element(var.https_ports, count.index)
  to_port           = element(var.https_ports, count.index)
  protocol          = "tcp"
  cidr_blocks       = var.https_ingress_cidr_blocks
  prefix_list_ids   = var.https_ingress_prefix_list_ids
}