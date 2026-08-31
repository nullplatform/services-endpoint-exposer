#!/usr/bin/env bats

load helpers

setup() {
  export TEST_TEMP_DIR="$(mktemp -d)"
  export OUTPUT_DIR="$TEST_TEMP_DIR/output"
  mkdir -p "$OUTPUT_DIR"
  export SERVICE_PATH="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  load_bats_support_libraries
}

teardown() {
  [[ -n "$TEST_TEMP_DIR" && -d "$TEST_TEMP_DIR" ]] && rm -rf "$TEST_TEMP_DIR"
}

# build_ingress_with_rule is meant to be sourced by process_routes, and its
# tail is a top-level "main script" block (not guarded by a
# `[[ "${BASH_SOURCE[0]}" == "$0" ]]` check) that reads K8S_NAMESPACE,
# SERVICE_ID, SCOPE_ID, RULE_PATH and SCOPE_RULE as if they were already
# exported by the caller. The file also carries `set -euo pipefail`.
# Sourcing it here to reach the bare `create_http_rule` function would run
# that block against an empty test environment and abort.
#
# A trailing `source build_ingress_with_rule || true` does NOT protect
# against that: when a *sourced* script hits `set -u`/`set -e`, bash calls
# exit() on the current process directly instead of returning a failure
# status from the `source` builtin, so the `|| true` after it never runs
# (verified empirically - the process exits before reaching it). So instead
# of sourcing the whole script, pull out only the function definitions -
# up to the "# Main script logic" marker - into a scratch file and source
# that.
source_build_ingress_functions() {
  local src="$SERVICE_PATH/scripts/istio/build_ingress_with_rule"
  local funcs_file="$TEST_TEMP_DIR/build_ingress_with_rule.functions"
  sed -n '1,/^# Main script logic$/p' "$src" | sed '$d' > "$funcs_file"
  # shellcheck disable=SC1090
  source "$funcs_file"
}

@test "el schema expone headers por ruta" {
  run jq -e '.attributes.schema.properties.routes.items.properties.headers.type' \
    "$SERVICE_PATH/specs/service-spec.json.tpl"
  assert_success
  assert_output '"array"'
}

@test "create_http_rule emite headers en el match" {
  source_build_ingress_functions
  run create_http_rule '/api' '{"name":"svc","port":{"number":8080}}' 'null' 'GET' \
    '[{"name":"x-canary","value":"true","type":"Exact"}]'
  assert_success
  assert_output --partial '"x-canary"'
  assert_output --partial '"Exact"'
}

@test "create_http_rule sin headers no agrega la clave" {
  source_build_ingress_functions
  run create_http_rule '/api' '{"name":"svc","port":{"number":8080}}' 'null' 'GET' ''
  assert_success
  run bash -c "echo '$output' | jq -e '.matches[0].headers'"
  assert_failure
}
