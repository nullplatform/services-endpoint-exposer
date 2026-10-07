#!/usr/bin/env bats

load helpers

setup() {
  export TEST_TEMP_DIR="$(mktemp -d)"
  export OUTPUT_DIR="$TEST_TEMP_DIR/output"
  mkdir -p "$OUTPUT_DIR"
  export SERVICE_PATH="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  load_bats_support_libraries

  export AUTH_TYPE="aws-cognito"
  export KUBECTL_CALLS="$TEST_TEMP_DIR/kubectl-calls"
  export WRITES="$TEST_TEMP_DIR/writes"
  export EXISTING_BASELINE=""

  # kubectl mock: `get` returns the exposer policies (+ EXTRA_POLICIES and an
  # existing baseline), `create -f -` and `patch` record what would be written.
  cat > "$TEST_TEMP_DIR/kubectl" << 'EOF2'
#!/bin/bash
echo "$*" >> "$KUBECTL_CALLS"
case "$1" in
  get)
    jq -n --argjson extra "${EXTRA_POLICIES:-[]}" --argjson baseline "${EXISTING_BASELINE:-null}" '{items: ([
      {metadata: {name: "hrac-a", labels: {"nullplatform.com/managed-by": "http-route-access-control"}},
       spec: {selector: {matchLabels: {"gateway.networking.k8s.io/gateway-name": "gateway-public"}}, action: "ALLOW",
              rules: [{to: [{operation: {hosts: ["a.example.com"]}}]}]}}
    ] + $extra + (if $baseline then [$baseline] else [] end))}' ;;
  create) { echo "CREATE"; cat; } >> "$WRITES" ;;
  patch) echo "PATCH ${*: -1}" >> "$WRITES" ;;
esac
exit 0
EOF2
  chmod +x "$TEST_TEMP_DIR/kubectl"
  export PATH="$TEST_TEMP_DIR:$PATH"
}

teardown() { rm -rf "$TEST_TEMP_DIR"; }

baseline_with() {
  jq -nc --argjson h "$1" '{metadata: {name: "hrac-baseline-gateway-public", resourceVersion: "42",
    labels: {"nullplatform.com/managed-by": "http-route-access-control-baseline"}},
    spec: {selector: {matchLabels: {"gateway.networking.k8s.io/gateway-name": "gateway-public"}}, action: "ALLOW",
           rules: [{to: [{operation: {notHosts: $h}}]}]}}'
}

written_not_hosts() {
  if grep -q '^CREATE' "$WRITES"; then
    sed '1d' "$WRITES" | jq -c '.spec.rules[0].to[0].operation.notHosts'
  else
    sed 's/^PATCH -p=//' "$WRITES" | jq -c '.[1].value[0].to[0].operation.notHosts'
  fi
}

@test "baseline: created admitting every host except the exposer's" {
  run bash "$SERVICE_PATH/scripts/istio/sync_gateway_baseline"

  assert_success
  [[ "$(written_not_hosts)" == '["a.example.com","a.example.com:*"]' ]]
  grep -q "delete authorizationpolicy hrac-baseline-gateway-private" "$KUBECTL_CALLS"
}

@test "baseline: never drops a host another run added (written with resourceVersion)" {
  export EXISTING_BASELINE=$(baseline_with '["b.example.com","b.example.com:*"]')

  run bash "$SERVICE_PATH/scripts/istio/sync_gateway_baseline"

  assert_success
  [[ "$(written_not_hosts)" == '["a.example.com","a.example.com:*","b.example.com","b.example.com:*"]' ]]
  grep -q '"op":"test","path":"/metadata/resourceVersion","value":"42"' "$WRITES"
}

@test "baseline: drops a host only when this run removed its policies" {
  export EXISTING_BASELINE=$(baseline_with '["b.example.com","b.example.com:*"]')
  echo "b.example.com" > "$OUTPUT_DIR/.authz-removed-hosts"

  run bash "$SERVICE_PATH/scripts/istio/sync_gateway_baseline"

  assert_success
  [[ "$(written_not_hosts)" == '["a.example.com","a.example.com:*"]' ]]
}

@test "baseline: keeps a removed host that another exposer policy still uses" {
  echo "a.example.com" > "$OUTPUT_DIR/.authz-removed-hosts"

  run bash "$SERVICE_PATH/scripts/istio/sync_gateway_baseline"

  assert_success
  [[ "$(written_not_hosts)" == '["a.example.com","a.example.com:*"]' ]]
}

@test "baseline: never widens another team's host-scoped ALLOW policy" {
  export EXTRA_POLICIES='[{"metadata": {"name": "team-x"}, "spec": {"selector": {"matchLabels": {"gateway.networking.k8s.io/gateway-name": "gateway-public"}},
    "action": "ALLOW", "rules": [{"to": [{"operation": {"hosts": ["x.example.com"], "paths": ["/public"]}}]}]}}]'

  run bash "$SERVICE_PATH/scripts/istio/sync_gateway_baseline"

  assert_success
  [[ "$(written_not_hosts)" == '["a.example.com","a.example.com:*","x.example.com","x.example.com:*"]' ]]
}

@test "baseline: not kept when another team already has a gateway-wide ALLOW policy" {
  export EXTRA_POLICIES='[{"metadata": {"name": "team-y"}, "spec": {"action": "ALLOW", "rules": [{"from": [{"source": {"namespaces": ["y"]}}]}]}}]'

  run bash "$SERVICE_PATH/scripts/istio/sync_gateway_baseline"

  assert_success
  assert_output --partial "not keeping a baseline"
  grep -q "delete authorizationpolicy hrac-baseline-gateway-public" "$KUBECTL_CALLS"
  [[ ! -s "$WRITES" ]]
}

@test "baseline: before apply it already excludes the hosts being created" {
  cat > "$OUTPUT_DIR/authorizationpolicy-svc-public-1.yaml" << 'EOF2'
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: hrac-new
  labels:
    nullplatform.com/managed-by: http-route-access-control
spec:
  selector:
    matchLabels:
      gateway.networking.k8s.io/gateway-name: gateway-public
  action: ALLOW
  rules:
    - to:
        - operation:
            hosts: ["new.example.com"]
EOF2
  export BASELINE_INCLUDE_RENDERED="true"

  run bash "$SERVICE_PATH/scripts/istio/sync_gateway_baseline"

  assert_success
  [[ "$(written_not_hosts)" == '["a.example.com","a.example.com:*","new.example.com","new.example.com:*"]' ]]
}
