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

@test "el schema expone rewrite por ruta" {
  run jq -e '.attributes.schema.properties.routes.items.properties.rewrite.type' \
    "$SERVICE_PATH/specs/service-spec.json.tpl"
  assert_success
  assert_output '"object"'
}

@test "build_filters emite un filtro URLRewrite" {
  source_build_ingress_functions
  run build_filters '{"path":"/v2"}' '{}'
  assert_success
  assert_output --partial 'URLRewrite'
  assert_output --partial 'ReplacePrefixMatch'
}

@test "build_filters devuelve vacio cuando no hay nada que aplicar" {
  source_build_ingress_functions
  run build_filters '' ''
  assert_success
  assert_output ""
}

@test "create_http_rule adjunta los filters a la rule" {
  source_build_ingress_functions
  run create_http_rule '/api' '{"name":"svc","port":{"number":8080}}' 'null' 'GET' '' \
    '[{"type":"URLRewrite","urlRewrite":{"path":{"type":"ReplacePrefixMatch","replacePrefixMatch":"/v2"}}}]'
  assert_success
  assert_output --partial '"filters"'
  assert_output --partial 'URLRewrite'
}

@test "create_http_rule sin filters no agrega la clave" {
  source_build_ingress_functions
  run create_http_rule '/api' '{"name":"svc","port":{"number":8080}}' 'null' 'GET' '' ''
  assert_success
  run bash -c "echo '$output' | jq -e '.filters'"
  assert_failure
}

@test "el schema expone weight por ruta" {
  run jq -e '.attributes.schema.properties.routes.items.properties.weight.type' \
    "$SERVICE_PATH/specs/service-spec.json.tpl"
  assert_success
  assert_output '"integer"'
}

@test "merge_weighted_backend suma un backend a una rule existente" {
  source_build_ingress_functions
  RULE='{"matches":[{"path":{"type":"Exact","value":"/a"}}],"backendRefs":[{"name":"blue","port":80,"weight":90}]}'
  run merge_weighted_backend "$RULE" 'green' '80' '10'
  assert_success
  assert_output --partial '"green"'
  assert_output --partial '"weight": 10'
}

@test "merge_weighted_backend reemplaza el backend existente del mismo scope" {
  source_build_ingress_functions
  RULE='{"matches":[{"path":{"type":"Exact","value":"/a"}}],"backendRefs":[{"name":"users","port":80,"weight":70},{"name":"items","port":80,"weight":30}]}'
  run merge_weighted_backend "$RULE" 'users' '80' '50'
  assert_success
  run bash -c "echo '$output' | jq -c '[.backendRefs[] | select(.name == \"users\")] | length'"
  assert_output '1'
}

@test "create_http_rule emite weight en el backendRef cuando la ruta lo declara" {
  source_build_ingress_functions
  run create_http_rule '/api' '{"name":"users","port":{"number":8080}}' 'null' 'GET' '' '' '30'
  assert_success
  assert_output --partial '"weight": 30'
}

@test "create_http_rule sin weight no agrega la clave al backendRef" {
  source_build_ingress_functions
  run create_http_rule '/api' '{"name":"users","port":{"number":8080}}' 'null' 'GET' '' '' ''
  assert_success
  run bash -c "echo '$output' | jq -e '.backendRefs[0].weight'"
  assert_failure
}
