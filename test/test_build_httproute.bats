#!/usr/bin/env bats

load helpers

# build_httproute renders one HTTPRoute per scope from the routes of one
# visibility. np and kubectl are mocked; gomplate, yq and jq are real.

setup() {
  export TEST_TEMP_DIR="$(mktemp -d)"
  export OUTPUT_DIR="$TEST_TEMP_DIR/output"
  mkdir -p "$OUTPUT_DIR"
  export SERVICE_PATH="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  load_bats_support_libraries

  export SERVICE_ID="svc-1"
  export SERVICE_SLUG="api"
  export APPLICATION_ID="4"
  export K8S_NAMESPACE="nullplatform"
  export VISIBILITY="public"
  export PRIVATE_ROUTES_JSON='[]'

  # Scope 10 has a deployment (service d-10-100), scope 20 doesn't.
  export NP_SCOPES='[{"id": 10, "slug": "prod", "domain": "prod.example.com"},
                     {"id": 20, "slug": "staging", "domain": "staging.example.com"}]'
  export NP_ACTIVE='{"10": 100}'
  export K8S_SERVICES='{"items": [{"metadata": {"name": "d-10-100"},
    "spec": {"selector": {"scope_id": "10", "deployment_id": "100"}, "ports": [{"port": 8080}]}}]}'

  cat > "$TEST_TEMP_DIR/np" << 'EOF'
#!/bin/bash
case "$1 $2" in
  "scope list") echo "{\"results\": $NP_SCOPES}" ;;
  "scope read")
    id=$(echo "$*" | sed -E 's/.*--id ([0-9]+).*/\1/')
    echo "$NP_SCOPES" | jq --argjson id "$id" --argjson active "$NP_ACTIVE" 'first(.[] | select(.id == $id)) + {active_deployment: $active[$id|tostring], in_progress_deployment: null}' ;;
esac
EOF
  cat > "$TEST_TEMP_DIR/kubectl" << 'EOF'
#!/bin/bash
echo "$K8S_SERVICES"
EOF
  chmod +x "$TEST_TEMP_DIR/np" "$TEST_TEMP_DIR/kubectl"
  export PATH="$TEST_TEMP_DIR:$PATH"
}

teardown() { rm -rf "$TEST_TEMP_DIR"; }

route_file() { echo "$OUTPUT_DIR/httproute-svc-1-$1.yaml"; }

@test "build_httproute: one HTTPRoute per scope, each with only its own domain" {
  export PUBLIC_ROUTES_JSON='[
    {"methods": ["GET"], "path": "/health", "scope": "prod",    "groups": ["admin"]},
    {"methods": ["GET"], "path": "/health", "scope": "staging", "groups": ["admin"]}
  ]'
  export ROUTES_JSON="$PUBLIC_ROUTES_JSON"
  export NP_ACTIVE='{"10": 100, "20": 200}'
  export K8S_SERVICES='{"items": [
    {"metadata": {"name": "d-10-100"}, "spec": {"selector": {"scope_id": "10", "deployment_id": "100"}, "ports": [{"port": 8080}]}},
    {"metadata": {"name": "d-20-200"}, "spec": {"selector": {"scope_id": "20", "deployment_id": "200"}, "ports": [{"port": 8080}]}}]}'

  run bash "$SERVICE_PATH/scripts/istio/build_httproute"

  assert_success
  [[ "$(yq -o=json '.spec.hostnames' "$(route_file public-10)" | jq -c .)" == '["prod.example.com"]' ]]
  [[ "$(yq '.spec.rules[0].backendRefs[0].name' "$(route_file public-20)")" == "d-20-200" ]]
  [[ "$(yq -o=json '.spec.hostnames' "$(route_file public-20)" | jq -c .)" == '["staging.example.com"]' ]]
  [[ "$(yq '.metadata.name' "$(route_file public-10)")" == "api-svc-1-public-10" ]]
  [[ "$(sort "$OUTPUT_DIR/.httproute-expected" | tr '\n' ' ')" == "api-svc-1-public-10 api-svc-1-public-20 " ]]
}

