################################################################################
# Service Definition
# Registers the service specification and action specs in nullplatform.
################################################################################

module "service_definition" {
  source = "../../../../tofu-modules/nullplatform/service_definition"

  nrn = var.nrn

  # Spec templates are fetched from GitHub via HTTP and parsed as JSON.
  # The module expects specs at `<service_path>/specs/service-spec.json.tpl`
  # (plus `specs/actions/*.json.tpl` and `specs/links/*.json.tpl` if any).
  repository_org    = var.repository_org
  repository_name   = var.repository_name
  repository_branch = var.repository_branch
  service_path      = var.spec_path
  repository_token  = var.github_token

  service_name = var.service_name

  # Override the module's default `available_links = ["connect"]`: this service
  # doesn't ship a `specs/links/connect.json.tpl`, and fetching a non-existent
  # template would make `jsondecode()` abort planning.
  available_links = []
}

################################################################################
# Service Definition Agent Association
# Creates the notification channel that connects nullplatform events to the agent.
#
# The module constructs the agent cmdline as
#   `${base_clone_path}/${repository_service_spec_repo}/${service_path}/entrypoint/entrypoint`
# so the agent must have the repo cloned at that location. `service_path` here
# is the runtime path (e.g. `endpoint-exposer`), NOT the specs path (which
# includes the `install/` prefix for this service).
################################################################################

module "service_definition_agent_association" {
  source = "../../../../tofu-modules/nullplatform/service_definition_agent_association"

  nrn            = var.nrn
  api_key        = var.np_api_key
  tags_selectors = var.tags_selectors

  service_specification_slug   = module.service_definition.service_specification_slug
  repository_service_spec_repo = "${var.repository_org}/${var.repository_name}"
  service_path                 = var.agent_service_path

  # Pass `--overrides-path=<path>` to the entrypoint when local config
  # overrides are enabled. The entrypoint handles the flag; the module just
  # forwards arguments verbatim.
  agent_arguments = var.overrides_enabled ? ["--overrides-path=${var.overrides_repo_path}"] : []
}
