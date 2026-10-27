#!/usr/bin/env bats

# Domain + links model: the service declares domain_name/visibility and each link
# exposes one path of the linking application on that domain.

load helpers

setup() {
  export TEST_TEMP_DIR="$(mktemp -d)"
  export OUTPUT_DIR="$TEST_TEMP_DIR/output"
  mkdir -p "$OUTPUT_DIR"
  export SERVICE_PATH="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

  load_bats_support_libraries

  unset NP_ACTION_CONTEXT NAMESPACE_OVERRIDE K8S_NAMESPACE
  export AUTH_TYPE="aws-cognito"
  export COGNITO_USER_POOL_ARN_DEV="arn:aws:cognito-idp:us-east-1:123456789012:userpool/us-east-1_AbCdEf"
  export CONTEXT="$(load_fixture link-notification)"

  # No scopes or Services unless a test sets them (scope_env): the link's HTTPRoute
  # stays in the default namespace.
  export NP_SCOPE_LIST_FILE="$TEST_TEMP_DIR/scopes.json" KUBECTL_SERVICES_FILE="$TEST_TEMP_DIR/services.json"
  echo '{"results": []}' > "$NP_SCOPE_LIST_FILE"
  echo '{"items": []}' > "$KUBECTL_SERVICES_FILE"

  # np mock: canned responses from files, every call logged
  cat > "$TEST_TEMP_DIR/np" << 'EOF'
#!/bin/bash
echo "np $*" >> "$TEST_TEMP_DIR/np.log"
case "$1 $2" in
  "service read") cat "$NP_SERVICE_READ_FILE" ;;
  "link list")    cat "$NP_LINK_LIST_FILE" ;;
  "scope list")   cat "$NP_SCOPE_LIST_FILE" ;;
  "link action")
    while [[ $# -gt 0 ]]; do
      [[ "$1" == "--results" ]] && echo "$2" > "$TEST_TEMP_DIR/link-action-results.json"
      shift
    done
    ;;
  "link patch")
    while [[ $# -gt 0 ]]; do
      [[ "$1" == "--body" ]] && echo "$2" > "$TEST_TEMP_DIR/link-patch-body.json"
      shift
    done
    ;;
esac
EOF

  # kubectl mock: canned responses from files, every call logged
  cat > "$TEST_TEMP_DIR/kubectl" << 'EOF'
#!/bin/bash
echo "kubectl $*" >> "$TEST_TEMP_DIR/kubectl.log"
case "$1 $2" in
  "get gateway")             cat "$KUBECTL_GATEWAY_FILE" ;;
  "get httproute")           cat "$KUBECTL_HTTPROUTES_FILE" ;;
  "get authorizationpolicy") cat "$KUBECTL_AUTHZ_NAMES_FILE" ;;
  "get services")            cat "$KUBECTL_SERVICES_FILE" ;;
esac
EOF
  chmod +x "$TEST_TEMP_DIR/np" "$TEST_TEMP_DIR/kubectl"
  export PATH="$TEST_TEMP_DIR:$PATH"
}

teardown() {
  if [[ -n "$TEST_TEMP_DIR" ]] && [[ -d "$TEST_TEMP_DIR" ]]; then
    rm -rf "$TEST_TEMP_DIR"
  fi
}

# Runs a context script and prints the requested exported variables, one per line.
run_context_script() {
  local script="$1"; shift
  local vars="$*"
  run bash -c "
    source \"$SERVICE_PATH/scripts/istio/$script\" >/dev/null
    for v in $vars; do echo \"\$v=\${!v}\"; done
  "
}

service_context() {
  jq -c --argjson attrs "$1" '{
    id: "svc-action", slug: "create-acme-api", type: "create",
    parameters: $attrs,
    service: {id: "svc-1234", slug: "acme-api", attributes: {}, dimensions: {environment: "dev"}},
    tags: {application_id: "999"}
  }' <<< '{}'
}

httproute_items() {
  # $1: JSON array of {name, link_id, host, path, method, service_id (default svc-1234)}
  jq -c '{items: [.[] | {
    metadata: {
      name: .name,
      labels: ({"nullplatform.com/managed-by": "http-route-access-control",
                "nullplatform.com/service-id": (.service_id // "svc-1234")}
        + (if .link_id then {"nullplatform.com/link-id": .link_id} else {} end))
    },
    spec: {
      hostnames: [.host],
      rules: [{matches: [{path: {type: "Exact", value: .path}} + (if .method then {method: .method} else {} end)]}]
    }
  }]}' <<< "$1"
}

# --- build_service_context ---------------------------------------------------

@test "build_service_context: normalizes domain_name and resolves the public gateway" {
  export CONTEXT="$(service_context '{"domain_name": " API.Acme.com ", "visibility": "public"}')"

  run_context_script build_service_context DOMAIN_NAME VISIBILITY GATEWAY_NAME COGNITO_USER_POOL_ARN

  assert_success
  assert_output --partial "DOMAIN_NAME=api.acme.com"
  assert_output --partial "GATEWAY_NAME=gateway-public"
  assert_output --partial "COGNITO_USER_POOL_ARN=$COGNITO_USER_POOL_ARN_DEV"
}

@test "build_service_context: private visibility uses the private gateway" {
  export CONTEXT="$(service_context '{"domain_name": "internal.acme.com", "visibility": "private"}')"

  run_context_script build_service_context GATEWAY_NAME

  assert_success
  assert_output --partial "GATEWAY_NAME=gateway-private"
}

@test "build_service_context: rejects a missing domain_name" {
  export CONTEXT="$(service_context '{"visibility": "public"}')"

  run_context_script build_service_context DOMAIN_NAME

  assert_failure
  assert_output --partial "domain_name is required"
}

