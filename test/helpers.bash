#!/bin/bash

# Test helpers for endpoint-exposer tests

# Setup function called before each test
setup() {
  # Create temporary output directory
  export TEST_TEMP_DIR="$(mktemp -d)"
  export OUTPUT_DIR="$TEST_TEMP_DIR/output"
  mkdir -p "$OUTPUT_DIR"

  # Set SERVICE_PATH to parent directory
  export SERVICE_PATH="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

  # Mock DRY_RUN to true by default to avoid actual kubectl calls
  export DRY_RUN="${DRY_RUN:-true}"
  export ACTION="${ACTION:-apply}"

  # Load bats support libraries if available
  load_bats_support_libraries
}

# Teardown function called after each test
teardown() {
  # Clean up temporary directory
  if [[ -n "$TEST_TEMP_DIR" ]] && [[ -d "$TEST_TEMP_DIR" ]]; then
    rm -rf "$TEST_TEMP_DIR"
  fi
}

# Load bats support libraries or define basic assertions
load_bats_support_libraries() {
  # Try to load bats-support and bats-assert if available
  local loaded=false
  if [[ -f "/usr/local/lib/bats-support/load.bash" ]]; then
    load "/usr/local/lib/bats-support/load.bash"
    loaded=true
  fi
  if [[ -f "/usr/local/lib/bats-assert/load.bash" ]]; then
    load "/usr/local/lib/bats-assert/load.bash"
    loaded=true
  fi

  # If libraries not loaded, define basic assertion functions
  if [[ "$loaded" == "false" ]]; then
    # Define assert_success
    assert_success() {
      if [[ "$status" -ne 0 ]]; then
        echo "Expected success (exit 0) but got: $status" >&2
        echo "Output: $output" >&2
        return 1
      fi
    }

    # Define assert_failure
    assert_failure() {
      if [[ "$status" -eq 0 ]]; then
        echo "Expected failure (non-zero exit) but got: $status" >&2
        echo "Output: $output" >&2
        return 1
      fi
    }

    # Define assert_output
    assert_output() {
      local expected=""
      local partial=false

      while [[ $# -gt 0 ]]; do
        case $1 in
          --partial)
            partial=true
            shift
            ;;
          *)
            expected="$1"
            shift
            ;;
        esac
      done

      if [[ "$partial" == "true" ]]; then
        if [[ "$output" != *"$expected"* ]]; then
          echo "Expected output to contain: $expected" >&2
          echo "Actual output: $output" >&2
          return 1
        fi
      else
        if [[ "$output" != "$expected" ]]; then
          echo "Expected output: $expected" >&2
          echo "Actual output: $output" >&2
          return 1
        fi
      fi
    }
  fi
}

# Assert that a file exists
assert_file_exists() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    echo "File does not exist: $file" >&2
    return 1
  fi
}

# Assert that a file does not exist
assert_file_not_exists() {
  local file="$1"
  if [[ -f "$file" ]]; then
    echo "File exists but should not: $file" >&2
    return 1
  fi
}

# Assert that a file contains a string
assert_file_contains() {
  local file="$1"
  local expected="$2"

  if [[ ! -f "$file" ]]; then
    echo "File does not exist: $file" >&2
    return 1
  fi

  if ! grep -q "$expected" "$file"; then
    echo "File does not contain expected string: $expected" >&2
    echo "File contents:" >&2
    cat "$file" >&2
    return 1
  fi
}

# Assert that a file does not contain a string
assert_file_not_contains() {
  local file="$1"
  local unexpected="$2"

  if [[ ! -f "$file" ]]; then
    echo "File does not exist: $file" >&2
    return 1
  fi

  if grep -q "$unexpected" "$file"; then
    echo "File contains unexpected string: $unexpected" >&2
    echo "File contents:" >&2
    cat "$file" >&2
    return 1
  fi
}

