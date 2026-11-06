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
[[ -n "${NP_FAIL:-}" && "$*" == "$NP_FAIL"* ]] && { echo '{"error": "request failed with status 503: unavailable"}'; exit 1; }
# NP_BAD_BODY: the call exits 0 with an error body instead of a list.
[[ -n "${NP_BAD_BODY:-}" && "$*" == "$NP_BAD_BODY"* ]] && { echo '{"error": "unauthorized"}'; exit 0; }
# NP_NULL_RESULTS: the call exits 0 with a null list.
[[ -n "${NP_NULL_RESULTS:-}" && "$*" == "$NP_NULL_RESULTS"* ]] && { echo '{"results": null}'; exit 0; }
# NP_CREATE_STATUS: action create answers this HTTP error, like the np CLI
if [[ -n "${NP_CREATE_STATUS:-}" && "$*" == *"action create"* ]]; then
  echo "{\"error\": \"request failed with status $NP_CREATE_STATUS: rejected\"}"
  exit 1
fi
case "$*" in
  "service specification action specification list"*)
    # NP_NO_ACTION_SPECS: what an api key that can't see the actions gets back.
    if [[ -n "${NP_NO_ACTION_SPECS:-}" ]]; then echo '{"results":null}'; else
    echo "{\"results\":[{\"id\":\"action-spec-1\",\"slug\":\"update-$NP_SPEC_SLUG\"}]}"; fi ;;
  "service specification list"*)
    SPECS="${NP_SPECS:-}"
    [[ -z "$SPECS" ]] && SPECS="[{\"id\":\"spec-1\",\"slug\":\"$NP_SPEC_SLUG\"}]"
    echo "{\"results\":$SPECS}" ;;
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
  assert_output --partial "WARNING: no service specification with slug"
  assert_output --partial "EXPOSER_SERVICE_SPECIFICATION_SLUG"
  assert_output --partial "skipping exposer sync"
}

@test "sync_exposer: finds a spec registered through the service_definition module without configuration" {
  export NP_SPEC_SLUG="endpoint-exposer"

  run bash "$SCRIPT"

  assert_success
  assert_output --partial "Endpoint exposer one updated"
}

@test "sync_exposer: fails when both exposer specs are visible and none is configured" {
  export NP_SPECS='[{"id":"spec-1","slug":"http-route-access-control"},{"id":"spec-2","slug":"endpoint-exposer"}]'

  run bash "$SCRIPT"

  assert_failure
  assert_output --partial "more than one exposer specification"
}

@test "sync_exposer: EXPOSER_SERVICE_SPECIFICATION_SLUG picks one spec when both are visible" {
  export NP_SPECS='[{"id":"spec-1","slug":"http-route-access-control"},{"id":"spec-2","slug":"endpoint-exposer"}]'
  export EXPOSER_SERVICE_SPECIFICATION_SLUG="http-route-access-control"

  run bash "$SCRIPT"

  assert_success
  assert_output --partial "Endpoint exposer one updated"
}

@test "sync_exposer: a malformed specification fails instead of skipping the sync" {
  export NP_SPECS='["http-route-access-control"]'

  run bash "$SCRIPT"

  assert_failure
  assert_output --partial "could not read the service specifications"
  [[ "$output" != *"skipping exposer sync"* ]]
}

@test "sync_exposer: a null list fails instead of skipping the sync" {
  export NP_NULL_RESULTS="service list"

  run bash "$SCRIPT"

  assert_failure
  assert_output --partial "unexpected response listing the services"
}

@test "sync_exposer: a service whose routes are not a list fails instead of skipping the sync" {
  export NP_SERVICES='[{"id":"svc-1","name":"one","specification_id":"spec-1","status":"active","attributes":{"routes":"prod"}}]'

  run bash "$SCRIPT"

  assert_failure
  assert_output --partial "could not read the services"
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
  run grep "service action create" "$NP_CALLS"
  assert_failure
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
  assert_output --partial "WARNING: the platform refused or failed the update of endpoint exposer(s) that were already failed: link one [link-1]"
}

