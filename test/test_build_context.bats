#!/usr/bin/env bats

load helpers

setup() {
  export TEST_TEMP_DIR="$(mktemp -d)"
  export OUTPUT_DIR="$TEST_TEMP_DIR/output"
  mkdir -p "$OUTPUT_DIR"
  export SERVICE_PATH="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

  load_bats_support_libraries

  unset NP_ACTION_CONTEXT
  export AUTH_TYPE="aws-cognito"
  export COGNITO_USER_POOL_ARN_STAGING="arn:aws:cognito-idp:us-east-1:111111111111:userpool/us-east-1_abc"

  # Scopes of the application as `np scope list` returns them. Visibility lives
  # in capabilities.visibility; legacy-api uses the old service attribute.
  export NP_SCOPES='[
    {"id": 10, "slug": "api-public",  "capabilities": {"visibility": "public"}},
    {"id": 20, "slug": "api-private", "capabilities": {"visibility": "private"}},
    {"id": 30, "slug": "legacy-api",  "service": {"attributes": {"visibility": "internal"}}}
  ]'
  cat > "$TEST_TEMP_DIR/np" << 'EOF'
#!/bin/bash
echo "{\"results\": $NP_SCOPES}"
EOF
  chmod +x "$TEST_TEMP_DIR/np"
  export PATH="$TEST_TEMP_DIR:$PATH"
}

teardown() {
  rm -rf "$TEST_TEMP_DIR"
}

context_with_routes() {
  jq -n --argjson routes "$1" '{
    id: "action-1",
    slug: "create-http-route-access-control",
    tags: {application_id: "4"},
    service: {id: "svc-1", slug: "api", dimensions: {environment: "staging"}},
    parameters: {routes: $routes}
  }'
}

@test "build_context: extracts service, action and application ids" {
  export CONTEXT=$(context_with_routes '[]')

  source "$SERVICE_PATH/scripts/istio/build_context"

  [[ "$SERVICE_ID" == "svc-1" ]]
  [[ "$SERVICE_SLUG" == "api" ]]
  [[ "$ACTION_ID" == "action-1" ]]
  [[ "$APPLICATION_ID" == "4" ]]
}

@test "build_context: reads the notification from NP_ACTION_CONTEXT" {
  export NP_ACTION_CONTEXT="'$(jq -n --argjson n "$(context_with_routes '[]')" '{notification: $n}')'"
  export CONTEXT='{"account": {}, "application": {}}'

  source "$SERVICE_PATH/scripts/istio/build_context"

  [[ "$SERVICE_ID" == "svc-1" ]]
}

@test "build_context: resolves visibility from the scope's capabilities" {
  export CONTEXT=$(context_with_routes '[
    {"methods": ["GET"], "path": "/a", "scope": "api-public",  "groups": ["admin"]},
    {"methods": ["GET"], "path": "/b", "scope": "api-private", "groups": ["admin"]},
    {"methods": ["GET"], "path": "/c", "scope": "legacy-api",  "groups": ["admin"]}
  ]')

  source "$SERVICE_PATH/scripts/istio/build_context"

  [[ "$(echo "$PUBLIC_ROUTES_JSON" | jq -c '[.[].path]')" == '["/a"]' ]]
  [[ "$(echo "$PRIVATE_ROUTES_JSON" | jq -c '[.[].path]')" == '["/b","/c"]' ]]
}

@test "build_context: recomputes a stale stored visibility" {
  export CONTEXT=$(context_with_routes '[
    {"methods": ["GET"], "path": "/b", "scope": "api-private", "groups": ["admin"], "visibility": "public"}
  ]')

  source "$SERVICE_PATH/scripts/istio/build_context"

  [[ "$(echo "$PUBLIC_ROUTES_JSON" | jq 'length')" == "0" ]]
  [[ "$(echo "$PRIVATE_ROUTES_JSON" | jq 'length')" == "1" ]]
}

@test "build_context: falls back to the stored attributes when the action has no routes" {
  export CONTEXT=$(jq -n '{
    id: "action-2", slug: "delete-http-route-access-control", tags: {application_id: "4"},
    service: {id: "svc-1", slug: "api", dimensions: {environment: "staging"},
              attributes: {routes: [{"methods": ["GET"], "path": "/a", "scope": "api-public", "groups": ["admin"]}]}},
    parameters: {}
  }')

  source "$SERVICE_PATH/scripts/istio/build_context"

  [[ "$(echo "$ROUTES_JSON" | jq 'length')" == "1" ]]
}

@test "build_context: picks the Cognito pool of the service's environment" {
  export CONTEXT=$(context_with_routes '[]')

  source "$SERVICE_PATH/scripts/istio/build_context"

  [[ "$COGNITO_USER_POOL_ARN" == "$COGNITO_USER_POOL_ARN_STAGING" ]]
}

@test "build_context: fails when the environment has no Cognito pool" {
  unset COGNITO_USER_POOL_ARN_STAGING
  export CONTEXT=$(context_with_routes '[]')

  run bash -c "source '$SERVICE_PATH/scripts/istio/build_context'"

  assert_failure
  assert_output --partial "COGNITO_USER_POOL_ARN_STAGING is required"
}
