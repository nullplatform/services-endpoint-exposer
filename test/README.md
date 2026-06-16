# HTTP Route Access Control Tests

This directory contains tests for the http-route-access-control service using BATS (Bash Automated Testing System).

## Prerequisites

Install BATS:
```bash
# macOS
brew install bats-core

# Linux
git clone https://github.com/bats-core/bats-core.git
cd bats-core
sudo ./install.sh /usr/local
```

## Running Tests

Run all tests:
```bash
cd test
./run-tests.sh
```

Run a specific test file:
```bash
bats test_istio_workflows.bats
```

## Git Hooks

The repository includes a pre-commit hook that automatically runs tests before each commit.

Setup the git hooks:
```bash
./scripts/setup-hooks.sh
```

This configures git to use the `.githooks` directory. The pre-commit hook will:
- Run all BATS tests before allowing a commit
- Skip tests if BATS is not installed (with a warning)
- Prevent commits if tests fail

## Test Structure

- `fixtures/` - Test data and context files
- `helpers.bash` - Common test helper functions
- `test_*.bats` - Test files
- `run-tests.sh` - Script to run all tests

## Writing Tests

Tests validate that given a specific context, the correct output files are generated without actually applying to Kubernetes.

### Context Structure

The test fixtures use the full nullplatform action context structure:

```json
{
  "action": "service:action:update",
  "id": "action-id",
  "parameters": {
    "routes": [...],
    "public_domain": "...",
    "private_domain": "...",
    "authorization": { "enabled": true/false }
  },
  "service": {
    "id": "service-id",
    "slug": "service-slug",
    "attributes": {
      "routes": [...],
      "public_domain": "...",
      "authorization": { "enabled": true/false }
    }
  },
  "tags": {...},
  ...
}
```

### Example Test

```bash
@test "description" {
  # Load a fixture with the full context structure
  export CONTEXT=$(load_fixture "simple-public-routes")

  # Run workflow step
  run bash "$SERVICE_PATH/scripts/istio/build_context"

  # Assert results
  assert_success
  assert_output --partial "expected output"

  # Verify generated files
  assert_file_exists "$OUTPUT_DIR/httproute-service-id-public.yaml"
  assert_file_contains "$OUTPUT_DIR/httproute-service-id-public.yaml" "expected content"
}
```
# Test
