#!/usr/bin/env bats

load helpers

setup() {
  export TEST_TEMP_DIR="$(mktemp -d)"
  export SERVICE_PATH="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  load_bats_support_libraries

  export SCOPE_ID="10"
  export K8S_NAMESPACE="nullplatform"
  unset _BUILD_RULE_CACHED_SCOPE _BUILD_RULE_CACHED_RULE
  # Two services of the scope, listed by name: the old deployment (999) sorts
  # after the new one (1000), the case that broke position-based blue/green.
  export K8S_SERVICES='{"items": [
    {"metadata": {"name": "d-10-1000"}, "spec": {"selector": {"scope_id": "10", "deployment_id": "1000"}, "ports": [{"port": 8080}]}},
    {"metadata": {"name": "d-10-999"},  "spec": {"selector": {"scope_id": "10", "deployment_id": "999"},  "ports": [{"port": 8080}]}},
    {"metadata": {"name": "d-20-5"},    "spec": {"selector": {"scope_id": "20", "deployment_id": "5"},    "ports": [{"port": 8080}]}}
  ]}'
  export ACTIVE="999" IN_PROGRESS="1000" STATUS="running" SWITCHED="30"

  cat > "$TEST_TEMP_DIR/np" << 'EOF2'
#!/bin/bash
case "$1 $2" in
  "scope read") jq -n --arg a "$ACTIVE" --arg p "$IN_PROGRESS" '{active_deployment: (if $a == "" then null else ($a|tonumber) end), in_progress_deployment: (if $p == "" then null else ($p|tonumber) end)}' ;;
  "deployment read") jq -n --arg s "$STATUS" --argjson t "$SWITCHED" '{status: $s, strategy_data: {desired_switched_traffic: $t}}' ;;
esac
EOF2
  cat > "$TEST_TEMP_DIR/kubectl" << 'EOF2'
#!/bin/bash
echo "$K8S_SERVICES"
EOF2
  chmod +x "$TEST_TEMP_DIR/np" "$TEST_TEMP_DIR/kubectl"
  export PATH="$TEST_TEMP_DIR:$PATH"
}

teardown() { rm -rf "$TEST_TEMP_DIR"; }

rule() { source "$SERVICE_PATH/scripts/istio/build_rule" >/dev/null; echo "$SCOPE_RULE" | jq -c "$1"; }

@test "build_rule: running splits traffic by deployment id, not by name order" {
  [[ "$(rule '.blue_green_annotation.forward.targetGroups')" == '[{"serviceName":"d-10-999","weight":70},{"serviceName":"d-10-1000","weight":30}]' ]]
}

@test "build_rule: finalizing sends everything to the new deployment" {
  export STATUS="finalizing"
  [[ "$(rule '.')" == '{"service":{"name":"d-10-1000","port":{"number":8080}}}' ]]
}

@test "build_rule: rolling back keeps everything on the active deployment" {
  export STATUS="rolling_back"
  [[ "$(rule '.service.name')" == '"d-10-999"' ]]
  [[ "$(rule '.blue_green_annotation')" == "null" ]]
}

@test "build_rule: no deployment in progress uses the active deployment" {
  export IN_PROGRESS="" ACTIVE="1000"
  [[ "$(rule '.service.name')" == '"d-10-1000"' ]]
}

@test "build_rule: without an active deployment picks the newest service" {
  export IN_PROGRESS="" ACTIVE=""
  [[ "$(rule '.service.name')" == '"d-10-1000"' ]]
}

@test "build_rule: first deployment of a scope routes to it" {
  export ACTIVE="" IN_PROGRESS="1000" STATUS="waiting_for_instances"
  export K8S_SERVICES='{"items": [{"metadata": {"name": "d-10-1000"}, "spec": {"selector": {"scope_id": "10", "deployment_id": "1000"}, "ports": [{"port": 8080}]}}]}'
  [[ "$(rule '.service.name')" == '"d-10-1000"' ]]
}

@test "build_rule: a scope without services gets the no-backend placeholder" {
  export SCOPE_ID="30" ACTIVE="" IN_PROGRESS=""
  [[ "$(rule '.service.name')" == '"response-404"' ]]
}
