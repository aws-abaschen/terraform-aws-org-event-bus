data "aws_partition" "current" {}
data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

locals {
  partition = data.aws_partition.current.partition
  region    = data.aws_region.current.region
  account   = data.aws_caller_identity.current.account_id

  # Per subscription: the source values the rule matches. A full path matches
  # one source exactly. A shorter path matches by prefix, closed with the
  # separator so that "payments.card" does not match "payments.cards".
  owner_values = {
    for k, s in var.subscriptions : k => [for l in var.hierarchy : s.owner[l] if contains(keys(s.owner), l)]
  }
  event_patterns = {
    for k, v in local.owner_values : k => (
      length(v) == length(var.hierarchy)
      ? jsonencode({ source = [join(var.separator, v)] })
      : jsonencode({ source = [{ prefix = "${join(var.separator, v)}${var.separator}" }] })
    )
  }

  target_account = { for k, s in var.subscriptions : k => split(":", s.target_arn)[4] }
}

resource "aws_cloudwatch_event_bus" "this" {
  name               = var.name
  description        = var.description
  kms_key_identifier = var.kms_key_arn
  tags               = var.tags
}

resource "aws_cloudwatch_event_bus_policy" "this" {
  event_bus_name = aws_cloudwatch_event_bus.this.name
  policy         = local.policy_json

  lifecycle {
    precondition {
      condition     = length(local.policy_json) <= var.policy_size_limit
      error_message = "The generated bus policy is ${length(local.policy_json)} characters, over the ${var.policy_size_limit}-character quota. Reduce the number of platforms or hierarchy levels."
    }
  }
}

# --- Delivery ----------------------------------------------------------------

# EventBridge assumes this role to send to the consumer queues in other
# accounts. Each consumer queue policy must allow it (spoke-connection-classic
# does that). It exists without subscriptions so that spokes can reference it
# before their first subscription is declared here.
resource "aws_iam_role" "delivery" {
  name                 = "${var.name}-event-delivery"
  permissions_boundary = var.permissions_boundary
  tags                 = var.tags

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = { "aws:SourceAccount" = local.account }
      }
    }]
  })
}

resource "aws_iam_role_policy" "delivery" {
  count = length(var.subscriptions) > 0 ? 1 : 0

  name = "deliver"
  role = aws_iam_role.delivery.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "DeliverToConsumerQueues"
      Effect   = "Allow"
      Action   = "sqs:SendMessage"
      Resource = distinct([for s in values(var.subscriptions) : s.target_arn])
    }]
  })
}

# Receives the events no consumer queue accepted. One queue for all rules:
# the rule ARN is in the attributes of each message.
resource "aws_sqs_queue" "dead_letter" {
  name                      = "${var.name}-event-dlq"
  message_retention_seconds = 1209600
  sqs_managed_sse_enabled   = true
  tags                      = var.tags
}

resource "aws_sqs_queue_policy" "dead_letter" {
  queue_url = aws_sqs_queue.dead_letter.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "RulesOfThisBus"
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.dead_letter.arn
      Condition = {
        ArnLike = {
          "aws:SourceArn" = "arn:${local.partition}:events:${local.region}:${local.account}:rule/${var.name}/*"
        }
      }
    }]
  })
}

# --- Subscriptions -----------------------------------------------------------

resource "aws_cloudwatch_event_rule" "subscription" {
  for_each = var.subscriptions

  name           = each.key
  description    = "${join(var.separator, [for l in var.hierarchy : each.value.consumer[l]])} receives ${join(var.separator, local.owner_values[each.key])}"
  event_bus_name = aws_cloudwatch_event_bus.this.name
  event_pattern  = local.event_patterns[each.key]
  tags           = var.tags

  lifecycle {
    precondition {
      condition     = length(var.subscriptions) <= var.rule_limit
      error_message = "${length(var.subscriptions)} subscriptions exceed the ${var.rule_limit} rules-per-bus quota."
    }

    # The subscription is the entitlement. This ties the queue that receives
    # the events to the consumer named in the reviewed entry.
    precondition {
      condition     = contains(try(var.platforms[each.value.consumer[local.top_level]].account_ids, []), local.target_account[each.key])
      error_message = "The target queue of \"${each.key}\" is in account ${local.target_account[each.key]}, which is not an account of the consumer's ${local.top_level} \"${each.value.consumer[local.top_level]}\"."
    }
  }
}

resource "aws_cloudwatch_event_target" "subscription" {
  for_each = var.subscriptions

  rule           = aws_cloudwatch_event_rule.subscription[each.key].name
  event_bus_name = aws_cloudwatch_event_bus.this.name
  target_id      = "queue"
  arn            = each.value.target_arn
  role_arn       = aws_iam_role.delivery.arn

  dead_letter_config {
    arn = aws_sqs_queue.dead_letter.arn
  }

  depends_on = [aws_iam_role_policy.delivery, aws_sqs_queue_policy.dead_letter]
}
