# Endpoint Exposer

A nullplatform service that manages dynamic exposure of application endpoints through public and private domains. It translates high-level route declarations into native Kubernetes resources using Istio — HTTPRoutes, AuthorizationPolicies, and RequestAuthentication — all without developers needing to touch YAML.

## What it does

Developers create a service for a domain, then link each application to it declaring which path it exposes, which nullplatform scope backs it, and which user groups are allowed to call it. The service handles the rest:

- Creates **HTTPRoutes** (Kubernetes Gateway API v1) pointing to the right backend service
- Creates **AuthorizationPolicies** enforcing group-based access control
- Creates **RequestAuthentication** resources validating JWT tokens (Cognito) or delegating to AVP

The gateway (public or private) is chosen on the service with its `visibility`.

### Supported auth schemes

| `AUTH_TYPE` | Mechanism |
|---|---|
| `aws-cognito` | Istio validates Cognito JWT; AuthorizationPolicies check `cognito:groups` claims |
| `aws-avp` | Amazon Verified Permissions policy store controls access |
| `none` (default) | No authentication. Only the declared routes are reachable, but anyone can call them |

#### `AUTH_TYPE=none`

This is the default when `AUTH_TYPE` is unset. Use it to expose specific endpoints of an API without authentication. Each route still gets an `ALLOW` AuthorizationPolicy (host + path + method, with no group condition), because once any `ALLOW` policy targets a gateway, Istio denies every request that matches none of them. So the declared routes are open, and the rest of the scope's endpoints stay closed on that gateway.

In this mode `Authorized Groups` is ignored and can be left empty, and no `COGNITO_*`/`AVP_*` variables or `environment` dimension are needed. No RequestAuthentication is created or deleted.

---

## Route configuration (developer UI)

Exposing endpoints takes two steps: a **service** owns a domain, and each **link** exposes one path of the linking application on that domain.

### 1. Create the service — the domain

| Field | Description |
|---|---|
| **Domain name** | Hostname the paths are exposed on, e.g. `api.example.com`. No wildcards. Fixed after creation. |
| **Visibility** | `public` attaches the domain to the public gateway, `private` to the private one. Fixed after creation. |

On create the service validates that the selected gateway has a listener for the domain and that no other service already serves links on it, checks the domain in DNS (see below), and ensures the Cognito `RequestAuthentication`. It creates no route by itself. It can only be deleted once every link is unlinked.

#### Domain DNS check

The domain must exist in DNS wherever it is hosted (Route 53, GoDaddy, Cloudflare, an internal DNS server…):

- **public** services are checked against public resolvers (`PUBLIC_DNS_RESOLVERS`, default `1.1.1.1 8.8.8.8`), so the check sees what internet clients see and not a split-horizon private view of the same zone. If none replies, the agent's resolver is used.
- **private** services are checked with the agent's own resolver: the agent runs inside the client's network, so it sees the internal DNS.

A domain that doesn't resolve fails the create, telling apart a domain that isn't registered (only the TLD answers) from a zone that lacks the record. A domain that resolves but not to the gateway's address only warns: a CDN or proxy may forward to it, but usually requests would never reach the routes. `DOMAIN_DNS_CHECK=warn` reports without failing, `off` skips the check.

### 2. Link an application — one path

| Field | Description |
|---|---|
| **Path** | Path on the service's domain. Supports exact (`/api/users`), parameterized (`/api/users/:id`) and wildcard (`/api/users/*`) |
| **Verbs** | Optional, `ALL` (any method) by default. Pick HTTP methods (`GET`, `POST`, `PUT`, `PATCH`, `DELETE`, `HEAD`, `OPTIONS`) to expose only those. `ALL` overrides any other verb selected on the same link |
| **Scope** | Optional. Slug of the linking application's scope that receives the traffic. When empty, the agent picks the application's scope in the link's dimensions whose visibility matches the service (`public` ↔ reachability `public`, `private` ↔ anything else) and that has a Kubernetes Service to route to. With several matches the pick is deterministic: active scopes first, then the oldest; the others are logged and the chosen slug is stored on the link. No match fails and asks for the slug. The form can't list the scopes: the platform doesn't pass them to the link context |
| **Authorized Groups** | Groups allowed to call the path. Required with `aws-cognito`: create and update fail without them. Optional and ignored with `AUTH_TYPE=none` |