@test "build_service_context: rejects wildcards and invalid hostnames" {
  for domain in "*.acme.com" "acme" "-api.acme.com" "api.acme.com/path"; do
    export CONTEXT="$(service_context "{\"domain_name\": \"$domain\"}")"
    run_context_script build_service_context DOMAIN_NAME
    assert_failure
    assert_output --partial "is not a valid hostname"
  done
}

@test "build_service_context: delete tolerates a service without domain_name" {
  export CONTEXT="$(service_context '{}')"
  export SERVICE_OPERATION=delete

  run_context_script build_service_context SERVICE_ID

  assert_success
  assert_output --partial "SERVICE_ID=svc-1234"
}

@test "build_service_context: aws-avp is rejected on apply" {
  export CONTEXT="$(service_context '{"domain_name": "api.acme.com"}')"
  export AUTH_TYPE=aws-avp OPA_PROVIDER_NAME=opa AVP_POLICY_STORE_ARN_DEV="arn:aws:verifiedpermissions::1:policy-store/X"

  run_context_script build_service_context DOMAIN_NAME

  assert_failure
  assert_output --partial "aws-avp is not supported"
}

# --- validate_domain ---------------------------------------------------------

@test "validate_domain: accepts exact, wildcard and hostname-less listeners" {
  export KUBECTL_GATEWAY_FILE="$TEST_TEMP_DIR/gateway.json"
  export GATEWAY_NAME=gateway-public SERVICE_ID=svc-1234 K8S_NAMESPACE=nullplatform
  export KUBECTL_HTTPROUTES_FILE="$TEST_TEMP_DIR/httproutes.json"
  echo '{"items": []}' > "$KUBECTL_HTTPROUTES_FILE"

  for listeners in '[{"hostname": "api.acme.com"}]' '[{"hostname": "*.acme.com"}]' '[{"name": "http"}]'; do
    jq -n --argjson l "$listeners" '{spec: {listeners: $l}}' > "$KUBECTL_GATEWAY_FILE"
    DOMAIN_NAME=api.acme.com run bash "$SERVICE_PATH/scripts/istio/validate_domain"
    assert_success
  done
}

@test "validate_domain: fails when no listener serves the domain" {
  export KUBECTL_GATEWAY_FILE="$TEST_TEMP_DIR/gateway.json"
  jq -n '{spec: {listeners: [{hostname: "*.other.com"}, {hostname: "acme.com"}]}}' > "$KUBECTL_GATEWAY_FILE"

  DOMAIN_NAME=api.acme.com GATEWAY_NAME=gateway-public run bash "$SERVICE_PATH/scripts/istio/validate_domain"

  assert_failure
  assert_output --partial "has no listener for 'api.acme.com'"
}

@test "validate_domain: rejects a domain that already serves links of another service" {
  export KUBECTL_GATEWAY_FILE="$TEST_TEMP_DIR/gateway.json" KUBECTL_HTTPROUTES_FILE="$TEST_TEMP_DIR/httproutes.json"
  export GATEWAY_NAME=gateway-public SERVICE_ID=svc-1234 K8S_NAMESPACE=nullplatform
  jq -n '{spec: {listeners: [{hostname: "*.acme.com"}]}}' > "$KUBECTL_GATEWAY_FILE"
  httproute_items '[{"name": "r1", "link_id": "l9", "service_id": "svc-other", "host": "api.acme.com", "path": "/x", "method": "GET"}]' > "$KUBECTL_HTTPROUTES_FILE"

  DOMAIN_NAME=api.acme.com run bash "$SERVICE_PATH/scripts/istio/validate_domain"

  assert_failure
  assert_output --partial "already serves links of service(s) svc-other"
}

@test "validate_domain: a legacy service on the same domain only warns (migration)" {
  export KUBECTL_GATEWAY_FILE="$TEST_TEMP_DIR/gateway.json" KUBECTL_HTTPROUTES_FILE="$TEST_TEMP_DIR/httproutes.json"
  export GATEWAY_NAME=gateway-public SERVICE_ID=svc-1234 K8S_NAMESPACE=nullplatform
  jq -n '{spec: {listeners: [{hostname: "*.acme.com"}]}}' > "$KUBECTL_GATEWAY_FILE"
  httproute_items '[{"name": "legacy", "service_id": "svc-legacy", "host": "api.acme.com", "path": "/x", "method": "GET"}]' > "$KUBECTL_HTTPROUTES_FILE"

  DOMAIN_NAME=api.acme.com run bash "$SERVICE_PATH/scripts/istio/validate_domain"

  assert_success
  assert_output --partial "WARNING: 'api.acme.com' is also served by legacy service(s) svc-legacy"
}

# --- build_link_context ------------------------------------------------------

# --- check_domain_dns --------------------------------------------------------

# dig mock: answers come from $DIG_DIR/<name>.<TYPE> (missing file = no answer);
# "+authority SOA" queries read $DIG_DIR/<name>.AUTH. Every call is logged.
dns_env() {
  export DOMAIN_NAME=api.acme.com GATEWAY_NAME=gateway-public VISIBILITY="${1:-public}" DOMAIN_DNS_CHECK=enforce
  export DIG_DIR="$TEST_TEMP_DIR/digdata" KUBECTL_GATEWAY_ADDRESSES_FILE="$TEST_TEMP_DIR/gw-addresses"
  mkdir -p "$DIG_DIR"
  echo "lb-123.elb.amazonaws.com" > "$KUBECTL_GATEWAY_ADDRESSES_FILE"
  cat > "$TEST_TEMP_DIR/dig" << 'MOCK'
#!/bin/bash
echo "dig $*" >> "$TEST_TEMP_DIR/dig.log"
name=""; type=""; auth=false
for a in "$@"; do
  case "$a" in
    +authority) auth=true ;;
    +*|@*) ;;
    A|AAAA|SOA|NS) type="$a" ;;
    *) name="$a" ;;
  esac
done
if [[ "$name" == "." ]]; then
  [[ -n "${DIG_RESOLVERS_DOWN:-}" ]] && exit 9
  echo "a.root-servers.net."; exit 0
