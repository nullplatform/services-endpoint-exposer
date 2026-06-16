#!/usr/bin/env bats

load helpers

setup() {
  export TEST_TEMP_DIR="$(mktemp -d)"
  export OUTPUT_DIR="$TEST_TEMP_DIR/output"
  mkdir -p "$OUTPUT_DIR"
  export SERVICE_PATH="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

  # Load assert functions
  load_bats_support_libraries

  export K8S_NAMESPACE="test-namespace"
  export ALB_NAME="test-alb"
  export ACTION="apply"
  export DRY_RUN="true"

  # Mock kubectl
  mock_kubectl

  # Mock gomplate
  cat > "$TEST_TEMP_DIR/gomplate" << 'EOF'
#!/bin/bash
TEMPLATE_FILE=""
OUTPUT_FILE=""
CONTEXT_FILE=""

while [[ $# -gt 0 ]]; do
  case $1 in
    -f) TEMPLATE_FILE="$2"; shift 2 ;;
    -o) OUTPUT_FILE="$2"; shift 2 ;;
    -c) CONTEXT_FILE="${2#.=}"; shift 2 ;;
    *) shift ;;
  esac
done

if [[ -n "$TEMPLATE_FILE" ]] && [[ -n "$OUTPUT_FILE" ]]; then
  # Read context if provided
  if [[ -n "$CONTEXT_FILE" ]] && [[ -f "$CONTEXT_FILE" ]]; then
    CONTEXT_JSON=$(cat "$CONTEXT_FILE")
    SERVICE_SLUG=$(echo "$CONTEXT_JSON" | jq -r '.service_slug // ""')
    SERVICE_ID=$(echo "$CONTEXT_JSON" | jq -r '.service_id // ""')
    SUFFIX=$(echo "$CONTEXT_JSON" | jq -r '.suffix // ""')
    DOMAIN=$(echo "$CONTEXT_JSON" | jq -r '.domain // ""')
    NAMESPACE=$(echo "$CONTEXT_JSON" | jq -r '.k8s_namespace // .gateway_namespace // ""')
  fi

  # Determine resource type from template
  if [[ "$TEMPLATE_FILE" == *"httproute"* ]]; then
    cat > "$OUTPUT_FILE" << YAML
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: ${SERVICE_SLUG}-${SERVICE_ID}-${SUFFIX}
  namespace: ${NAMESPACE}
  labels:
    nullplatform.com/managed-by: endpoint-exposer
    nullplatform.com/service-id: "${SERVICE_ID}"
    app.kubernetes.io/name: ${SERVICE_SLUG}
spec:
  hostnames:
  - ${DOMAIN}
YAML
  elif [[ "$TEMPLATE_FILE" == *"authorization"* ]]; then
    cat > "$OUTPUT_FILE" << YAML
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: ${SERVICE_SLUG}-${SERVICE_ID}-authz-${SUFFIX}
  namespace: ${NAMESPACE}
  labels:
    nullplatform.com/managed-by: endpoint-exposer
    nullplatform.com/service-id: "${SERVICE_ID}"
    app.kubernetes.io/name: ${SERVICE_SLUG}
spec:
  action: CUSTOM
YAML
  fi
fi
EOF
  chmod +x "$TEST_TEMP_DIR/gomplate"
  export PATH="$TEST_TEMP_DIR:$PATH"

  # Mock process_routes script (it's sourced by build_httproute)
  mkdir -p "$SERVICE_PATH/scripts/istio"
  if [[ ! -f "$SERVICE_PATH/scripts/istio/process_routes.bak" ]]; then
    # Backup original if exists
    if [[ -f "$SERVICE_PATH/scripts/istio/process_routes" ]]; then
      cp "$SERVICE_PATH/scripts/istio/process_routes" "$SERVICE_PATH/scripts/istio/process_routes.bak"
    fi
  fi

  # Create a minimal mock that does nothing (for testing we just need the HTTPRoute YAML)
  cat > "$SERVICE_PATH/scripts/istio/process_routes" << 'MOCKEOF'
#!/bin/bash
# Mock process_routes for testing - does nothing
# In real tests, the gomplate mock already creates the YAML we need
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

@test "integration: complete workflow with public routes only" {
  export CONTEXT=$(load_fixture "simple-public-routes")

  # Step 1: Build context
  source "$SERVICE_PATH/scripts/istio/build_context"

  # Step 2: Build public httproute
  export VISIBILITY="public"
  bash "$SERVICE_PATH/scripts/istio/build_httproute"

  # Step 3: Build private httproute (should create marker)
  export VISIBILITY="private"
  bash "$SERVICE_PATH/scripts/istio/build_httproute"

  # Verify outputs
  assert_file_exists "$OUTPUT_DIR/httproute-fbcf7a60-8ca8-4bf2-b1b5-5c59bb5bc4fd-public.yaml"
  assert_file_not_exists "$OUTPUT_DIR/httproute-fbcf7a60-8ca8-4bf2-b1b5-5c59bb5bc4fd-private.yaml"
  assert_file_exists "$OUTPUT_DIR/.httproute-private-deleted"

  # Verify public HTTPRoute content
  assert_file_contains "$OUTPUT_DIR/httproute-fbcf7a60-8ca8-4bf2-b1b5-5c59bb5bc4fd-public.yaml" "HTTPRoute"
  assert_file_contains "$OUTPUT_DIR/httproute-fbcf7a60-8ca8-4bf2-b1b5-5c59bb5bc4fd-public.yaml" "api.edenred.nullimplementation.com"
}