# Assert that a YAML file has a specific key-value pair
assert_yaml_contains() {
  local file="$1"
  local key="$2"
  local expected_value="$3"

  if [[ ! -f "$file" ]]; then
    echo "File does not exist: $file" >&2
    return 1
  fi

  local actual_value
  actual_value=$(yq eval "$key" "$file" 2>/dev/null || echo "")

  if [[ "$actual_value" != "$expected_value" ]]; then
    echo "YAML key '$key' has unexpected value" >&2
    echo "Expected: $expected_value" >&2
    echo "Actual: $actual_value" >&2
    return 1
  fi
}

# Count the number of YAML documents in a file
count_yaml_documents() {
  local file="$1"
  grep -c "^---" "$file" || echo "0"
}

# Load a fixture context file
load_fixture() {
  local fixture_name="$1"
  local fixture_file="$BATS_TEST_DIRNAME/fixtures/$fixture_name.json"

  if [[ ! -f "$fixture_file" ]]; then
    echo "Fixture not found: $fixture_file" >&2
    return 1
  fi

  cat "$fixture_file"
}

# Mock kubectl to avoid actual API calls
mock_kubectl() {
  # Create a mock kubectl script
  cat > "$TEST_TEMP_DIR/kubectl" << 'EOF'
#!/bin/bash
echo "Mock kubectl called with: $@" >&2
exit 0
EOF
  chmod +x "$TEST_TEMP_DIR/kubectl"
  export PATH="$TEST_TEMP_DIR:$PATH"
}

# Create a minimal valid context for testing with full structure
create_test_context() {
  local service_id="${1:-test-service-id}"
  local service_slug="${2:-test-service}"
  local public_domain="${3:-test.example.com}"
  local private_domain="${4:-test-private.example.com}"

  cat <<EOF
{
  "action": "service:action:update",
  "id": "test-action-id",
  "name": "update-$service_slug",
  "slug": "update-$service_slug",
  "status": "pending",
  "created_at": "2026-01-12T00:00:00.000Z",
  "updated_at": "2026-01-12T00:00:00.000Z",
  "parameters": {
    "routes": [],
    "public_domain": "$public_domain",
    "authorization": {
      "enabled": false
    },
    "private_domain": "$private_domain"
  },
  "results": {},
  "type": "update",
  "specification": {
    "id": "test-spec-id",
    "slug": "update-endpoint-exposer"
  },
  "service": {
    "id": "$service_id",
    "slug": "$service_slug",
    "attributes": {
      "routes": [],
      "public_domain": "$public_domain",
      "authorization": {
        "enabled": false
      },
      "private_domain": "$private_domain"
    },
    "type": "dependency",
    "specification": {
      "id": "test-service-spec-id",
      "slug": "endpoint-exposer"
    },
    "dimensions": {}
  },
  "link": null,
  "user": {
    "id": 1,
    "email": "test@example.com"
  },
  "tags": {
    "organization_id": "test-org",
    "organization": "test-org",
    "namespace_id": "test-namespace",
    "namespace": "test",
    "account_id": "test-account",
    "account": "test",
    "application_id": "test-app",
    "application": "test-app"
  },
  "entity_nrn": "organization=test-org:account=test-account:namespace=test-namespace:application=test-app"
}
EOF
}

# Add a route to a context JSON (adds to both parameters.routes and service.attributes.routes)
add_route_to_context() {
  local context="$1"
  local path="$2"
  local method="$3"
  local scope="$4"
  local visibility="${5:-public}"

  echo "$context" | jq --arg path "$path" \
    --arg method "$method" \
    --arg scope "$scope" \
    --arg visibility "$visibility" \
    '.parameters.routes += [{
      path: $path,
      method: $method,
      scope: $scope,
      visibility: $visibility
    }] |
    .service.attributes.routes += [{
      path: $path,
      method: $method,
      scope: $scope,
      visibility: $visibility
    }]'
}
