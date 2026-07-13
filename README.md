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

### 1. Apply the `specs/install` module

[`specs/install/`](./specs/install) wraps the `service_definition` and `service_definition_agent_association` tofu-modules and registers the service specification + notification channel in nullplatform:

```hcl
module "endpoint_exposer_install" {
  source = "git::https://github.com/nullplatform/services-endpoint-exposer.git//specs/install?ref=main"

  nrn            = var.nrn
  np_api_key     = var.np_api_key
  tags_selectors = { "owner" = "my-agent", "environment" = "{$context.service.dimensions.environment}" }
}
```

See [`specs/install/variables.tf`](./specs/install/variables.tf) for the full set of inputs (repository overrides, `tofu_modules_ref` pin, and the `enable_scope_channel` flag covered in step 3 below).

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

##### Reading the JWT from a cookie instead of a header

By default, Istio only looks for the Cognito JWT in the `Authorization: Bearer <token>` header (or an `access_token` query param). If the frontend instead sends the token as a cookie (e.g. `id_token`), set:

| Variable | Description | Example |
|---|---|---|
| `COGNITO_TOKEN_COOKIE_NAME` | Name of the cookie holding the Cognito `id_token`. When unset, falls back to the default header/query-param extraction. | `COGNITO_TOKEN_COOKIE_NAME=id_token` |

This is global (applies to every environment's `RequestAuthentication`), not per-environment. Only the JWT itself (Cognito's `id_token`) can be validated this way — the `refresh_token` is an opaque token, not a JWT, and isn't usable here.

#### Required per environment — `aws-avp`

| Variable | Description | Example |
|---|---|---|
| `AVP_POLICY_STORE_ARN_<ENV>` | ARN of the Amazon Verified Permissions Policy Store | `AVP_POLICY_STORE_ARN_PRODUCTION=arn:aws:verifiedpermissions::123456789:policy-store/AbCdEf` |
| `OPA_PROVIDER_NAME` | Name of the OPA ext-authz provider in the cluster | `opa-ext-authz` |

With `aws-avp`, the service also calls the Amazon Verified Permissions API directly, so the agent needs AWS credentials for that. Apply [`specs/requirements/aws`](./specs/requirements/aws) once per cluster to create the IAM role the agent assumes, then pass its output to the agent:

```hcl
module "endpoint_exposer_requirements" {
  source = "git::https://github.com/nullplatform/services-endpoint-exposer.git//specs/requirements/aws?ref=main"

  cluster_name = var.cluster_name
}
```

`aws-cognito` makes no AWS API calls (Istio validates the JWT against Cognito's JWKS endpoint directly), so this module is not needed in that mode.

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

Set `enable_scope_channel = true` on the same `specs/install` module from step 1, along with the target scope specification:

```hcl
module "endpoint_exposer_install" {
  source = "git::https://github.com/nullplatform/services-endpoint-exposer.git//specs/install?ref=main"

  nrn            = var.nrn
  np_api_key     = var.np_api_key
  tags_selectors = { "owner" = "my-agent", "environment" = "{$context.service.dimensions.environment}" }

  enable_scope_channel     = true
  scope_specification_id   = var.scope_specification_id # ID of the scope spec used by apps that expose routes through this service
  scope_specification_slug = var.scope_specification_slug
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
│   ├── links/connect.json.tpl
│   ├── install/             # OpenTofu module: registers the service in nullplatform (service + notification channels)
│   └── requirements/aws/    # OpenTofu module: IAM role the agent assumes to manage AVP (aws-avp only)
├── templates/istio/         # Kubernetes resource templates (httproute, authorizationpolicy, request-authentication)
├── workflows/istio/         # create.yaml, update.yaml, delete.yaml, read.yaml
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