fi
if $auth; then cat "$DIG_DIR/$name.AUTH" 2>/dev/null; exit 0; fi
cat "$DIG_DIR/$name.$type" 2>/dev/null
exit 0
MOCK
  chmod +x "$TEST_TEMP_DIR/dig"
  # kubectl mock: the gateway's status addresses
  cat > "$TEST_TEMP_DIR/kubectl" << 'MOCK'
#!/bin/bash
echo "kubectl $*" >> "$TEST_TEMP_DIR/kubectl.log"
cat "$KUBECTL_GATEWAY_ADDRESSES_FILE"
MOCK
}

@test "check_domain_dns: a public domain pointing at the gateway passes, checked on a public resolver" {
  dns_env public
  printf 'lb-123.elb.amazonaws.com.\n10.0.0.1\n' > "$DIG_DIR/api.acme.com.A"

  run bash "$SERVICE_PATH/scripts/istio/check_domain_dns"

  assert_success
  assert_output --partial "points at gateway gateways/gateway-public"
  assert_file_contains "$TEST_TEMP_DIR/dig.log" "@1.1.1.1 api.acme.com A"
}

@test "check_domain_dns: a private domain uses the agent's resolver" {
  dns_env private
  echo "10.0.0.9" > "$DIG_DIR/api.acme.com.A"
  echo "10.0.0.9" > "$DIG_DIR/lb-123.elb.amazonaws.com.A"

  run bash "$SERVICE_PATH/scripts/istio/check_domain_dns"

  assert_success
  assert_output --partial "with the agent's resolver"
  assert_output --partial "points at gateway"
  run grep -c "@" "$TEST_TEMP_DIR/dig.log"
  assert_output "0"
}

@test "check_domain_dns: a domain resolving elsewhere only warns" {
  dns_env public
  echo "203.0.113.7" > "$DIG_DIR/api.acme.com.A"

  run bash "$SERVICE_PATH/scripts/istio/check_domain_dns"

  assert_success
  assert_output --partial "WARNING: 'api.acme.com' doesn't point at gateway"
}

@test "check_domain_dns: tells a missing record from an unregistered domain" {
  dns_env public
  echo "acme.com. 900 IN SOA ns1.acme.com. hostmaster.acme.com. 1 2 3 4 5" > "$DIG_DIR/api.acme.com.AUTH"
  run bash "$SERVICE_PATH/scripts/istio/check_domain_dns"
  assert_failure
  assert_output --partial "has no A/AAAA/CNAME record in zone 'acme.com'"

  echo "com. 900 IN SOA a.gtld-servers.net. nstld.verisign-grs.com. 1 2 3 4 5" > "$DIG_DIR/api.acme.com.AUTH"
  run bash "$SERVICE_PATH/scripts/istio/check_domain_dns"
  assert_failure
  assert_output --partial "doesn't exist in DNS: no zone serves it (only the TLD 'com')"
}

@test "check_domain_dns: warn mode reports a missing domain without failing" {
  dns_env public
  export DOMAIN_DNS_CHECK=warn

  run bash "$SERVICE_PATH/scripts/istio/check_domain_dns"

  assert_success
  assert_output --partial "WARNING: 'api.acme.com' doesn't exist in DNS"
}

@test "check_domain_dns: falls back to the agent's resolver when no public resolver replies" {
  dns_env public
  export DIG_RESOLVERS_DOWN=1
  echo "lb-123.elb.amazonaws.com." > "$DIG_DIR/api.acme.com.A"

  run bash "$SERVICE_PATH/scripts/istio/check_domain_dns"

  assert_success
  assert_output --partial "no public resolver replied"
  assert_output --partial "points at gateway"
}

@test "build_link_context: builds a single route on the service's domain" {
  run_context_script build_link_context LINK_ID DOMAIN_NAME GATEWAY_NAME APPLICATION_ID ROUTES_JSON

  assert_success
  assert_output --partial "LINK_ID=link-5678"
  assert_output --partial "DOMAIN_NAME=api.acme.com"
  assert_output --partial "GATEWAY_NAME=gateway-public"
  # The scope belongs to the linking application (link.entity_nrn), not the service owner (tags)
  assert_output --partial "APPLICATION_ID=444"
  assert_output --partial 'ROUTES_JSON=[{"path":"/api/users/*","methods":["GET","POST"],"groups":["admin","read-only"],"scope":"users-prod","visibility":"public"}]'
}

@test "build_link_context: private services map to the internal visibility and private gateway" {
  export CONTEXT="$(jq -c '.service.attributes.visibility = "private"' <<< "$CONTEXT")"

  run_context_script build_link_context GATEWAY_NAME ROUTES_JSON

  assert_success
  assert_output --partial "GATEWAY_NAME=gateway-private"
  assert_output --partial '"visibility":"internal"'
}

@test "build_link_context: normalizes legacy method and comma separated groups" {
  export CONTEXT="$(jq -c '.parameters = {path: "/health", method: "GET", groups: "admin, ops", scope: "users-prod"}' <<< "$CONTEXT")"

  run_context_script build_link_context ROUTES_JSON

  assert_success
  assert_output --partial '"methods":["GET"]'
  assert_output --partial '"groups":["admin","ops"]'
}

@test "build_link_context: stored link attributes are used when the action has no parameters" {
  export CONTEXT="$(jq -c '.link.attributes = .parameters | del(.parameters)' <<< "$CONTEXT")"

  run_context_script build_link_context ROUTES_JSON

  assert_success
  assert_output --partial '"path":"/api/users/*"'
}

@test "build_link_context: falls back to the link's scope" {
  export CONTEXT="$(jq -c 'del(.parameters.scope) | .link.scope = {id: 1, slug: "users-dev"}' <<< "$CONTEXT")"

  run_context_script build_link_context ROUTES_JSON

  assert_success
  assert_output --partial '"scope":"users-dev"'
}

