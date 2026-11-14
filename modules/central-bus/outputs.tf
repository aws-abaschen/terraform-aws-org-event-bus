output "bus_arn" {
  description = "ARN of the event bus. Pass it to spoke-connection."
  value       = local.bus_arn
}

output "bus_name" {
  description = "Name of the event bus."
  value       = awscc_eventsv2_event_bus.this.name
}

output "hierarchy" {
  description = "Hierarchy level names. Pass them to spoke-connection unchanged."
  value       = var.hierarchy
}

output "tag_key_prefix" {
  description = "Prefix of the IAM tag keys. Pass it to spoke-connection unchanged."
  value       = var.tag_key_prefix
}

output "tag_keys" {
  description = "IAM tag keys that carry the hierarchy, in order. Protect these with the guardrail SCP."
  value       = [for l in var.hierarchy : local.tag_key[l]]
}

output "policy_json" {
  description = "The generated bus policy."
  value       = local.policy_json
}

output "policy_bytes" {
  description = "Size of the generated bus policy, against policy_size_limit."
  value       = length(local.policy_json)
}

output "ram_share_arn" {
  description = "ARN of the RAM resource share, or null when share_with is empty."
  value       = try(aws_ram_resource_share.this[0].arn, null)
}
