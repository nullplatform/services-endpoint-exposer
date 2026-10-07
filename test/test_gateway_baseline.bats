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
  export APPLIED="$TEST_TEMP_DIR/applied"
  export CLUSTER_POLICIES='{"items": [
    {"spec": {"selector": {"matchLabels": {"gateway.networking.k8s.io/gateway-name": "gateway-public"}},
              "rules": [{"to": [{"operation": {"hosts": ["a.example.com"]}}]}]}},
    {"spec": {"selector": {"matchLabels": {"gateway.networking.k8s.io/gateway-name": "gateway-public"}},
              "rules": [{"to": [{"operation": {"hosts": ["b.example.com"]}}]}]}}
  ]}'

  cat > "$TEST_TEMP_DIR/kubectl" << 'EOF2'
#!/bin/bash
echo "$*" >> "$KUBECTL_CALLS"
case "$1" in
  get) echo "$CLUSTER_POLICIES" ;;
  apply) cat >> "$APPLIED"; echo "---" >> "$APPLIED" ;;
esac
exit 0
EOF2
  chmod +x "$TEST_TEMP_DIR/kubectl"
  export PATH="$TEST_TEMP_DIR:$PATH"
}

teardown() { rm -rf "$TEST_TEMP_DIR"; }

@test "baseline: admits every host except the ones the exposer manages" {
  run bash "$SERVICE_PATH/scripts/istio/sync_gateway_baseline"

  assert_success
  [[ "$(jq -s -c '.[0] | {name: .metadata.name, notHosts: .spec.rules[0].to[0].operation.notHosts, action: .spec.action}' < <(sed '/^---$/d' "$APPLIED"))" == \
     '{"name":"hrac-baseline-gateway-public","notHosts":["a.example.com","a.example.com:*","b.example.com","b.example.com:*"],"action":"ALLOW"}' ]]
}

@test "baseline: removed from a gateway without exposer policies" {
  run bash "$SERVICE_PATH/scripts/istio/sync_gateway_baseline"

  assert_success
  grep -q "delete authorizationpolicy hrac-baseline-gateway-private" "$KUBECTL_CALLS"
}

@test "baseline: before apply it already excludes the hosts being created" {
  export CLUSTER_POLICIES='{"items": []}'
  cat > "$OUTPUT_DIR/authorizationpolicy-svc-public-1.yaml" << 'EOF2'
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
spec:
  selector:
    matchLabels:
      gateway.networking.k8s.io/gateway-name: gateway-public
  rules:
    - to:
        - operation:
            hosts: ["new.example.com"]
EOF2
  export BASELINE_INCLUDE_RENDERED="true"

  run bash "$SERVICE_PATH/scripts/istio/sync_gateway_baseline"

  assert_success
  grep -q '"new.example.com:\*"' "$APPLIED"
}
