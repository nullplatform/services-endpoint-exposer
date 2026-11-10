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

# A local, not just the output: a root module can't read its own outputs, and the
# agent module call in the same project needs this value.
locals {
  agent_extra_envs = {
    INGRESS_TYPE = "istio"
    AUTH_TYPE    = var.auth_type
  }
}

output "agent_extra_envs" {
  description = "INGRESS_TYPE and AUTH_TYPE for the agent module's extra_envs; merge in the scheme's COGNITO_*/AVP_* variables"
  value       = local.agent_extra_envs
}

output "scope_channel_id" {
  description = "ID of the scope notification channel used for blue/green sync, if enabled"
  value       = try(module.endpoint_exposer_scope_channel[0].id, null)
}
