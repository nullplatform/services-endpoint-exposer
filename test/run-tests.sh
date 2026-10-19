#!/bin/bash

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "================================================"
echo "  Endpoint Exposer Test Suite"
echo "================================================"
echo ""

# Check if bats is installed
if ! command -v bats &> /dev/null; then
    echo -e "${RED}Error: bats is not installed${NC}"
    echo ""
    echo "Install bats:"
    echo "  macOS:  brew install bats-core"
    echo "  Linux:  git clone https://github.com/bats-core/bats-core.git && cd bats-core && sudo ./install.sh /usr/local"
    echo ""
    exit 1
fi

# Check if jq is installed (required by tests)
if ! command -v jq &> /dev/null; then
    echo -e "${RED}Error: jq is not installed${NC}"
    echo ""
    echo "Install jq:"
    echo "  macOS:  brew install jq"
    echo "  Linux:  sudo apt-get install jq"
    echo ""
    exit 1
fi

# Change to test directory
cd "$(dirname "$0")"

# Run tests
echo "Running tests..."
echo ""

TEST_FILES=(
  "test_build_context.bats"
  "test_build_httproute.bats"
  "test_authorization_policy.bats"
  "test_apply_cleanup.bats"
  "test_integration.bats"
)

FAILED=0
PASSED=0

for test_file in "${TEST_FILES[@]}"; do
  if [[ -f "$test_file" ]]; then
    echo -e "${YELLOW}Running $test_file...${NC}"
    if bats "$test_file"; then
      ((PASSED++))
      echo -e "${GREEN}✓ $test_file passed${NC}"
    else
      ((FAILED++))
      echo -e "${RED}✗ $test_file failed${NC}"
    fi
    echo ""
  fi
done

echo "================================================"
echo "  Test Summary"
echo "================================================"
echo -e "Passed: ${GREEN}$PASSED${NC}"
echo -e "Failed: ${RED}$FAILED${NC}"
echo ""

if [[ $FAILED -gt 0 ]]; then
  echo -e "${RED}Some tests failed${NC}"
  exit 1
else
  echo -e "${GREEN}All tests passed!${NC}"
  exit 0
fi