@test "build_link_context: reads the service when the notification doesn't embed its attributes" {
  export CONTEXT="$(jq -c '.service.attributes = {}' <<< "$CONTEXT")"
  export NP_SERVICE_READ_FILE="$TEST_TEMP_DIR/service.json"
  echo '{"id": "svc-1234", "attributes": {"domain_name": "from-api.acme.com", "visibility": "public"}, "dimensions": {"environment": "dev"}}' > "$NP_SERVICE_READ_FILE"

  run_context_script build_link_context DOMAIN_NAME

  assert_success
  assert_output --partial "DOMAIN_NAME=from-api.acme.com"
}

@test "build_link_context: fails on a legacy service without domain_name" {
  export CONTEXT="$(jq -c '.service.attributes = {routes: [{path: "/x"}]}' <<< "$CONTEXT")"
  export NP_SERVICE_READ_FILE="$TEST_TEMP_DIR/service.json"
  echo '{"id": "svc-1234", "attributes": {"routes": [{"path": "/x"}]}}' > "$NP_SERVICE_READ_FILE"

  run_context_script build_link_context DOMAIN_NAME

  assert_failure
  assert_output --partial "has no domain_name"
}

@test "build_link_context: rejects invalid routes" {
  for params in \
    '{"path": "api/users", "methods": ["GET"], "groups": ["a"], "scope": "s"}' \
    '{"path": "/api", "methods": ["FETCH"], "groups": ["a"], "scope": "s"}' \
    '{"path": "/api", "methods": ["GET"], "groups": [], "scope": "s"}'; do
    export CONTEXT="$(jq -c --argjson p "$params" '.parameters = $p' <<< "$(load_fixture link-notification)")"
    run_context_script build_link_context ROUTES_JSON
    assert_failure
  done
}

@test "build_link_context: no verbs means ALL" {
  for params in '{"path": "/api", "groups": ["a"], "scope": "s"}' '{"path": "/api", "methods": [], "groups": ["a"], "scope": "s"}'; do
    export CONTEXT="$(jq -c --argjson p "$params" '.parameters = $p | .link.attributes = {}' <<< "$(load_fixture link-notification)")"

    run_context_script build_link_context ROUTES_JSON

    assert_success
    assert_output --partial '"methods":["ALL"]'
  done
}

@test "build_link_context: accepts the ALL verb" {
  export CONTEXT="$(jq -c '.parameters.methods = ["ALL"]' <<< "$CONTEXT")"

  run_context_script build_link_context ROUTES_JSON

  assert_success
  assert_output --partial '"methods":["ALL"]'
}

@test "build_link_context: AUTH_TYPE=none makes groups optional and drops them" {
  export AUTH_TYPE=none
  for groups in '[]' '["admin"]'; do
    export CONTEXT="$(jq -c --argjson g "$groups" '.parameters.groups = $g' <<< "$(load_fixture link-notification)")"

    run_context_script build_link_context ROUTES_JSON AUTH_TYPE COGNITO_USER_POOL_ARN

    assert_success
    assert_output --partial '"groups":[]'
    assert_output --partial "AUTH_TYPE=none"
    assert_output --partial "COGNITO_USER_POOL_ARN="
  done
}

@test "build_link_context: aws-cognito requires groups even on a delete-typed notification" {
  export CONTEXT="$(jq -c '.parameters.groups = [] | .type = "delete"' <<< "$CONTEXT")"

  run_context_script build_link_context ROUTES_JSON

  assert_failure
  assert_output --partial "at least one authorized group is required"
}

@test "build_link_context: unset AUTH_TYPE refuses to reopen a link stored with auth" {
  unset AUTH_TYPE
  export CONTEXT="$(jq -c '.parameters.groups = [] | .link.attributes.auth_type = "aws-cognito"' <<< "$CONTEXT")"

  run_context_script build_link_context ROUTES_JSON

  assert_failure
  assert_output --partial "configured with auth: aws-cognito"
}

@test "build_link_context: unset AUTH_TYPE defaults to none for a link without auth" {
  unset AUTH_TYPE
  export CONTEXT="$(jq -c '.parameters.groups = [] | .link.attributes = {} | .service.attributes.routes = []' <<< "$CONTEXT")"

  run_context_script build_link_context AUTH_TYPE

  assert_success
  assert_output --partial "AUTH_TYPE=none"
}

