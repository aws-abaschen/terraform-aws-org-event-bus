data "aws_region" "current" {}

locals {
  region = data.aws_region.current.region

  # IAM tags that carry the hierarchy path.
  hierarchy_tags = { for l in var.hierarchy : "${var.tag_key_prefix}${l}" => var.path[l] }

  # The only source this service may publish.
  event_source = join(var.separator, [for l in var.hierarchy : var.path[l]])

  queue_arns = [for q in aws_sqs_queue.this : q.arn]
}

# --- Network -----------------------------------------------------------------

data "aws_vpc" "this" {
  count = var.create_endpoints ? 1 : 0
  id    = var.vpc_id
}

resource "aws_security_group" "endpoints" {
  count = var.create_endpoints ? 1 : 0

  name_prefix = "${var.name}-event-endpoints-"
  description = "HTTPS from the workload VPC to the EventBridge and SQS endpoints"
  vpc_id      = var.vpc_id
  tags        = var.tags

  lifecycle {
    create_before_destroy = true

    precondition {
      condition     = var.vpc_id != null && length(var.subnet_ids) > 0
      error_message = "vpc_id and subnet_ids are required when create_endpoints is true."
    }
  }
}

resource "aws_vpc_security_group_ingress_rule" "endpoints" {
  for_each = var.create_endpoints ? toset(coalesce(var.endpoint_ingress_cidr_blocks, [data.aws_vpc.this[0].cidr_block])) : toset([])

  security_group_id = aws_security_group.endpoints[0].id
  description       = "HTTPS"
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

# A Classic bus is served by the `events` endpoint service.
resource "aws_vpc_endpoint" "events" {
  count = var.create_endpoints ? 1 : 0

  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.${local.region}.events"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = var.subnet_ids
  security_group_ids  = [aws_security_group.endpoints[0].id]
  private_dns_enabled = true
  tags                = merge(var.tags, { Name = "${var.name}-events" })

  # Third gate next to the identity policy and the bus policy: nothing in
  # this VPC can reach a bus other than the central one, and only as a
  # principal of the organization.
  policy = var.enable_endpoint_policy ? jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "CentralBusOnly"
      Effect    = "Allow"
      Principal = "*"
      Action    = var.endpoint_allowed_actions
      Resource  = var.bus_arn
      Condition = {
        StringEquals = { "aws:PrincipalOrgID" = var.organization_id }
      }
    }]
  }) : null
}

resource "aws_vpc_endpoint" "sqs" {
  count = var.create_endpoints && var.create_sqs_endpoint ? 1 : 0

  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.${local.region}.sqs"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = var.subnet_ids
  security_group_ids  = [aws_security_group.endpoints[0].id]
  private_dns_enabled = true
  tags                = merge(var.tags, { Name = "${var.name}-sqs" })
}

# --- Workload role -----------------------------------------------------------

resource "aws_iam_role" "workload" {
  count = var.create_role ? 1 : 0

  name                 = var.name
  assume_role_policy   = var.assume_role_policy
  permissions_boundary = var.permissions_boundary
  tags                 = merge(var.tags, local.hierarchy_tags)

  lifecycle {
    precondition {
      condition     = var.assume_role_policy != null
      error_message = "assume_role_policy is required when create_role is true."
    }
  }
}

resource "aws_iam_role_policy" "workload" {
  count = var.create_role && (var.publish || length(var.queues) > 0) ? 1 : 0

  name = "event-bus"
  role = aws_iam_role.workload[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        for s in [{
          Sid      = "PublishOwnSourceToCentralBus"
          Effect   = "Allow"
          Action   = "events:PutEvents"
          Resource = var.bus_arn
          # The bus policy enforces the same rule from the role tags. Stating
          # it here too keeps a mis-tagged role from publishing at all.
          Condition = {
            StringEquals = { "events:source" = local.event_source }
          }
        }] : s if var.publish
      ],
      [
        for s in [{
          Sid      = "DescribeCentralBus"
          Effect   = "Allow"
          Action   = "events:DescribeEventBus"
          Resource = var.bus_arn
        }] : s if var.publish
      ],
      [
        for s in [{
          Sid    = "ConsumeQueues"
          Effect = "Allow"
          Action = [
            "sqs:ReceiveMessage",
            "sqs:DeleteMessage",
            "sqs:ChangeMessageVisibility",
            "sqs:GetQueueAttributes",
            "sqs:GetQueueUrl",
          ]
          Resource = local.queue_arns
        }] : s if length(var.queues) > 0
      ],
    )
  })
}

# --- Queues ------------------------------------------------------------------

resource "aws_sqs_queue" "this" {
  for_each = var.queues

  name                       = "${var.name}-${each.key}"
  visibility_timeout_seconds = each.value.visibility_timeout_seconds
  message_retention_seconds  = each.value.message_retention_seconds
  sqs_managed_sse_enabled    = true
  tags                       = var.tags

  lifecycle {
    precondition {
      condition     = var.delivery_role_arn != null
      error_message = "delivery_role_arn is required when queues is not empty."
    }
  }
}

# The rule and its target live in the bus account. EventBridge sends with the
# central delivery role, which this policy admits by ARN.
resource "aws_sqs_queue_policy" "this" {
  for_each = var.queues

  queue_url = aws_sqs_queue.this[each.key].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "CentralBusDelivery"
      Effect    = "Allow"
      Principal = { AWS = var.delivery_role_arn }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.this[each.key].arn
    }]
  })
}
