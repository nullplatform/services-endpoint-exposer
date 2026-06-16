#!/usr/bin/env bats

load helpers

setup() {
  export TEST_TEMP_DIR="$(mktemp -d)"
  export OUTPUT_DIR="$TEST_TEMP_DIR/output"
  mkdir -p "$OUTPUT_DIR"
  export SERVICE_PATH="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

  # Load assert functions
  load_bats_support_libraries

  export K8S_NAMESPACE="test-namespace"
  export SERVICE_ID="test-service-id"
  export SERVICE_SLUG="test-service"
  export ACTION="apply"
  export DRY_RUN="true"

  # Mock kubectl
  mock_kubectl
}

@test "apply: detects public httproute marker and attempts deletion" {
  # Create marker file
  touch "$OUTPUT_DIR/.httproute-public-deleted"

  run bash "$SERVICE_PATH/scripts/common/apply"

  assert_success
  assert_output --partial "Public HTTPRoute marked for deletion"
  assert_output --partial "httproute"
  assert_output --partial "$SERVICE_SLUG-$SERVICE_ID-public"
}

@test "apply: detects private httproute marker and attempts deletion" {
  # Create marker file
  touch "$OUTPUT_DIR/.httproute-private-deleted"

  run bash "$SERVICE_PATH/scripts/common/apply"

  assert_success
  assert_output --partial "Private HTTPRoute marked for deletion"
  assert_output --partial "httproute"
  assert_output --partial "$SERVICE_SLUG-$SERVICE_ID-private"
}

@test "apply: detects public authz marker and attempts deletion" {
  # Create marker file
  touch "$OUTPUT_DIR/.authz-public-deleted"

  run bash "$SERVICE_PATH/scripts/common/apply"

  assert_success
  assert_output --partial "Public AuthorizationPolicy marked for deletion"
  assert_output --partial "authorizationpolicy"
  assert_output --partial "$SERVICE_SLUG-$SERVICE_ID-authz-public"
}

@test "apply: detects private authz marker and attempts deletion" {
  # Create marker file
  touch "$OUTPUT_DIR/.authz-private-deleted"

  run bash "$SERVICE_PATH/scripts/common/apply"

  assert_success
  assert_output --partial "Private AuthorizationPolicy marked for deletion"
  assert_output --partial "authorizationpolicy"
  assert_output --partial "$SERVICE_SLUG-$SERVICE_ID-authz-private"
}

@test "apply: handles multiple marker files" {
  # Create multiple marker files
  touch "$OUTPUT_DIR/.httproute-public-deleted"
  touch "$OUTPUT_DIR/.httproute-private-deleted"
  touch "$OUTPUT_DIR/.authz-public-deleted"
  touch "$OUTPUT_DIR/.authz-private-deleted"

  run bash "$SERVICE_PATH/scripts/common/apply"

  assert_success
  assert_output --partial "Public HTTPRoute marked for deletion"
  assert_output --partial "Private HTTPRoute marked for deletion"
  assert_output --partial "Public AuthorizationPolicy marked for deletion"
  assert_output --partial "Private AuthorizationPolicy marked for deletion"
}

@test "apply: applies yaml files when present" {
  # Create a test yaml file
  cat > "$OUTPUT_DIR/test-resource.yaml" << EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: test
EOF

  run bash "$SERVICE_PATH/scripts/common/apply"

  assert_success
  assert_output --partial "Applying 1 resources"
}

@test "apply: handles no resources to apply" {
  # No yaml files, no markers

  run bash "$SERVICE_PATH/scripts/common/apply"

  assert_success
  assert_output --partial "No resources to apply"
}

@test "apply: removes marker files after processing" {
  # Create marker files
  touch "$OUTPUT_DIR/.httproute-public-deleted"
  touch "$OUTPUT_DIR/.authz-private-deleted"

  bash "$SERVICE_PATH/scripts/common/apply"

  # Marker files should be removed
  assert_file_not_exists "$OUTPUT_DIR/.httproute-public-deleted"
  assert_file_not_exists "$OUTPUT_DIR/.authz-private-deleted"
}

@test "apply: moves yaml files to apply directory after processing" {
  # Create a test yaml file
  cat > "$OUTPUT_DIR/test-resource.yaml" << EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: test
EOF

  bash "$SERVICE_PATH/scripts/common/apply"

  # Original file should be moved
  assert_file_not_exists "$OUTPUT_DIR/test-resource.yaml"
  # Should be in apply directory
  assert_file_exists "$OUTPUT_DIR/apply/test-resource.yaml"
}
