#!/usr/bin/env bats

load helpers

setup() {
  export TEST_TEMP_DIR="$(mktemp -d)"
  export OUTPUT_DIR="$TEST_TEMP_DIR/output"
  mkdir -p "$OUTPUT_DIR"
  export SERVICE_PATH="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  load_bats_support_libraries

  export SERVICE_ID="svc-1"
  export KUBECTL_CALLS="$TEST_TEMP_DIR/kubectl-calls"
  cat > "$TEST_TEMP_DIR/kubectl" << 'EOF2'
#!/bin/bash
echo "$*" >> "$KUBECTL_CALLS"
case "$1" in
  get) if [[ "$*" == *"-o json"* ]]; then echo '{"spec": {"rules": [{"to": [{"operation": {"hosts": ["old.example.com"]}}]}]}}'; else echo -n "hrac-keep hrac-stale"; fi ;;
esac
exit 0
EOF2
  chmod +x "$TEST_TEMP_DIR/kubectl"
  export PATH="$TEST_TEMP_DIR:$PATH"
  printf 'metadata:\n  name: hrac-keep\n' > "$OUTPUT_DIR/authorizationpolicy-keep.yaml"
}

teardown() { rm -rf "$TEST_TEMP_DIR"; }

@test "replace_allow_policies: applies the rendered policies before deleting the stale ones" {
  run bash "$SERVICE_PATH/scripts/istio/replace_allow_policies"

  assert_success
  [[ "$(grep -nE '^(apply|delete)' "$KUBECTL_CALLS" | cut -d' ' -f1-3 | tr '\n' '|')" == *"apply -f"*"delete authorizationpolicy hrac-stale"* ]]
  ! grep -q "delete authorizationpolicy hrac-keep" "$KUBECTL_CALLS"
  grep -qx "old.example.com" "$OUTPUT_DIR/.authz-removed-hosts"
}

@test "manage_policies sync: no longer deletes every policy up front" {
  ! grep -q 'delete_allow_policies' <(sed -n '/sync)/,/;;/p' "$SERVICE_PATH/scripts/common/manage_policies")
}
