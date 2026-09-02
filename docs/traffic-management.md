# Traffic management

Beyond access control, a route can shape the traffic that reaches it: match on
request headers, rewrite the request before it hits the backend, split traffic
across scopes by weight, and choose which gateway serves it. Every field is
optional — a route that declares none behaves exactly as it did before these
fields existed.

All of it lands on fields the Kubernetes Gateway API already has. The service
writes no `VirtualService` and no `EnvoyFilter`, and the containers behind the
route are untouched.

## The fields

| Field | Type | What it does |
|---|---|---|
| `path` | string | Route path. Exact (`/users`), parameterized (`/users/{id}`), or prefix (`/users/*`) |
| `methods` | array | HTTP verbs the route answers |
| `scope` | string | nullplatform scope that backs the route |
| `groups` | array | Groups allowed to call it. **Empty or absent means the route is open** |
| `visibility` | `public` \| `internal` | Which gateway serves the route. Absent inherits the scope's own visibility |
| `weight` | 0-100 | Share of traffic when several routes declare the same path and method |
| `headers` | array of `{name, value, type}` | The route only matches when every listed header matches. `type` is `Exact` (default) or `RegularExpression` |
| `rewrite` | `{path, hostname}` | Replaces the matched path prefix and/or the hostname before the request reaches the backend |
| `request_headers` | `{set, remove}` | Headers added to or removed from the request on its way to the backend |

`request_headers` is spelled in snake_case on purpose: the platform normalizes
the keys of an action's parameters, so a camelCase property is stored under one
spelling and delivered to the workflow under the other, and an entity holding
both spellings rejects every later write. Instances created before the rename
kept the camelCase spelling and still work — the workflow reads either.

## Open by default, then closed

Leave `groups` empty and the generated `AuthorizationPolicy` carries no `when`
block: an ALLOW on host, path and method, and the route answers without a
token. Add a group later and the same route closes, with no change to the
application or its deployment.

```yaml
# groups: []
rules:
  - to:
      - operation:
          hosts: ["api.example.com"]
          paths: ["/users"]
          methods: ["GET"]
```

Watch out for allow-all policies created elsewhere in the cluster: an
`AuthorizationPolicy` that already permits the path masks whatever the route
declares, and the route looks open when it is not the one deciding.

## Match on request header

A route with `headers` only matches requests carrying all of them, so a share
of the traffic on an existing path can be tagged and treated differently.

```json
{
  "path": "/api/*", "methods": ["GET"], "scope": "canary",
  "headers": [{ "name": "x-canary", "value": "true", "type": "Exact" }]
}
```

What the route does not take falls through to whatever else serves that
hostname — typically the scope's own route, which publishes a catch-all on
`/`. That is what makes a header canary work without declaring the baseline.

Two limits worth knowing before designing around it:

- A rule is identified by **path and method**, headers excluded, so a baseline
  and a canary on the same path and method cannot both be declared on one
  instance: the second replaces the first.
- The `AuthorizationPolicy` host comes from the route's scope, while HTTPRoute
  rules are not host-scoped. Tagging traffic that arrives on scope A's domain
  and sending it to scope B puts the policy on B's domain, and the request on
  A's domain is denied by default.

## Weights across scopes

Several routes that declare the same path and method, each pointing at a
different scope, become **one rule with several weighted backends**. Envoy does
the split with relative weights.

```json
[
  { "path": "/users", "methods": ["GET"], "scope": "v1", "weight": 70 },
  { "path": "/users", "methods": ["GET"], "scope": "v2", "weight": 30 }
]
```

Declare a weight on **every** route of the group. A backend without one is not
zero: Gateway API assumes `1`, so 30 against an omitted weight splits ~97/3,
not 70/30.

Weights are ignored while a blue/green deployment is in progress on the scope —
the deployment's own annotation decides, by design.

## Rewrite

`rewrite.path` replaces the matched prefix; `rewrite.hostname` replaces the
host. `request_headers` adds and removes request headers. Both become HTTPRoute
`filters`.

```json
{
  "path": "/old/*", "methods": ["GET"], "scope": "api",
  "rewrite": { "path": "/new" },
  "request_headers": {
    "set": [{ "name": "x-source", "value": "gateway" }],
    "remove": ["x-internal-debug"]
  }
}
```

`/old/thing` reaches the backend as `/new/thing`. Gateway API rewrites by
prefix or by full path — **not by regex**; a rewrite with a capture needs an
EnvoyFilter, which this service does not write. There is no response header
modifier either.

## Visibility per route

`visibility` overrides the scope's own attribute for that route alone, so the
same scope can serve public and internal routes at once. Internal routes are
grouped into their own HTTPRoute attached to the private gateway, with their
policies selecting that gateway.

The private HTTPRoute takes the scope's domain, the same one the public route
uses — the gateway is what separates them. A distinct internal hostname would
need the domain of private routes to become a parameter.

## Testing

Unit tests cover the translation of every field into its Gateway API
equivalent, and need no cluster:

```bash
bats test/test_traffic_management.bats test/test_route_visibility.bats test/test_authorization_policy.bats
```

Against a deployed instance, the conformance runner reads the routes the
instance actually carries and asserts what each declared field promises —
including that a header-matched route does not answer without its header, and
that shares of traffic land within tolerance:

```bash
test/e2e/route_conformance.sh --service-id <uuid> --dry-run
test/e2e/route_conformance.sh --service-id <uuid> --samples 30
```

Header injection is not observable from outside the cluster, so the runner
reports it as SKIP. To verify it, read the compiled route config of the
gateway, which is stronger evidence than the manifest — it shows what the
proxy accepted:

```bash
kubectl exec -n <gateway-namespace> <gateway-pod> -- curl -s localhost:15000/config_dump \
  | jq '[.. | objects | select(has("request_headers_to_add"))
         | {match: .match.path_separated_prefix, add: [.request_headers_to_add[].header.key]}]'
```
