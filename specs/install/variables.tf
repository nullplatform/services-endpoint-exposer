variable "nrn" {
  description = "Nullplatform Resource Name (organization:account format) to register the service and channels under"
  type        = string
}

variable "np_api_key" {
  description = "API key used by the notification channels to authenticate with the nullplatform API"
  type        = string
  sensitive   = true
}

variable "tags_selectors" {
  description = "Map of tags used to select and filter the agent(s) that will handle this service's notification channels"
  type        = map(string)
}

variable "tofu_modules_ref" {
  description = "Git ref (tag) of nullplatform/tofu-modules to pull the service_definition / service_definition_agent_association / scope_definition_agent_association modules from"
  type        = string
  default     = "v6.2.2"
}

variable "repository_org" {
  description = "GitHub org that owns this service repository"
  type        = string
  default     = "nullplatform"
}

variable "repository_name" {
  description = "Name of this service repository"
  type        = string
  default     = "services-endpoint-exposer"
}

variable "repository_branch" {
  description = "Branch of this service repository to register the spec/entrypoint from"
  type        = string
  default     = "main"
}

variable "enable_scope_channel" {
  description = "Whether to also register the scope notification channel needed for blue/green sync (see README, section 3). Requires scope_specification_id and scope_specification_slug."
  type        = bool
  default     = false
}

variable "scope_specification_id" {
  description = "ID of the scope specification used by apps that expose routes through this service. Required when enable_scope_channel = true."
  type        = string
  default     = null
}

variable "scope_specification_slug" {
  description = "Slug of the scope specification used by apps that expose routes through this service. Required when enable_scope_channel = true."
  type        = string
  default     = null
}

variable "override_repo_path" {
  description = "Local filesystem path (inside the scope agent pod) where this service repository is cloned, used to locate container-scope-override/"
  type        = string
  default     = "/root/.np/nullplatform/services-endpoint-exposer"
}

variable "overrides_service_path" {
  description = "Path (within the cloned repository) to the scope override directory injecting the sync_exposer step"
  type        = string
  default     = "/container-scope-override"
}
