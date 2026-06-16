#!/usr/bin/env bats

load helpers

setup() {
  # Call parent setup
  export TEST_TEMP_DIR="$(mktemp -d)"
  export OUTPUT_DIR="$TEST_TEMP_DIR/output"
  mkdir -p "$OUTPUT_DIR"
  export SERVICE_PATH="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

  # Load assert functions
  load_bats_support_libraries

  # Mock kubectl and provider data
  export K8S_NAMESPACE="test-namespace"
  export ALB_NAME="test-alb"

  # Mock gomplate
  cat > "$TEST_TEMP_DIR/gomplate" << 'EOF'
#!/bin/bash
# Simple gomplate mock - just copy template to output
TEMPLATE_FILE=""
OUTPUT_FILE=""

while [[ $# -gt 0 ]]; do
  case $1 in
    -f) TEMPLATE_FILE="$2"; shift 2 ;;
    -o) OUTPUT_FILE="$2"; shift 2 ;;
    -c) shift 2 ;; # Ignore context
    *) shift ;;
  esac
done

if [[ -n "$TEMPLATE_FILE" ]] && [[ -n "$OUTPUT_FILE" ]]; then
  # For testing, just create a valid YAML with the service info
  cat > "$OUTPUT_FILE" << YAML
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: ${SERVICE_SLUG}-${SERVICE_ID}-${SUFFIX:-public}
  namespace: ${K8S_NAMESPACE}
spec:
  hostnames:
  - ${DOMAIN}
YAML
fi
EOF
  chmod +x "$TEST_TEMP_DIR/gomplate"
  export PATH="$TEST_TEMP_DIR:$PATH"

  # Mock process_routes script
  if [[ ! -f "$SERVICE_PATH/scripts/istio/process_routes.bak" ]]; then
    if [[ -f "$SERVICE_PATH/scripts/istio/process_routes" ]]; then
      cp "$SERVICE_PATH/scripts/istio/process_routes" "$SERVICE_PATH/scripts/istio/process_routes.bak"
    fi
  fi
  cat > "$SERVICE_PATH/scripts/istio/process_routes" << 'MOCKEOF'
#!/bin/bash
# Mock - does nothing
# Use return instead of exit so it doesn't exit the sourcing shell
return 0 2>/dev/null || true
MOCKEOF
  chmod +x "$SERVICE_PATH/scripts/istio/process_routes"
}

teardown() {
  # Always restore original process_routes if backup exists
  if [[ -f "$SERVICE_PATH/scripts/istio/process_routes.bak" ]]; then
    mv -f "$SERVICE_PATH/scripts/istio/process_routes.bak" "$SERVICE_PATH/scripts/istio/process_routes"
  fi

  # Clean up temp directory
  if [[ -n "$TEST_TEMP_DIR" ]] && [[ -d "$TEST_TEMP_DIR" ]]; then
    rm -rf "$TEST_TEMP_DIR"
  fi
}

@test "build_httproute: generates public HTTPRoute with routes" {
  export CONTEXT=$(load_fixture "simple-public-routes")
  source "$SERVICE_PATH/scripts/istio/build_context"

  export VISIBILITY="public"

  run bash "$SERVICE_PATH/scripts/istio/build_httproute"

  assert_success
  assert_file_exists "$OUTPUT_DIR/httproute-fbcf7a60-8ca8-4bf2-b1b5-5c59bb5bc4fd-public.yaml"
}

@test "build_httproute: generates private HTTPRoute with routes" {
  export CONTEXT=$(load_fixture "public-and-private-routes")
  source "$SERVICE_PATH/scripts/istio/build_context"

  export VISIBILITY="private"

  run bash "$SERVICE_PATH/scripts/istio/build_httproute"

  assert_success
  assert_file_exists "$OUTPUT_DIR/httproute-fbcf7a60-8ca8-4bf2-b1b5-5c59bb5bc4fd-private.yaml"
}

@test "build_httproute: creates marker file when no public routes" {
  export CONTEXT=$(load_fixture "no-public-routes")
  source "$SERVICE_PATH/scripts/istio/build_context"

  export VISIBILITY="public"

  run bash "$SERVICE_PATH/scripts/istio/build_httproute"

  assert_success
  assert_file_not_exists "$OUTPUT_DIR/httproute-fbcf7a60-8ca8-4bf2-b1b5-5c59bb5bc4fd-public.yaml"
  assert_file_exists "$OUTPUT_DIR/.httproute-public-deleted"
}

@test "build_httproute: creates marker file when no public domain" {
  export CONTEXT='{
    "service": {"id": "test-id", "slug": "test"},
    "parameters": {"publicDomain": "", "privateDomain": "private.test.com"},
    "routes": [{"path": "/test", "method": "GET", "scope": "test", "visibility": "public"}]
  }'
  source "$SERVICE_PATH/scripts/istio/build_context"

  export VISIBILITY="public"

  run bash "$SERVICE_PATH/scripts/istio/build_httproute"

  assert_success
  assert_file_not_exists "$OUTPUT_DIR/httproute-test-id-public.yaml"
  assert_file_exists "$OUTPUT_DIR/.httproute-public-deleted"
}

@test "build_httproute: creates marker file when no private routes" {
  export CONTEXT=$(load_fixture "simple-public-routes")
  source "$SERVICE_PATH/scripts/istio/build_context"

  export VISIBILITY="private"

  run bash "$SERVICE_PATH/scripts/istio/build_httproute"

  assert_success
  assert_file_not_exists "$OUTPUT_DIR/httproute-fbcf7a60-8ca8-4bf2-b1b5-5c59bb5bc4fd-private.yaml"
  assert_file_exists "$OUTPUT_DIR/.httproute-private-deleted"
}

@test "build_httproute: fails with invalid visibility" {
  export CONTEXT=$(load_fixture "simple-public-routes")
  source "$SERVICE_PATH/scripts/istio/build_context"

  export VISIBILITY="invalid"

  run bash "$SERVICE_PATH/scripts/istio/build_httproute"

  assert_failure
}

@test "build_httproute: exports HTTPROUTE_PUBLIC_FILE for public" {
  export CONTEXT=$(load_fixture "simple-public-routes")
  source "$SERVICE_PATH/scripts/istio/build_context"

  export VISIBILITY="public"

  source "$SERVICE_PATH/scripts/istio/build_httproute"

  [[ -n "$HTTPROUTE_PUBLIC_FILE" ]]
  [[ "$HTTPROUTE_PUBLIC_FILE" == *"public.yaml" ]]
}

@test "build_httproute: exports HTTPROUTE_PRIVATE_FILE for private" {
  export CONTEXT=$(load_fixture "public-and-private-routes")
  source "$SERVICE_PATH/scripts/istio/build_context"

  export VISIBILITY="private"

  source "$SERVICE_PATH/scripts/istio/build_httproute"

  [[ -n "$HTTPROUTE_PRIVATE_FILE" ]]
  [[ "$HTTPROUTE_PRIVATE_FILE" == *"private.yaml" ]]
}
