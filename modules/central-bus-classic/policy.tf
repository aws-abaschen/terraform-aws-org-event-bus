locals {
  bus_arn   = aws_cloudwatch_event_bus.this.arn
  top_level = var.hierarchy[0]

  # level name => IAM tag key
  tag_key = { for l in var.hierarchy : l => "${var.tag_key_prefix}${l}" }

  # The source a principal may publish: its own tags, joined. IAM resolves
  # the variables per request; a principal missing any tag matches nothing.
  own_source = join(var.separator, [for l in var.hierarchy : "$${aws:PrincipalTag/${local.tag_key[l]}}"])

  org_condition = { "aws:PrincipalOrgID" = var.organization_id }

  # Added to every Deny so that named forwarders are not caught.
  exemption = {
    for k, v in { ArnNotLike = { "aws:PrincipalArn" = var.exempt_principal_arns } } : k => v
    if length(var.exempt_principal_arns) > 0
  }

  statements = concat(
    # --- Publish only your own source ----------------------------------------
    [
      {
        Sid       = "PublishOwnSource"
        Effect    = "Allow"
        Principal = "*"
        Action    = "events:PutEvents"
        Resource  = local.bus_arn
        Condition = {
          StringEquals = merge(local.org_condition, { "events:source" = local.own_source })
        }
      },
    ],

    # --- Forwarders publish sources that are not a hierarchy path ------------
    [
      for s in [{
        Sid       = "ExemptPrincipalsPublish"
        Effect    = "Allow"
        Principal = "*"
        Action    = "events:PutEvents"
        Resource  = local.bus_arn
        Condition = {
          StringEquals = local.org_condition
          ArnLike      = { "aws:PrincipalArn" = var.exempt_principal_arns }
        }
      }] : s
      if length(var.exempt_principal_arns) > 0
    ],

    # --- The top-level tag must name a registered unit -----------------------
    # A negated operator also matches a missing tag, so untagged principals
    # are denied here.
    [
      {
        Sid       = "DenyUnregistered${title(local.top_level)}"
        Effect    = "Deny"
        Principal = "*"
        Action    = "events:PutEvents"
        Resource  = local.bus_arn
        Condition = merge(local.exemption, {
          StringNotEquals = {
            "aws:PrincipalTag/${local.tag_key[local.top_level]}" = keys(var.platforms)
          }
        })
      },
    ],

    # --- A unit's tag is only valid in that unit's accounts ------------------
    [
      for name, p in var.platforms : {
        Sid       = "Accounts${join("", regexall("[A-Za-z0-9]", title(name)))}"
        Effect    = "Deny"
        Principal = "*"
        Action    = "events:PutEvents"
        Resource  = local.bus_arn
        Condition = merge(local.exemption, {
          StringEquals    = { "aws:PrincipalTag/${local.tag_key[local.top_level]}" = name }
          StringNotEquals = { "aws:PrincipalAccount" = p.account_ids }
        })
      }
    ],

    # --- A tag value may not span levels -------------------------------------
    # The levels are joined into one string, so a value containing the
    # separator could spell the source of another service. One Deny per
    # level: conditions in one statement are ANDed.
    [
      for l in var.hierarchy : {
        Sid       = "NoSeparatorIn${join("", regexall("[A-Za-z0-9]", title(l)))}"
        Effect    = "Deny"
        Principal = "*"
        Action    = "events:PutEvents"
        Resource  = local.bus_arn
        Condition = merge(local.exemption, {
          StringLike = { "aws:PrincipalTag/${local.tag_key[l]}" = "*${var.separator}*" }
        })
      }
    ],
  )

  policy_json = jsonencode({
    Version   = "2012-10-17"
    Statement = local.statements
  })
}
