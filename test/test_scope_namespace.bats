#!/usr/bin/env bats

# Apps in more than one Kubernetes namespace: namespace resolution per scope,
# HTTPRoute placement next to the app's Services, and cleanup across namespaces.
# np and kubectl are stubbed; the kubectl stub serves $KUBECTL_SERVICES and
# $KUBECTL_HTTPROUTES and logs every call to $KUBECTL_LOG.

load helpers

setup() {
  export TEST_TEMP_DIR="$(mktemp -d)"
  export OUTPUT_DIR="$TEST_TEMP_DIR/output"
  mkdir -p "$OUTPUT_DIR"
  export SERVICE_PATH="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  load_bats_support_libraries

  export SERVICE_ID="svc-1"
  export SERVICE_SLUG="exposer"
  export APPLICATION_ID="app-1"
  export K8S_NAMESPACE="nullplatform"
  unset NAMESPACE_OVERRIDE
  export CONTEXT='{"tags": {"application_id": "app-1"}}'
  export KUBECTL_LOG="$TEST_TEMP_DIR/kubectl.log"
  export KUBECTL_SERVICES="$TEST_TEMP_DIR/services.json"
  export KUBECTL_HTTPROUTES="$TEST_TEMP_DIR/httproutes.json"
  echo '{"items": []}' > "$KUBECTL_SERVICES"
  echo '{"items": []}' > "$KUBECTL_HTTPROUTES"
  touch "$KUBECTL_LOG"

  cat > "$TEST_TEMP_DIR/kubectl" <<'EOF'
#!/bin/bash
echo "kubectl $*" >> "$KUBECTL_LOG"
[[ "$1" == "get" && -n "${KUBECTL_FAIL_LIST:-}" ]] && { echo "forbidden" >&2; exit 1; }
if [[ "$1" == "get" ]]; then
  case "$2" in
    services) file="$KUBECTL_SERVICES" ;;
    httproute|httproutes) file="$KUBECTL_HTTPROUTES" ;;
    *) exit 0 ;;
  esac
  namespace=""
  [[ "$3" == "-n" ]] && namespace="$4"
  jq --arg ns "$namespace" '{items: [.items[] | select($ns == "" or .metadata.namespace == $ns)]}' "$file"
fi
exit 0
EOF

  # Scopes: web (101) and api (202); domains only for web
  cat > "$TEST_TEMP_DIR/np" <<'EOF'
#!/bin/bash
case "$1 $2" in
  "scope list") echo '{"results": [{"id": "101", "slug": "web"}, {"id": "202", "slug": "api"}]}' ;;
  "scope read") echo "{\"id\": \"$4\", \"domain\": \"app-$4.example.com\", \"in_progress_deployment\": null}" ;;
  *) echo '{}' ;;
esac
EOF
  chmod +x "$TEST_TEMP_DIR/kubectl" "$TEST_TEMP_DIR/np"
  export PATH="$TEST_TEMP_DIR:$PATH"
}

# service <namespace> <scope_id> <name>: a Service the scope agent created
service() {
  jq -n --arg ns "$1" --arg scope "$2" --arg name "$3" \
    '{metadata: {name: $name, namespace: $ns}, spec: {selector: {nullplatform: "true", scope_id: $scope, deployment_id: $name}, ports: [{port: 8080}]}}'
}

# httproute <namespace> <name>
httproute() {
  jq -n --arg ns "$1" --arg name "$2" \
    '{metadata: {name: $name, namespace: $ns, labels: {"nullplatform.com/service-id": "svc-1"}}}'
}

# Fails when the kubectl log has $1 (a bare "! grep" does not fail a bats test)
refute_kubectl_call() {
  if grep -q -- "$1" "$KUBECTL_LOG"; then
    echo "unexpected kubectl call: $1" >&2
    return 1
  fi
}

set_items() {
  local file="$1"; shift
  printf '%s\n' "$@" | jq -s '{items: .}' > "$file"
}

build_public_httproute() {
  export ROUTES_JSON="$1"
  export PUBLIC_ROUTES_JSON="$1"
  export PRIVATE_ROUTES_JSON="[]"
  VISIBILITY=public run bash "$SERVICE_PATH/scripts/istio/build_httproute"
}

# --- resolve_scope_namespace ---

@test "resolve_scope_namespace: NAMESPACE_OVERRIDE wins" {
  set_items "$KUBECTL_SERVICES" "$(service team-a 101 d-101-1)"

  NAMESPACE_OVERRIDE=team-b run "$SERVICE_PATH/scripts/istio/resolve_scope_namespace" 101

  assert_success
  assert_output "team-b"
}

@test "resolve_scope_namespace: finds the scope's Service in any namespace" {
  set_items "$KUBECTL_SERVICES" "$(service team-a 101 d-101-1)" "$(service team-b 202 d-202-1)"

  run "$SERVICE_PATH/scripts/istio/resolve_scope_namespace" 202

  assert_success
  assert_output "team-b"
  grep -q "kubectl get services --all-namespaces -o json" "$KUBECTL_LOG"
}

