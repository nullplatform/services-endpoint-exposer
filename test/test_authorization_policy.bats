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

@test "el schema no exige groups" {
  run jq -e '.attributes.schema.properties.routes.items.required | index("groups")' \
    "$SERVICE_PATH/specs/service-spec.json.tpl"
  assert_failure
}

@test "groups admite un array vacio" {
  run jq -e '.attributes.schema.properties.routes.items.properties.groups.minItems' \
    "$SERVICE_PATH/specs/service-spec.json.tpl"
  assert_failure
}

@test "el template omite el bloque when cuando no hay groups" {
  run grep -c 'if gt (len .groups) 0' "$SERVICE_PATH/templates/istio/authorizationpolicy.yaml.tpl"
  assert_success
  assert_output "1"
}
