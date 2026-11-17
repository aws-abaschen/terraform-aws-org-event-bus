# Checks the generated bus policy and the rules. Runs offline with a mocked
# provider: `terraform test`. It does not prove that AWS evaluates the policy
# as intended.

mock_provider "aws" {
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_data "aws_region" {
    defaults = { region = "eu-west-1" }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "999999999999" }
  }
  mock_resource "aws_cloudwatch_event_bus" {
    defaults = { arn = "arn:aws:events:eu-west-1:999999999999:event-bus/org" }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::999999999999:role/org-event-delivery" }
  }
  mock_resource "aws_sqs_queue" {
    defaults = { arn = "arn:aws:sqs:eu-west-1:999999999999:org-event-dlq" }
  }
}

variables {
  name            = "org"
  organization_id = "o-a1b2c3d4e5"
  platforms = {
    payments  = { account_ids = ["111111111111", "222222222222"] }
    logistics = { account_ids = ["333333333333"] }
  }
  subscriptions = {
    tracker-own = {
      owner      = { platform = "logistics", solution = "delivery", product = "tracking", service = "tracker" }
      consumer   = { platform = "logistics", solution = "delivery", product = "tracking", service = "tracker" }
      target_arn = "arn:aws:sqs:eu-west-1:333333333333:tracker-own"
    }
    tracker-issuing = {
      # A whole product.
      owner      = { platform = "payments", solution = "cards", product = "issuing" }
      consumer   = { platform = "logistics", solution = "delivery", product = "tracking", service = "tracker" }
      target_arn = "arn:aws:sqs:eu-west-1:333333333333:tracker-issuing"
    }
  }
}

run "default_hierarchy" {
  command = apply

  assert {
    condition = toset([for s in jsondecode(output.policy_json).Statement : s.Sid]) == toset([
      "PublishOwnSource",
      "DenyUnregisteredPlatform",
      "AccountsPayments",
      "AccountsLogistics",
      "NoSeparatorInPlatform",
      "NoSeparatorInSolution",
      "NoSeparatorInProduct",
      "NoSeparatorInService",
    ])
    error_message = "Unexpected set of statements."
  }

  assert {
    condition = one([
      for s in jsondecode(output.policy_json).Statement : s if s.Sid == "PublishOwnSource"
      ]).Condition.StringEquals == {
      "aws:PrincipalOrgID" = "o-a1b2c3d4e5"
      "events:source"      = "$${aws:PrincipalTag/platform}.$${aws:PrincipalTag/solution}.$${aws:PrincipalTag/product}.$${aws:PrincipalTag/service}"
    }
    error_message = "Publishing must be limited to the organization and to the source spelled by the caller's tags."
  }

  assert {
    condition = alltrue([
      for s in jsondecode(output.policy_json).Statement : s.Action == "events:PutEvents"
    ])
    error_message = "The bus policy must grant nothing but PutEvents: rules stay with the platform account."
  }

  assert {
    condition = one([
      for s in jsondecode(output.policy_json).Statement : s if s.Sid == "NoSeparatorInSolution"
    ]).Condition.StringLike["aws:PrincipalTag/solution"] == "*.*"
    error_message = "A tag value containing the separator must be denied."
  }

  assert {
    condition     = jsondecode(aws_cloudwatch_event_rule.subscription["tracker-own"].event_pattern) == { source = ["logistics.delivery.tracking.tracker"] }
    error_message = "A full owner path must match one source exactly."
  }

  assert {
    condition     = jsondecode(aws_cloudwatch_event_rule.subscription["tracker-issuing"].event_pattern) == { source = [{ prefix = "payments.cards.issuing." }] }
    error_message = "A partial owner path must match by prefix, closed with the separator."
  }

  assert {
    condition     = aws_cloudwatch_event_target.subscription["tracker-issuing"].arn == "arn:aws:sqs:eu-west-1:333333333333:tracker-issuing"
    error_message = "The target must be the consumer's queue."
  }

  assert {
    condition = toset(jsondecode(aws_iam_role_policy.delivery[0].policy).Statement[0].Resource) == toset([
      "arn:aws:sqs:eu-west-1:333333333333:tracker-own",
      "arn:aws:sqs:eu-west-1:333333333333:tracker-issuing",
    ])
    error_message = "The delivery role must reach the declared queues only."
  }
}

run "custom_hierarchy_prefix_separator_and_exemption" {
  command = apply

  variables {
    hierarchy             = ["domain", "app"]
    tag_key_prefix        = "bus-"
    separator             = "/"
    platforms             = { sales = { account_ids = ["111111111111"] } }
    subscriptions         = {}
    exempt_principal_arns = ["arn:aws:iam::*:role/event-forwarder"]
  }

  assert {
    condition = one([
      for s in jsondecode(output.policy_json).Statement : s if s.Sid == "PublishOwnSource"
    ]).Condition.StringEquals["events:source"] == "$${aws:PrincipalTag/bus-domain}/$${aws:PrincipalTag/bus-app}"
    error_message = "The source must follow hierarchy, tag_key_prefix and separator."
  }

  assert {
    condition = one([
      for s in jsondecode(output.policy_json).Statement : s if s.Sid == "ExemptPrincipalsPublish"
    ]).Condition.ArnLike["aws:PrincipalArn"] == ["arn:aws:iam::*:role/event-forwarder"]
    error_message = "Exempt principals need their own Allow."
  }

  assert {
    condition = alltrue([
      for s in jsondecode(output.policy_json).Statement :
      s.Condition.ArnNotLike["aws:PrincipalArn"] == ["arn:aws:iam::*:role/event-forwarder"] if s.Effect == "Deny"
    ])
    error_message = "Every Deny must skip the exempt principals."
  }

  assert {
    condition     = output.tag_keys == ["bus-domain", "bus-app"]
    error_message = "tag_keys must carry the prefix."
  }

  assert {
    condition     = length(aws_iam_role_policy.delivery) == 0
    error_message = "Without subscriptions the delivery role has no policy."
  }
}

run "rejects_queue_outside_the_consumer_accounts" {
  command = plan

  variables {
    subscriptions = {
      stolen = {
        owner      = { platform = "payments", solution = "cards", product = "issuing", service = "authorizer" }
        consumer   = { platform = "logistics", solution = "delivery", product = "tracking", service = "tracker" }
        target_arn = "arn:aws:sqs:eu-west-1:444444444444:elsewhere"
      }
    }
  }

  expect_failures = [aws_cloudwatch_event_rule.subscription]
}

run "rejects_owner_with_gap" {
  command = plan

  variables {
    subscriptions = {
      gap = {
        owner      = { platform = "payments", product = "issuing" }
        consumer   = { platform = "logistics", solution = "delivery", product = "tracking", service = "tracker" }
        target_arn = "arn:aws:sqs:eu-west-1:333333333333:gap"
      }
    }
  }

  expect_failures = [var.subscriptions]
}

run "rejects_value_with_separator" {
  command = plan

  variables {
    subscriptions = {
      dotted = {
        owner      = { platform = "payments", solution = "cards.issuing" }
        consumer   = { platform = "logistics", solution = "delivery", product = "tracking", service = "tracker" }
        target_arn = "arn:aws:sqs:eu-west-1:333333333333:dotted"
      }
    }
  }

  expect_failures = [var.subscriptions]
}

run "rejects_oversized_policy" {
  command = plan

  variables {
    policy_size_limit = 500
  }

  expect_failures = [aws_cloudwatch_event_bus_policy.this]
}
