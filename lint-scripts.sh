#!/usr/bin/env bash
# lint-scripts.sh - Run shellcheck on all bash scripts in the repo

set -euo pipefail

cd "$(dirname "$0")"

echo "Running ShellCheck on bash scripts..."
echo ""

# Check if shellcheck is installed
if ! command -v shellcheck &>/dev/null; then
    echo "Error: shellcheck is not installed"
    echo "Install with: brew install shellcheck (macOS) or apt install shellcheck (Linux)"
    exit 1
fi

# Run shellcheck on all .sh files
# Exclude SC1090 and SC1091 (can't follow external files)
shellcheck \
    --exclude=SC1090,SC1091 \
    --severity=warning \
    oc-bootstrap.sh \
    oc-configure.sh \
    oc-provision.sh

echo ""
echo "✅ All scripts passed ShellCheck!"
