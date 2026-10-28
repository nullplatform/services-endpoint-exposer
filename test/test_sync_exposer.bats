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
  export NP_LINKS='[]'
  export NP_CALLS="$TEST_TEMP_DIR/np-calls"

  # Mock np: answers each subcommand from the NP_* variables and logs every call.
  cat > "$TEST_TEMP_DIR/np" << 'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$NP_CALLS"
# Like the np CLI in the controlplane-agent image (aws-0.7.0).
if [[ " $* " == *" --specification-id "* ]]; then echo "Error: unknown flag: --specification-id" >&2; exit 1; fi
[[ -n "${NP_FAIL:-}" && "$*" == "$NP_FAIL"* ]] && exit 1
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
  "link specification action specification list"*)
    echo '{"results":[{"id":"link-action-spec-1","slug":"update-connect","type":"update"}]}' ;;
  "link list"*)
    echo "{\"results\":$NP_LINKS}" ;;
  "link action list"*)
    echo '{"results":[]}' ;;
  "link action create"*)
    echo '{"id":"link-action-new"}' ;;
  "link action read"*)
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

@test "sync_exposer: updates the active and failed exposers of the deployed scope and skips the rest" {
  export NP_SERVICES='[
    {"id":"svc-1","name":"one","specification_id":"spec-1","status":"active","attributes":{"routes":[{"scope":"prod"}]}},
    {"id":"svc-2","name":"two","specification_id":"spec-1","status":"active","attributes":{"routes":[{"scope":"other"},{"scope":"prod"}]}},
    {"id":"svc-3","name":"three","specification_id":"spec-1","status":"failed","attributes":{"routes":[{"scope":"prod"}]}},
    {"id":"svc-4","name":"four","specification_id":"spec-1","status":"active","attributes":{"routes":[{"scope":"other"}]}},
    {"id":"svc-5","name":"five","specification_id":"spec-1","status":"creating","attributes":{"routes":[{"scope":"prod"}]}}
  ]'

  run bash "$SCRIPT"

  assert_success
  assert_output --partial "Skipping endpoint exposer five [svc-5] (status=creating)"
  # [[ ]] does not fail a test under bash 3.2, so the counts go through run + assert.
  run bash -c "grep -o 'service action create --serviceId svc-[0-9]' '$NP_CALLS' | sort | tr '\n' ' '"
  assert_output "service action create --serviceId svc-1 service action create --serviceId svc-2 service action create --serviceId svc-3 "
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

@test "sync_exposer: fails the deploy step when the services can't be listed" {
  export NP_FAIL="service list"

  run bash "$SCRIPT"

  assert_failure
  assert_output --partial "could not list the services"
  ! grep -q "service action create" "$NP_CALLS"
}

# --- domain + links model ---

domain_model() {
  export NP_SERVICES='[{"id":"svc-d","name":"api","specification_id":"spec-1","status":"active","attributes":{"domain_name":"api.acme.com","visibility":"public"}}]'
}

@test "sync_exposer: updates the links with a route on the deployed scope, with the declared routes only" {
  domain_model
  export NP_LINKS='[
    {"id":"link-1","name":"one","service_id":"svc-d","specification_id":"ls-1","status":"active",
     "attributes":{"routes":[{"path":"/a","methods":["ALL"],"scope":"other","summary":"x"},{"path":"/b","methods":["GET"],"scope":"prod","summary":"y"}],"endpoints":["api.acme.com/a"],"summary":"ALL /a","auth_type":"none"}},
    {"id":"link-2","name":"two","service_id":"svc-d","specification_id":"ls-1","status":"active","attributes":{"routes":[{"path":"/c","scope":"other"}]}},
    {"id":"link-3","name":"three","service_id":"svc-other","specification_id":"ls-1","status":"active","attributes":{"routes":[{"path":"/d","scope":"prod"}]}}
  ]'

  run bash "$SCRIPT"

  assert_success
  [[ "$(grep -c "link action create --linkId link-1" "$NP_CALLS")" -eq 1 ]]
  ! grep -q "link action create --linkId link-2" "$NP_CALLS"
  ! grep -q "link action create --linkId link-3" "$NP_CALLS"
  # The domain service itself has no routes to update.
  ! grep -q "service action create" "$NP_CALLS"
  body=$(grep "link action create --linkId link-1" "$NP_CALLS" | sed 's/.*--body //; s/ --format json$//')
  [[ "$(jq -c '.parameters' <<< "$body")" == '{"routes":[{"path":"/a","methods":["ALL"],"scope":"other"},{"path":"/b","methods":["GET"],"scope":"prod"}]}' ]]
  [[ "$(jq -r '.specification_id' <<< "$body")" == "link-action-spec-1" ]]
  # The flag the np CLI takes (not --link-specification-id).
  grep -q "link specification action specification list --linkSpecificationId ls-1" "$NP_CALLS"
}

