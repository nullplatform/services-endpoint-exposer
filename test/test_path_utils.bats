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

@test "authz_path: a parameter inside a segment is left as is" {
  run authz_path "/a:id"
  assert_output "/a:id"
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
