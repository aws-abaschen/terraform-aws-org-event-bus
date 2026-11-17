locals {
  bus_arn   = awscc_eventsv2_event_bus.this.event_bus_arn
  top_level = var.hierarchy[0]

  # level name => IAM tag key
  tag_key = { for l in var.hierarchy : l => "${var.tag_key_prefix}${l}" }

  # Levels a subscriber filter must name when reading without a grant.
  own_scope_index = var.own_read_scope == null ? length(var.hierarchy) - 1 : index(var.hierarchy, var.own_read_scope)
  own_levels      = slice(var.hierarchy, 0, local.own_scope_index + 1)

  subscribe_actions = ["events:CreateSubscriber", "events:UpdateSubscriber"]
  guarded_actions   = concat(["events:PutEvents", "events:PutRawEvents"], local.subscribe_actions)

  org_condition = { "aws:PrincipalOrgID" = var.organization_id }

  # Added to every Deny so that named operators and forwarders are not caught.
  exemption = {
    for k, v in { ArnNotLike = { "aws:PrincipalArn" = var.exempt_principal_arns } } : k => v
    if length(var.exempt_principal_arns) > 0
  }

  # A filter must name each of these levels, with an exact matcher. Without
  # the Null check, ForAllValues passes when the filter omits the key.
  filter_shape = {
    Null         = { for l in local.own_levels : "events:Metadata/${l}" => "false" }
    StringEquals = { for l in local.own_levels : "events:Metadata/${l}/Matcher" => "exact" }
  }

  # Audience namespaces a principal belongs to: its own path cut at every
  # depth (payments, payments.cards, ... down to its service), plus the
  # organization-wide value. IAM resolves the tag variables per request.
  visibility_audiences = concat(
    [
      for d in range(1, length(var.hierarchy) + 1) :
      join(var.visibility_separator, [for l in slice(var.hierarchy, 0, d) : "$${aws:PrincipalTag/${local.tag_key[l]}}"])
    ],
    var.visibility_public_value == null ? [] : [var.visibility_public_value],
  )

  statements = concat(
    # --- Organization-wide publish -------------------------------------------
    [
      {
        Sid       = "AllowOrganizationToPublish"
        Effect    = "Allow"
        Principal = "*"
        Action = concat(
          ["events:PutRawEvents", "events:DescribeEventBus"],
          var.allow_put_events ? ["events:PutEvents"] : [],
        )
        Resource  = local.bus_arn
        Condition = { StringEquals = local.org_condition }
      },
    ],

    # --- PutEvents carries no metadata and would bypass the hierarchy --------
    [
      for s in [{
        Sid       = "DenyEnvelopePublish"
        Effect    = "Deny"
        Principal = "*"
        Action    = "events:PutEvents"
        Resource  = local.bus_arn
      }] : s
      if !var.allow_put_events && length(var.exempt_principal_arns) == 0
    ],
    [
      for s in [{
        Sid       = "DenyEnvelopePublish"
        Effect    = "Deny"
        Principal = "*"
        Action    = "events:PutEvents"
        Resource  = local.bus_arn
        Condition = local.exemption
      }] : s
      if !var.allow_put_events && length(var.exempt_principal_arns) > 0
    ],

    # --- The top-level tag must name a registered unit -----------------------
    # A negated operator also matches a missing tag, so untagged principals
    # are denied here.
    [
      {
        Sid       = "DenyUnregistered${title(local.top_level)}"
        Effect    = "Deny"
        Principal = "*"
        Action    = local.guarded_actions
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
        Action    = local.guarded_actions
        Resource  = local.bus_arn
        Condition = merge(local.exemption, {
          StringEquals    = { "aws:PrincipalTag/${local.tag_key[local.top_level]}" = name }
          StringNotEquals = { "aws:PrincipalAccount" = p.account_ids }
        })
      }
    ],

    # --- Publish only what you own -------------------------------------------
    # One Deny per level: conditions in one statement are ANDed, and a
    # mismatch on any single level must deny. A missing metadata key or a
    # missing principal tag also matches the negated operator.
    [
      for l in var.hierarchy : {
        Sid       = "PublishOwn${join("", regexall("[A-Za-z0-9]", title(l)))}Only"
        Effect    = "Deny"
        Principal = "*"
        Action    = "events:PutRawEvents"
        Resource  = local.bus_arn
        Condition = merge(local.exemption, {
          StringNotEquals = {
            "events:Metadata/${l}" = "$${aws:PrincipalTag/${local.tag_key[l]}}"
          }
        })
      }
    ],

    # --- Subscribe to your own events ----------------------------------------
    [
      {
        Sid       = "SubscribeOwnEvents"
        Effect    = "Allow"
        Principal = "*"
        Action    = local.subscribe_actions
        Resource  = local.bus_arn
        Condition = {
          Null         = local.filter_shape.Null
          StringEquals = merge(local.org_condition, local.filter_shape.StringEquals)
          "ForAllValues:StringEquals" = {
            for l in local.own_levels : "events:Metadata/${l}" => "$${aws:PrincipalTag/${local.tag_key[l]}}"
          }
        }
      },
    ],

    # --- Subscribe to events the producer made visible to you ----------------
    # The producer sets the visibility key on each event; that is its consent.
    # The filter must name the key, exactly, with only audiences the caller
    # belongs to. Producer levels in the same filter are not constrained: they
    # only narrow what is received.
    [
      {
        Sid       = "SubscribeVisibleEvents"
        Effect    = "Allow"
        Principal = "*"
        Action    = local.subscribe_actions
        Resource  = local.bus_arn
        Condition = {
          Null = { "events:Metadata/${var.visibility_key}" = "false" }
          StringEquals = merge(local.org_condition, {
            "events:Metadata/${var.visibility_key}/Matcher" = "exact"
          })
          "ForAllValues:StringEquals" = {
            "events:Metadata/${var.visibility_key}" = local.visibility_audiences
          }
        }
      },
    ],

    # --- A tag value may not span levels -------------------------------------
    # Audiences join tag values with the separator, so a value containing it
    # could spell another unit's namespace. One Deny per level: conditions in
    # one statement are ANDed.
    [
      for l in var.hierarchy : {
        Sid       = "NoSeparatorIn${join("", regexall("[A-Za-z0-9]", title(l)))}"
        Effect    = "Deny"
        Principal = "*"
        Action    = local.subscribe_actions
        Resource  = local.bus_arn
        Condition = merge(local.exemption, {
          StringLike = { "aws:PrincipalTag/${local.tag_key[l]}" = "*${var.visibility_separator}*" }
        })
      }
    ],

    # --- Allow-list ----------------------------------------------------------
    # Exceptions only: visibility covers sharing the producer consents to.
    # Literal values on both sides: the owner's path constrains the filter,
    # the consumer's path constrains the caller's tags.
    [
      for i, g in var.grants : {
        Sid       = "Grant${i}"
        Effect    = "Allow"
        Principal = "*"
        Action    = local.subscribe_actions
        Resource  = local.bus_arn
        Condition = {
          Null = { for l, v in g.owner : "events:Metadata/${l}" => "false" }
          StringEquals = merge(
            local.org_condition,
            { for l, v in g.owner : "events:Metadata/${l}/Matcher" => "exact" },
            { for l, v in g.consumer : "aws:PrincipalTag/${local.tag_key[l]}" => v },
          )
          "ForAllValues:StringEquals" = {
            for l, v in g.owner : "events:Metadata/${l}" => v
          }
        }
      }
    ],
  )

  policy_json = jsonencode({
    Version   = "2012-10-17"
    Statement = local.statements
  })
}
