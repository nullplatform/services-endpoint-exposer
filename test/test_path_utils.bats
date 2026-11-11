#!/usr/bin/env bats

# path_utils: one developer path, read the same way by the HTTPRoute (detect_path_type)
# and by the AuthorizationPolicy (authz_path).

load helpers

setup() {
  export SERVICE_PATH="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  load_bats_support_libraries
  source "$SERVICE_PATH/scripts/istio/path_utils"
}

@test "authz_path: a parameter becomes a one-segment template" {
  run authz_path "/api/users/:id"
  assert_success
  assert_output "/api/users/{*}"
}

@test "authz_path: every parameter is converted" {
  run authz_path "/a/:x/b/:y"
  assert_output "/a/{*}/b/{*}"
}

@test "authz_path: a parameter with a trailing wildcard ends in the multi-segment template" {
  run authz_path "/a/:x/*"
  assert_output "/a/{*}/{**}"
}

@test "authz_path: a root parameter" {
  run authz_path "/:id"
  assert_output "/{*}"
}

@test "authz_path: a wildcard without parameters is left to Istio's prefix match" {
  run authz_path "/a/*"
  assert_output "/a/*"
}

@test "authz_path: a plain path is unchanged" {
  run authz_path "/a/b"
  assert_output "/a/b"
}

@test "authz_path: a relative path is made absolute, as the HTTPRoute does" {
  run authz_path "health"
  assert_output "/health"
  run authz_path "a/:id"
  assert_output "/a/{*}"
}

@test "authz_path: a ':' that doesn't start a segment is literal" {
  run authz_path "/v1/things:batchGet"
  assert_success
  assert_output "/v1/things:batchGet"
  run authz_path "/v1/things:batchGet/*"
  assert_output "/v1/things:batchGet/*"
  run authz_path "/v1/things:batch/:id"
  assert_output "/v1/things:batch/{*}"
}

@test "authz_path: a parameter followed by more text in its segment is still one template" {
  run authz_path "/a/:id:x"
  assert_success
  assert_output "/a/{*}"
}

@test "detect_path_type: a ':' that doesn't start a segment is literal" {
  run detect_path_type "/v1/things:batchGet"
  assert_success
  assert_output "Exact:/v1/things:batchGet"
  run detect_path_type "/v1/things:batchGet/*"
  assert_output "PathPrefix:/v1/things:batchGet"
  run detect_path_type "/v1/things:batch/:id"
  assert_output "RegularExpression:/v1/things:batch/[^/]+"
}

@test "authz_path: a parameter mixed with a non-trailing wildcard fails" {
  run authz_path "/a/*/:id"
  assert_failure
  assert_output --partial "mixes :parameters with a '*'"
  run authz_path "/a/:id*"
  assert_failure
}

@test "detect_path_type: a parameter with a trailing wildcard is a regex covering the prefix and below" {
  run detect_path_type "/api/users/:id/files/*"
  assert_success
  assert_output "RegularExpression:/api/users/[^/]+/files(/.*)?"
}

@test "detect_path_type: a wildcard without parameters stays a PathPrefix" {
  run detect_path_type "/api/public/*"
  assert_output "PathPrefix:/api/public"
}

@test "detect_path_type: a parameter is a one-segment regex" {
  run detect_path_type "/api/users/:id"
  assert_output "RegularExpression:/api/users/[^/]+"
}

@test "detect_path_type: a parameter mixed with a non-trailing wildcard fails" {
  run detect_path_type "/a/*/:id"
  assert_failure
  assert_output --partial "mixes :parameters with a '*'"
}

@test "both builders reject the same paths" {
  local p
  for p in "/a/*/:id" "/a/:id*" "/:x/*/y" "a/*/:id"; do
    run detect_path_type "$p"
    assert_failure
    run authz_path "$p"
    assert_failure
  done
}

@test "both builders read a ':' that doesn't name a segment parameter as literal" {
  local p
  for p in "/a:id" "/a/b:id/c" "/a/:/b" "/:" "/a/:"; do
    run detect_path_type "$p"
    assert_output "Exact:$p"
    run authz_path "$p"
    assert_output "$p"
  done
}

# build_ingress_with_rule runs create_http_rule inside command substitutions,
# where set -e doesn't apply: the rejection must still stop the build.
@test "build_ingress_with_rule: a rejected path stops the build of an empty HTTPRoute" {
  local tmp hr
  tmp=$(mktemp -d)
  hr="$tmp/hr.yaml"
  cat > "$hr" <<'YAML'
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: test-hr}
spec:
  hostnames: [a.example.com]
  parentRefs: [{name: gateway-public}]
  rules:
    - matches: [{path: {type: PathPrefix, value: /}}]
      backendRefs: [{name: response-404, port: 80, weight: 0}]
YAML
  export OUTPUT_DIR="$tmp" SCOPE_ID=1 K8S_NAMESPACE=ns SERVICE_ID=s HTTPROUTE_FILE="$hr"
  export SCOPE_RULE='{"service":{"name":"svc","port":{"number":8080}},"blue_green_annotation":null}'

  RULE_PATH="/a/*/:id" run bash "$SERVICE_PATH/scripts/istio/build_ingress_with_rule"

  assert_failure
  assert_output --partial "mixes :parameters with a '*'"
  [[ "$(yq '.spec.rules[0].backendRefs[0].name' "$hr")" == "response-404" ]]
  rm -rf "$tmp"
}

@test "build_ingress_with_rule: a rejected path stops the build of a non-empty HTTPRoute" {
  local tmp hr
  tmp=$(mktemp -d)
  hr="$tmp/hr.yaml"
  cat > "$hr" <<'YAML'
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: test-hr}
spec:
  hostnames: [a.example.com]
  parentRefs: [{name: gateway-public}]
  rules:
    - matches: [{path: {type: Exact, value: /other}}]
      backendRefs: [{name: svc, port: 8080}]
YAML
  export OUTPUT_DIR="$tmp" SCOPE_ID=1 K8S_NAMESPACE=ns SERVICE_ID=s HTTPROUTE_FILE="$hr"
  export SCOPE_RULE='{"service":{"name":"svc","port":{"number":8080}},"blue_green_annotation":null}'

  RULE_PATH="/a/*/:id" run bash "$SERVICE_PATH/scripts/istio/build_ingress_with_rule"

  assert_failure
  [[ "$(yq '.spec.rules | length' "$hr")" == "1" ]]
  rm -rf "$tmp"
}
