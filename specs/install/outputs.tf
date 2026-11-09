output "service_specification_id" {
  description = "ID of the created endpoint-exposer service specification"
  value       = module.endpoint_exposer.service_specification_id
}

output "service_specification_slug" {
  description = "Slug of the created endpoint-exposer service specification"
  value       = module.endpoint_exposer.service_specification_slug
}

output "service_channel_id" {
  description = "ID of the service notification channel that dispatches service actions to an agent"
  value       = module.endpoint_exposer_channel.id
}

output "agent_extra_envs" {
  description = "Environment for the agent module's extra_envs (merge in the scheme's COGNITO_*/AVP_* variables)"
  value = {
    INGRESS_TYPE = "istio"
    AUTH_TYPE    = var.auth_type
  }
}

output "scope_channel_id" {
  description = "ID of the scope notification channel used for blue/green sync, if enabled"
  value       = try(module.endpoint_exposer_scope_channel[0].id, null)
}
