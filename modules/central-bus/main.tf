resource "awscc_eventsv2_event_bus" "this" {
  name        = var.name
  description = var.description

  storage_configuration = {
    retention_period_in_days = var.retention_days
  }

  encryption_configuration = var.kms_key_arn == null ? null : {
    kms_key_identifier = var.kms_key_arn
  }

  tags = [for k, v in var.tags : { key = k, value = v }]
}

resource "awscc_eventsv2_resource_policy" "this" {
  event_bus_arn   = local.bus_arn
  policy_document = local.policy_json

  lifecycle {
    precondition {
      condition     = length(local.policy_json) <= var.policy_size_limit
      error_message = "The generated bus policy is ${length(local.policy_json)} bytes, over the ${var.policy_size_limit}-byte quota. Reduce the number of grants, widen them to a higher level, or request a quota increase and raise policy_size_limit."
    }
  }
}

# Optional. Access is granted by the bus policy; the RAM share only makes the
# bus discoverable (ListEventBuses) in the accounts it is shared with. The
# publish-only permission is used on purpose: RAM permissions carry no
# conditions, so subscribe rights must come from the bus policy alone.
resource "aws_ram_resource_share" "this" {
  count = length(var.share_with) > 0 ? 1 : 0

  name                      = var.name
  allow_external_principals = false
  permission_arns           = ["arn:${data.aws_partition.current.partition}:ram::aws:permission/AWSRAMEventBridgeEventBusV2PublishOnly"]
  tags                      = var.tags
}

resource "aws_ram_resource_association" "this" {
  count = length(var.share_with) > 0 ? 1 : 0

  resource_share_arn = aws_ram_resource_share.this[0].arn
  resource_arn       = local.bus_arn
}

resource "aws_ram_principal_association" "this" {
  for_each = toset(var.share_with)

  resource_share_arn = aws_ram_resource_share.this[0].arn
  principal          = each.value
}

data "aws_partition" "current" {}