# Scopes of the linking application and the k8s Services routing to them, for the
# scope auto-resolution. $1: JSON array of {id, slug, reachability, status, routable}.
scope_env() {
  export NP_SCOPE_LIST_FILE="$TEST_TEMP_DIR/scopes.json" KUBECTL_SERVICES_FILE="$TEST_TEMP_DIR/services.json"
  jq -c '{results: [.[] | {id, slug, status: (.status // "active"), dimensions: {environment: "dev"},
    capabilities: {visibility: {reachability: .reachability}}}]}' <<< "$1" > "$NP_SCOPE_LIST_FILE"
  jq -c '{items: [.[] | select(.routable != false)
    | {metadata: {namespace: (.namespace // "nullplatform")}, spec: {selector: {scope_id: (.id | tostring)}}}]}' \
    <<< "$1" > "$KUBECTL_SERVICES_FILE"
  export CONTEXT="$(jq -c 'del(.parameters.scope) | del(.link.attributes.scope) | .link.scope = null' <<< "$CONTEXT")"
}

@test "build_link_context: without a scope, resolves the routable scope matching the service's visibility" {
  scope_env '[
    {"id": 1, "slug": "pub",        "reachability": "public"},
    {"id": 2, "slug": "priv",       "reachability": "account"},
    {"id": 3, "slug": "serverless", "reachability": "public", "routable": false},
    {"id": 4, "slug": "gone",       "reachability": "public", "status": "deleted"}
  ]'

  run_context_script build_link_context ROUTES_JSON

  assert_success
  assert_output --partial '"scope":"pub"'
}

@test "build_link_context: without a scope, a private service resolves the private scope" {
  scope_env '[{"id": 1, "slug": "pub", "reachability": "public"}, {"id": 2, "slug": "priv", "reachability": "account"}]'
  export NP_SERVICE_READ_FILE="$TEST_TEMP_DIR/service.json"
  jq -c '.service | .attributes.visibility = "private"' <<< "$CONTEXT" > "$NP_SERVICE_READ_FILE"
  export CONTEXT="$(jq -c '.service.attributes = {}' <<< "$CONTEXT")"

  run_context_script build_link_context ROUTES_JSON

  assert_success
  assert_output --partial '"scope":"priv"'
}

@test "build_link_context: without a scope, fails when no scope matches" {
  scope_env '[{"id": 2, "slug": "priv", "reachability": "account"}]'
  run_context_script build_link_context ROUTES_JSON
  assert_failure
  assert_output --partial "no public scope running in Kubernetes"

}

@test "build_link_context: without a scope, several matches pick active first, then the oldest" {
  scope_env '[
    {"id": 1, "slug": "old-failed", "reachability": "public", "status": "failed"},
    {"id": 2, "slug": "newer",      "reachability": "public"},
    {"id": 3, "slug": "older",      "reachability": "public"}
  ]'
  jq -c '.results |= map(.created_at = ({"1": "2024-01-01", "2": "2026-05-01", "3": "2025-03-01"}[.id | tostring]))' \
    "$NP_SCOPE_LIST_FILE" > "$NP_SCOPE_LIST_FILE.tmp" && mv "$NP_SCOPE_LIST_FILE.tmp" "$NP_SCOPE_LIST_FILE"

  run bash -c "source \"$SERVICE_PATH/scripts/istio/build_link_context\" && echo \"ROUTES_JSON=\$ROUTES_JSON\""

  assert_success
  assert_output --partial '"scope":"older"'
  assert_output --partial "other public scopes also match: newer (active), old-failed (failed)"
}

# --- routes list ---

routes_context() {
  export CONTEXT="$(jq -c --argjson routes "$1" '.parameters = {routes: $routes} | .link.attributes = {}' <<< "$(load_fixture link-notification)")"
}

@test "build_link_context: a routes list builds one route per item" {
  routes_context '[
    {"path": "/api/v1/clientes", "methods": ["ALL"], "groups": ["admin"], "scope": "users-prod"},
    {"path": "/health", "groups": ["ops"], "scope": "health-prod"}]'

  run_context_script build_link_context ROUTES_JSON

  assert_success
  assert_output --partial 'ROUTES_JSON=[{"path":"/api/v1/clientes","methods":["ALL"],"groups":["admin"],"scope":"users-prod","visibility":"public"},{"path":"/health","methods":["ALL"],"groups":["ops"],"scope":"health-prod","visibility":"public"}]'
}

@test "build_link_context: the routes list wins over a stale single route" {
  export CONTEXT="$(jq -c '.link.attributes = {path: "/old", methods: ["GET"], groups: ["admin"], scope: "users-prod"}
    | .parameters = {routes: [{path: "/new", groups: ["admin"], scope: "users-prod"}]}' <<< "$CONTEXT")"

  run_context_script build_link_context ROUTES_JSON

  assert_success
  assert_output --partial '"path":"/new"'
  [[ "$output" != *'"/old"'* ]]
}

@test "build_link_context: routes without a scope share the resolved one, explicit scopes stay" {
  scope_env '[{"id": 1, "slug": "pub", "reachability": "public"}]'
  export CONTEXT="$(jq -c '.parameters = {routes: [{path: "/a", groups: ["g"]}, {path: "/b", groups: ["g"], scope: "other"}]} | .link.attributes = {}' <<< "$CONTEXT")"

  run_context_script build_link_context ROUTES_JSON

  assert_success
  assert_output --partial '{"path":"/a","methods":["ALL"],"groups":["g"],"scope":"pub"'
  assert_output --partial '{"path":"/b","methods":["ALL"],"groups":["g"],"scope":"other"'
}

@test "build_link_context: rejects an empty list, duplicated paths and invalid paths" {
  routes_context '[]'
  run_context_script build_link_context ROUTES_JSON
  assert_failure
  assert_output --partial "the link has no routes"

  routes_context '[{"path": "/a", "methods": ["GET"], "groups": ["g"], "scope": "s"}, {"path": "/a", "methods": ["POST"], "groups": ["g"], "scope": "s"}]'
  run_context_script build_link_context ROUTES_JSON
  assert_failure
  assert_output --partial "paths declared more than once in the link: /a"

  routes_context '[{"path": "/ok", "groups": ["g"], "scope": "s"}, {"path": "bad", "groups": ["g"], "scope": "s"}, {"path": "", "groups": ["g"], "scope": "s"}]'
  run_context_script build_link_context ROUTES_JSON
  assert_failure
  assert_output --partial "invalid: bad, (empty)"
}

@test "build_link_context: aws-cognito names the routes without groups" {
  routes_context '[{"path": "/a", "groups": ["g"], "scope": "s"}, {"path": "/b", "scope": "s"}]'

  run_context_script build_link_context ROUTES_JSON

  assert_failure
  assert_output --partial "/b"
}

@test "build_link_context: AUTH_TYPE=none drops the groups of every route" {
  export AUTH_TYPE=none
  routes_context '[{"path": "/a", "groups": ["g"], "scope": "s"}, {"path": "/b", "scope": "s"}]'

  run_context_script build_link_context ROUTES_JSON

  assert_success
  run bash -c "source \"$SERVICE_PATH/scripts/istio/build_link_context\" >/dev/null && echo \"\$ROUTES_JSON\" | jq -c 'map(.groups)'"
  assert_output "[[],[]]"
}

