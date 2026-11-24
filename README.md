# Endpoint Exposer

A nullplatform service that manages dynamic exposure of application endpoints through public and private domains. It translates high-level route declarations into native Kubernetes resources using Istio — HTTPRoutes, AuthorizationPolicies, and RequestAuthentication — all without developers needing to touch YAML.

## What it does

Developers create a service for a domain, then link each application to it declaring which paths it exposes, which nullplatform scope backs each one, and which user groups are allowed to call them. The service handles the rest:

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

No JWT is validated, so groups can't be enforced: a route that declares them is still open to anyone. The create or update succeeds and logs a warning naming those routes, e.g. `WARNING: AUTH_TYPE=none does not authenticate requests: the authorized groups are ignored and these routes are open to anyone: /admin`. This does not fail the action or the deploy sync. To restrict such a route, set `AUTH_TYPE` to a scheme that validates tokens, or drop the groups so the route's configuration says what it does.

---

## Route configuration (developer UI)

Exposing endpoints takes two steps: a **service** owns a domain, and each **link** exposes the paths of the linking application on that domain.

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

A domain that doesn't resolve fails the create, telling apart a domain that isn't registered (only the TLD answers) from a zone that lacks the record. A domain that resolves but not to the gateway's address only warns: a CDN or proxy may forward to it, but usually requests would never reach the routes. A resolver that doesn't answer is reported as such (dig exits non-zero, e.g. 9 when no server is reachable), never as a missing domain. `DOMAIN_DNS_CHECK=warn` reports without failing, `off` skips the check. With `enforce` the record must exist before the service is created (a zone without a wildcard record needs the entry first); `warn` lets the create go through and reports the missing record.

The check uses `dig`. The agent images don't always ship it: without `dig` it uses `getent ahosts`, which only asks the agent's resolver (also for public domains) and can't tell a missing record from a resolver that doesn't answer, nor name the zone. With neither, it warns and skips the check, even with `enforce`.

### 2. Link an application — its routes

nullplatform allows a single link per application and dimensions, so the link carries a **list of routes**, one item per path the application exposes on the domain:

| Route field | Description |
|---|---|
| **Path** | Path on the service's domain. Supports exact (`/api/users`), parameterized (`/api/users/:id`) and wildcard (`/api/users/*`), also combined (`/api/users/:id/files/*`). A parameter is a segment that starts with `:` (`/users/:id`); a `:` anywhere else is a literal character (`/v1/things:batchGet`). With parameters, `*` can only be the last segment; other forms fail the link. A wildcard authorizes what's below the prefix, not the prefix itself: with `/api/users/*`, a request to `/api/users` answers 403, so add it as its own route if needed. Each path can appear once per link |
| **Verbs** | Optional, `ALL` (any method) by default. Pick HTTP methods (`GET`, `POST`, `PUT`, `PATCH`, `DELETE`, `HEAD`, `OPTIONS`) to expose only those. `ALL` overrides any other verb selected on the same route |
| **Scope** | Optional. Slug of the linking application's scope that receives the traffic. When empty, the agent picks (once for the whole link) the application's scope in the link's dimensions whose visibility matches the service (`public` ↔ reachability `public`, `private` ↔ anything else) and that has a Kubernetes Service to route to. A single active match is used, even next to inactive ones; with no active match, a single inactive one is used. Its slug is stored on the link. Several active matches, or several inactive ones and no active one, fail and ask for the slug, so the link never guesses between scopes. No match fails too. The form can't list the scopes: the platform doesn't pass them to the link context |
| **Authorized Groups** | Groups allowed to call the path. Required with `aws-cognito`: create and update fail without them. Ignored with `AUTH_TYPE=none`: the route is open to anyone, and create/update log a `WARNING` naming the routes whose groups were dropped |

