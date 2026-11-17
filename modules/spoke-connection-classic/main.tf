data "aws_region" "current" {}
data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}

locals {
  region    = data.aws_region.current.region
  partition = data.aws_partition.current.partition
  account   = data.aws_caller_identity.current.account_id

  # Customer managed key for the queues: the one passed in, else the one this
  # module creates. Null only when there are no queues.
  create_key = var.kms_key_arn == null && var.create_kms_key && length(var.queues) > 0
  key_arn    = var.kms_key_arn != null ? var.kms_key_arn : try(aws_kms_key.queues[0].arn, null)

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
          Sid      = "DecryptQueues"
          Effect   = "Allow"
          Action   = "kms:Decrypt"
          Resource = local.key_arn
        }] : s if length(var.queues) > 0
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

# --- Encryption --------------------------------------------------------------

# The central delivery role lives in the bus account. It reaches this key
# through the key policy, and the bus account grants it the matching IAM
# permission (target_kms_key_arn of the subscription). This account's own IAM
# controls everything else.
resource "aws_kms_key" "queues" {
  count = local.create_key ? 1 : 0

  description             = "Event queues of ${var.name}"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  tags                    = var.tags

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "EnableIAMPolicies"
        Effect    = "Allow"
        Principal = { AWS = "arn:${local.partition}:iam::${local.account}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid       = "CentralDeliveryRoleEncrypts"
        Effect    = "Allow"
        Principal = { AWS = var.delivery_role_arn }
        Action    = ["kms:GenerateDataKey", "kms:Decrypt"]
        Resource  = "*"
      },
    ]
  })

  lifecycle {
    precondition {
      condition     = var.delivery_role_arn != null
      error_message = "delivery_role_arn is required when queues is not empty."
    }
  }
}

resource "aws_kms_alias" "queues" {
  count = local.create_key ? 1 : 0

  name          = "alias/${var.name}-event-queues"
  target_key_id = aws_kms_key.queues[0].key_id
}

# --- Queues ------------------------------------------------------------------

resource "aws_sqs_queue" "this" {
  for_each = var.queues

  name                       = "${var.name}-${each.key}"
  visibility_timeout_seconds = each.value.visibility_timeout_seconds
  message_retention_seconds  = each.value.message_retention_seconds
  kms_master_key_id          = local.key_arn
  tags                       = var.tags

  lifecycle {
    precondition {
      condition     = var.delivery_role_arn != null
      error_message = "delivery_role_arn is required when queues is not empty."
    }

    precondition {
      condition     = local.key_arn != null
      error_message = "Queues need a customer managed key: set kms_key_arn, or leave create_kms_key true."
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