@test "build_link_context: unlink only needs the link identity" {
  export CONTEXT="$(jq -c '.parameters = {} | .service.attributes = {} | .service.dimensions = {}' <<< "$CONTEXT")"
  export LINK_OPERATION=delete

  run_context_script build_link_context LINK_ID K8S_NAMESPACE

  assert_success
  assert_output --partial "LINK_ID=link-5678"
  assert_output --partial "K8S_NAMESPACE=nullplatform"
}

# --- check_link_conflict -----------------------------------------------------

conflict_env() {
  export DOMAIN_NAME=api.acme.com SERVICE_ID=svc-1234 LINK_ID=link-5678 K8S_NAMESPACE=nullplatform
  export ROUTES_JSON="[{\"path\": \"$1\", \"methods\": $2}]"
  export KUBECTL_HTTPROUTES_FILE="$TEST_TEMP_DIR/httproutes.json"
}

@test "check_link_conflict: fails when another link exposes the same path and method" {
  conflict_env "/api/users" '["GET", "POST"]'
  httproute_items '[{"name": "r1", "link_id": "link-other", "host": "api.acme.com", "path": "/api/users", "method": "POST"}]' > "$KUBECTL_HTTPROUTES_FILE"

  run bash "$SERVICE_PATH/scripts/istio/check_link_conflict"

  assert_failure
  assert_output --partial "already exposed by link link-other"
}

@test "check_link_conflict: compares the converted Gateway API path (wildcards)" {
  conflict_env "/files/*" '["GET"]'
  httproute_items '[{"name": "r1", "link_id": "link-other", "host": "api.acme.com", "path": "/files", "method": "GET"}]' > "$KUBECTL_HTTPROUTES_FILE"

  run bash "$SERVICE_PATH/scripts/istio/check_link_conflict"

  assert_failure
}

@test "check_link_conflict: a rule without method conflicts with every method" {
  conflict_env "/api/users" '["DELETE"]'
  httproute_items '[{"name": "r1", "link_id": "link-other", "host": "api.acme.com", "path": "/api/users"}]' > "$KUBECTL_HTTPROUTES_FILE"

  run bash "$SERVICE_PATH/scripts/istio/check_link_conflict"

  assert_failure
}

@test "check_link_conflict: ALL conflicts with any method on the same path" {
  conflict_env "/api/users" '["ALL"]'
  httproute_items '[{"name": "r1", "link_id": "link-other", "host": "api.acme.com", "path": "/api/users", "method": "PATCH"}]' > "$KUBECTL_HTTPROUTES_FILE"

  run bash "$SERVICE_PATH/scripts/istio/check_link_conflict"

  assert_failure
  assert_output --partial "already exposed by link link-other"
}

@test "check_link_conflict: checks every route of the link" {
  export DOMAIN_NAME=api.acme.com SERVICE_ID=svc-1234 LINK_ID=link-5678 K8S_NAMESPACE=nullplatform
  export ROUTES_JSON='[{"path": "/free", "methods": ["GET"]}, {"path": "/taken", "methods": ["ALL"]}]'
  export KUBECTL_HTTPROUTES_FILE="$TEST_TEMP_DIR/httproutes.json"
  httproute_items '[{"name": "r1", "link_id": "link-other", "host": "api.acme.com", "path": "/taken", "method": "DELETE"}]' > "$KUBECTL_HTTPROUTES_FILE"

  run bash "$SERVICE_PATH/scripts/istio/check_link_conflict"

  assert_failure
  assert_output --partial "DELETE api.acme.com/taken is already exposed by link link-other"
  [[ "$output" != *"/free is already"* ]]
}

@test "check_link_conflict: passes for its own route, other methods, paths and domains" {
  conflict_env "/api/users" '["GET"]'
  httproute_items '[
    {"name": "own",    "link_id": "link-5678",  "host": "api.acme.com",   "path": "/api/users", "method": "GET"},
    {"name": "method", "link_id": "link-other", "host": "api.acme.com",   "path": "/api/users", "method": "POST"},
    {"name": "path",   "link_id": "link-other", "host": "api.acme.com",   "path": "/api/orders", "method": "GET"},
    {"name": "domain", "link_id": "link-other", "host": "other.acme.com", "path": "/api/users", "method": "GET"}
  ]' > "$KUBECTL_HTTPROUTES_FILE"

  run bash "$SERVICE_PATH/scripts/istio/check_link_conflict"

  assert_success
  assert_output --partial "No conflicts found"
}

@test "check_link_conflict: rejects a domain whose links belong to another service" {
  conflict_env "/brand-new" '["GET"]'
  httproute_items '[{"name": "r1", "link_id": "l9", "service_id": "svc-other", "host": "api.acme.com", "path": "/other", "method": "GET"}]' > "$KUBECTL_HTTPROUTES_FILE"

  run bash "$SERVICE_PATH/scripts/istio/check_link_conflict"

  assert_failure
  assert_output --partial "can't be shared by service svc-1234"
}

@test "check_link_conflict: a legacy HTTPRoute on the same path only warns" {
  conflict_env "/api/users" '["GET"]'
  httproute_items '[{"name": "acme-api-svc-public", "host": "api.acme.com", "path": "/api/users", "method": "GET"}]' > "$KUBECTL_HTTPROUTES_FILE"

  run bash "$SERVICE_PATH/scripts/istio/check_link_conflict"

  assert_success
  assert_output --partial "WARNING"
  assert_output --partial "legacy HTTPRoute acme-api-svc-public"
}

# --- templates ---------------------------------------------------------------

