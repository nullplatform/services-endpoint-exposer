#!/usr/bin/env bats

load helpers

# Mock np so build_context's scope->visibility lookup (build_context:35-44)
# can resolve offline if a test ever exercises it. It only fires when
# APPLICATION_ID is non-empty; the tests below use an empty tags object (as
# the plan's own fixture does), so the lookup is skipped entirely and this
# mock is never actually called — it's wired up so the environment is
# complete, following the same pattern as mock_kubectl in helpers.bash.
mock_np() {
  cat > "$TEST_TEMP_DIR/np" << 'EOF'
#!/bin/bash
if [[ "$1" == "scope" && "$2" == "list" ]]; then
  cat <<'JSON'
{"results":[
  {"id":"scope-1","slug":"s1","service":{"attributes":{"visibility":"internal"}}}
]}
JSON
  exit 0
fi
echo "Mock np called with: $@" >&2
exit 0
EOF
  chmod +x "$TEST_TEMP_DIR/np"
  export PATH="$TEST_TEMP_DIR:$PATH"
}

setup() {
  export TEST_TEMP_DIR="$(mktemp -d)"
  export OUTPUT_DIR="$TEST_TEMP_DIR/output"
  mkdir -p "$OUTPUT_DIR"
  export SERVICE_PATH="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  load_bats_support_libraries
  mock_np
}

teardown() {
  [[ -n "$TEST_TEMP_DIR" && -d "$TEST_TEMP_DIR" ]] && rm -rf "$TEST_TEMP_DIR"
}

@test "el schema expone visibility por ruta" {
  run jq -e '.attributes.schema.properties.routes.items.properties.visibility.enum' \
    "$SERVICE_PATH/specs/service-spec.json.tpl"
  assert_success
  assert_output --partial '"public"'
  assert_output --partial '"internal"'
}

@test "el uiSchema tiene un control para visibility" {
  run jq -e '.. | objects | select(.scope? == "#/properties/visibility")' \
    "$SERVICE_PATH/specs/service-spec.json.tpl"
  assert_success
  assert_output --partial '"label": "Visibility"'
}

@test "visibility private legacy cae en las rutas privadas" {
  ROUTES='[{"path":"/a","methods":["GET"],"scope":"s1","visibility":"private"}]'
  run bash -c "echo '$ROUTES' | jq -c '[.[] | select(.visibility == \"internal\" or .visibility == \"private\")]'"
  assert_success
  assert_output --partial '"/a"'
}

@test "build_context normaliza private a internal" {
  export NP_ACTION_CONTEXT='{"notification":{"id":"a","slug":"update-x","service":{"id":"s","slug":"svc","dimensions":{"environment":"development"},"attributes":{"routes":[{"path":"/a","methods":["GET"],"scope":"s1","visibility":"private"}]}},"tags":{}}}'
  export AUTH_TYPE="aws-cognito"
  export COGNITO_USER_POOL_ARN_DEVELOPMENT="arn:aws:cognito-idp:us-east-1:1:userpool/us-east-1_x"
  run bash -c "source '$SERVICE_PATH/scripts/istio/build_context' && echo \$PRIVATE_ROUTES_JSON"
  assert_success
  assert_output --partial '"/a"'
}

@test "build_context no deja la ruta legacy en PUBLIC_ROUTES_JSON" {
  export NP_ACTION_CONTEXT='{"notification":{"id":"a","slug":"update-x","service":{"id":"s","slug":"svc","dimensions":{"environment":"development"},"attributes":{"routes":[{"path":"/a","methods":["GET"],"scope":"s1","visibility":"private"}]}},"tags":{}}}'
  export AUTH_TYPE="aws-cognito"
  export COGNITO_USER_POOL_ARN_DEVELOPMENT="arn:aws:cognito-idp:us-east-1:1:userpool/us-east-1_x"
  run bash -c "source '$SERVICE_PATH/scripts/istio/build_context' && echo \$PUBLIC_ROUTES_JSON"
  assert_success
  assert_output '[]'
}

@test "build_context respeta visibility internal explicita (no legacy)" {
  export NP_ACTION_CONTEXT='{"notification":{"id":"a","slug":"update-x","service":{"id":"s","slug":"svc","dimensions":{"environment":"development"},"attributes":{"routes":[{"path":"/b","methods":["GET"],"scope":"s1","visibility":"internal"}]}},"tags":{}}}'
  export AUTH_TYPE="aws-cognito"
  export COGNITO_USER_POOL_ARN_DEVELOPMENT="arn:aws:cognito-idp:us-east-1:1:userpool/us-east-1_x"
  run bash -c "source '$SERVICE_PATH/scripts/istio/build_context' && echo \$PRIVATE_ROUTES_JSON"
  assert_success
  assert_output --partial '"/b"'
}

@test "build_context deja una ruta publica explicita en PUBLIC_ROUTES_JSON" {
  export NP_ACTION_CONTEXT='{"notification":{"id":"a","slug":"update-x","service":{"id":"s","slug":"svc","dimensions":{"environment":"development"},"attributes":{"routes":[{"path":"/c","methods":["GET"],"scope":"s1","visibility":"public"}]}},"tags":{}}}'
  export AUTH_TYPE="aws-cognito"
  export COGNITO_USER_POOL_ARN_DEVELOPMENT="arn:aws:cognito-idp:us-east-1:1:userpool/us-east-1_x"
  run bash -c "source '$SERVICE_PATH/scripts/istio/build_context' && echo \$PUBLIC_ROUTES_JSON"
  assert_success
  assert_output --partial '"/c"'
}
