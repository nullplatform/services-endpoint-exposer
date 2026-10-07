#!/usr/bin/env bats

load helpers

# Runs the create workflow's scripts in order (build_context, build_httproute
# public/private, manage_policies, baseline, apply, prune) with np and kubectl
# mocked, and checks what reaches the cluster.

setup() {
  export TEST_TEMP_DIR="$(mktemp -d)"
  export OUTPUT_DIR="$TEST_TEMP_DIR/output"
  mkdir -p "$OUTPUT_DIR"
  export SERVICE_PATH="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  load_bats_support_libraries

  unset NP_ACTION_CONTEXT
  export AUTH_TYPE="aws-cognito"
  export COGNITO_USER_POOL_ARN_PRODUCTION="arn:aws:cognito-idp:us-east-1:111111111111:userpool/us-east-1_pool"
  export DRY_RUN="true"
  export KUBECTL_CALLS="$TEST_TEMP_DIR/kubectl-calls"

  export NP_SCOPES='[
    {"id": 10, "slug": "prod",     "domain": "prod.example.com",     "capabilities": {"visibility": "public"},  "active_deployment": 100},
    {"id": 30, "slug": "backoffice", "domain": "bo.internal.example", "capabilities": {"visibility": "private"}, "active_deployment": 300}
  ]'
  export K8S_SERVICES='{"items": [
    {"metadata": {"name": "d-10-100"},  "spec": {"selector": {"scope_id": "10", "deployment_id": "100"}, "ports": [{"port": 8080}]}},
    {"metadata": {"name": "d-30-300"},  "spec": {"selector": {"scope_id": "30", "deployment_id": "300"}, "ports": [{"port": 8080}]}}
  ]}'

  cat > "$TEST_TEMP_DIR/np" << 'EOF'
#!/bin/bash
case "$1 $2" in
  "scope list") echo "{\"results\": $NP_SCOPES}" ;;
  "scope read")
    id=$(echo "$*" | sed -E 's/.*--id ([0-9]+).*/\1/')
    echo "$NP_SCOPES" | jq --argjson id "$id" 'first(.[] | select(.id == $id)) + {in_progress_deployment: null}' ;;
esac
EOF
  cat > "$TEST_TEMP_DIR/kubectl" << 'EOF'
#!/bin/bash
echo "$*" >> "$KUBECTL_CALLS"
case "$1 $2" in
  "get services") echo "$K8S_SERVICES" ;;
  "get authorizationpolicy") if [[ "$*" == *"-o json"* ]]; then echo '{"items": []}'; fi ;;
  "get requestauthentication") exit 1 ;;
esac
exit 0
EOF
  chmod +x "$TEST_TEMP_DIR/np" "$TEST_TEMP_DIR/kubectl"
  export PATH="$TEST_TEMP_DIR:$PATH"

  export CONTEXT=$(jq -n '{
    id: "action-1", slug: "create-http-route-access-control", tags: {application_id: "4"},
    service: {id: "svc-1", slug: "api", dimensions: {environment: "production"}},
    parameters: {routes: [
      {methods: ["GET", "POST"], path: "/orders/{id}", scope: "prod",       groups: ["admin", "ops"]},
      {methods: ["GET"],         path: "/files/*",     scope: "prod",       groups: ["admin"]},
      {methods: ["GET"],         path: "/reports",     scope: "backoffice", groups: ["finance"]}
    ]}
  }')
}

teardown() { rm -rf "$TEST_TEMP_DIR"; }

run_create() {
  bash -c '
    set -euo pipefail
    source "$SERVICE_PATH/scripts/istio/build_context"
    VISIBILITY=public  bash "$SERVICE_PATH/scripts/istio/build_httproute"
    VISIBILITY=private bash "$SERVICE_PATH/scripts/istio/build_httproute"
    ACTION=apply bash "$SERVICE_PATH/scripts/common/manage_policies"
    BASELINE_INCLUDE_RENDERED=true bash "$SERVICE_PATH/scripts/istio/sync_gateway_baseline"
    ACTION=apply bash "$SERVICE_PATH/scripts/common/apply"
    bash "$SERVICE_PATH/scripts/istio/prune_stale_resources"
  '
}

@test "integration: create renders one route per scope, on the gateway of its visibility" {
  run run_create
  assert_success

  [[ "$(yq '.spec.parentRefs[0].name' "$OUTPUT_DIR/apply/httproute-svc-1-public-10.yaml")" == "gateway-public" ]]
  [[ "$(yq '.spec.parentRefs[0].name' "$OUTPUT_DIR/apply/httproute-svc-1-private-30.yaml")" == "gateway-private" ]]
  [[ "$(yq '.spec.hostnames[0]' "$OUTPUT_DIR/apply/httproute-svc-1-private-30.yaml")" == "bo.internal.example" ]]
}

@test "integration: every routed request has exactly one policy admitting its groups" {
  run run_create
  assert_success

  routes=$(for f in "$OUTPUT_DIR"/apply/httproute-*.yaml; do yq -o=json '.' "$f"; done | jq -s -c \
    '[.[] | .spec.hostnames[0] as $h | .spec.rules[].matches[] | {h: $h, m: .method, t: .path.type, v: .path.value}] | sort')
  policies=$(for f in "$OUTPUT_DIR"/apply/authorizationpolicy-*.yaml; do yq -o=json '.' "$f"; done | jq -s -c \
    '[.[] | .spec.rules[0] as $r | {h: $r.to[0].operation.hosts[0], m: $r.to[0].operation.methods[0], p: $r.to[0].operation.paths, g: $r.when[0].values}] | sort_by(.h, .m, .p)')

  [[ "$routes" == '[{"h":"bo.internal.example","m":"GET","t":"Exact","v":"/reports"},{"h":"prod.example.com","m":"GET","t":"PathPrefix","v":"/files"},{"h":"prod.example.com","m":"GET","t":"RegularExpression","v":"/orders/[^/]+"},{"h":"prod.example.com","m":"POST","t":"RegularExpression","v":"/orders/[^/]+"}]' ]]
  [[ "$policies" == '[{"h":"bo.internal.example","m":"GET","p":["/reports"],"g":["finance"]},{"h":"prod.example.com","m":"GET","p":["/files","/files/*"],"g":["admin"]},{"h":"prod.example.com","m":"GET","p":["/orders/{*}"],"g":["admin","ops"]},{"h":"prod.example.com","m":"POST","p":["/orders/{*}"],"g":["admin","ops"]}]' ]]
}

@test "integration: the baseline keeps other hosts reachable on both gateways" {
  run run_create
  assert_success

  grep -q "create -f -" "$KUBECTL_CALLS"
  assert_output --partial "Baseline on gateway-public admits every host except prod.example.com"
  assert_output --partial "Baseline on gateway-private admits every host except bo.internal.example"
}

@test "integration: the shared RequestAuthentication is created for the pool's issuer" {
  run run_create
  assert_success

  grep -q "create -f .*request-authentication-public.yaml.tmp" "$KUBECTL_CALLS"
  grep -q "create -f .*request-authentication-private.yaml.tmp" "$KUBECTL_CALLS"
}

@test "integration: every resource carries the service labels used for cleanup" {
  run run_create
  assert_success

  for f in "$OUTPUT_DIR"/apply/*.yaml; do
    [[ "$(yq '.metadata.labels["nullplatform.com/service-id"]' "$f")" == "svc-1" ]]
    [[ "$(yq '.metadata.labels["nullplatform.com/managed-by"]' "$f")" == "http-route-access-control" ]]
  done
}
