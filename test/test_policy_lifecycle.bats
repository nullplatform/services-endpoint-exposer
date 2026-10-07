#!/usr/bin/env bats

load helpers

setup() {
  export TEST_TEMP_DIR="$(mktemp -d)"
  export OUTPUT_DIR="$TEST_TEMP_DIR/output"
  mkdir -p "$OUTPUT_DIR"
  export SERVICE_PATH="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

  load_bats_support_libraries

  export SERVICE_ID="svc-1"
  export AUTH_TYPE="aws-cognito"
  export KUBECTL_CALLS="$TEST_TEMP_DIR/kubectl-calls"
  export EXISTING_POLICIES="hrac-svc-1-public-keep hrac-svc-1-public-stale"
  export EXISTING_HTTPROUTES="api-svc-1-public-10 api-svc-1-public-20 api-svc-1-public"
  export K8S_NAMESPACE="nullplatform"

  # kubectl mock: `get authorizationpolicy` returns EXISTING_POLICIES, every
  # call is logged.
  cat > "$TEST_TEMP_DIR/kubectl" << 'EOF2'
#!/bin/bash
echo "$*" >> "$KUBECTL_CALLS"
if [[ "$1 $2" == "get authorizationpolicy" ]]; then
  echo -n "$EXISTING_POLICIES"
elif [[ "$1 $2" == "get httproute" ]]; then
  echo -n "$EXISTING_HTTPROUTES"
fi
exit 0
EOF2
  chmod +x "$TEST_TEMP_DIR/kubectl"
  export PATH="$TEST_TEMP_DIR:$PATH"
}

teardown() {
  rm -rf "$TEST_TEMP_DIR"
}

@test "prune: deletes only the policies this run didn't render" {
  echo "hrac-svc-1-public-keep" > "$OUTPUT_DIR/.authz-expected"

  run bash "$SERVICE_PATH/scripts/istio/prune_stale_resources"

  assert_success
  grep -q "delete authorizationpolicy hrac-svc-1-public-stale" "$KUBECTL_CALLS"
  ! grep -q "delete authorizationpolicy hrac-svc-1-public-keep" "$KUBECTL_CALLS"
}

@test "prune: an empty list (all routes removed) deletes every policy of the service" {
  : > "$OUTPUT_DIR/.authz-expected"

  run bash "$SERVICE_PATH/scripts/istio/prune_stale_resources"

  assert_success
  grep -q "delete authorizationpolicy hrac-svc-1-public-keep" "$KUBECTL_CALLS"
  grep -q "delete authorizationpolicy hrac-svc-1-public-stale" "$KUBECTL_CALLS"
}

@test "prune: deletes HTTPRoutes of removed scopes and the old per-visibility route" {
  echo "api-svc-1-public-10" > "$OUTPUT_DIR/.httproute-expected"

  run bash "$SERVICE_PATH/scripts/istio/prune_stale_resources"

  assert_success
  grep -q "delete httproute api-svc-1-public-20 -n nullplatform" "$KUBECTL_CALLS"
  grep -q "delete httproute api-svc-1-public -n nullplatform" "$KUBECTL_CALLS"
  ! grep -q "delete httproute api-svc-1-public-10 " "$KUBECTL_CALLS"
}

@test "prune: without the rendered list it deletes nothing" {
  run bash "$SERVICE_PATH/scripts/istio/prune_stale_resources"

  assert_success
  assert_output --partial "skipping prune"
  ! grep -q "delete" "$KUBECTL_CALLS" 2>/dev/null
}

@test "manage_policies sync: never deletes policies before they are re-applied" {
  export ACTION="sync"
  export ROUTES_JSON='[]'
  export APPLICATION_ID="1"
  export COGNITO_USER_POOL_ARN=""
  cat > "$TEST_TEMP_DIR/np" << 'EOF2'
#!/bin/bash
echo '{"results":[]}'
EOF2
  chmod +x "$TEST_TEMP_DIR/np"

  run bash "$SERVICE_PATH/scripts/common/manage_policies"

  assert_success
  ! grep -q "delete authorizationpolicy" "$KUBECTL_CALLS" 2>/dev/null
}

@test "manage_policies delete: cleans RequestAuthentication even when the service has no policies left" {
  export ACTION="delete"
  export EXISTING_POLICIES=""
  export COGNITO_USER_POOL_ARN="arn:aws:cognito-idp:us-east-1:111111111111:userpool/us-east-1_abc"
  export GATEWAY_NAMESPACE="gateways"

  run bash "$SERVICE_PATH/scripts/common/manage_policies"

  assert_success
  assert_output --partial "Cleaning up RequestAuthentication"
}