@test "build_httproute: every route x method of a scope is a match of one rule" {
  export PUBLIC_ROUTES_JSON='[
    {"methods": ["GET", "POST"], "path": "/orders",  "scope": "prod", "groups": ["admin"]},
    {"methods": ["GET"],         "path": "/health",  "scope": "prod", "groups": ["admin"]}
  ]'
  export ROUTES_JSON="$PUBLIC_ROUTES_JSON"

  run bash "$SERVICE_PATH/scripts/istio/build_httproute"

  assert_success
  rules=$(yq -o=json '.spec.rules' "$(route_file public-10)")
  [[ "$(echo "$rules" | jq length)" == "1" ]]
  [[ "$(echo "$rules" | jq -c '[.[0].matches[] | "\(.method) \(.path.type) \(.path.value)"] | sort')" == \
     '["GET Exact /health","GET Exact /orders","POST Exact /orders"]' ]]
  [[ "$(echo "$rules" | jq -c '.[0].backendRefs')" == '[{"name":"d-10-100","port":8080}]' ]]
}

@test "build_httproute: parameters and wildcards become regex and prefix matches" {
  export PUBLIC_ROUTES_JSON='[
    {"methods": ["GET"], "path": "/items/{id}", "scope": "prod", "groups": ["admin"]},
    {"methods": ["GET"], "path": "/users/:id",  "scope": "prod", "groups": ["admin"]},
    {"methods": ["GET"], "path": "/api/*",      "scope": "prod", "groups": ["admin"]},
    {"methods": ["GET"], "path": "/api",        "scope": "prod", "groups": ["admin"]}
  ]'
  export ROUTES_JSON="$PUBLIC_ROUTES_JSON"

  run bash "$SERVICE_PATH/scripts/istio/build_httproute"

  assert_success
  [[ "$(yq -o=json '.spec.rules[0].matches' "$(route_file public-10)" | jq -c '[.[] | "\(.path.type) \(.path.value)"] | sort')" == \
     '["Exact /api","PathPrefix /api","RegularExpression /items/[^/]+","RegularExpression /users/[^/]+"]' ]]
}

@test "build_httproute: a scope without a deployment gets no HTTPRoute (404 until its first deploy)" {
  export PUBLIC_ROUTES_JSON='[{"methods": ["GET"], "path": "/health", "scope": "staging", "groups": ["admin"]}]'
  export ROUTES_JSON="$PUBLIC_ROUTES_JSON"

  run bash "$SERVICE_PATH/scripts/istio/build_httproute"

  assert_success
  assert_output --partial "Scope 'staging' has no deployment yet"
  assert_file_not_exists "$(route_file public-20)"
  ! grep -q "public-20" "$OUTPUT_DIR/.httproute-expected"
}

@test "build_httproute: unsupported wildcards are skipped with a warning" {
  export PUBLIC_ROUTES_JSON='[
    {"methods": ["GET"], "path": "/x*/y",   "scope": "prod", "groups": ["admin"]},
    {"methods": ["GET"], "path": "/health", "scope": "prod", "groups": ["admin"]}
  ]'
  export ROUTES_JSON="$PUBLIC_ROUTES_JSON"

  run bash "$SERVICE_PATH/scripts/istio/build_httproute"

  assert_success
  assert_output --partial "WARNING: skipping route: unsupported wildcard in /x*/y"
  [[ "$(yq '.spec.rules[0].matches | length' "$(route_file public-10)")" == "1" ]]
}

@test "build_httproute: more than 64 matches are split across rules" {
  export PUBLIC_ROUTES_JSON=$(jq -nc '[range(0; 70) | {methods: ["GET"], path: "/p\(.)", scope: "prod", groups: ["admin"]}]')
  export ROUTES_JSON="$PUBLIC_ROUTES_JSON"

  run bash "$SERVICE_PATH/scripts/istio/build_httproute"

  assert_success
  [[ "$(yq -o=json '.spec.rules' "$(route_file public-10)" | jq -c '[.[] | .matches | length]')" == '[64,6]' ]]
}

@test "build_httproute: no routes leaves a marker so earlier HTTPRoutes are removed" {
  export PUBLIC_ROUTES_JSON='[]'
  export ROUTES_JSON='[]'

  run bash "$SERVICE_PATH/scripts/istio/build_httproute"

  assert_success
  assert_file_exists "$OUTPUT_DIR/.httproute-public-deleted"
  assert_file_exists "$OUTPUT_DIR/.httproute-expected"
}

@test "build_httproute: private routes attach to the private gateway" {
  export VISIBILITY="private"
  export PUBLIC_ROUTES_JSON='[]'
  export PRIVATE_ROUTES_JSON='[{"methods": ["GET"], "path": "/internal", "scope": "prod", "groups": ["admin"]}]'
  export ROUTES_JSON="$PRIVATE_ROUTES_JSON"

  run bash "$SERVICE_PATH/scripts/istio/build_httproute"

  assert_success
  [[ "$(yq '.spec.parentRefs[0].name' "$(route_file private-10)")" == "gateway-private" ]]
}
