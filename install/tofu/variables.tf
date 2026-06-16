################################################################################
# Required
################################################################################

variable "nrn" {
  description = "Nullplatform Resource Name (organization:account format)"
  type        = string
}

variable "np_api_key" {
  description = "Nullplatform API key used by the agent to authenticate with nullplatform"
  type        = string
  sensitive   = true
}

variable "tags_selectors" {
  description = "Map of tags used to select the agent that will handle this service's notification channel"
  type        = map(string)
}

variable "github_token" {
  description = "GitHub token for fetching spec templates. Only required when the spec repository is private."
  type        = string
  sensitive   = true
  default     = null
}

################################################################################
# Repository
# Where the service specs and runtime code live. Both are assumed to be in the
# same repository; `spec_path` and `agent_service_path` can differ if the specs
# are nested deeper (as is the case for endpoint-exposer with its `install/`
# subdirectory).
################################################################################

variable "repository_org" {
  description = "GitHub organization owning the service repository"
  type        = string
  default     = "nullplatform"
}

variable "repository_name" {
  description = "Name of the service repository"
  type        = string
  default     = "services"
}

variable "repository_branch" {
  description = "Branch of the service repository to fetch specs from. Must be a short branch name (e.g. \"main\"), not a full ref."
  type        = string
  default     = "main"
}

variable "spec_path" {
  description = "Path within the repository where `specs/service-spec.json.tpl` lives (used at registration time by the service_definition module)"
  type        = string
  default     = "endpoint-exposer/install"
}

variable "agent_service_path" {
  description = "Path within the repository where the runtime `entrypoint/entrypoint` lives (used at execution time by the agent)"
  type        = string
  default     = "endpoint-exposer"
}

################################################################################
# Service Definition
################################################################################

variable "service_name" {
  description = "Display name for the service in nullplatform"
  type        = string
  default     = "Endpoint Exposer"
}

################################################################################
# Overrides (optional)
# When enabled, the agent receives `--overrides-path=<overrides_repo_path>` as
# an argument, so the entrypoint can layer tenant-specific configuration on
# top of the in-repo defaults.
################################################################################

variable "overrides_enabled" {
  description = "Append `--overrides-path` to the agent arguments for local config overrides"
  type        = bool
  default     = false
}

variable "overrides_repo_path" {
  description = "Absolute path inside the agent container where the overrides directory is located. Required when overrides_enabled = true."
  type        = string
  default     = null

  validation {
    condition     = var.overrides_repo_path == null || startswith(coalesce(var.overrides_repo_path, "/"), "/")
    error_message = "overrides_repo_path must be an absolute path (start with /)."
  }
}
