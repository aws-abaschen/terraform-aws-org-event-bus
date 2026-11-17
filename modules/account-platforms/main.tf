# Reads the account tags in AWS Organizations and builds the `platforms` input
# of central-bus. IAM has no condition key for account tags, so the bus policy
# cannot read them itself; this module turns them into the account list the
# policy checks. Run it with a provider in the management account or in a
# delegated administrator account for AWS Organizations.
#
# Re-apply the central stack whenever an account is created or retagged, for
# example as the last step of the account vending pipeline.

data "aws_organizations_organization" "this" {
  count = var.parent_id == null ? 1 : 0
}

data "aws_organizations_organizational_unit_descendant_accounts" "this" {
  count     = var.parent_id == null ? 0 : 1
  parent_id = var.parent_id
}

locals {
  accounts = var.parent_id == null ? data.aws_organizations_organization.this[0].accounts : data.aws_organizations_organizational_unit_descendant_accounts.this[0].accounts

  # Suspended and closing accounts cannot call the bus; leave them out.
  active_ids = toset([for a in local.accounts : a.id if a.status == "ACTIVE"])

  account_unit = {
    for id, t in data.aws_organizations_resource_tags.account : id => t.tags[var.tag_key]
    if trimspace(lookup(t.tags, var.tag_key, "")) != ""
  }

  platforms = {
    for unit in sort(distinct(values(local.account_unit))) : unit => {
      account_ids = sort([for id, u in local.account_unit : id if u == unit])
    }
  }
}

data "aws_organizations_resource_tags" "account" {
  for_each    = local.active_ids
  resource_id = each.value
}
