# Endpoint Exposer

A nullplatform service that manages dynamic exposure of application endpoints through public and private domains. It translates high-level route declarations into native Kubernetes resources using Istio — HTTPRoutes, AuthorizationPolicies, and RequestAuthentication — all without developers needing to touch YAML.

## What it does

Developers declare which HTTP routes they want to expose, which nullplatform scope backs each route, and which user groups are allowed to call it. The service handles the rest:

- Creates **HTTPRoutes** (Kubernetes Gateway API v1) pointing to the right backend service
- Creates **AuthorizationPolicies** enforcing group-based access control
- Creates **RequestAuthentication** resources validating JWT tokens (Cognito) or delegating to AVP

Route visibility is resolved automatically from the scope's own `visibility` attribute (`external` → public gateway, `internal` → private gateway).

### Supported auth schemes

| `AUTH_TYPE` | Mechanism |
|---|---|
| `aws-cognito` | Istio validates Cognito JWT; AuthorizationPolicies check `cognito:groups` claims |
| `aws-avp` | Amazon Verified Permissions policy store controls access |

---

## Route configuration (developer UI)

When creating or updating the service, developers configure one or more routes:

| Field | Description |
|---|---|
| **Verbs** | HTTP methods (`GET`, `POST`, `PUT`, `PATCH`, `DELETE`, `HEAD`, `OPTIONS`) |
| **Path** | Route path. Supports exact (`/api/users`), parameterized (`/api/users/{id}`), and wildcard (`/api/users/*`) |
| **Scope** | nullplatform scope slug that backs this route |
| **Authorized Groups** | Comma-separated list of groups allowed to call this route (e.g. `admin, read-only`) |

Auth configuration is **not** part of the developer UI — it is set once at the infrastructure level via agent environment variables (see below).

---

## Installation with tofu modules

### Prerequisites

- A running nullplatform agent with `kubectl` access to the cluster
- Istio installed with Gateway API CRDs
- `gateway-public` and `gateway-private` Gateway resources deployed

### 1. Use the `service_definition` module

Register the service specification and notification channel in nullplatform:

```hcl
module "endpoint_exposer" {
  source = "git::https://github.com/nullplatform/tofu-modules.git//nullplatform/service_definition?ref=<version>"

  nrn               = var.nrn
  repository_org    = "nullplatform"
  repository_name   = "services-endpoint-exposer"
  repository_branch = "main"
  service_path      = ""                        # specs live at repo root
  service_name      = "Endpoint Exposer"
  available_links   = ["connect"]
}

module "endpoint_exposer_channel" {
  source = "git::https://github.com/nullplatform/tofu-modules.git//nullplatform/service_definition_agent_association?ref=<version>"

  nrn                          = var.nrn
  api_key                      = var.np_api_key
  tags_selectors               = { "owner" = "my-agent", "environment" = "{$context.service.dimensions.environment}" }
  service_specification_slug   = module.endpoint_exposer.service_specification_slug
  repository_service_spec_repo = "nullplatform/services-endpoint-exposer"
  service_path                 = ""             # entrypoint lives at repo root
}
```

### 2. Set agent environment variables

Auth configuration is resolved at **runtime from the agent's environment**, not from the developer UI. Set these variables in the agent's `extra_envs` (Helm) or equivalent.

#### Required — global

| Variable | Description | Example |
|---|---|---|
| `AUTH_TYPE` | Authorization scheme for the entire installation | `aws-cognito` |
| `INGRESS_TYPE` | Must be `istio` | `istio` |

#### Required per environment — `aws-cognito`

One variable per nullplatform environment dimension value (uppercased):

| Variable | Description | Example |
|---|---|---|
| `COGNITO_USER_POOL_ARN_<ENV>` | ARN of the Cognito User Pool for that environment | `COGNITO_USER_POOL_ARN_PRODUCTION=arn:aws:cognito-idp:us-east-1:123456789:userpool/us-east-1_AbCdEf` |

`<ENV>` corresponds to `service.dimensions.environment` uppercased (e.g. `dev` → `DEV`, `production` → `PRODUCTION`).

#### Required per environment — `aws-avp`

| Variable | Description | Example |
|---|---|---|
| `AVP_POLICY_STORE_ARN_<ENV>` | ARN of the Amazon Verified Permissions Policy Store | `AVP_POLICY_STORE_ARN_PRODUCTION=arn:aws:verifiedpermissions::123456789:policy-store/AbCdEf` |
| `OPA_PROVIDER_NAME` | Name of the OPA ext-authz provider in the cluster | `opa-ext-authz` |

