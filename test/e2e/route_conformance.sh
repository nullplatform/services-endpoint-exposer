#!/usr/bin/env bash
#
# End-to-end conformance for a deployed HTTP Route Access Control instance.
#
# Reads the routes actually stored on the service and asserts, per route, the
# behaviour the declared fields are supposed to produce against the public
# gateway. It derives everything else (application, scopes, domains) from the
# API, so the only required input is the service id.
#
# Rewrite and weight checks need the backend to echo something identifiable in
# its JSON response; point --path-field / --scope-field at those keys. Checks
# whose inputs are missing are reported as SKIP, never as PASS.
#
# Usage:
#   route_conformance.sh --service-id <uuid> [options]
#
#   --samples N        requests per weighted path         (default 40)
#   --tolerance PCT    allowed deviation per share        (default 15)
#   --path-field JQ    jq path to the served request path (default .path)
#   --scope-field JQ   jq path to the answering scope     (default .scope)
#   --token JWT        bearer token for routes with groups
#   --timeout SECONDS  per-request curl timeout           (default 10)
#   --dry-run          print the plan without sending traffic
#
# Requires: np (authenticated), jq, curl.

set -euo pipefail

# Percentages go through awk's printf, which honours the locale's decimal
# separator: without this the report prints "30,0%" under es_* locales.
export LC_NUMERIC=C

SERVICE_ID=""
SAMPLES=40
TOLERANCE=15
PATH_FIELD=".path"
SCOPE_FIELD=".scope"
TOKEN=""
TIMEOUT=10
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --service-id) SERVICE_ID="$2"; shift 2 ;;
    --samples) SAMPLES="$2"; shift 2 ;;
    --tolerance) TOLERANCE="$2"; shift 2 ;;
    --path-field) PATH_FIELD="$2"; shift 2 ;;
    --scope-field) SCOPE_FIELD="$2"; shift 2 ;;
    --token) TOKEN="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$SERVICE_ID" ]] || { echo "--service-id is required" >&2; exit 2; }
for bin in np jq curl; do
  command -v "$bin" >/dev/null || { echo "$bin not found in PATH" >&2; exit 2; }
done

PASS=0; FAIL=0; SKIP=0
declare -a REPORT=()

record() { # record <status> <feature> <detail>
  REPORT+=("$1|$2|$3")
  case "$1" in
    PASS) PASS=$((PASS + 1)) ;;
    FAIL) FAIL=$((FAIL + 1)) ;;
    SKIP) SKIP=$((SKIP + 1)) ;;
  esac
}

# A wildcard path becomes a PathPrefix match, so probe a child of the prefix:
# that is the only way a rewrite is observable.
probe_path() {
  local declared="$1"
  if [[ "$declared" == *"*"* ]]; then
    echo "${declared%/\*}/conformance-probe"
  else
    echo "$declared"
  fi
}

curl_code() { # curl_code <url> <method> [header...]
  local url="$1" method="$2"; shift 2
  local args=(-s -o /dev/null -w '%{http_code}' -m "$TIMEOUT" -X "$method")
  for h in "$@"; do args+=(-H "$h"); done
  curl "${args[@]}" "$url" || echo "000"
}

curl_body() { # curl_body <url> <method> [header...]
  local url="$1" method="$2"; shift 2
  local args=(-s -m "$TIMEOUT" -X "$method")
  for h in "$@"; do args+=(-H "$h"); done
  curl "${args[@]}" "$url" || true
}

SERVICE_JSON=$(np service read --id "$SERVICE_ID" --format json)
ROUTES=$(echo "$SERVICE_JSON" | jq -c '.attributes.routes // []')
APPLICATION_ID=$(echo "$SERVICE_JSON" | jq -r '.entity_nrn | capture("application=(?<id>[0-9]+)").id')
SCOPES=$(np scope list --application_id "$APPLICATION_ID" --limit 200 --format json | jq -c '[.results[] | select(.status == "active") | {slug, domain}]')

echo "service     $SERVICE_ID"
echo "application $APPLICATION_ID"
echo "routes      $(echo "$ROUTES" | jq 'length')"
echo

domain_for() {
  echo "$SCOPES" | jq -r --arg s "$1" '.[] | select(.slug == $s) | .domain' | head -1
}

