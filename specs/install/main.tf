################################################################################
# endpoint-exposer — nullplatform registration
#
# Registers this repository's service spec (specs/service-spec.json.tpl,
# specs/links/connect.json.tpl) and entrypoint as a nullplatform service, wires
# a notification channel so an agent picks up service actions, and optionally
# registers the scope notification channel that keeps HTTPRoutes in sync
# across blue/green deploys (see README "Installation with tofu modules").
#
# This module only performs nullplatform-side registration. It does not grant
# any AWS permissions — for AUTH_TYPE=aws-avp, also apply
# specs/requirements/aws so the agent can assume a role that manages the
# Verified Permissions policy store.
################################################################################

module "endpoint_exposer" {
  source = "git::https://github.com/nullplatform/tofu-modules.git//nullplatform/service_definition?ref=${var.tofu_modules_ref}"

  nrn               = var.nrn
  repository_org    = var.repository_org
  repository_name   = var.repository_name
  repository_branch = var.repository_branch
  service_path      = "" # specs live at repo root
  service_name      = "Endpoint Exposer"
  available_links   = ["connect"]
}

module "endpoint_exposer_channel" {
  source = "git::https://github.com/nullplatform/tofu-modules.git//nullplatform/service_definition_agent_association?ref=${var.tofu_modules_ref}"

  nrn                          = var.nrn
  api_key                      = var.np_api_key
  tags_selectors               = var.tags_selectors
  service_specification_slug   = module.endpoint_exposer.service_specification_slug
  repository_service_spec_repo = "${var.repository_org}/${var.repository_name}"
  service_path                 = "" # entrypoint lives at repo root
}

module "endpoint_exposer_scope_channel" {
  count = var.enable_scope_channel ? 1 : 0

  source = "git::https://github.com/nullplatform/tofu-modules.git//nullplatform/scope_definition_agent_association?ref=${var.tofu_modules_ref}"

  nrn                      = var.nrn
  api_key                  = var.np_api_key
  tags_selectors           = var.tags_selectors
  scope_specification_id   = var.scope_specification_id
  scope_specification_slug = var.scope_specification_slug
  enabled_override         = true
  override_repo_path       = var.override_repo_path
  overrides_service_path   = var.overrides_service_path
}
