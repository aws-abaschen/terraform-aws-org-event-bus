# Organization guardrails that make the hierarchy tags trustworthy.
# Apply from the management account (or a delegated policy administrator)
# before onboarding any spoke.

terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0"
    }
  }
}

variable "organization_id" {
  description = "AWS Organizations ID (o-...)."
  type        = string
}

variable "target_ids" {
  description = "Roots, OUs or accounts to attach the policies to."
  type        = list(string)
}

variable "tag_keys" {
  description = "IAM tag keys that carry the hierarchy (output tag_keys of central-bus)."
  type        = list(string)
  default     = ["platform", "solution", "product", "service"]
}

variable "top_level_values" {
  description = "Allowed values of the first tag key (the keys of central-bus var.platforms). Used by the tag policy."
  type        = list(string)
  default     = []
}

variable "exempt_principal_arns" {
  description = "Principal ARN patterns allowed to set any hierarchy tag: the account vending or provisioning roles that create each service's deployment role."
  type        = list(string)
}

variable "enable_rcp" {
  description = "Create the resource control policy. Requires the RESOURCE_CONTROL_POLICY type to be enabled in the organization."
  type        = bool
  default     = true
}

variable "enable_tag_policy" {
  description = "Create the tag policy. Requires the TAG_POLICY type to be enabled in the organization."
  type        = bool
  default     = false
}

locals {
  exempt = { ArnNotLike = { "aws:PrincipalArn" = var.exempt_principal_arns } }

  scp = {
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          # Session tags override role tags, so nobody may pass hierarchy
          # keys as session tags.
          Sid      = "DenyHierarchySessionTags"
          Effect   = "Deny"
          Action   = "sts:TagSession"
          Resource = "*"
          Condition = merge(local.exempt, {
            "ForAnyValue:StringEquals" = { "aws:TagKeys" = var.tag_keys }
          })
        },
        {
          Sid      = "DenyRemovingHierarchyTags"
          Effect   = "Deny"
          Action   = ["iam:UntagRole", "iam:UntagUser"]
          Resource = "*"
          Condition = merge(local.exempt, {
            "ForAnyValue:StringEquals" = { "aws:TagKeys" = var.tag_keys }
          })
        },
      ],
      # Tag inheritance: a principal may put a hierarchy tag on an IAM
      # identity only with the value it carries itself. A service's
      # deployment role can therefore create that service's workload role,
      # and nothing else. An untagged principal can set none of them.
      [
        for k in var.tag_keys : {
          Sid      = "Inherit${join("", regexall("[A-Za-z0-9]", title(k)))}Tag"
          Effect   = "Deny"
          Action   = ["iam:CreateRole", "iam:TagRole", "iam:CreateUser", "iam:TagUser"]
          Resource = "*"
          Condition = merge(local.exempt, {
            Null            = { "aws:RequestTag/${k}" = "false" }
            StringNotEquals = { "aws:RequestTag/${k}" = "$${aws:PrincipalTag/${k}}" }
          })
        }
      ],
    )
  }

  rcp = {
    Version = "2012-10-17"
    Statement = [{
      Sid       = "EventBusesForOrganizationOnly"
      Effect    = "Deny"
      Principal = "*"
      Action    = "events:*"
      Resource  = "*"
      Condition = {
        StringNotEqualsIfExists = { "aws:PrincipalOrgID" = var.organization_id }
        BoolIfExists            = { "aws:PrincipalIsAWSService" = "false" }
      }
    }]
  }

  tag_policy = {
    tags = merge(
      { for k in var.tag_keys : k => { tag_key = { "@@assign" = k } } },
      length(var.top_level_values) == 0 ? {} : {
        (var.tag_keys[0]) = {
          tag_key   = { "@@assign" = var.tag_keys[0] }
          tag_value = { "@@assign" = var.top_level_values }
        }
      },
    )
  }
}

resource "aws_organizations_policy" "scp" {
  name        = "event-bus-hierarchy-tags"
  description = "Protects the IAM tags used for event bus access control"
  type        = "SERVICE_CONTROL_POLICY"
  content     = jsonencode(local.scp)
}

resource "aws_organizations_policy_attachment" "scp" {
  for_each = toset(var.target_ids)

  policy_id = aws_organizations_policy.scp.id
  target_id = each.value
}

resource "aws_organizations_policy" "rcp" {
  count = var.enable_rcp ? 1 : 0

  name        = "event-bus-organization-only"
  description = "Event buses accept principals of this organization only"
  type        = "RESOURCE_CONTROL_POLICY"
  content     = jsonencode(local.rcp)
}

resource "aws_organizations_policy_attachment" "rcp" {
  for_each = var.enable_rcp ? toset(var.target_ids) : toset([])

  policy_id = aws_organizations_policy.rcp[0].id
  target_id = each.value
}

resource "aws_organizations_policy" "tags" {
  count = var.enable_tag_policy ? 1 : 0

  name        = "event-bus-hierarchy-tag-values"
  description = "Standardizes the hierarchy tag keys and the top-level values"
  type        = "TAG_POLICY"
  content     = jsonencode(local.tag_policy)
}

resource "aws_organizations_policy_attachment" "tags" {
  for_each = var.enable_tag_policy ? toset(var.target_ids) : toset([])

  policy_id = aws_organizations_policy.tags[0].id
  target_id = each.value
}

output "scp_bytes" {
  description = "Size of the SCP, against the 5,120-character quota."
  value       = length(jsonencode(local.scp))
}
