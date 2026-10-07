#!/usr/bin/env bats

load helpers

setup() {
  export TEST_TEMP_DIR="$(mktemp -d)"
  export SERVICE_PATH="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  export SCRIPT="$SERVICE_PATH/container-scope-override/deployment/sync_exposer"

  load_bats_support_libraries

  export CONTEXT='{"application":{"nrn":"organization=1:account=2:namespace=3:application=4"},"scope":{"id":10,"slug":"prod"}}'
  export SERVICE_SPECIFICATION_SLUG="http-route-access-control"
  unset EXPOSER_SERVICE_SPECIFICATION_SLUG
  export EXPOSER_SYNC_POLL_SECONDS=0

  export NP_SPEC_SLUG="http-route-access-control"
  export NP_SERVICES='[{"id":"svc-1","name":"one","specification_id":"spec-1","status":"active","attributes":{"routes":[{"scope":"prod"}]}}]'
  export NP_ACTION_STATUS="success"
  export NP_EXISTING_ACTIONS='[]'
  export NP_CALLS="$TEST_TEMP_DIR/np-calls"

  # Mock np: answers each subcommand from the NP_* variables and logs every call.
  cat > "$TEST_TEMP_DIR/np" << 'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$NP_CALLS"
case "$*" in
  "service specification action specification list"*)
    echo "{\"results\":[{\"id\":\"action-spec-1\",\"slug\":\"update-$NP_SPEC_SLUG\"}]}" ;;
  "service specification list"*)
    echo "{\"results\":[{\"id\":\"spec-1\",\"slug\":\"$NP_SPEC_SLUG\"}]}" ;;
  "service list"*)
    echo "{\"results\":$NP_SERVICES}" ;;
  "service read"*)
    echo '{"attributes":{"routes":[{"methods":["GET"],"path":"/a","scope":"prod","groups":["admin"],"visibility":"public","summary":"GET | /a | admin"}]}}' ;;
  "service action list"*)
    echo "{\"results\":$NP_EXISTING_ACTIONS}" ;;
  "service action create"*)
    echo '{"id":"action-new"}' ;;
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
  assert_output --partial "Spec: endpoint-exposer"
  assert_output --partial "Endpoint exposer one updated"
}

@test "sync_exposer: updates every active exposer of the deployed scope and skips the rest" {
  export NP_SERVICES='[
    {"id":"svc-1","name":"one","specification_id":"spec-1","status":"active","attributes":{"routes":[{"scope":"prod"}]}},
    {"id":"svc-2","name":"two","specification_id":"spec-1","status":"active","attributes":{"routes":[{"scope":"other"},{"scope":"prod"}]}},
    {"id":"svc-3","name":"three","specification_id":"spec-1","status":"failed","attributes":{"routes":[{"scope":"prod"}]}},
    {"id":"svc-4","name":"four","specification_id":"spec-1","status":"active","attributes":{"routes":[{"scope":"other"}]}}
  ]'

  run bash "$SCRIPT"

  assert_success
  [[ "$(grep -c "service action create --serviceId svc-1" "$NP_CALLS")" -eq 1 ]]
  [[ "$(grep -c "service action create --serviceId svc-2" "$NP_CALLS")" -eq 1 ]]
  [[ "$(grep -c "service action create --serviceId svc-3" "$NP_CALLS")" -eq 0 ]]
  [[ "$(grep -c "service action create --serviceId svc-4" "$NP_CALLS")" -eq 0 ]]
  assert_output --partial "Skipping endpoint exposer three [svc-3] (status=failed)"
}

@test "sync_exposer: nothing to do when no exposer routes to the deployed scope" {
  export NP_SERVICES='[{"id":"svc-4","name":"four","specification_id":"spec-1","status":"active","attributes":{"routes":[{"scope":"other"}]}}]'

  run bash "$SCRIPT"

  assert_success
  assert_output --partial "No endpoint exposer routes to this scope"
  ! grep -q "service action create" "$NP_CALLS"
}

@test "sync_exposer: sends the declared routes without the derived fields" {
  run bash "$SCRIPT"

  assert_success
  body=$(grep "service action create" "$NP_CALLS" | sed 's/.*--body //; s/ --format json$//')
  [[ "$(jq -c '.parameters' <<< "$body")" == '{"routes":[{"methods":["GET"],"path":"/a","scope":"prod","groups":["admin"]}]}' ]]
}

@test "sync_exposer: waits for an action in progress and still runs a fresh update" {
  export NP_EXISTING_ACTIONS='[{"id":"action-old","status":"in_progress"}]'

  run bash "$SCRIPT"

  assert_success
  grep -q "service action read --serviceId svc-1 --id action-old" "$NP_CALLS"
  grep -q "service action create --serviceId svc-1" "$NP_CALLS"
}

@test "sync_exposer: fails the deploy step when an update fails" {
  export NP_ACTION_STATUS="failed"

  run bash "$SCRIPT"

  assert_failure
  assert_output --partial "Could not update endpoint exposer(s): one [svc-1]"
}

@test "sync_exposer: a cancelled update also fails the step" {
  export NP_ACTION_STATUS="cancelled"

  run bash "$SCRIPT"

  assert_failure
}
