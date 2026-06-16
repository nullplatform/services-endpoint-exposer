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

  # Mock K8S_NAMESPACE (required by build_context)
  export K8S_NAMESPACE="test-namespace"
}

teardown() {
  if [[ -n "$TEST_TEMP_DIR" ]] && [[ -d "$TEST_TEMP_DIR" ]]; then
    rm -rf "$TEST_TEMP_DIR"
  fi
}

@test "build_context: extracts service id and slug correctly" {
  export CONTEXT=$(load_fixture "simple-public-routes")

  source "$SERVICE_PATH/scripts/istio/build_context"

  [[ "$SERVICE_ID" == "fbcf7a60-8ca8-4bf2-b1b5-5c59bb5bc4fd" ]]
  [[ "$SERVICE_SLUG" == "api" ]]
}

@test "build_context: extracts public and private domains" {
  export CONTEXT=$(load_fixture "public-and-private-routes")

  source "$SERVICE_PATH/scripts/istio/build_context"

  [[ "$PUBLIC_DOMAIN" == "api.edenred.nullimplementation.com" ]]
  [[ "$PRIVATE_DOMAIN" == "api-private.edenred.nullimplementation.com" ]]
}

@test "build_context: splits routes by visibility" {
  export CONTEXT=$(load_fixture "public-and-private-routes")

  source "$SERVICE_PATH/scripts/istio/build_context"

  # Check public routes
  local num_public=$(echo "$PUBLIC_ROUTES_JSON" | jq 'length')
  [[ "$num_public" == "1" ]]

  # Check private routes
  local num_private=$(echo "$PRIVATE_ROUTES_JSON" | jq 'length')
  [[ "$num_private" == "2" ]]
}

@test "build_context: handles missing visibility as public" {
  export CONTEXT='{
    "service": {"id": "test-id", "slug": "test"},
    "parameters": {"publicDomain": "test.com", "privateDomain": ""},
    "routes": [
      {"path": "/test", "method": "GET", "scope": "test:read"}
    ]
  }'

  source "$SERVICE_PATH/scripts/istio/build_context"

  # Route without visibility should be treated as public
  local num_public=$(echo "$PUBLIC_ROUTES_JSON" | jq 'length')
  [[ "$num_public" == "1" ]]

  local num_private=$(echo "$PRIVATE_ROUTES_JSON" | jq 'length')
  [[ "$num_private" == "0" ]]
}

@test "build_context: handles empty private domain" {
  export CONTEXT=$(load_fixture "simple-public-routes")

  source "$SERVICE_PATH/scripts/istio/build_context"

  [[ "$PUBLIC_DOMAIN" == "api.edenred.nullimplementation.com" ]]
  [[ -z "$PRIVATE_DOMAIN" ]]
}

@test "build_context: exports all required variables" {
  export CONTEXT=$(load_fixture "public-and-private-routes")

  source "$SERVICE_PATH/scripts/istio/build_context"

  # Check that all required variables are exported
  [[ -n "$SERVICE_ID" ]]
  [[ -n "$SERVICE_SLUG" ]]
  [[ -n "$PUBLIC_DOMAIN" ]]
  [[ -n "$PRIVATE_DOMAIN" ]]
  [[ -n "$ROUTES_JSON" ]]
  [[ -n "$PUBLIC_ROUTES_JSON" ]]
  [[ -n "$PRIVATE_ROUTES_JSON" ]]
}