Each link gets its own `HTTPRoute` (hostname = the service's domain, one rule per route) and `AuthorizationPolicies`, labeled `nullplatform.com/link-id`; unlink deletes exactly those. A path + method can be exposed by a single link per domain: a link with a route that would overlap another link fails instead of being silently shadowed (Gateway API gives the oldest route the traffic).

Updating a link replaces its `HTTPRoute` in place and prunes the policies it no longer needs, so removing one route takes down only that path: the others keep serving. To retire a scope, remove the routes that target it first, then delete the scope. Links created before the routes list (a single top-level `path`) keep working and are stored as a one-route list on their next update.

Auth configuration is **not** part of the developer UI — it is set once at the infrastructure level via agent environment variables (see below). The domain + links model supports `AUTH_TYPE=aws-cognito` and `none` (`aws-avp` is not supported yet).

### Services created before the domain + links model

Always fill `domain_name` (or `routes`) when creating a service. The platform has been seen accepting an empty service and leaving it `pending` with no action to run, and such a service can't be deleted until it reaches `active`, `failed`, `cancelled` or `archived`. A `routes` update on a service that has a `domain_name` is only stored: routes are served by the links of a domain service, so no `HTTPRoute` is created for them.

Services that declare their routes inline (`routes` attribute, no `domain_name`) keep working: `entrypoint/service` runs them with `workflows/istio/legacy/`, and `sync_exposer` keeps their routes in sync on deploys. The spec requires `domain_name` or `routes` (`anyOf`), not `domain_name` alone: the platform copies the schema to the update action, and the deploy sync updates these services with `{routes}` only. Their routes are no longer editable from the UI; migrate them by creating a domain service per `(domain, visibility)` they serve and one link per route, then deleting the legacy service. While both exist, the legacy `HTTPRoute` keeps the traffic (it is older), so deleting it switches traffic to the links without a gap.

---

## Install in your organization

The service is published once as the package `np-http-route-access-control` (specification "Endpoint Exposer"), visible to every organization. You do not copy its specs: you install the package and use it read-only.

How installing a package works, how it coexists with a copy you registered, how to upgrade, and when to fork instead are in the [package installation guide](https://docs.nullplatform.com/docs/packages/install); this section has what is specific to this service.

### Prerequisites

- A running nullplatform agent with `kubectl` access to the cluster, `public.ecr.aws/nullplatform/*` in its `worker.allowedRegistries` and `np-http-route-access-control` in its `worker_orchestrated_packages` (the worker then runs as the agent's service account, the one with the RBAC in step 2)
- Istio installed with Gateway API CRDs (1.22+ for routes with `:parameters`, which use AuthorizationPolicy path templates)
- `gateway-public` and `gateway-private` Gateway resources deployed

### 1. Install the package

Pick ONE release of this repository (the latest is on its [releases page](https://github.com/nullplatform/services-endpoint-exposer/releases)) and install its version; with `aws-avp`, the requirements module of step 2 is referenced at the same release.

```hcl
# ── nullplatform layer ───────────────────────────────────────────────
# For a service the installation is the whole nullplatform side, channel included.
module "endpoint_exposer" {
  source = "git::https://github.com/nullplatform/tofu-modules.git//nullplatform/service_package_installation?ref=v9.16.0"

  nrn                  = var.nrn
  package_slug         = "np-http-route-access-control"
  package_version      = "X.Y.Z" # the same release, without the v
  agent_tags_selectors = { cluster = "runtime" } # must match the agent's TAGS
}
# Keeping channels in a separate bindings layer instead? Use
# nullplatform/package_installation here and service_definition_agent_association
# there, with package_slug = "np-http-route-access-control".
```

The authorization scheme is chosen on the agent, in `AUTH_TYPE` (step 2): the package carries no install-time variable for it. `aws-avp` works only for services created before the domain + links model. To upgrade, move `package_version` to the new release. See tofu-modules' [`service_package_installation`](https://github.com/nullplatform/tofu-modules/tree/main/nullplatform/service_package_installation) for its inputs and outputs.

> **Coming from a copy registered with the former `specs/install`?** Its `auth_type` variable is now the agent's `AUTH_TYPE`: set it to the same value. If the agent has none set, check the stored services before choosing `none`: unset is not the same as `none` (see [step 2](#2-set-agent-environment-variables)), and `none` drops auth from services that have it. The copy itself keeps working; if you sourced `specs/install` as a module, pin its `?ref` to a release that still has it.

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
| `DOMAIN_DNS_CHECK` | `enforce` | Domain DNS check on service create/update: `enforce` fails when the domain doesn't resolve, `warn` only reports, `off` skips it. Uses `dig`, else `getent` (agent's resolver only), else skips with a warning ([Domain DNS check](#domain-dns-check)) |
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

With `aws-avp`, the service also calls the Amazon Verified Permissions API directly, so the agent needs AWS credentials for that. [`specs/requirements/aws`](./specs/requirements/aws) creates the IAM role the agent assumes, once per cluster, at the same release as the package; pass its output to the agent:

```hcl
module "endpoint_exposer_requirements" {
  source = "git::https://github.com/nullplatform/services-endpoint-exposer.git//specs/requirements/aws?ref=vX.Y.Z"

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

#### Optional — applications in their own namespaces

Each HTTPRoute is created in the namespace of the Services it routes to, so no ReferenceGrant is needed. The namespace of a scope is resolved by `scripts/istio/resolve_scope_namespace`, in this order:

1. `NAMESPACE_OVERRIDE`, when set on the agent or channel (e.g. `{context.tags.namespace}`, the same value the scope agent uses).
2. The namespace of the platform's Services whose selector has the scope's `scope_id`, searched across the cluster.
3. `K8S_NAMESPACE` (default `nullplatform`), when the scope has no Service yet. Legacy services (routes on the service) ignore `K8S_NAMESPACE` here and always use `nullplatform`.

A `NAMESPACE_OVERRIDE` that arrives uninterpolated (it still contains `{` or `}`, e.g. a channel template written without `$`) is ignored with a warning. A scope with Services in two namespaces fails. If the Services can't be listed across the cluster, the action fails with kubectl's error: the default namespace is never assumed, since a route whose Service isn't seen there would be removed.

Only the Services the scope agent creates count, here and when picking the backend: their selector carries `nullplatform: "true"`, `scope_id` and `deployment_id`. Another Service that selects a `scope_id` (a test echo, a hand-made one) is never routed to. A route whose scope has no such Service yet (not deployed, or failed) is left out of the HTTPRoute with a warning, so the gateway answers 404 on it until the scope is deployed and the deploy sync updates the exposer; a link with no backend at all gets no HTTPRoute. The link also logs a warning when its scope isn't `active` or has no active deployment.

All the routes of one link (or of one legacy service) must point to scopes in the same namespace. The links of one domain can live in different namespaces, so the link conflict and domain-owner checks read HTTPRoutes across the cluster.

Requirements:

- **RBAC**: the agent needs cluster-wide `list` on `services`, and cluster-wide `get`, `list`, `create`, `patch` and `delete` on `httproutes` (unlink, service delete and the cleanup of an HTTPRoute that moved namespace delete HTTPRoutes in every namespace). Missing cluster-wide access is handled the same way everywhere: the action fails with kubectl's error. It is never worked around with a single namespace, which could remove a working route or miss a conflict. For example:

  ```yaml
  apiVersion: rbac.authorization.k8s.io/v1
  kind: ClusterRole
  metadata:
    name: endpoint-exposer
  rules:
    - apiGroups: [""]
      resources: ["services"]
      verbs: ["list"]
    - apiGroups: ["gateway.networking.k8s.io"]
      resources: ["httproutes"]
      verbs: ["get", "list", "create", "patch", "delete"]
  ---
  apiVersion: rbac.authorization.k8s.io/v1
  kind: ClusterRoleBinding
  metadata:
    name: endpoint-exposer
  roleRef:
    apiGroup: rbac.authorization.k8s.io
    kind: ClusterRole
    name: endpoint-exposer
  subjects:
    - kind: ServiceAccount
      name: <agent service account>
      namespace: <agent namespace>
  ```

  The AuthorizationPolicies and RequestAuthentications stay in the gateway namespace, as before.
- **Gateway listeners** must accept routes from the applications' namespaces: `allowedRoutes.namespaces.from: All`, or `Selector` with the applications' namespaces labeled to match it. The Gateway API default, `Same`, only accepts routes from the gateway's own namespace, so an HTTPRoute next to the app stays unaccepted and its paths answer 404.

> **Upgrade note:** installations whose agent only has a namespaced Role (e.g. on `nullplatform`) can no longer create, update or delete domain services, links (unlink included) or legacy services, and the deploy sync fails the scope deploys that have active exposers: all of these fail until the agent gets the cluster-wide access above.

#### Example — OpenTofu agent module

```hcl
module "agent" {
  source = "git::https://github.com/nullplatform/tofu-modules.git//nullplatform/agent?ref=<version>"

  # ... other agent config ...

  extra_envs = {
    INGRESS_TYPE                     = "istio"
    AUTH_TYPE                        = "aws-cognito" # the scheme chosen in step 1
    COGNITO_USER_POOL_ARN_DEV        = "arn:aws:cognito-idp:us-east-1:123456789:userpool/us-east-1_AbCdEf"
    COGNITO_USER_POOL_ARN_PRODUCTION = "arn:aws:cognito-idp:us-east-1:123456789:userpool/us-east-1_XyZwVu"
  }
}
```

### 3. Register the `container-scope-override` on the target scope

The `container-scope-override/` directory injects a `sync_exposer` step into scope deploy workflows (initial, blue_green, switch_traffic, finalize, rollback, delete). This keeps HTTPRoutes in sync when the underlying Kubernetes service names change during a blue/green deploy: it re-runs the update action of every active or failed link of the application with a route on the scope being deployed (and the update of legacy services). Failed ones are included because a link left failed by a refused update still has its previous HTTPRoute, which would keep pointing at a deleted Service.

The step fails the deploy when an np call fails (it can't tell what to update), when the update of an active link or service is refused or ends failed, and when an update times out. A link or service that was already failed and whose update the platform refuses or fails again (e.g. a link whose create never succeeded) is only reported.

The step finds the exposer by its service specification slug. By default it looks up `np-http-route-access-control` (the installed package), `http-route-access-control` (the default in `container-scope-override/values.yaml`, the slug of a copy registered from `specs/service-spec.json.tpl`) and `endpoint-exposer` (a copy registered through the `service_definition` module, which derives it from the name). The same spec listed more than once counts as one. If more than one is visible, the step syncs the one the application's exposers use, and an application without exposers deploys as usual. Only an application with exposers under more than one of them fails, asking for `EXPOSER_SERVICE_SPECIFICATION_SLUG` in the agent environment, which names the one to sync; set it too for a spec registered under any other slug. Without a matching spec the step logs `WARNING: no service specification with slug ...` and skips the sync, and the deploy passes: an application that never installed the exposer goes through here on every deploy.

This mechanism only activates when the entrypoint of the **target scope** (the scope specification used by apps that expose routes through this service, not the service channel from step 1) receives `--overrides-path=` pointing to the override directory. How it gets there depends on how the agent runs the scope:

- **Legacy agent** (the agent clones repositories and runs the scope itself): through the scope's notification channel, below.
- **Worker orchestrator** (`worker_orchestrator = true`, the scope runs as a `package-exec` worker): through the worker pod, see [Worker orchestrator mode](#worker-orchestrator-mode).

#### Legacy agent

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

> **Do not add a second `scope_definition_agent_association` call for the same scope just to carry the override** — e.g. by writing your own `module "endpoint_exposer_scope_channel" { ... }` alongside a module that already registers that scope's channel. The channel's `filters` are built solely from `scope_specification_slug` / `scope_specification_id`; `enabled_override` doesn't change them, it only appends `--overrides-path=...` to the channel's `cmdline`. Two module calls pointed at the same scope produce two `nullplatform_notification_channel` resources with **identical filters**, so every action notification for that scope fires both channels — the scope's base entrypoint logic runs twice, once per channel, and one of the two invocations additionally triggers the override sync. Only register a brand-new, dedicated channel for the override when the target scope has **no** existing agent association in your project at all.

#### Worker orchestrator mode

With `worker_orchestrator = true` the inputs above do nothing: `scope_definition_agent_association` only appends `--overrides-path` in the legacy branch, and the worker runs the Containers scope image, which doesn't ship `container-scope-override/`. Wire the override into the worker pod instead. The scope images start with `worker-bridge`, which reads `NP_OVERRIDES_PATH` (comma-separated) from the pod environment and passes each entry to the entrypoint as `--overrides-path=`.

Add a patch for the `containers` package to the agent module's `worker.patches`: an init container fetches this repository's release into a volume, and `NP_OVERRIDES_PATH` points the `worker` container at `container-scope-override/` inside it. Use the same release as the installed exposer package.

```hcl
module "agent" {
  # ...
  worker_orchestrator = true

  worker = {
    patches = [
      {
        target = { package = "containers" }
        merge = {
          spec = {
            volumes = [{ name = "exposer-override", emptyDir = {} }]
            initContainers = [{
              name         = "fetch-exposer-override"
              image        = "public.ecr.aws/docker/library/alpine:3.20"
              command      = ["sh", "-c", "wget -qO- https://github.com/nullplatform/services-endpoint-exposer/archive/refs/tags/${var.endpoint_exposer_version}.tar.gz | tar -xzC /overrides --strip-components=1"]
              volumeMounts = [{ name = "exposer-override", mountPath = "/overrides" }]
            }]
            containers = [{
              name         = "worker"
              volumeMounts = [{ name = "exposer-override", mountPath = "/app/overrides/exposer", readOnly = true }]
              env          = [{ name = "NP_OVERRIDES_PATH", value = "/app/overrides/exposer/container-scope-override" }]
            }]
          }
        }
      },
    ]
  }
}
```

`endpoint_exposer_version` is a release tag of this repository (e.g. `v2.2.0`). The patch is a strategic merge, so the `env` entry joins the worker's other variables by name. If the package has a different name in your installation, adjust `target.package`.

- The init container runs on every worker start. If GitHub can't be reached, the worker stays in `Init` and every action of the Containers scope is blocked until it can.
- After a restart, the agent adopts an existing worker Deployment as it is. A changed patch applies on the package's next action, or when the idle reaper recycles the worker.

Without this override wired into the target scope, HTTPRoutes will point to stale backend service names after a blue/green deploy and traffic will break.

## How the package is published

Every release publishes a new revision of the package from this repository, in the same run that pushes the worker image ([`.github/workflows/release.yml`](./.github/workflows/release.yml)): the `publish-package` job applies [`publish`](./publish), a stack on tofu-modules' `service_package_publish`, which pins this tag's specs and the image by digest. The package version is the release tag, as for the image. The stack keeps its state where the organization secrets `PACKAGE_STATE_AWS_ACCOUNT_ID`, `PACKAGE_TFSTATE_BUCKET` and `PACKAGE_TFSTATE_REGION` point; the state role is `github-actions-<repository>-package-state` in that account, by convention.

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
│   └── requirements/aws/    # IAM role for the Verified Permissions calls (aws-avp only)
├── publish/                 # publishes the service as a package (release workflow only)
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
