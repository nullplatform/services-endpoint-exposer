# Contributing to Tests

## Adding New Tests

### 1. Create a New Test File

Create a new file named `test_<feature>.bats`:

```bash
#!/usr/bin/env bats

load helpers

@test "feature: description of what is being tested" {
  # Setup test data
  export CONTEXT=$(load_fixture "fixture-name")
  source "$SERVICE_PATH/scripts/istio/build_context"

  # Execute the code under test
  run bash "$SERVICE_PATH/scripts/your-script"

  # Assert results
  assert_success
  assert_output --partial "expected output"
  assert_file_exists "$OUTPUT_DIR/expected-file.yaml"
  assert_file_contains "$OUTPUT_DIR/expected-file.yaml" "expected content"
}
```

### 2. Add Test Fixtures

Create fixture files in `fixtures/` directory:

```bash
# fixtures/my-new-scenario.json
{
  "service": {
    "id": "test-id",
    "slug": "test-service"
  },
  "parameters": {
    "publicDomain": "test.example.com",
    "privateDomain": "test-private.example.com",
    "authorization": {
      "enabled": true
    }
  },
  "routes": [
    {
      "path": "/api/test",
      "method": "GET",
      "scope": "test:read",
      "visibility": "public"
    }
  ]
}
```

### 3. Use Helper Functions

Available helpers from `helpers.bash`:

#### Setup/Teardown
- `setup()` - Automatically called before each test
- `teardown()` - Automatically called after each test

#### File Assertions
- `assert_file_exists <path>` - Assert file exists
- `assert_file_not_exists <path>` - Assert file does not exist
- `assert_file_contains <path> <string>` - Assert file contains string
- `assert_file_not_contains <path> <string>` - Assert file does not contain string
- `assert_yaml_contains <path> <key> <value>` - Assert YAML has key-value pair

#### Fixtures
- `load_fixture <name>` - Load a fixture JSON file
- `create_test_context <id> <slug> <public_domain> <private_domain>` - Create minimal context
- `add_route_to_context <context> <path> <method> <scope> <visibility>` - Add route to context

#### Mocking
- `mock_kubectl()` - Create a mock kubectl command

### 4. Test Structure Best Practices

#### Arrange-Act-Assert Pattern

```bash
@test "description" {
  # Arrange - Setup test data
  export CONTEXT=$(load_fixture "scenario")
  source "$SERVICE_PATH/scripts/istio/build_context"

  # Act - Execute the code
  run bash "$SERVICE_PATH/scripts/my-script"

  # Assert - Verify results
  assert_success
  assert_file_exists "$OUTPUT_DIR/output.yaml"
}
```

#### Test One Thing

Each test should verify one specific behavior:

```bash
# Good - tests one thing
@test "build_httproute: creates public HTTPRoute when routes exist" {
  # ...
}

# Good - tests one thing
@test "build_httproute: creates marker when no routes exist" {
  # ...
}

# Bad - tests multiple things
@test "build_httproute: handles all scenarios" {
  # ... tests too many things
}
```

#### Descriptive Test Names

Use the format: `<component>: <what it does> <under what conditions>`

```bash
@test "build_httproute: creates HTTPRoute when routes exist"
@test "build_httproute: creates marker when no routes exist"
@test "build_httproute: fails with invalid visibility parameter"
```

### 5. Testing Different Scenarios

#### Test Success Cases

```bash
@test "script: succeeds with valid input" {
  export CONTEXT=$(load_fixture "valid-scenario")
  run bash "$SERVICE_PATH/scripts/my-script"
  assert_success
}
```

#### Test Failure Cases

```bash
@test "script: fails with invalid input" {
  export CONTEXT='{"invalid": "data"}'
  run bash "$SERVICE_PATH/scripts/my-script"
  assert_failure
}
```

#### Test Edge Cases

```bash
@test "script: handles empty routes array" {
  export CONTEXT=$(create_test_context "id" "slug" "" "")
  # ...
}

@test "script: handles missing optional parameters" {
  export CONTEXT='{
    "service": {"id": "test", "slug": "test"},
    "parameters": {},
    "routes": []
  }'
  # ...
}
```

### 6. Integration Tests

For end-to-end workflow tests:

```bash
@test "integration: complete update workflow" {
  export CONTEXT=$(load_fixture "complete-scenario")

  # Step 1: Build context
  source "$SERVICE_PATH/scripts/istio/build_context"

  # Step 2: Build httproutes
  export VISIBILITY="public"
  bash "$SERVICE_PATH/scripts/istio/build_httproute"

  export VISIBILITY="private"
  bash "$SERVICE_PATH/scripts/istio/build_httproute"

  # Step 3: Apply
  run bash "$SERVICE_PATH/scripts/common/apply"

  # Assert complete workflow
  assert_success
  assert_file_exists "$OUTPUT_DIR/httproute-*-public.yaml"
  # ... more assertions
}
```

### 7. Running Your Tests

Run a specific test file:
```bash
bats test_my_feature.bats
```

Run all tests:
```bash
./run-tests.sh
```

Run with verbose output:
```bash
bats -t test_my_feature.bats
```

### 8. Debugging Tests

Add debug output:
```bash
@test "my test" {
  # Print variable values
  echo "CONTEXT: $CONTEXT" >&3
  echo "OUTPUT_DIR: $OUTPUT_DIR" >&3

  # Show file contents
  cat "$OUTPUT_DIR/somefile.yaml" >&3

  # ... rest of test
}
```

Run with trace:
```bash
bats -x test_my_feature.bats
```

### 9. Common Patterns

#### Testing with Different Contexts

```bash
@test "script: handles scenario A" {
  export CONTEXT=$(load_fixture "scenario-a")
  # ... test
}

@test "script: handles scenario B" {
  export CONTEXT=$(load_fixture "scenario-b")
  # ... test
}
```

#### Testing File Generation

```bash
@test "script: generates correct file" {
  # ... run script

  # Check file exists
  assert_file_exists "$OUTPUT_DIR/generated.yaml"

  # Check content
  assert_file_contains "$OUTPUT_DIR/generated.yaml" "expected: value"

  # Check YAML structure
  assert_yaml_contains "$OUTPUT_DIR/generated.yaml" ".metadata.name" "expected-name"
}
```

#### Testing Cleanup Behavior

```bash
@test "script: creates cleanup marker when needed" {
  # ... run script that should create marker

  assert_file_exists "$OUTPUT_DIR/.marker-deleted"
  assert_file_not_exists "$OUTPUT_DIR/actual-resource.yaml"
}
```

### 10. Adding Tests to CI/CD

The test suite can be integrated into CI/CD pipelines:

```yaml
# Example GitHub Actions workflow
- name: Run tests
  run: |
    cd test
    ./run-tests.sh
```

### 11. Test Coverage Guidelines

Aim to test:
- ✅ Happy paths (normal operation)
- ✅ Error conditions (invalid input, missing data)
- ✅ Edge cases (empty arrays, null values, special characters)
- ✅ Integration scenarios (complete workflows)
- ✅ Cleanup behavior (resource deletion)
- ✅ Configuration variations (enabled/disabled features)
