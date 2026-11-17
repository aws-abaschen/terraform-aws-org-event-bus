output "role_arn" {
  description = "ARN of the workload role, or null when create_role is false."
  value       = try(aws_iam_role.workload[0].arn, null)
}

output "role_name" {
  description = "Name of the workload role, or null when create_role is false."
  value       = try(aws_iam_role.workload[0].name, null)
}

output "hierarchy_tags" {
  description = "IAM tags that carry this service's hierarchy path. Any principal that publishes or subscribes for this service must carry them."
  value       = local.hierarchy_tags
}

output "event_metadata" {
  description = "Metadata every published event must carry (PutRawEvents Metadata)."
  value       = { for l in var.hierarchy : l => var.path[l] }
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
  description = "Subscription key => ARN of its queue."
  value       = { for k, q in aws_sqs_queue.subscription : k => q.arn }
}

output "queue_urls" {
  description = "Subscription key => URL of its queue."
  value       = { for k, q in aws_sqs_queue.subscription : k => q.url }
}

output "dead_letter_queue_arns" {
  description = "Subscription key => ARN of its dead-letter queue."
  value       = { for k, q in aws_sqs_queue.dead_letter : k => q.arn }
}

output "subscriber_arns" {
  description = "Subscription key => ARN of its subscriber."
  value       = { for k, s in awscc_eventsv2_subscriber.this : k => s.subscriber_arn }
}

output "kms_key_arn" {
  description = "Customer managed key of the queues, or null when there are no subscriptions."
  value       = local.key_arn
}
