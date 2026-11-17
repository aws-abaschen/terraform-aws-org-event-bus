output "bus_arn" {
  description = "ARN of the central bus."
  value       = module.central_bus.bus_arn
}

output "policy_bytes" {
  description = "Size of the generated bus policy, against the 10,240-character quota."
  value       = module.central_bus.policy_bytes
}

output "authorizer_event_source" {
  description = "Source the authorizer must put on every event."
  value       = module.authorizer.event_source
}

output "tracker_queue_urls" {
  description = "Queues the tracker reads."
  value       = module.tracker.queue_urls
}
