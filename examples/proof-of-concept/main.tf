data "aws_caller_identity" "platform" {
  provider = aws.platform
}

data "aws_caller_identity" "spoke" {
  provider = aws.spoke
}

locals {
  platform_account = data.aws_caller_identity.platform.account_id
  spoke_account    = data.aws_caller_identity.spoke.account_id
  spoke_root       = "arn:aws:iam::${local.spoke_account}:root"
  bus_arn          = awscc_eventsv2_event_bus.this.event_bus_arn

  # The single allow-list entry under test: granted may read owner's events.
  grants = [{ owner = "owner", consumer = "granted" }]

  subscribe_actions = ["events:CreateSubscriber", "events:UpdateSubscriber"]

  # Every level must be named by the filter, with an exact matcher.
  filter_shape_conditions = {
    Null = { for l in var.hierarchy : "events:Metadata/${l}" => "false" }
    StringEquals = {
      for l in var.hierarchy : "events:Metadata/${l}/Matcher" => "exact"
    }
  }

  statements = concat(
    [
      {
        Sid       = "AllowSpokeToPublishAndDescribe"
        Effect    = "Allow"
        Principal = { AWS = local.spoke_root }
        Action    = ["events:PutRawEvents", "events:DescribeEventBus"]
        Resource  = local.bus_arn
      },
      {
        # PutEvents carries no metadata, so it would bypass the hierarchy.
        Sid       = "DenyEnvelopePublish"
        Effect    = "Deny"
        Principal = { AWS = local.spoke_root }
        Action    = "events:PutEvents"
        Resource  = local.bus_arn
      },
    ],

    # Assumption 1a: publish only what you own. One Deny per level, because a
    # mismatch on any single level must deny. A negated operator also matches
    # when the metadata key or the principal tag is missing.
    [
      for l in var.hierarchy : {
        Sid       = "PublishOwn${title(l)}Only"
        Effect    = "Deny"
        Principal = { AWS = local.spoke_root }
        Action    = "events:PutRawEvents"
        Resource  = local.bus_arn
        Condition = {
          StringNotEquals = {
            "events:Metadata/${l}" = "$${aws:PrincipalTag/${l}}"
          }
        }
      }
    ],

    # Assumption 1b: subscribe to your own events, constant size.
    [
      {
        Sid       = "SubscribeOwnEvents"
        Effect    = "Allow"
        Principal = { AWS = local.spoke_root }
        Action    = local.subscribe_actions
        Resource  = local.bus_arn
        Condition = merge(local.filter_shape_conditions, {
          "ForAllValues:StringEquals" = {
            for l in var.hierarchy : "events:Metadata/${l}" => "$${aws:PrincipalTag/${l}}"
          }
        })
      }
    ],

    # Allow-list: literal owner path in the filter, literal consumer path in
    # the principal tags.
    [
      for g in local.grants : {
        Sid       = "Grant${title(g.owner)}To${title(g.consumer)}"
        Effect    = "Allow"
        Principal = { AWS = local.spoke_root }
        Action    = local.subscribe_actions
        Resource  = local.bus_arn
        Condition = {
          Null = local.filter_shape_conditions.Null
          StringEquals = merge(
            local.filter_shape_conditions.StringEquals,
            { for l in var.hierarchy : "aws:PrincipalTag/${l}" => var.services[g.consumer][l] },
          )
          "ForAllValues:StringEquals" = {
            for l in var.hierarchy : "events:Metadata/${l}" => var.services[g.owner][l]
          }
        }
      }
    ],
  )
}

# --- Platform account -------------------------------------------------------

resource "awscc_eventsv2_event_bus" "this" {
  provider = awscc.platform

  name        = var.name_prefix
  description = "Proof of concept for hierarchy ABAC. Safe to delete."

  storage_configuration = {
    retention_period_in_days = 1
  }

  lifecycle {
    precondition {
      condition     = local.platform_account != local.spoke_account
      error_message = "The platform and spoke profiles must be different accounts. In one account the role's identity policy alone would allow the calls and the bus policy Allow statements would not be tested."
    }
  }
}

resource "awscc_eventsv2_resource_policy" "this" {
  provider = awscc.platform

  event_bus_arn = local.bus_arn
  policy_document = jsonencode({
    Version   = "2012-10-17"
    Statement = local.statements
  })

  # The policy names the spoke account, and IAM tags must exist before the
  # tests run. Nothing here depends on the roles, but keep the order obvious.
  depends_on = [aws_iam_role.service]
}

# --- Spoke account ----------------------------------------------------------

resource "aws_iam_role" "service" {
  provider = aws.spoke
  for_each = var.services

  name = "${var.name_prefix}-${each.key}"
  tags = each.value

  # sts:AssumeRole only. Without sts:TagSession a caller cannot pass session
  # tags that would override the role's hierarchy tags.
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = local.spoke_root }
      Action    = "sts:AssumeRole"
    }]
  })
}

# Deliberately broad on the bus: both sides must allow a cross-account call,
# and this proof of concept tests what the bus policy alone decides.
resource "aws_iam_role_policy" "service" {
  provider = aws.spoke
  for_each = var.services

  name = "event-bus"
  role = aws_iam_role.service[each.key].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "UseTheBus"
        Effect = "Allow"
        Action = [
          "events:PutEvents",
          "events:PutRawEvents",
          "events:DescribeEventBus",
          "events:CreateSubscriber",
          "events:UpdateSubscriber",
        ]
        Resource = local.bus_arn
      },
      {
        Sid    = "ManageOwnSubscribers"
        Effect = "Allow"
        Action = [
          "events:CreateSubscriber",
          "events:UpdateSubscriber",
          "events:DescribeSubscriber",
          "events:DeleteSubscriber",
        ]
        Resource = "arn:aws:events:${var.region}:${local.spoke_account}:subscriber/${var.name_prefix}-*"
      },
      {
        Sid      = "ListOwnSubscribers"
        Effect   = "Allow"
        Action   = "events:ListSubscribers"
        Resource = "*"
      },
      {
        Sid      = "PassDeliveryRole"
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = aws_iam_role.delivery.arn
      },
    ]
  })
}

# Disposable test queues: SQS-managed encryption, no key to leave behind.
resource "aws_sqs_queue" "target" {
  provider                = aws.spoke
  name                    = "${var.name_prefix}-target"
  sqs_managed_sse_enabled = true
}

resource "aws_sqs_queue" "dlq" {
  provider                = aws.spoke
  name                    = "${var.name_prefix}-dlq"
  sqs_managed_sse_enabled = true
}

resource "aws_iam_role" "delivery" {
  provider = aws.spoke
  name     = "${var.name_prefix}-delivery"

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
  provider = aws.spoke
  name     = "deliver"
  role     = aws_iam_role.delivery.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "sqs:SendMessage"
      Resource = [aws_sqs_queue.target.arn, aws_sqs_queue.dlq.arn]
    }]
  })
}
