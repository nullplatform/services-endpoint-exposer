#!/usr/bin/env bats

load helpers

setup() {
  export TEST_TEMP_DIR="$(mktemp -d)"
  export SERVICE_PATH="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  export SCRIPT="$SERVICE_PATH/container-scope-override/deployment/sync_exposer"

  load_bats_support_libraries

  export CONTEXT='{"application":{"nrn":"organization=1:account=2:namespace=3:application=4"}}'
  export SERVICE_SPECIFICATION_SLUG="http-route-access-control"
  unset EXPOSER_SERVICE_SPECIFICATION_SLUG

  export NP_SPEC_SLUG="http-route-access-control"
  export NP_SERVICES='[{"id":"svc-1","specification_id":"spec-1","status":"active"}]'
  export NP_ACTION_STATUS="success"
  export NP_CALLS="$TEST_TEMP_DIR/np-calls"

  # Mock np: answers each subcommand from the NP_* variables and logs every call.
  cat > "$TEST_TEMP_DIR/np" << 'EOF'
#!/bin/bash
echo "$*" >> "$NP_CALLS"
case "$*" in
  "service specification list"*)
    echo "{\"results\":[{\"id\":\"spec-1\",\"slug\":\"$NP_SPEC_SLUG\"}]}" ;;
  "service list"*)
    echo "{\"results\":$NP_SERVICES}" ;;
  "service read"*)
    echo '{"attributes":{"routes":[]}}' ;;
  "service specification action specification list"*)
    echo "{\"results\":[{\"id\":\"action-spec-1\",\"slug\":\"update-$NP_SPEC_SLUG\"}]}" ;;
  "service action create"*)
    echo '{"id":"action-1"}' ;;
  "service action read"*)
    echo "{\"status\":\"$NP_ACTION_STATUS\"}" ;;
esac
EOF
  chmod +x "$TEST_TEMP_DIR/np"
  export PATH="$TEST_TEMP_DIR:$PATH"
}

teardown() {
  rm -rf "$TEST_TEMP_DIR"
}

@test "sync_exposer: skips without failing when the spec is not installed" {
  export NP_SPEC_SLUG="something-else"

  run bash "$SCRIPT"

  assert_success
  assert_output --partial "skipping exposer sync"
}

@test "sync_exposer: EXPOSER_SERVICE_SPECIFICATION_SLUG overrides the values.yaml slug" {
  export NP_SPEC_SLUG="endpoint-exposer"
  export EXPOSER_SERVICE_SPECIFICATION_SLUG="endpoint-exposer"

  run bash "$SCRIPT"

  assert_success
  assert_output --partial "SERVICE SPECIFICATION SLUG: endpoint-exposer"
  assert_output --partial "Endpoint exposer successfully updated"
}

@test "sync_exposer: updates every active exposer and skips the rest" {
  export NP_SERVICES='[{"id":"svc-1","specification_id":"spec-1","status":"active"},{"id":"svc-2","specification_id":"spec-1","status":"active"},{"id":"svc-3","specification_id":"spec-1","status":"failed"}]'

  run bash "$SCRIPT"

  assert_success
  [[ "$(grep -c "service action create --serviceId svc-1" "$NP_CALLS")" -eq 1 ]]
  [[ "$(grep -c "service action create --serviceId svc-2" "$NP_CALLS")" -eq 1 ]]
  [[ "$(grep -c "service action create --serviceId svc-3" "$NP_CALLS")" -eq 0 ]]
  assert_output --partial "Skipping endpoint exposer svc-3 (status=failed)"
}

@test "sync_exposer: fails the deploy step when an update fails" {
  export NP_ACTION_STATUS="failed"

  run bash "$SCRIPT"

  assert_failure
  assert_output --partial "Could not update endpoint exposer(s): svc-1"
}
