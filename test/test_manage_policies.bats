#!/usr/bin/env bats

# AUTH_TYPE=none: routes are exposed through unconditional ALLOW policies,
# and the groups requirement only applies when auth is enabled.
# np and kubectl are stubbed on PATH so the tests run without a cluster.

load helpers

setup() {
  export TEST_TEMP_DIR="$(mktemp -d)"
  export OUTPUT_DIR="$TEST_TEMP_DIR/output"
  mkdir -p "$OUTPUT_DIR"
  export SERVICE_PATH="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  load_bats_support_libraries

  unset NP_ACTION_CONTEXT
  export CALLS_LOG="$TEST_TEMP_DIR/calls.log"
  touch "$CALLS_LOG"

  mkdir -p "$TEST_TEMP_DIR/bin"
  cat > "$TEST_TEMP_DIR/bin/np" <<'EOF'
#!/bin/bash
echo "np $*" >> "$CALLS_LOG"
case "$1 $2" in
  "scope list") echo '{"results":[{"id":"10","slug":"users-prod","service":{"attributes":{"visibility":"external"}}}]}' ;;
  "scope read") echo '{"domain":"users.example.com"}' ;;
  *) echo '{}' ;;
esac
EOF
  cat > "$TEST_TEMP_DIR/bin/kubectl" <<'EOF'
#!/bin/bash
echo "kubectl $*" >> "$CALLS_LOG"
[[ "$1 $2" == "get authorizationpolicy" ]] && echo "${EXISTING_POLICIES:-}"
exit 0
EOF
  chmod +x "$TEST_TEMP_DIR/bin/np" "$TEST_TEMP_DIR/bin/kubectl"
  export PATH="$TEST_TEMP_DIR/bin:$PATH"
}

teardown() {
  if [[ -n "$TEST_TEMP_DIR" ]] && [[ -d "$TEST_TEMP_DIR" ]]; then
    rm -rf "$TEST_TEMP_DIR"
  fi
}

# context <type> <routes-json> [environment]
context() {
  jq -n --arg type "$1" --argjson routes "$2" --arg env "${3:-}" '{
    id: "action-1", slug: "create-api", type: $type,
    parameters: {routes: $routes},
    service: {id: "fbcf7a60-8ca8-4bf2-b1b5-5c59bb5bc4fd", slug: "api",
              dimensions: (if $env == "" then {} else {environment: $env} end)},
    tags: {application_id: "179976948"}
  }'
}

ROUTES_NO_GROUPS='[{"methods":["GET","POST"],"path":"/api/users","scope":"users-prod"}]'
ROUTES_WITH_GROUPS='[{"methods":["GET"],"path":"/api/users","scope":"users-prod","groups":["admin"]}]'

@test "build_context: none accepts routes without groups and needs no environment or ARNs" {
  export AUTH_TYPE="none"
  export CONTEXT=$(context create "$ROUTES_NO_GROUPS")

  source "$SERVICE_PATH/scripts/istio/build_context"

  [[ "$COGNITO_USER_POOL_ARN" == "" ]]
  [[ "$AVP_POLICY_STORE_ID" == "" ]]
  [[ "$(echo "$PUBLIC_ROUTES_JSON" | jq 'length')" == "1" ]]
}

@test "build_context: aws-cognito rejects routes without groups" {
  export AUTH_TYPE="aws-cognito"
  export COGNITO_USER_POOL_ARN_DEV="arn:aws:cognito-idp:us-east-1:123456789:userpool/us-east-1_AbCdEf"
  export CONTEXT=$(context create "$ROUTES_NO_GROUPS" dev)

  run bash "$SERVICE_PATH/scripts/istio/build_context"

  assert_failure
  assert_output --partial "requires at least one authorized group per route"
  assert_output --partial "GET,POST /api/users"
}

@test "build_context: aws-cognito still allows deleting a service whose routes lack groups" {
  export AUTH_TYPE="aws-cognito"
  export COGNITO_USER_POOL_ARN_DEV="arn:aws:cognito-idp:us-east-1:123456789:userpool/us-east-1_AbCdEf"
  export CONTEXT=$(context delete "$ROUTES_NO_GROUPS" dev)

  run bash "$SERVICE_PATH/scripts/istio/build_context"

  assert_success
}

@test "build_context: aws-cognito accepts routes with groups" {
  export AUTH_TYPE="aws-cognito"
  export COGNITO_USER_POOL_ARN_DEV="arn:aws:cognito-idp:us-east-1:123456789:userpool/us-east-1_AbCdEf"
  export CONTEXT=$(context create "$ROUTES_WITH_GROUPS" dev)

  run bash "$SERVICE_PATH/scripts/istio/build_context"

  assert_success
}

@test "manage_policies: none apply emits unconditional ALLOW policies and no RequestAuthentication" {
  export AUTH_TYPE="none" ACTION="apply"
  export CONTEXT=$(context create "$ROUTES_WITH_GROUPS")
  export SERVICE_ID="fbcf7a60-8ca8-4bf2-b1b5-5c59bb5bc4fd" APPLICATION_ID="179976948"
  export ROUTES_JSON="$ROUTES_WITH_GROUPS"

  run bash "$SERVICE_PATH/scripts/common/manage_policies"

  assert_success
  local policies=("$OUTPUT_DIR"/authorizationpolicy-*.yaml)
  [[ ${#policies[@]} -eq 1 ]]
  assert_file_contains "${policies[0]}" 'hosts: \["users.example.com"\]'
  assert_file_contains "${policies[0]}" 'methods: \["GET"\]'
  [[ $(grep -c "when:" "${policies[0]}") -eq 0 ]]
  [[ -z $(compgen -G "$OUTPUT_DIR/request-authentication-*") ]]
  # Stored routes drop the groups that no longer apply
  local patch_call
  patch_call=$(grep "np service patch" "$CALLS_LOG")
  [[ -n "$patch_call" && "$patch_call" != *groups* ]]
}

@test "manage_policies: none delete removes only this service's AuthorizationPolicies" {
  export AUTH_TYPE="none" ACTION="delete"
  export SERVICE_ID="fbcf7a60-8ca8-4bf2-b1b5-5c59bb5bc4fd" ROUTES_JSON="[]"
  export EXISTING_POLICIES="hrac-fbcf7a60-public-1234abcd"

  run bash "$SERVICE_PATH/scripts/common/manage_policies"

  assert_success
  grep -q "kubectl delete authorizationpolicy hrac-fbcf7a60-public-1234abcd" "$CALLS_LOG"
  [[ $(grep -c "requestauthentication" "$CALLS_LOG") -eq 0 ]]
}