@test "sync_exposer: a failed link update fails the deploy step" {
  domain_model
  export NP_ACTION_STATUS="failed"
  export NP_LINKS='[{"id":"link-1","name":"one","service_id":"svc-d","specification_id":"ls-1","status":"active","attributes":{"routes":[{"path":"/a","scope":"prod"}]}}]'

  run bash "$SCRIPT"

  assert_failure
  assert_output --partial "Could not update endpoint exposer(s): link one [link-1]"
}

@test "sync_exposer: nothing to do when neither services nor links route to the scope" {
  domain_model
  export NP_LINKS='[{"id":"link-1","name":"one","service_id":"svc-d","specification_id":"ls-1","status":"active","attributes":{"routes":[{"path":"/a","scope":"other"}]}}]'

  run bash "$SCRIPT"

  assert_success
  assert_output --partial "No endpoint exposer routes to this scope"
  ! grep -q "action create" "$NP_CALLS"
}

@test "sync_exposer: a link with a single top-level path is sent as a one-route list" {
  domain_model
  export NP_LINKS='[{"id":"link-1","name":"one","service_id":"svc-d","specification_id":"ls-1","status":"active",
    "attributes":{"path":"/prueba","methods":["ALL"],"scope":"prod","groups":[],"auth_type":"none","endpoint":"api.acme.com/prueba","summary":"ALL | /prueba"}}]'

  run bash "$SCRIPT"

  assert_success
  body=$(grep "link action create --linkId link-1" "$NP_CALLS" | sed 's/.*--body //; s/ --format json$//')
  [[ "$(jq -c '.parameters' <<< "$body")" == '{"routes":[{"path":"/prueba","methods":["ALL"],"scope":"prod","groups":[]}]}' ]]
}

@test "sync_exposer: a failed link is synced with its stored routes, so its route follows the deploy" {
  # A link update refused by a conflict leaves the link failed with its previous routes.
  export NP_SERVICES='[{"id":"svc-d","name":"api","specification_id":"spec-1","status":"active","attributes":{"domain_name":"api.acme.com","visibility":"public"}}]'
  export NP_LINKS='[{"id":"link-1","name":"one","service_id":"svc-d","specification_id":"ls-1","status":"failed","attributes":{"routes":[{"path":"/a","scope":"prod"}]}}]'

  run bash "$SCRIPT"

  assert_success
  grep -q "link action create --linkId link-1" "$NP_CALLS"
  grep "link action create --linkId link-1" "$NP_CALLS" | grep -q '"path":"/a"'
}

@test "sync_exposer: a failed link whose update fails again is reported, not the deploy step" {
  export NP_ACTION_STATUS="failed"
  export NP_SERVICES='[{"id":"svc-d","name":"api","specification_id":"spec-1","status":"active","attributes":{"domain_name":"api.acme.com","visibility":"public"}}]'
  export NP_LINKS='[{"id":"link-1","name":"one","service_id":"svc-d","specification_id":"ls-1","status":"failed","attributes":{"routes":[{"path":"/a","scope":"prod"}]}}]'

  run bash "$SCRIPT"

  assert_success
  assert_output --partial "WARNING: could not update endpoint exposer(s) that were already failed: link one [link-1]"
}
