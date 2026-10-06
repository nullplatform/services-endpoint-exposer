#!/usr/bin/env bats

load helpers

setup() {
  export TEST_TEMP_DIR="$(mktemp -d)"
  export SERVICE_PATH="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

  load_bats_support_libraries

  export SERVICE_ID="svc-1"
  export ROUTES_JSON='[{"method":"GET","path":"/health","scope":"staging","visibility":"public"}]'
  # The notification delivers parameters snake_cased, unlike the UI's camelCase.
  export NP_ACTION_CONTEXT='{"notification":{"parameters":{"public_domain":"example.com","private_domain":"example.com","routes":[]}}}'
  export NP_CALLS="$TEST_TEMP_DIR/np-calls"

  cat > "$TEST_TEMP_DIR/np" << 'EOF2'
#!/bin/bash
if [[ "$1 $2 $3 $4" == "service action update --results" ]]; then
  printf '%s' "$5" > "$NP_CALLS.results"
fi
EOF2
  chmod +x "$TEST_TEMP_DIR/np"
  export PATH="$TEST_TEMP_DIR:$PATH"
}

teardown() {
  rm -rf "$TEST_TEMP_DIR"
}

@test "update_service_results: results carry only the keys the script produces" {
  export AUTH_TYPE="aws-cognito"

  run bash "$SERVICE_PATH/scripts/np/update_service_results"

  assert_success
  RESULTS=$(cat "$NP_CALLS.results")
  [[ "$(jq -c 'keys' <<< "$RESULTS")" == '["routes"]' ]]
  [[ "$(jq -r '.routes[0].summary' <<< "$RESULTS")" == "GET | /health" ]]
}

@test "update_service_results: aws-avp results add only the policy store arn" {
  export AUTH_TYPE="aws-avp"
  export AVP_POLICY_STORE_ARN="arn:aws:verifiedpermissions::1:policy-store/x"

  run bash "$SERVICE_PATH/scripts/np/update_service_results"

  assert_success
  RESULTS=$(cat "$NP_CALLS.results")
  [[ "$(jq -c 'keys' <<< "$RESULTS")" == '["avp_policy_store_arn","routes"]' ]]
}
