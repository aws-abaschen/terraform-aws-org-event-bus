output "role_arn" {
  description = "ARN of the workload role, or null when create_role is false."
  value       = try(aws_iam_role.workload[0].arn, null)
}

output "role_name" {
  description = "Name of the workload role, or null when create_role is false."
  value       = try(aws_iam_role.workload[0].name, null)
}

output "hierarchy_tags" {
  description = "IAM tags that carry this service's hierarchy path. Any principal that publishes for this service must carry them."
  value       = local.hierarchy_tags
}

output "event_source" {
  description = "Source every published event must carry (PutEvents Source)."
  value       = local.event_source
}

output "events_endpoint_id" {
  description = "ID of the EventBridge interface endpoint, or null when create_endpoints is false."
  value       = try(aws_vpc_endpoint.events[0].id, null)
}

output "sqs_endpoint_id" {
  description = "ID of the SQS interface endpoint, or null when not created."
  value       = try(aws_vpc_endpoint.sqs[0].id, null)
}

output "endpoint_security_group_id" {
  description = "Security group of the endpoints, or null when create_endpoints is false."
  value       = try(aws_security_group.endpoints[0].id, null)
}

output "queue_arns" {
  description = "Queue key => ARN. Give these to the platform team as target_arn of a central-bus-classic subscription."
  value       = { for k, q in aws_sqs_queue.this : k => q.arn }
}

output "kms_key_arn" {
  description = "Customer managed key of the queues, or null when there are no queues. Give it to the platform team as target_kms_key_arn of the subscription."
  value       = local.key_arn
}

output "queue_urls" {
  description = "Queue key => URL."
  value       = { for k, q in aws_sqs_queue.this : k => q.url }
}