@test "sync_exposer: an app without exposers deploys even when the update action isn't visible" {
  export NP_SERVICES='[]'
  export NP_NO_ACTION_SPECS=1

  run bash "$SCRIPT"

  assert_success
  assert_output --partial "No endpoint exposer routes to this scope, skipping exposer sync"
  run grep -c "service specification action specification list" "$NP_CALLS"
  assert_output "0"
}

@test "sync_exposer: links sync without the service's update action" {
  export NP_SERVICES='[{"id":"dom-1","name":"domain","specification_id":"spec-1","status":"active","attributes":{"domain_name":"api.example.com"}}]'
  export NP_LINKS='[{"id":"link-1","name":"app","service_id":"dom-1","specification_id":"link-spec-1","status":"active","attributes":{"routes":[{"path":"/a","methods":["GET"],"scope":"prod"}]}}]'
  export NP_NO_ACTION_SPECS=1

  run bash "$SCRIPT"

  assert_success
  assert_output --partial "sync_exposer completed"
  run grep -c "link action create" "$NP_CALLS"
  assert_output "1"
}

@test "sync_exposer: an active legacy exposer without a visible update action fails the deploy step" {
  export NP_NO_ACTION_SPECS=1

  run bash "$SCRIPT"

  assert_failure
  assert_output --partial "No action specification 'update-http-route-access-control' visible"
  assert_output --partial "Could not update endpoint exposer(s): one [svc-1]"
}

# --- review of PR #58: np failures never pass for success ------------------------------

failed_link() {
  domain_model
  export NP_LINKS='[{"id":"link-1","name":"one","service_id":"svc-d","specification_id":"ls-1","status":"failed","attributes":{"routes":[{"path":"/a","scope":"prod"}]}}]'
}

@test "sync_exposer: a failed spec list fails the deploy step instead of skipping the sync" {
  export NP_FAIL="service specification list"

  run bash "$SCRIPT"

  assert_failure
  assert_output --partial "could not list the service specifications"
  [[ "$output" != *"skipping exposer sync"* ]]
}

@test "sync_exposer: a failed read of a legacy exposer fails the step, it never sends empty routes" {
  export NP_FAIL="service read"

  run bash "$SCRIPT"

  assert_failure
  assert_output --partial "Could not read endpoint exposer one [svc-1]"
  ! grep -q "service action create" "$NP_CALLS"
}

@test "sync_exposer: an action that can't be read fails fast instead of waiting for the timeout" {
  export NP_FAIL="service action read"

  run bash "$SCRIPT"

  assert_failure
  assert_output --partial "could not read action action-new"
  [[ "$(grep -c "service action read" "$NP_CALLS")" -eq 3 ]]
}

@test "sync_exposer: a failed pending-action list fails the step" {
  export NP_FAIL="service action list"

  run bash "$SCRIPT"

  assert_failure
  assert_output --partial "Could not list the actions of endpoint exposer one [svc-1]"
}

@test "sync_exposer: a refused update of a failed link is only reported" {
  failed_link
  export NP_CREATE_STATUS=400

  run bash "$SCRIPT"

  assert_success
  assert_output --partial "The platform refused the update of endpoint exposer link one [link-1]"
  assert_output --partial "WARNING: the platform refused or failed the update"
}

@test "sync_exposer: an infra error updating a failed link fails the step" {
  failed_link
  export NP_CREATE_STATUS=503

  run bash "$SCRIPT"

  assert_failure
  assert_output --partial "Could not create an update action for endpoint exposer link one [link-1]"
  assert_output --partial "Could not update endpoint exposer(s): link one [link-1]"
}

@test "sync_exposer: a refused update of an active link fails the step" {
  domain_model
  export NP_LINKS='[{"id":"link-1","name":"one","service_id":"svc-d","specification_id":"ls-1","status":"active","attributes":{"routes":[{"path":"/a","scope":"prod"}]}}]'
  export NP_CREATE_STATUS=400

  run bash "$SCRIPT"

  assert_failure
  assert_output --partial "Could not update endpoint exposer(s): link one [link-1]"
}

