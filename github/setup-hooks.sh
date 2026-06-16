#!/bin/bash

# Get the git repository root
REPO_ROOT="$(git rev-parse --show-toplevel)"

# Configure git to use .githooks directory instead of .git/hooks
cd "$REPO_ROOT"
git config core.hooksPath .githooks

echo "✅ Git hooks configured successfully!"
echo "Pre-commit hook will run endpoint-exposer tests before each commit when endpoint-exposer files are changed"