# The platform delivers action parameters with snake_cased keys, so a stored
# route can carry either spelling of requestHeaders.
route_headers() { echo "$1" | jq -c '.headers // []'; }
route_rewrite() { echo "$1" | jq -c '.rewrite // {}'; }
route_reqhdrs() { echo "$1" | jq -c '.requestHeaders // .request_headers // {}'; }

# Routes sharing path+method are one Gateway API rule with weighted backends,
# so the weight check is per group, not per route.
ROUTE_GROUPS=$(echo "$ROUTES" | jq -c '
  group_by([.path, (.methods // [.method] | sort)])
  | map({path: .[0].path, methods: (.[0].methods // [.[0].method]), routes: .})')

while read -r group; do
  gpath=$(echo "$group" | jq -r '.path')
  gmethod=$(echo "$group" | jq -r '.methods[0]')
  members=$(echo "$group" | jq -c '.routes')
  count=$(echo "$members" | jq 'length')
  first=$(echo "$members" | jq -c '.[0]')
  scope=$(echo "$first" | jq -r '.scope')
  host=$(domain_for "$scope")
  visibility=$(echo "$first" | jq -r '.visibility // "public"')
  groups_len=$(echo "$first" | jq '(.groups // []) | length')
  headers=$(route_headers "$first")
  rewrite=$(route_rewrite "$first")
  probe=$(probe_path "$gpath")

  if [[ -z "$host" || "$host" == "To be defined" ]]; then
    record SKIP "host" "$gmethod $gpath -> scope '$scope' has no domain"
    continue
  fi
  url="https://$host$probe"

  if $DRY_RUN; then
    echo "would probe $gmethod $url (scope=$scope visibility=$visibility groups=$groups_len headers=$(echo "$headers" | jq 'length') rewrite=$(echo "$rewrite" | jq 'length') backends=$count)"
    continue
  fi

  header_args=()
  while read -r h; do [[ -n "$h" ]] && header_args+=("$h"); done < <(echo "$headers" | jq -r '.[] | "\(.name): \(.value)"')

  # F7 - a route pinned to the private gateway must not answer publicly.
  if [[ "$visibility" == "internal" || "$visibility" == "private" ]]; then
    code=$(curl_code "$url" "$gmethod" "${header_args[@]+"${header_args[@]}"}")
    if [[ "$code" == "200" ]]; then
      record FAIL "F7 visibility" "$gmethod $probe answered $code on the public gateway"
    else
      record PASS "F7 visibility" "$gmethod $probe -> $code publicly (private gateway only)"
    fi
    continue
  fi

  # F2/F3 - empty groups is an open route; a non-empty one must reject an
  # anonymous request.
  code=$(curl_code "$url" "$gmethod" "${header_args[@]+"${header_args[@]}"}")
  if [[ "$groups_len" -eq 0 ]]; then
    if [[ "$code" == "200" ]]; then
      record PASS "F2 open route" "$gmethod $probe -> 200 without a token"
    else
      record FAIL "F2 open route" "$gmethod $probe -> $code without a token, expected 200"
    fi
  else
    if [[ "$code" == "401" || "$code" == "403" ]]; then
      record PASS "F3 access control" "$gmethod $probe -> $code without a token"
    else
      record FAIL "F3 access control" "$gmethod $probe -> $code without a token, expected 401/403"
    fi
    if [[ -n "$TOKEN" ]]; then
      code=$(curl_code "$url" "$gmethod" "Authorization: Bearer $TOKEN" "${header_args[@]+"${header_args[@]}"}")
      if [[ "$code" == "200" ]]; then
        record PASS "F3 access control" "$gmethod $probe -> 200 with a token"
      else
        record FAIL "F3 access control" "$gmethod $probe -> $code with a token, expected 200"
      fi
    else
      record SKIP "F3 access control" "$gmethod $probe authorized path needs --token"
    fi
  fi

  # F5a - without its declared headers the request must not reach this rule. A
  # 200 alone does not prove that it did: another HTTPRoute on the same
  # hostname absorbs the fallthrough, and a scope publishes its own catch-all
  # on "/". When the rule also rewrites, the served path tells the two apart -
  # an unrewritten path means some other route answered.
  if [[ "$(echo "$headers" | jq 'length')" -gt 0 ]]; then
    code=$(curl_code "$url" "$gmethod")
    if [[ "$code" != "200" ]]; then
      record PASS "F5a header match" "$gmethod $probe -> $code without the header"
    else
      rw=$(echo "$rewrite" | jq -r '.path // ""')
      served=""
      if [[ -n "$rw" ]]; then
        served=$(curl_body "$url" "$gmethod" | jq -r "$PATH_FIELD // empty" 2>/dev/null || true)
      fi
      if [[ -z "$rw" || -z "$served" ]]; then
        record SKIP "F5a header match" "$gmethod $probe answered 200 without the header, cannot tell which route served it"
      elif [[ "$served" == "$rw"* ]]; then
        record FAIL "F5a header match" "$gmethod $probe was served by this rule without its declared header"
      else
        record PASS "F5a header match" "$gmethod $probe -> another route served $served without the header"
      fi
    fi
  fi

  # F6 - the backend must see the rewritten path.
  rewrite_path=$(echo "$rewrite" | jq -r '.path // ""')
  if [[ -n "$rewrite_path" ]]; then
    body=$(curl_body "$url" "$gmethod" "${header_args[@]+"${header_args[@]}"}")
    served=$(echo "$body" | jq -r "$PATH_FIELD // empty" 2>/dev/null || true)
    if [[ -z "$served" ]]; then
      record SKIP "F6 rewrite" "$gmethod $probe backend does not echo $PATH_FIELD"
    elif [[ "$served" == "$rewrite_path"* ]]; then
      record PASS "F6 rewrite" "$gmethod $probe -> backend saw $served"
    else
      record FAIL "F6 rewrite" "$gmethod $probe -> backend saw $served, expected prefix $rewrite_path"
    fi
  fi

  # F6 - injected request headers are only observable if the backend echoes
  # them, so this stays a declaration check unless it does.
  if [[ "$(route_reqhdrs "$first" | jq 'length')" -gt 0 ]]; then
    record SKIP "F6 request headers" "$gmethod $probe injection is not observable from outside"
  fi

  # F5b - shares of traffic across the weighted backends of one rule.
  if [[ "$count" -gt 1 ]]; then
    total=$(echo "$members" | jq '[.[] | .weight // 1] | add')
    counts=$(for _ in $(seq 1 "$SAMPLES"); do
      curl_body "$url" "$gmethod" "${header_args[@]+"${header_args[@]}"}" | jq -r "$SCOPE_FIELD // \"?\"" 2>/dev/null || echo "?"
    done | sort | uniq -c)
    if echo "$counts" | grep -q '?'; then
      record SKIP "F5b weights" "$gmethod $probe backend does not echo $SCOPE_FIELD"
    else
      while read -r seen slug; do
        declared=$(echo "$members" | jq --arg s "$slug" '[.[] | select(.scope == $s) | .weight // 1] | add // 0')
        want=$(awk -v d="$declared" -v t="$total" 'BEGIN{printf "%.1f", (d/t)*100}')
        got=$(awk -v c="$seen" -v n="$SAMPLES" 'BEGIN{printf "%.1f", (c/n)*100}')
        within=$(awk -v w="$want" -v g="$got" -v tol="$TOLERANCE" 'BEGIN{print ((g-w) <= tol && (w-g) <= tol) ? "yes" : "no"}')
        record "$([[ "$within" == "yes" ]] && echo PASS || echo FAIL)" \
          "F5b weights" "$gmethod $probe $slug got ${got}% of $SAMPLES, declared ${want}%"
      done <<< "$counts"
    fi
  fi
done < <(echo "$ROUTE_GROUPS" | jq -c '.[]')

$DRY_RUN && exit 0

printf '%-6s %-22s %s\n' STATUS FEATURE DETAIL
for line in "${REPORT[@]+"${REPORT[@]}"}"; do
  IFS='|' read -r status feature detail <<< "$line"
  printf '%-6s %-22s %s\n' "$status" "$feature" "$detail"
done

echo
echo "pass $PASS  fail $FAIL  skip $SKIP"
[[ "$FAIL" -eq 0 ]]
