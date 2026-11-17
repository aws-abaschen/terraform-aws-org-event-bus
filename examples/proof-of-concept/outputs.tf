locals {
  last_level = var.hierarchy[length(var.hierarchy) - 1]
  owner      = var.services["owner"]

  # A METADATA filter matching one full hierarchy path.
  filter_for = {
    for k, path in var.services : k => jsonencode({
      Filters = [{
        Scope   = "METADATA"
        Pattern = jsonencode({ for l in var.hierarchy : l => [path[l]] })
      }]
    })
  }

  # Owner's path without the last level: a wider filter than any grant allows.
  owner_filter_missing_level = jsonencode({
    Filters = [{
      Scope   = "METADATA"
      Pattern = jsonencode({ for l in var.hierarchy : l => [local.owner[l]] if l != local.last_level })
    }]
  })

  # The owner's first two levels as an audience: payments.cards.
  owner_solution = join(".", [for l in slice(var.hierarchy, 0, min(2, length(var.hierarchy))) : local.owner[l]])

  visibility_filter = {
    for k, v in {
      solution = [local.owner_solution]
      public   = ["public"]
      mixed    = [local.owner_solution, "public"]
    } : k => jsonencode({ Filters = [{ Scope = "METADATA", Pattern = jsonencode({ visibility = v }) }] })
  }

  # A permitted filter next to a forbidden one in the same subscriber.
  # Expected denied; if allowed, a second filter bypasses every subscribe rule.
  filter_two_filters = jsonencode({
    Filters = [
      { Scope = "METADATA", Pattern = jsonencode({ visibility = ["public"] }) },
      { Scope = "METADATA", Pattern = jsonencode({ for l in var.hierarchy : l => [local.owner[l]] }) },
    ]
  })

  test_env = {
    REGION               = var.region
    SPOKE_PROFILE        = var.spoke_profile
    NAME_PREFIX          = var.name_prefix
    BUS_ARN              = local.bus_arn
    QUEUE_ARN            = aws_sqs_queue.target.arn
    DLQ_ARN              = aws_sqs_queue.dlq.arn
    DELIVERY_ROLE_ARN    = aws_iam_role.delivery.arn
    ROLE_OWNER           = aws_iam_role.service["owner"].arn
    ROLE_GRANTED         = aws_iam_role.service["granted"].arn
    ROLE_STRANGER        = aws_iam_role.service["stranger"].arn
    TAG_KEY              = local.last_level
    META_OWNER           = jsonencode(local.owner)
    META_WRONG_LEVEL     = jsonencode(merge(local.owner, { (local.last_level) = "intruder" }))
    META_MISSING_LEVEL   = jsonencode({ for l in var.hierarchy : l => local.owner[l] if l != local.last_level })
    FILTER_OWNER         = local.filter_for["owner"]
    FILTER_GRANTED       = local.filter_for["granted"]
    FILTER_MISSING_LEVEL = local.owner_filter_missing_level
    META_OWNER_VISIBLE   = jsonencode(merge(local.owner, { visibility = local.owner_solution }))
    FILTER_VIS_SOLUTION  = local.visibility_filter["solution"]
    FILTER_VIS_PUBLIC    = local.visibility_filter["public"]
    FILTER_VIS_MIXED     = local.visibility_filter["mixed"]
    FILTER_TWO_FILTERS   = local.filter_two_filters
  }
}

output "bus_arn" {
  description = "ARN of the proof-of-concept bus."
  value       = local.bus_arn
}

output "policy_bytes" {
  description = "Size of the generated bus policy, to extrapolate against the 20,480-byte quota."
  value       = length(awscc_eventsv2_resource_policy.this.policy_document)
}

output "test_env" {
  description = "Shell variables for run-tests.sh. No secrets."
  value       = join("\n", [for k, v in local.test_env : "${k}='${v}'"])
}
