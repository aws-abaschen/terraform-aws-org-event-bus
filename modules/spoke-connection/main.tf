data "aws_region" "current" {}
data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}

locals {
  region    = data.aws_region.current.region
  partition = data.aws_partition.current.partition
  account   = data.aws_caller_identity.current.account_id

  # IAM tags that carry the hierarchy path.
  hierarchy_tags = { for l in var.hierarchy : "${var.tag_key_prefix}${l}" => var.path[l] }

  # Resolved owner path per subscription; defaults to this service.
  owners = { for k, s in var.subscriptions : k => coalesce(s.owner, var.path) }

  queue_arns = concat(
    [for q in aws_sqs_queue.subscription : q.arn],
    [for q in aws_sqs_queue.dead_letter : q.arn],
  )
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

# The Custom Event Bus has its own endpoint service (eventsv2). The classic
# `events` endpoint does not serve it.
resource "aws_vpc_endpoint" "events" {
  count = var.create_endpoints ? 1 : 0

  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.${local.region}.eventsv2"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = var.subnet_ids
  security_group_ids  = [aws_security_group.endpoints[0].id]
  private_dns_enabled = true
  tags                = merge(var.tags, { Name = "${var.name}-eventsv2" })

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
  count = var.create_role && (var.publish || length(var.subscriptions) > 0) ? 1 : 0

  name = "event-bus"
  role = aws_iam_role.workload[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        for s in [{
          Sid      = "PublishToCentralBus"
          Effect   = "Allow"
          Action   = ["events:PutRawEvents", "events:DescribeEventBus"]
          Resource = var.bus_arn
        }] : s if var.publish
      ],
      [
        for s in [{
          Sid    = "ConsumeSubscriptionQueues"
          Effect = "Allow"
          Action = [
            "sqs:ReceiveMessage",
            "sqs:DeleteMessage",
            "sqs:ChangeMessageVisibility",
            "sqs:GetQueueAttributes",
            "sqs:GetQueueUrl",
          ]
          Resource = local.queue_arns
        }] : s if length(var.subscriptions) > 0
      ],
    )
  })
}

# --- Subscriptions -----------------------------------------------------------

resource "aws_sqs_queue" "subscription" {
  for_each = var.subscriptions

  name                       = "${var.name}-${each.key}"
  visibility_timeout_seconds = each.value.visibility_timeout_seconds
  message_retention_seconds  = each.value.message_retention_seconds
  sqs_managed_sse_enabled    = true
  tags                       = var.tags
}

# Receives one record per event that the subscriber could not deliver.
resource "aws_sqs_queue" "dead_letter" {
  for_each = var.subscriptions

  name                      = "${var.name}-${each.key}-dlq"
  message_retention_seconds = 1209600
  sqs_managed_sse_enabled   = true
  tags                      = var.tags
}

resource "aws_iam_role" "delivery" {
  count = length(var.subscriptions) > 0 ? 1 : 0

  name                 = "${var.name}-event-delivery"
  permissions_boundary = var.permissions_boundary
  tags                 = var.tags

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "delivery" {
  count = length(var.subscriptions) > 0 ? 1 : 0

  name = "deliver"
  role = aws_iam_role.delivery[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "DeliverAndDeadLetter"
      Effect   = "Allow"
      Action   = "sqs:SendMessage"
      Resource = local.queue_arns
    }]
  })
}

# The bus policy authorizes this call against the caller's principal tags and
# the METADATA filter below. The target and the delivery role must be in this
# account. The bus runs one subscriber create or delete at a time across all
# accounts; apply with -parallelism=1 if creates collide.
resource "awscc_eventsv2_subscriber" "this" {
  for_each = var.subscriptions

  name          = "${var.name}-${each.key}"
  description   = "Events of ${join("/", [for l in var.hierarchy : local.owners[each.key][l] if contains(keys(local.owners[each.key]), l)])}"
  event_bus_arn = var.bus_arn

  filter_configuration = {
    filters = [{
      scope = "METADATA"
      # Exact match on every level the owner path names.
      pattern = jsonencode({
        for l in var.hierarchy : l => [local.owners[each.key][l]]
        if contains(keys(local.owners[each.key]), l)
      })
    }]
  }

  invoke_configuration = {
    target_arn = aws_sqs_queue.subscription[each.key].arn
    role_arn   = aws_iam_role.delivery[0].arn
  }

  on_failure_configuration = {
    arn = aws_sqs_queue.dead_letter[each.key].arn
  }

  transformer = {
    type = each.value.transformer_type
  }

  tags = [for k, v in var.tags : { key = k, value = v }]

  depends_on = [aws_iam_role_policy.delivery]
}
