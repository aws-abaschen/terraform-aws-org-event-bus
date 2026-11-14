# Checks the shape of the generated bus policy. Runs offline with mocked
# providers: `terraform test`. It does not prove that AWS evaluates the
# policy as intended; examples/proof-of-concept does that.

mock_provider "aws" {
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
}

mock_provider "awscc" {
  mock_resource "awscc_eventsv2_event_bus" {
    defaults = {
      event_bus_arn = "arn:aws:events:eu-west-1:999999999999:event-busv2/org/abcdefghijklmnopqrstuvwxy"
    }
  }
}

variables {
  name            = "org"
  organization_id = "o-a1b2c3d4e5"
  platforms = {
    payments  = { account_ids = ["111111111111", "222222222222"] }
    logistics = { account_ids = ["333333333333"] }
  }
  grants = [
    {
      owner    = { platform = "payments", solution = "cards", product = "issuing", service = "authorizer" }
      consumer = { platform = "logistics", solution = "delivery", product = "tracking", service = "tracker" }
    },
    {
      # A whole product granted to a whole platform.
      owner    = { platform = "payments", solution = "cards", product = "issuing" }
      consumer = { platform = "logistics" }
    },
  ]
}

run "default_hierarchy" {
  command = apply

  assert {
    condition = toset([for s in jsondecode(output.policy_json).Statement : s.Sid]) == toset([
      "AllowOrganizationToPublish",
      "DenyEnvelopePublish",
      "DenyUnregisteredPlatform",
      "AccountsPayments",
      "AccountsLogistics",
      "PublishOwnPlatformOnly",
      "PublishOwnSolutionOnly",
      "PublishOwnProductOnly",
      "PublishOwnServiceOnly",
      "SubscribeOwnEvents",
      "Grant0",
      "Grant1",
    ])
    error_message = "Unexpected set of statements."
  }

  assert {
    condition = alltrue([
      for s in jsondecode(output.policy_json).Statement :
      s.Condition.StringEquals["aws:PrincipalOrgID"] == "o-a1b2c3d4e5" if s.Effect == "Allow"
    ])
    error_message = "Every Allow must be limited to the organization."
  }

  assert {
    condition = one([
      for s in jsondecode(output.policy_json).Statement : s if s.Sid == "PublishOwnServiceOnly"
    ]).Condition.StringNotEquals["events:Metadata/service"] == "$${aws:PrincipalTag/service}"
    error_message = "The publish guardrail must compare the metadata key with the principal tag."
  }

  assert {
    condition = one([
      for s in jsondecode(output.policy_json).Statement : s if s.Sid == "SubscribeOwnEvents"
      ]).Condition.Null == {
      "events:Metadata/platform" = "false"
      "events:Metadata/solution" = "false"
      "events:Metadata/product"  = "false"
      "events:Metadata/service"  = "false"
    }
    error_message = "Own-event subscriptions must require every level in the filter."
  }

  assert {
    condition = one([
      for s in jsondecode(output.policy_json).Statement : s if s.Sid == "Grant1"
      ]).Condition == {
      Null = {
        "events:Metadata/platform" = "false"
        "events:Metadata/solution" = "false"
        "events:Metadata/product"  = "false"
      }
      StringEquals = {
        "aws:PrincipalOrgID"               = "o-a1b2c3d4e5"
        "aws:PrincipalTag/platform"        = "logistics"
        "events:Metadata/platform/Matcher" = "exact"
        "events:Metadata/solution/Matcher" = "exact"
        "events:Metadata/product/Matcher"  = "exact"
      }
      "ForAllValues:StringEquals" = {
        "events:Metadata/platform" = "payments"
        "events:Metadata/solution" = "cards"
        "events:Metadata/product"  = "issuing"
      }
    }
    error_message = "A partial grant must constrain exactly the levels it names."
  }

  assert {
    condition     = output.ram_share_arn == null
    error_message = "No RAM share expected when share_with is empty."
  }
}

run "custom_hierarchy_prefix_and_scope" {
  command = apply

  variables {
    hierarchy             = ["domain", "team", "app"]
    tag_key_prefix        = "evt-"
    own_read_scope        = "team"
    platforms             = { retail = { account_ids = ["111111111111"] } }
    grants                = []
    exempt_principal_arns = ["arn:aws:iam::999999999999:role/platform-ops"]
  }

  assert {
    condition = one([
      for s in jsondecode(output.policy_json).Statement : s if s.Sid == "PublishOwnAppOnly"
      ]).Condition == {
      ArnNotLike      = { "aws:PrincipalArn" = ["arn:aws:iam::999999999999:role/platform-ops"] }
      StringNotEquals = { "events:Metadata/app" = "$${aws:PrincipalTag/evt-app}" }
    }
    error_message = "Custom levels, the tag prefix and the exemption must all appear in the publish guardrail."
  }

  assert {
    condition = one([
      for s in jsondecode(output.policy_json).Statement : s if s.Sid == "SubscribeOwnEvents"
      ]).Condition["ForAllValues:StringEquals"] == {
      "events:Metadata/domain" = "$${aws:PrincipalTag/evt-domain}"
      "events:Metadata/team"   = "$${aws:PrincipalTag/evt-team}"
    }
    error_message = "own_read_scope = team must stop the required levels at team."
  }

  assert {
    condition     = output.tag_keys == ["evt-domain", "evt-team", "evt-app"]
    error_message = "tag_keys must carry the prefix."
  }
}

run "rejects_grant_with_gap" {
  command = plan

  variables {
    grants = [{
      owner    = { platform = "payments", product = "issuing" }
      consumer = { platform = "logistics" }
    }]
  }

  expect_failures = [var.grants]
}

run "rejects_oversized_policy" {
  command = plan

  variables {
    policy_size_limit = 500
  }

  expect_failures = [awscc_eventsv2_resource_policy.this]
}