@test "sync_exposer: a link that stored a single method sends it as methods" {
  domain_model
  export NP_LINKS='[{"id":"link-1","name":"one","service_id":"svc-d","specification_id":"ls-1","status":"active",
    "attributes":{"path":"/old","method":"GET","scope":"prod","groups":[]}},
    {"id":"link-2","name":"two","service_id":"svc-d","specification_id":"ls-1","status":"active",
    "attributes":{"routes":[{"path":"/b","method":"POST","scope":"prod"}]}}]'

  run bash "$SCRIPT"

  assert_success
  body=$(grep "link action create --linkId link-1" "$NP_CALLS" | sed 's/.*--body //; s/ --format json$//')
  [[ "$(jq -c '.parameters' <<< "$body")" == '{"routes":[{"path":"/old","methods":["GET"],"scope":"prod","groups":[]}]}' ]]
  body=$(grep "link action create --linkId link-2" "$NP_CALLS" | sed 's/.*--body //; s/ --format json$//')
  [[ "$(jq -c '.parameters' <<< "$body")" == '{"routes":[{"path":"/b","scope":"prod","methods":["POST"]}]}' ]]
}

@test "sync_exposer: a service list that answers without results fails instead of skipping the sync" {
  export NP_BAD_BODY="service list"

  run bash "$SCRIPT"

  assert_failure
  assert_output --partial "unexpected response listing the services"
}

@test "sync_exposer: a link list that answers without results fails instead of skipping the sync" {
  domain_model
  export NP_BAD_BODY="link list"

  run bash "$SCRIPT"

  assert_failure
  assert_output --partial "unexpected response listing the links"
}

@test "sync_exposer: a malformed service fails instead of skipping the sync" {
  export NP_SERVICES='[{"id":"svc-1","name":"one","specification_id":"spec-1","status":"active","attributes":{"routes":["prod"]}}]'

  run bash "$SCRIPT"

  assert_failure
  assert_output --partial "could not read the services"
  [[ "$output" != *"skipping exposer sync"* ]]
}

@test "sync_exposer: a malformed link fails instead of skipping the sync" {
  domain_model
  export NP_LINKS='[{"id":"link-1","service_id":"svc-d","status":"active","attributes":{"routes":["prod"]}}]'

  run bash "$SCRIPT"

  assert_failure
  assert_output --partial "could not read the links"
  [[ "$output" != *"skipping exposer sync"* ]]
}

@test "sync_exposer: a specification list that answers without results fails instead of skipping the sync" {
  export NP_BAD_BODY="service specification list"

  run bash "$SCRIPT"

  assert_failure
  assert_output --partial "unexpected response listing the service specifications"
}

@test "sync_exposer: a failed link list fails the deploy step" {
  domain_model
  export NP_FAIL="link list"

  run bash "$SCRIPT"

  assert_failure
  assert_output --partial "could not list the links"
}

@test "sync_exposer: a failed list of a link's action specifications fails the step of an active link" {
  failed_link
  export NP_LINKS="${NP_LINKS//failed/active}"
  export NP_FAIL="link specification action specification list"

  run bash "$SCRIPT"

  assert_failure
  assert_output --partial "Could not list the actions of the link specification"
}

@test "sync_exposer: a platform refusal of a failed link is only reported, whatever the refusing status" {
  failed_link
  for status in 404 409 422; do
    NP_CREATE_STATUS=$status run bash "$SCRIPT"
    assert_success
    assert_output --partial "The platform refused the update of endpoint exposer link one [link-1]"
  done
}

@test "sync_exposer: a server error updating a failed link fails the step" {
  failed_link
  for status in 500 502; do
    NP_CREATE_STATUS=$status run bash "$SCRIPT"
    assert_failure
    assert_output --partial "Could not update endpoint exposer(s): link one [link-1]"
  done
}
