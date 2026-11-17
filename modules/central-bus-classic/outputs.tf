output "bus_arn" {
  description = "ARN of the event bus. Pass it to spoke-connection-classic."
  value       = local.bus_arn
}

output "bus_name" {
  description = "Name of the event bus."
  value       = aws_cloudwatch_event_bus.this.name
}

output "hierarchy" {
  description = "Hierarchy level names. Pass them to spoke-connection-classic unchanged."
  value       = var.hierarchy
}

output "tag_key_prefix" {
  description = "Prefix of the IAM tag keys. Pass it to spoke-connection-classic unchanged."
  value       = var.tag_key_prefix
}

output "separator" {
  description = "Separator of the event source. Pass it to spoke-connection-classic unchanged."
  value       = var.separator
}

output "tag_keys" {
  description = "IAM tag keys that carry the hierarchy, in order. Protect these with the guardrail SCP."
  value       = [for l in var.hierarchy : local.tag_key[l]]
}

output "delivery_role_arn" {
  description = "Role EventBridge uses to send to consumer queues. Pass it to spoke-connection-classic."
  value       = aws_iam_role.delivery.arn
}

output "dead_letter_queue_arn" {
  description = "ARN of the queue that receives undeliverable events."
  value       = aws_sqs_queue.dead_letter.arn
}

output "kms_key_arn" {
  description = "Customer managed key of the bus and the dead-letter queue."
  value       = local.key_arn
}

output "rule_arns" {
  description = "Subscription key => ARN of its rule."
  value       = { for k, r in aws_cloudwatch_event_rule.subscription : k => r.arn }
}

output "policy_json" {
  description = "The generated bus policy."
  value       = local.policy_json
}

output "policy_bytes" {
  description = "Size of the generated bus policy, against policy_size_limit."
  value       = length(local.policy_json)
}