@test "httproute template: link route carries the link-id label and the domain" {
  jq -n '{name: "acme-api-link-link-5678", service_slug: "acme-api", service_id: "svc-1234",
          link_id: "link-5678", k8s_namespace: "nullplatform", hostnames: ["api.acme.com"],
          gateway_name: "gateway-public", gateway_namespace: "gateways"}' > "$TEST_TEMP_DIR/ctx.json"

  gomplate -c ".=$TEST_TEMP_DIR/ctx.json" -f "$SERVICE_PATH/templates/istio/httproute.yaml.tpl" -o "$TEST_TEMP_DIR/route.yaml"

  assert_yaml_contains "$TEST_TEMP_DIR/route.yaml" '.metadata.name' "acme-api-link-link-5678"
  assert_yaml_contains "$TEST_TEMP_DIR/route.yaml" '.metadata.labels["nullplatform.com/link-id"]' "link-5678"
  assert_yaml_contains "$TEST_TEMP_DIR/route.yaml" '.spec.hostnames[0]' "api.acme.com"
}

@test "httproute template: legacy route keeps its name and has no link-id label" {
  jq -n '{name: "acme-api-svc-1234-public", service_slug: "acme-api", service_id: "svc-1234",
          link_id: "", k8s_namespace: "nullplatform", hostnames: ["a.acme.com"],
          gateway_name: "gateway-public", gateway_namespace: "gateways"}' > "$TEST_TEMP_DIR/ctx.json"

  gomplate -c ".=$TEST_TEMP_DIR/ctx.json" -f "$SERVICE_PATH/templates/istio/httproute.yaml.tpl" -o "$TEST_TEMP_DIR/route.yaml"

  assert_yaml_contains "$TEST_TEMP_DIR/route.yaml" '.metadata.name' "acme-api-svc-1234-public"
  assert_yaml_contains "$TEST_TEMP_DIR/route.yaml" '.metadata.labels["nullplatform.com/link-id"]' "null"
}

# --- prune_link_policies -----------------------------------------------------

@test "prune_link_policies: deletes only the link's policies that were not regenerated" {
  export LINK_ID=link-5678
  mkdir -p "$OUTPUT_DIR/apply"
  printf 'metadata:\n  name: hrac-keep\n' > "$OUTPUT_DIR/apply/authorizationpolicy-keep.yaml"
  export KUBECTL_AUTHZ_NAMES_FILE="$TEST_TEMP_DIR/authz.txt"
  printf 'hrac-keep\nhrac-stale\n' > "$KUBECTL_AUTHZ_NAMES_FILE"

  run bash "$SERVICE_PATH/scripts/istio/prune_link_policies"

  assert_success
  assert_file_contains "$TEST_TEMP_DIR/kubectl.log" "delete authorizationpolicy hrac-stale"
  assert_file_not_contains "$TEST_TEMP_DIR/kubectl.log" "delete authorizationpolicy hrac-keep"
}

# --- delete_link_resources ---------------------------------------------------

@test "delete_link_resources: deletes by link-id label only" {
  export LINK_ID=link-5678 K8S_NAMESPACE=nullplatform

  run bash "$SERVICE_PATH/scripts/istio/delete_link_resources"

  assert_success
  assert_file_contains "$TEST_TEMP_DIR/kubectl.log" "delete httproute --all-namespaces -l nullplatform.com/managed-by=http-route-access-control,nullplatform.com/link-id=link-5678"
  assert_file_contains "$TEST_TEMP_DIR/kubectl.log" "delete authorizationpolicy -n gateways -l nullplatform.com/managed-by=http-route-access-control,nullplatform.com/link-id=link-5678"
}

# --- np results --------------------------------------------------------------

@test "update_link_results: stores the routes list, endpoints and summary, dropping the legacy single route" {
  export LINK_ID=link-5678 DOMAIN_NAME=api.acme.com
  export LINK_ATTRIBUTES_JSON='{"path": "/old", "method": "GET", "groups": "admin", "scope": "users-prod", "endpoint": "api.acme.com/old"}'
  export ROUTES_JSON='[
    {"path": "/api/users/*", "methods": ["GET"], "groups": ["admin"], "scope": "users-prod", "visibility": "public"},
    {"path": "/health", "methods": ["ALL"], "groups": ["ops"], "scope": "users-prod", "visibility": "public"}]'

  run bash "$SERVICE_PATH/scripts/np/update_link_results"

  assert_success
  run jq -c '.attributes | {routes: (.routes | map({path, methods, scope, summary})), endpoints, summary, legacy: [.path, .method, .groups, .scope, .endpoint]}' "$TEST_TEMP_DIR/link-patch-body.json"
  assert_output '{"routes":[{"path":"/api/users/*","methods":["GET"],"scope":"users-prod","summary":"GET | api.acme.com/api/users/* | admin"},{"path":"/health","methods":["ALL"],"scope":"users-prod","summary":"ALL | api.acme.com/health | ops"}],"endpoints":["api.acme.com/api/users/*","api.acme.com/health"],"summary":"GET /api/users/*; ALL /health","legacy":[null,null,null,null,null]}'
}

@test "update_link_results: stores the auth_type and the same attributes as action results" {
  export LINK_ID=link-5678 DOMAIN_NAME=api.acme.com AUTH_TYPE=none
  export LINK_ATTRIBUTES_JSON='{"routes": [{"path": "/health"}]}'
  export ROUTES_JSON='[{"path": "/health", "methods": ["ALL"], "groups": [], "scope": "users-prod", "visibility": "public"}]'

  run bash "$SERVICE_PATH/scripts/np/update_link_results"

  assert_success
  run jq -r '"\(.attributes.auth_type)|\(.attributes.routes[0].summary)"' "$TEST_TEMP_DIR/link-patch-body.json"
  assert_output "none|ALL | api.acme.com/health"
  # The action results carry the same attributes: the platform writes them onto the link.
  run jq -r '"\(.routes[0].methods | join(","))|\(.routes[0].scope)"' "$TEST_TEMP_DIR/link-action-results.json"
  assert_output "ALL|users-prod"
}

