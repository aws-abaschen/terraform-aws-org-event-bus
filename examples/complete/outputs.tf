output "bus_arn" {
  description = "ARN of the central bus."
  value       = module.central_bus.bus_arn
}

output "policy_bytes" {
  description = "Size of the generated bus policy."
  value       = module.central_bus.policy_bytes
}

output "authorizer_role_arn" {
  description = "Workload role of the authorizer."
  value       = module.authorizer.role_arn
}

output "authorizer_event_metadata" {
  description = "Metadata the authorizer must put on every event."
  value       = module.authorizer.event_metadata
}

output "tracker_queue_urls" {
  description = "Queues the tracker reads."
  value       = module.tracker.queue_urls
}
