output "platforms" {
  description = "Tag value => { account_ids }. Pass it to central-bus as platforms."
  value       = local.platforms

  precondition {
    condition     = length(var.allowed_values) == 0 || length(setsubtract(keys(local.platforms), var.allowed_values)) == 0
    error_message = "Accounts are tagged ${var.tag_key} with values outside allowed_values: ${join(", ", setsubtract(keys(local.platforms), var.allowed_values))}."
  }
}

output "untagged_account_ids" {
  description = "Active accounts without the tag. They can neither publish nor subscribe."
  value       = sort(tolist(setsubtract(local.active_ids, keys(local.account_unit))))
}