@test "check_active_links: blocks the delete while links are active" {
  export SERVICE_ID=svc-1234 NP_LINK_LIST_FILE="$TEST_TEMP_DIR/links.json" NP_SERVICE_READ_FILE="$TEST_TEMP_DIR/service.json"
  echo '{"id": "svc-1234", "entity_nrn": "organization=1:account=2:namespace=3:application=999"}' > "$NP_SERVICE_READ_FILE"
  echo '{"results": [{"id": "l1", "status": "active", "attributes": {"summary": "GET | api.acme.com/x | admin"}}, {"id": "l2", "status": "archived"}]}' > "$NP_LINK_LIST_FILE"

  run bash "$SERVICE_PATH/scripts/np/check_active_links"

  assert_failure
  assert_output --partial "link l1 [active]"
  # An API key can only list links with an NRN; links live under any app of the org.
  assert_file_contains "$TEST_TEMP_DIR/np.log" "link list --nrn organization=1 --show-descendants --service-id svc-1234"
}

@test "check_active_links: allows the delete when every link is archived or failed" {
  export SERVICE_ID=svc-1234 NP_LINK_LIST_FILE="$TEST_TEMP_DIR/links.json" NP_SERVICE_READ_FILE="$TEST_TEMP_DIR/service.json"
  echo '{"id": "svc-1234", "entity_nrn": "organization=1:account=2:namespace=3:application=999"}' > "$NP_SERVICE_READ_FILE"
  echo '{"results": [{"id": "l1", "status": "archived"}, {"id": "l2", "status": "failed"}]}' > "$NP_LINK_LIST_FILE"

  run bash "$SERVICE_PATH/scripts/np/check_active_links"

  assert_success
}

# --- apps in their own namespace ----------------------------------------------

@test "build_link_context: the link's HTTPRoute goes to the namespace of its scope's Services" {
  scope_env '[{"id": 1, "slug": "pub", "reachability": "public", "namespace": "team-a"}]'

  run_context_script build_link_context ROUTES_JSON K8S_NAMESPACE

  assert_success
  assert_output --partial '"scope":"pub"'
  assert_output --partial "K8S_NAMESPACE=team-a"
  assert_file_contains "$TEST_TEMP_DIR/kubectl.log" "get services --all-namespaces"
}

@test "build_link_context: a scope named on the route resolves its namespace too" {
  scope_env '[{"id": 7, "slug": "users-prod", "reachability": "public", "namespace": "team-b"}]'
  routes_context '[{"path": "/api/users", "groups": ["admin"], "scope": "users-prod"}]'

  run_context_script build_link_context K8S_NAMESPACE

  assert_success
  assert_output --partial "K8S_NAMESPACE=team-b"
}

@test "build_link_context: an app without Services yet keeps the default namespace" {
  scope_env '[{"id": 7, "slug": "users-prod", "reachability": "public", "routable": false}]'
  routes_context '[{"path": "/api/users", "groups": ["admin"], "scope": "users-prod"}]'

  run_context_script build_link_context K8S_NAMESPACE

  assert_success
  assert_output --partial "K8S_NAMESPACE=nullplatform"
}

@test "build_link_context: NAMESPACE_OVERRIDE places the link's HTTPRoute" {
  scope_env '[{"id": 7, "slug": "users-prod", "reachability": "public", "namespace": "team-b"}]'
  routes_context '[{"path": "/api/users", "groups": ["admin"], "scope": "users-prod"}]'

  NAMESPACE_OVERRIDE=fixed run_context_script build_link_context K8S_NAMESPACE

  assert_success
  assert_output --partial "K8S_NAMESPACE=fixed"
}

@test "build_link_context: refuses routes to scopes in different namespaces" {
  scope_env '[
    {"id": 7, "slug": "users-prod",  "reachability": "public", "namespace": "team-a"},
    {"id": 8, "slug": "health-prod", "reachability": "public", "namespace": "team-b"}]'
  routes_context '[
    {"path": "/api/users", "groups": ["admin"], "scope": "users-prod"},
    {"path": "/health", "groups": ["ops"], "scope": "health-prod"}]'

  run_context_script build_link_context K8S_NAMESPACE

  assert_failure
  assert_output --partial "scopes in different namespaces: team-a team-b"
}

@test "check_link_conflict: looks for conflicts in every namespace" {
  conflict_env "/api/users" '["GET"]'
  httproute_items '[{"name": "r1", "link_id": "link-other", "host": "api.acme.com", "path": "/api/users", "method": "GET"}]' > "$KUBECTL_HTTPROUTES_FILE"

  run bash "$SERVICE_PATH/scripts/istio/check_link_conflict"

  assert_failure
  assert_file_contains "$TEST_TEMP_DIR/kubectl.log" "get httproute --all-namespaces"
}

@test "validate_domain: checks the domain owner in every namespace" {
  export KUBECTL_GATEWAY_FILE="$TEST_TEMP_DIR/gateway.json" KUBECTL_HTTPROUTES_FILE="$TEST_TEMP_DIR/httproutes.json"
  export GATEWAY_NAME=gateway-public SERVICE_ID=svc-1234 K8S_NAMESPACE=nullplatform
  jq -n '{spec: {listeners: [{hostname: "*.acme.com"}]}}' > "$KUBECTL_GATEWAY_FILE"
  echo '{"items": []}' > "$KUBECTL_HTTPROUTES_FILE"

  DOMAIN_NAME=api.acme.com run bash "$SERVICE_PATH/scripts/istio/validate_domain"

  assert_success
  assert_file_contains "$TEST_TEMP_DIR/kubectl.log" "get httproute --all-namespaces"
}

@test "delete_service_resources: removes leftover HTTPRoutes in every namespace" {
  export SERVICE_ID=svc-1234 K8S_NAMESPACE=nullplatform

  run bash "$SERVICE_PATH/scripts/istio/delete_service_resources"

  assert_success
  assert_file_contains "$TEST_TEMP_DIR/kubectl.log" "delete httproute --all-namespaces -l nullplatform.com/managed-by=http-route-access-control,nullplatform.com/service-id=svc-1234"
}