@test "resolve_scope_namespace: blue/green Services in one namespace resolve to it" {
  set_items "$KUBECTL_SERVICES" "$(service team-a 101 d-101-1)" "$(service team-a 101 d-101-2)"

  run "$SERVICE_PATH/scripts/istio/resolve_scope_namespace" 101

  assert_success
  assert_output "team-a"
}

@test "resolve_scope_namespace: falls back to K8S_NAMESPACE when the scope has no Service" {
  run "$SERVICE_PATH/scripts/istio/resolve_scope_namespace" 101

  assert_success
  assert_output "nullplatform"
}

@test "resolve_scope_namespace: falls back to K8S_NAMESPACE when the cluster-wide list is forbidden" {
  KUBECTL_FAIL_LIST=1 run "$SERVICE_PATH/scripts/istio/resolve_scope_namespace" 101

  assert_success
  assert_output --partial "WARNING: could not list Services across namespaces"
  [[ "${lines[${#lines[@]}-1]}" == "nullplatform" ]]
}

@test "resolve_scope_namespace: fails when the scope has Services in two namespaces" {
  set_items "$KUBECTL_SERVICES" "$(service nullplatform 101 d-101-1)" "$(service team-a 101 d-101-2)"

  run "$SERVICE_PATH/scripts/istio/resolve_scope_namespace" 101

  assert_failure
  assert_output --partial "more than one namespace"
}

# --- build_httproute ---

@test "build_httproute: puts the HTTPRoute in the app's namespace with its backend" {
  set_items "$KUBECTL_SERVICES" "$(service nullplatform 999 other)" "$(service team-a 101 d-101-1)"

  build_public_httproute '[{"path": "/", "scope": "web", "methods": ["GET"]}]'

  assert_success
  assert_output --partial "public HTTPRoute namespace: team-a"
  FILE="$OUTPUT_DIR/httproute-svc-1-public.yaml"
  assert_yaml_contains "$FILE" '.metadata.namespace' "team-a"
  assert_yaml_contains "$FILE" '.spec.rules[0].backendRefs[0].name' "d-101-1"
  grep -q "kubectl get services -n team-a -o json" "$KUBECTL_LOG"
}

@test "build_httproute: an app in the nullplatform namespace keeps working" {
  set_items "$KUBECTL_SERVICES" "$(service nullplatform 101 d-101-1)"

  build_public_httproute '[{"path": "/", "scope": "web", "methods": ["GET"]}]'

  assert_success
  FILE="$OUTPUT_DIR/httproute-svc-1-public.yaml"
  assert_yaml_contains "$FILE" '.metadata.namespace' "nullplatform"
  assert_yaml_contains "$FILE" '.spec.rules[0].backendRefs[0].name' "d-101-1"
}

@test "build_httproute: NAMESPACE_OVERRIDE places the HTTPRoute without a cluster-wide lookup" {
  set_items "$KUBECTL_SERVICES" "$(service team-b 101 d-101-1)"

  NAMESPACE_OVERRIDE=team-b build_public_httproute '[{"path": "/", "scope": "web", "methods": ["GET"]}]'

  assert_success
  assert_yaml_contains "$OUTPUT_DIR/httproute-svc-1-public.yaml" '.metadata.namespace' "team-b"
  refute_kubectl_call "--all-namespaces"
}

@test "build_httproute: refuses routes to scopes in different namespaces" {
  set_items "$KUBECTL_SERVICES" "$(service team-a 101 d-101-1)" "$(service team-b 202 d-202-1)"

  build_public_httproute '[{"path": "/", "scope": "web", "methods": ["GET"]}, {"path": "/api", "scope": "api", "methods": ["GET"]}]'

  assert_failure
  assert_output --partial "different namespaces"
  assert_file_not_exists "$OUTPUT_DIR/httproute-svc-1-public.yaml"
}

# --- apply ---

@test "apply: a deletion marker removes the HTTPRoute from the namespace it lives in" {
  set_items "$KUBECTL_HTTPROUTES" "$(httproute team-a exposer-svc-1-public)"
  touch "$OUTPUT_DIR/.httproute-public-deleted"

  ACTION=apply DRY_RUN=false run bash "$SERVICE_PATH/scripts/common/apply"

  assert_success
  grep -q "kubectl delete httproute exposer-svc-1-public -n team-a" "$KUBECTL_LOG"
  refute_kubectl_call "kubectl delete httproute exposer-svc-1-public -n nullplatform"
}