Each link gets its own `HTTPRoute` (hostname = the service's domain) and `AuthorizationPolicies`, labeled `nullplatform.com/link-id`; unlink deletes exactly those. A path + method can be exposed by a single link per domain: a link that would overlap another one fails instead of being silently shadowed (Gateway API gives the oldest route the traffic). Updating a link replaces its route and prunes the policies it no longer needs.

Auth configuration is **not** part of the developer UI — it is set once at the infrastructure level via agent environment variables (see below). The domain + links model supports `AUTH_TYPE=aws-cognito` and `none` (`aws-avp` is not supported yet).

### Services created before the domain + links model

Services that declare their routes inline (`routes` attribute, no `domain_name`) keep working: `entrypoint/service` runs them with `workflows/istio/legacy/`, and `sync_exposer` keeps their routes in sync on deploys. Their routes are no longer editable from the UI; migrate them by creating a domain service per `(domain, visibility)` they serve and one link per route, then deleting the legacy service. While both exist, the legacy `HTTPRoute` keeps the traffic (it is older), so deleting it switches traffic to the links without a gap.

---

## Installation with tofu modules

> **The HCL in this section is illustrative, not a module to reference directly.** Every snippet below — including [`specs/install/`](./specs/install) and [`specs/requirements/aws/`](./specs/requirements/aws) — exists in this repository as a working reference implementation (and test fixture), not as a published module. Don't add `source = "git::https://github.com/nullplatform/services-endpoint-exposer.git//specs/install?ref=..."` (or `//specs/requirements/aws`) to your own project. Copy the underlying `nullplatform/tofu-modules` module calls shown below into your project's own `.tf` files and adapt the values (`nrn`, `tags_selectors`, refs, etc.) instead. This keeps your project's module versions, api keys, and scope wiring under your own control instead of an indirect reference to this repo.

### Prerequisites

- A running nullplatform agent with `kubectl` access to the cluster
- Istio installed with Gateway API CRDs
- `gateway-public` and `gateway-private` Gateway resources deployed

### 1. Register the service specification and its notification channel

The following two module calls (copied from [`specs/install/main.tf`](./specs/install/main.tf) — read that file for the definitive, up-to-date version) register this repo's service spec/entrypoint with nullplatform and wire a notification channel so an agent picks up the service's own `create`/`update`/`delete`/`link` actions:

```hcl
module "service_definition_endpoint_exposer" {
  source = "git::https://github.com/nullplatform/tofu-modules.git//nullplatform/service_definition?ref=<tofu-modules version>"

  nrn               = var.nrn
  repository_org    = "nullplatform"
  repository_name   = "services-endpoint-exposer"
  repository_branch = "main" # or the branch you're testing
  service_path      = "" # specs live at repo root
  service_name      = "Endpoint Exposer"
  available_links   = ["connect"]
}

module "service_definition_channel_association_endpoint_exposer" {
  source = "git::https://github.com/nullplatform/tofu-modules.git//nullplatform/service_definition_agent_association?ref=<tofu-modules version>"

  nrn                           = var.nrn
  api_key                       = var.np_api_key
  tags_selectors                = { "owner" = "my-agent", "environment" = "{$context.service.dimensions.environment}" }
  service_specification_slug    = module.service_definition_endpoint_exposer.service_specification_slug
  repository_service_spec_repo  = "nullplatform/services-endpoint-exposer"
  service_path                  = "" # entrypoint lives at repo root
}
```

Pin `<tofu-modules version>` to a real tag from [`nullplatform/tofu-modules` releases](https://github.com/nullplatform/tofu-modules/releases) — check its `CHANGELOG.md` for breaking changes before bumping.

### 2. Set agent environment variables

Auth configuration is resolved at **runtime from the agent's environment**, not from the developer UI. Set these variables in the agent's `extra_envs` (Helm) or equivalent.

#### Required — global

| Variable | Description | Example |
|---|---|---|
| `INGRESS_TYPE` | Must be `istio` | `istio` |

#### Optional — global

| Variable | Default | Description |
|---|---|---|
| `AUTH_TYPE` | `none` | Authorization scheme for the entire installation: `aws-cognito`, `aws-avp` or `none`. Unset means no authentication for services that never had it (see below) |
| `DOMAIN_DNS_CHECK` | `enforce` | Domain DNS check on service create/update: `enforce` fails when the domain doesn't resolve, `warn` only reports, `off` skips it |
| `PUBLIC_DNS_RESOLVERS` | `1.1.1.1 8.8.8.8` | Space-separated resolvers used to check public domains; the first that replies is used |

Leaving `AUTH_TYPE` unset never removes auth from an existing service. Each create/update stores the scheme in the service's `auth_type` attribute, and when the variable is missing, create/update **fail** for any service stored with auth (or, for services created before `auth_type` existed, whose stored routes have authorized groups). Set `AUTH_TYPE=none` explicitly to drop auth on purpose. Deletes always proceed.

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

With `aws-avp`, the service also calls the Amazon Verified Permissions API directly, so the agent needs AWS credentials for that. [`specs/requirements/aws`](./specs/requirements/aws) is a reference implementation of the IAM role the agent assumes — copy its resources into your own project once per cluster rather than sourcing it from this repo (see the note at the top of this section), then pass the role output to the agent:

```hcl
# Illustrative — read specs/requirements/aws/main.tf and copy its resources
# into your own project instead of sourcing this path directly.
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

### 3. Register the `container-scope-override` on the target scope

The `container-scope-override/` directory injects a `sync_exposer` step into scope deploy workflows (initial, blue_green, switch_traffic, finalize, rollback, delete). This keeps HTTPRoutes in sync when the underlying Kubernetes service names change during a blue/green deploy: it re-runs the update action of every active link of the application whose scope is the one being deployed (and the update of legacy services).

This mechanism only activates when the scope agent entrypoint receives `--overrides-path=` pointing to the override directory. That flag must be set on the notification channel that fires for the **target scope** — i.e. the scope specification used by apps that expose routes through this service — not on the service channel from step 1 above.

`enabled_override` / `override_repo_path` / `overrides_service_path` are extra inputs on the standard `nullplatform/tofu-modules//nullplatform/scope_definition_agent_association` module — not a separate mechanism. **A given scope specification should only ever have one `scope_definition_agent_association` module call.** If your project already registers a notification channel for that scope (it almost always does — that's what makes the scope's own deploy/lifecycle actions work at all), add these three inputs to that **same** module call:

```hcl
module "scope_definition_agent_association" {
  source                   = "git::https://github.com/nullplatform/tofu-modules.git//nullplatform/scope_definition_agent_association?ref=<tofu-modules version>"
  nrn                      = var.nrn
  tags_selectors           = var.tags_selectors
  api_key                  = module.scope_definition_agent_association_api_key.api_key
  scope_specification_id   = var.scope_specification_id
  scope_specification_slug = var.scope_specification_slug

  # container-scope-override for services-endpoint-exposer
  enabled_override        = true
  override_repo_path      = "/root/.np/nullplatform/services-endpoint-exposer"
  overrides_service_path  = "/container-scope-override"
}
```

> **Do not add a second `scope_definition_agent_association` call for the same scope just to carry the override** — e.g. by calling `specs/install`'s wrapper with `enable_scope_channel = true` (or writing your own `module "endpoint_exposer_scope_channel" { ... }`) alongside a module that already registers that scope's channel. The channel's `filters` are built solely from `scope_specification_slug` / `scope_specification_id`; `enabled_override` doesn't change them, it only appends `--overrides-path=...` to the channel's `cmdline`. Two module calls pointed at the same scope produce two `nullplatform_notification_channel` resources with **identical filters**, so every action notification for that scope fires both channels — the scope's base entrypoint logic runs twice, once per channel, and one of the two invocations additionally triggers the override sync. Only register a brand-new, dedicated channel for the override when the target scope has **no** existing agent association in your project at all.

Without this override wired into the scope's channel, HTTPRoutes will point to stale backend service names after a blue/green deploy and traffic will break.

---

## How auth resolution works

On every action (create / update / delete) the service, unless `AUTH_TYPE=none`:

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
│   ├── install/             # Reference OpenTofu implementation of the nullplatform registration (see "Installation with tofu modules" — illustrative, not meant to be sourced directly)
│   └── requirements/aws/    # Reference OpenTofu implementation of the AVP IAM role (aws-avp only — same caveat as install/)
├── templates/istio/         # Kubernetes resource templates (httproute, authorizationpolicy, request-authentication)
├── workflows/istio/         # service: create/update/delete/read · link: link (create/update), unlink
│   └── legacy/              # services with inline routes (pre domain + links model)
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