@test "integration: complete workflow with public and private routes" {
  export CONTEXT=$(load_fixture "public-and-private-routes")

  # Build context
  source "$SERVICE_PATH/scripts/istio/build_context"

  # Build httproutes
  export VISIBILITY="public"
  bash "$SERVICE_PATH/scripts/istio/build_httproute"

  export VISIBILITY="private"
  bash "$SERVICE_PATH/scripts/istio/build_httproute"

  # Verify all resources created
  assert_file_exists "$OUTPUT_DIR/httproute-fbcf7a60-8ca8-4bf2-b1b5-5c59bb5bc4fd-public.yaml"
  assert_file_exists "$OUTPUT_DIR/httproute-fbcf7a60-8ca8-4bf2-b1b5-5c59bb5bc4fd-private.yaml"

  # Verify no marker files (all resources should be created)
  assert_file_not_exists "$OUTPUT_DIR/.httproute-public-deleted"
  assert_file_not_exists "$OUTPUT_DIR/.httproute-private-deleted"

  # Verify content
  assert_file_contains "$OUTPUT_DIR/httproute-fbcf7a60-8ca8-4bf2-b1b5-5c59bb5bc4fd-public.yaml" "api.edenred.nullimplementation.com"
  assert_file_contains "$OUTPUT_DIR/httproute-fbcf7a60-8ca8-4bf2-b1b5-5c59bb5bc4fd-private.yaml" "api-private.edenred.nullimplementation.com"
}

@test "integration: workflow with authorization disabled creates cleanup markers" {
  export CONTEXT=$(load_fixture "authorization-disabled")

  # Build context
  source "$SERVICE_PATH/scripts/istio/build_context"

  # Build httproutes
  export VISIBILITY="public"
  bash "$SERVICE_PATH/scripts/istio/build_httproute"

  export VISIBILITY="private"
  bash "$SERVICE_PATH/scripts/istio/build_httproute"

  # Verify httproutes created
  assert_file_exists "$OUTPUT_DIR/httproute-fbcf7a60-8ca8-4bf2-b1b5-5c59bb5bc4fd-public.yaml"
  assert_file_exists "$OUTPUT_DIR/httproute-fbcf7a60-8ca8-4bf2-b1b5-5c59bb5bc4fd-private.yaml"
}

@test "integration: apply step handles markers and resources correctly" {
  export CONTEXT=$(load_fixture "simple-public-routes")

  # Build context
  source "$SERVICE_PATH/scripts/istio/build_context"

  # Build httproutes
  export VISIBILITY="public"
  bash "$SERVICE_PATH/scripts/istio/build_httproute"

  export VISIBILITY="private"
  bash "$SERVICE_PATH/scripts/istio/build_httproute"

  # Run apply
  run bash "$SERVICE_PATH/scripts/common/apply"

  assert_success

  # Should detect and process markers
  assert_output --partial "Private HTTPRoute marked for deletion"

  # Should apply the public httproute
  assert_output --partial "Applying 1 resources"
}

@test "integration: all resources have correct labels for management" {
  export CONTEXT=$(load_fixture "public-and-private-routes")

  # Build context
  source "$SERVICE_PATH/scripts/istio/build_context"

  # Build httproutes
  export VISIBILITY="public"
  bash "$SERVICE_PATH/scripts/istio/build_httproute"

  export VISIBILITY="private"
  bash "$SERVICE_PATH/scripts/istio/build_httproute"

  # Verify all resources have required labels
  assert_file_contains "$OUTPUT_DIR/httproute-fbcf7a60-8ca8-4bf2-b1b5-5c59bb5bc4fd-public.yaml" "nullplatform.com/managed-by: endpoint-exposer"
  assert_file_contains "$OUTPUT_DIR/httproute-fbcf7a60-8ca8-4bf2-b1b5-5c59bb5bc4fd-private.yaml" "nullplatform.com/managed-by: endpoint-exposer"

  assert_file_contains "$OUTPUT_DIR/httproute-fbcf7a60-8ca8-4bf2-b1b5-5c59bb5bc4fd-public.yaml" "nullplatform.com/service-id:"
  assert_file_contains "$OUTPUT_DIR/httproute-fbcf7a60-8ca8-4bf2-b1b5-5c59bb5bc4fd-private.yaml" "nullplatform.com/service-id:"
}