@test "apply: removes the old copy of an HTTPRoute that moved namespace" {
  set_items "$KUBECTL_HTTPROUTES" "$(httproute nullplatform exposer-svc-1-public)" "$(httproute team-a exposer-svc-1-public)"
  cat > "$OUTPUT_DIR/httproute-svc-1-public.yaml" <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: exposer-svc-1-public
  namespace: team-a
EOF

  ACTION=apply DRY_RUN=false run bash "$SERVICE_PATH/scripts/common/apply"

  assert_success
  grep -q "kubectl apply -f" "$KUBECTL_LOG"
  grep -q "kubectl delete httproute exposer-svc-1-public -n nullplatform" "$KUBECTL_LOG"
  refute_kubectl_call "kubectl delete httproute exposer-svc-1-public -n team-a"
}

@test "apply: without cluster-wide list, deletes in K8S_NAMESPACE as before" {
  touch "$OUTPUT_DIR/.httproute-public-deleted"

  KUBECTL_FAIL_LIST=1 ACTION=apply DRY_RUN=false run bash "$SERVICE_PATH/scripts/common/apply"

  assert_success
  assert_output --partial "WARNING: could not list HTTPRoutes across namespaces"
  grep -q "kubectl get httproute exposer-svc-1-public -n nullplatform" "$KUBECTL_LOG"
}

# --- only the platform's Services are backends ---

# echo_service <namespace> <scope_id> <name>: selects the scope_id but wasn't
# created by the scope agent (no nullplatform label, no deployment_id)
echo_service() {
  jq -n --arg ns "$1" --arg scope "$2" --arg name "$3" \
    '{metadata: {name: $name, namespace: $ns}, spec: {selector: {scope_id: $scope}, ports: [{port: 80}]}}'
}

build_link_httproute() {
  export ROUTES_JSON="$1" LINK_ID="link-1" DOMAIN_NAME="api.example.com" GATEWAY_NAME="gateway-public"
  run bash -c 'source "$SERVICE_PATH/scripts/istio/build_link_httproute"'
}

@test "resolve_scope_namespace: a Service the platform didn't create doesn't count" {
  set_items "$KUBECTL_SERVICES" "$(service team-a 101 d-101-1)" "$(echo_service nullplatform 101 echo)"

  run "$SERVICE_PATH/scripts/istio/resolve_scope_namespace" 101

  assert_success
  assert_output "team-a"
}

@test "build_link_httproute: a route whose scope has no platform Service is left out" {
  set_items "$KUBECTL_SERVICES" "$(service nullplatform 101 d-101-1)" "$(echo_service nullplatform 202 echo)"

  build_link_httproute '[{"path": "/web", "scope": "web", "methods": ["GET"]}, {"path": "/api", "scope": "api", "methods": ["GET"]}]'

  assert_success
  assert_output --partial "WARNING: route GET /api skipped: scope api has no backend"
  FILE="$OUTPUT_DIR/httproute-link-link-1.yaml"
  assert_yaml_contains "$FILE" '.spec.rules | length' "1"
  assert_yaml_contains "$FILE" '.spec.rules[0].backendRefs[0].name' "d-101-1"
  [[ "$(yq '[.spec.rules[].backendRefs[].name] | contains(["response-404"])' "$FILE")" == "false" ]]
  [[ "$(yq '[.spec.rules[].backendRefs[].name] | contains(["echo"])' "$FILE")" == "false" ]]
}

@test "build_link_httproute: without any backend the link's HTTPRoute is removed, not left as a catch-all" {
  set_items "$KUBECTL_SERVICES" "$(echo_service nullplatform 101 echo)"

  build_link_httproute '[{"path": "/web", "scope": "web", "methods": ["ALL"]}]'

  assert_success
  assert_output --partial "no route of link link-1 has a backend"
  assert_file_not_exists "$OUTPUT_DIR/httproute-link-link-1.yaml"
  assert_file_exists "$OUTPUT_DIR/.httproute-link-deleted"
}

@test "apply: the link deletion marker removes the link's HTTPRoute wherever it is" {
  touch "$OUTPUT_DIR/.httproute-link-deleted"

  LINK_ID=link-1 ACTION=apply DRY_RUN=false run bash "$SERVICE_PATH/scripts/common/apply"

  assert_success
  grep -q "kubectl delete httproute --all-namespaces --ignore-not-found -l nullplatform.com/managed-by=http-route-access-control,nullplatform.com/link-id=link-1" "$KUBECTL_LOG"
  assert_file_not_exists "$OUTPUT_DIR/.httproute-link-deleted"
}

@test "resolve_scope_namespace: a NAMESPACE_OVERRIDE the channel didn't interpolate is ignored" {
  set_items "$KUBECTL_SERVICES" "$(service team-a 101 d-101-1)"

  NAMESPACE_OVERRIDE='{context.tags.namespace}' run "$SERVICE_PATH/scripts/istio/resolve_scope_namespace" 101

  assert_success
  assert_output --partial "WARNING: ignoring NAMESPACE_OVERRIDE='{context.tags.namespace}'"
  [[ "${lines[${#lines[@]}-1]}" == "team-a" ]]
}
