# Checks how account tags become the platforms map. Runs offline with a
# mocked provider: `terraform test`.

mock_provider "aws" {}

override_data {
  target = data.aws_organizations_organization.this[0]
  values = {
    accounts = [
      { id = "111111111111", arn = "", email = "", name = "pay-prod", status = "ACTIVE", joined_method = "", joined_timestamp = "", state = "ACTIVE" },
      { id = "222222222222", arn = "", email = "", name = "pay-dev", status = "ACTIVE", joined_method = "", joined_timestamp = "", state = "ACTIVE" },
      { id = "333333333333", arn = "", email = "", name = "log-prod", status = "ACTIVE", joined_method = "", joined_timestamp = "", state = "ACTIVE" },
      { id = "444444444444", arn = "", email = "", name = "sandbox", status = "ACTIVE", joined_method = "", joined_timestamp = "", state = "ACTIVE" },
      { id = "555555555555", arn = "", email = "", name = "old", status = "SUSPENDED", joined_method = "", joined_timestamp = "", state = "SUSPENDED" },
    ]
  }
}

override_data {
  target = data.aws_organizations_resource_tags.account["111111111111"]
  values = { tags = { platform = "payments", env = "prod" } }
}

override_data {
  target = data.aws_organizations_resource_tags.account["222222222222"]
  values = { tags = { platform = "payments" } }
}

override_data {
  target = data.aws_organizations_resource_tags.account["333333333333"]
  values = { tags = { platform = "logistics" } }
}

override_data {
  target = data.aws_organizations_resource_tags.account["444444444444"]
  values = { tags = { env = "sandbox" } }
}

run "groups_accounts_by_tag" {
  command = plan

  assert {
    condition = jsonencode(output.platforms) == jsonencode({
      logistics = { account_ids = ["333333333333"] }
      payments  = { account_ids = ["111111111111", "222222222222"] }
    })
    error_message = "Accounts are not grouped by their platform tag."
  }

  assert {
    condition     = jsonencode(output.untagged_account_ids) == jsonencode(["444444444444"])
    error_message = "Only the active untagged account should be reported; suspended accounts are ignored."
  }
}

run "allowed_values_rejects_unknown_unit" {
  command = plan

  variables {
    allowed_values = ["payments"]
  }

  expect_failures = [output.platforms]
}

run "allowed_values_accepts_known_units" {
  command = plan

  variables {
    allowed_values = ["payments", "logistics"]
  }
}
