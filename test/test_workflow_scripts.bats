#!/usr/bin/env bats

load helpers

# The np CLI ends a whole workflow, successfully, when a step script calls
# `exit 0`: every step after it is skipped. That silently dropped the steps
# after apply, and in the scope override it would cut the scope's own deploy
# workflow short. Step scripts (and what they source) must never `exit 0`.

setup() {
  export SERVICE_PATH="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  load_bats_support_libraries
}

step_scripts() {
  cat "$SERVICE_PATH"/workflows/istio/*.yaml "$SERVICE_PATH"/container-scope-override/deployment/workflows/*.yaml \
    | sed -nE 's/^ *file: "\$(SERVICE_PATH|OVERRIDES_PATH)\/(.*)"$/\1 \2/p' \
    | while read -r base rel; do
        if [[ "$base" == "OVERRIDES_PATH" ]]; then echo "$SERVICE_PATH/container-scope-override/$rel"; else echo "$SERVICE_PATH/$rel"; fi
      done | sort -u
}

@test "workflows: every step script exists" {
  while read -r f; do
    [[ -f "$f" ]] || { echo "missing: $f"; return 1; }
  done < <(step_scripts)
}

@test "workflows: no step script, or script it sources, calls exit 0" {
  offenders=$(
    { step_scripts; grep -rhoE 'source "\$SERVICE_PATH/[^"]+"' "$SERVICE_PATH/scripts" | sed -E 's/source "\$SERVICE_PATH\/(.*)"/\1/' | sed "s|^|$SERVICE_PATH/|"; } \
      | sort -u | xargs grep -nE '(^|[^#]*[;&|] *|^ *)exit 0' 2>/dev/null | grep -vE ':[0-9]+: *#' || true)
  [[ -z "$offenders" ]] || { echo "$offenders"; return 1; }
}