#### Optional — gateway configuration (have defaults)

| Variable | Default | Description |
|---|---|---|
| `PUBLIC_GATEWAY_NAME` | `gateway-public` | Name of the public Istio Gateway resource |
| `PRIVATE_GATEWAY_NAME` | `gateway-private` | Name of the private Istio Gateway resource |
| `GATEWAY_NAMESPACE` | `gateways` | Kubernetes namespace where Gateway resources live |

#### Example — OpenTofu agent module

```hcl
module "agent" {
  source = "git::https://github.com/nullplatform/tofu-modules.git//nullplatform/agent?ref=<version>"

  # ... other agent config ...

  extra_envs = {
    INGRESS_TYPE                     = "istio"
    AUTH_TYPE                        = "aws-cognito"
    COGNITO_USER_POOL_ARN_DEV        = "arn:aws:cognito-idp:us-east-1:123456789:userpool/us-east-1_AbCdEf"
    COGNITO_USER_POOL_ARN_PRODUCTION = "arn:aws:cognito-idp:us-east-1:123456789:userpool/us-east-1_XyZwVu"
  }
}
```

### 3. Register the scope notification channel for blue/green sync

The `container-scope-override/` directory injects a `sync_exposer` step into scope deploy workflows (initial, blue_green, switch_traffic, finalize, rollback, delete). This keeps HTTPRoutes in sync when the underlying Kubernetes service names change during a blue/green deploy.

This mechanism only activates when the scope agent entrypoint receives `--overrides-path=` pointing to the override directory. That flag must be set in a **separate scope notification channel** — it cannot come from the service channel above.

```hcl
module "endpoint_exposer_scope_channel" {
  source = "git::https://github.com/nullplatform/tofu-modules.git//nullplatform/scope_definition_agent_association?ref=<version>"

  nrn                      = var.nrn
  api_key                  = var.np_api_key
  tags_selectors           = { "owner" = "my-agent", "environment" = "{$context.service.dimensions.environment}" }
  scope_specification_id   = var.scope_specification_id   # ID of the scope spec used by apps that expose routes through this service
  scope_specification_slug = var.scope_specification_slug
  enabled_override         = true
  override_repo_path       = "/root/.np/nullplatform/services-endpoint-exposer"
  overrides_service_path   = "/container-scope-override"
}
```

Without this channel, HTTPRoutes will point to stale backend service names after a blue/green deploy and traffic will break.

---

## How auth resolution works

On every action (create / update / delete) the service:

1. Reads `AUTH_TYPE` from the agent environment
2. Reads `service.dimensions.environment` from the action context (e.g. `"dev"`)
3. Uppercases and normalizes the value → `DEV`
4. Looks up `COGNITO_USER_POOL_ARN_DEV` (or `AVP_POLICY_STORE_ARN_DEV`) via bash indirect expansion
5. Fails with a clear error if the required variable is not set

This means a single agent deployment can serve multiple environments, each with its own pool/store ARN.

---

## File structure

```
├── entrypoint/              # Action handler (service, link)
├── scripts/
│   ├── common/              # apply, manage_policies
│   ├── istio/               # build_context, build_httproute, process_routes, build_allow_policies,
│   │                        # build_request_authentication, delete_*, fetch_provider_data, config
│   ├── np/                  # update_service_results
│   └── avp/                 # AVP-specific policy management (aws-avp only)
├── specs/
│   ├── service-spec.json.tpl
│   └── links/connect.json.tpl
├── templates/istio/         # Kubernetes resource templates (httproute, authorizationpolicy, request-authentication)
├── workflows/istio/         # create.yaml, update.yaml, delete.yaml, read.yaml
├── install/tofu/            # OpenTofu module for registering the service in nullplatform
├── test/                    # BATS test suite
└── container-scope-override/ # Deployment templates for override scope agent
```

---

## Testing

```bash
./test/run-tests.sh
```

Tests use [BATS](https://github.com/bats-core/bats-core) and cover HTTPRoute generation, AuthorizationPolicy creation, context building, and apply/cleanup flows.

---

## Monitoring generated resources

```bash
# HTTPRoutes
kubectl get httproutes -n nullplatform

# AuthorizationPolicies
kubectl get authorizationpolicies -n gateways

# RequestAuthentication (Cognito JWT rules)
kubectl get requestauthentication -n gateways
```
