#!/usr/bin/env bash
# run-tests.sh - Consolidated test script for OpenClaw deployment
#
# This script runs ALL tests that are executed in GitHub Actions CI/CD.
# Use this script to run the complete test suite locally before pushing.
#
# Tests included:
#   1. ShellCheck - Static analysis of shell scripts
#   2. Syntax validation - Bash syntax checking
#   3. Executable permissions - Verify scripts can be executed
#   4. Integration checks - Shebangs, error handling, secrets, TODOs
#   5. Bats tests - Full behavioral test suite
#
# Usage: ./run-tests.sh
#
# Exit codes:
#   0 - All tests passed
#   1 - One or more tests failed

set -euo pipefail

# Ensure we're running under bash, not fish or zsh
if [ -z "${BASH_VERSION:-}" ]; then
    echo "Error: This script must be run with bash, not $0" >&2
    echo "Please run: bash $0" >&2
    exit 1
fi

cd "$(dirname "$0")"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

passed=0
failed=0

step() {
    echo -e "\n${YELLOW}━━━ $1 ━━━${NC}"
}

ok() {
    echo -e "  ${GREEN}✅ $1${NC}"
    ((passed++))
}

fail() {
    echo -e "  ${RED}❌ $1${NC}"
    ((failed++))
}

# ── ShellCheck Tests ─────────────────────────────────────────────────────────

step "Running ShellCheck"

if command -v shellcheck &>/dev/null; then
    if shellcheck --exclude=SC1090,SC1091 --severity=warning oc-*.sh lint-scripts.sh 2>&1; then
        ok "ShellCheck passed"
    else
        fail "ShellCheck found issues"
    fi
else
    echo "  Installing shellcheck..."
    if command -v brew &>/dev/null; then
        brew install shellcheck
    elif command -v apt-get &>/dev/null; then
        sudo apt-get update && sudo apt-get install -y shellcheck
    else
        echo "  Please install shellcheck manually"
        exit 1
    fi
    
    if shellcheck --exclude=SC1090,SC1091 --severity=warning oc-*.sh lint-scripts.sh 2>&1; then
        ok "ShellCheck passed"
    else
        fail "ShellCheck found issues"
    fi
fi

# ── Syntax Tests ─────────────────────────────────────────────────────────────

step "Running Syntax Checks"

for script in oc-provision.sh oc-bootstrap.sh oc-configure.sh oc-load-secrets.sh lint-scripts.sh; do
    if bash -n "$script" 2>&1; then
        ok "$script syntax is valid"
    else
        fail "$script has syntax errors"
    fi
done

# ── Permission Tests ─────────────────────────────────────────────────────────

step "Checking Executable Permissions"

for script in oc-provision.sh oc-bootstrap.sh oc-configure.sh oc-load-secrets.sh lint-scripts.sh; do
    if [ -x "$script" ]; then
        ok "$script is executable"
    else
        fail "$script is not executable"
        echo "  Run: chmod +x $script"
    fi
done

# ── Integration Tests ────────────────────────────────────────────────────────

step "Running Integration Checks"

# Check shebangs
for script in oc-provision.sh oc-bootstrap.sh oc-configure.sh oc-load-secrets.sh lint-scripts.sh; do
    if head -1 "$script" | grep -q "^#!/usr/bin/env bash"; then
        ok "$script has correct shebang"
    else
        fail "$script missing proper shebang"
    fi
done

# Check for set -euo pipefail
for script in oc-provision.sh oc-bootstrap.sh oc-configure.sh oc-load-secrets.sh lint-scripts.sh; do
    if grep -q "set -euo pipefail" "$script"; then
        ok "$script has set -euo pipefail"
    else
        fail "$script missing 'set -euo pipefail'"
    fi
done

# Check for hardcoded secrets (basic patterns)
if grep -r "password.*=" oc-*.sh 2>/dev/null | grep -v "read.*password\|PASSWORD.*read\|example\|# " | head -5; then
    fail "Possible hardcoded password detected"
else
    ok "No hardcoded secrets found"
fi

# Check for TODO/FIXME
if grep -rn "\bTODO\b\|\bFIXME\b\|\bXXX\b" oc-*.sh 2>/dev/null | grep -v "# TODO:\|# FIXME:\|Check for TODO"; then
    fail "Found TODO/FIXME markers"
else
    ok "No TODO/FIXME markers found"
fi

# ── Bats Tests ───────────────────────────────────────────────────────────────

step "Running Bats Tests"

if command -v bats &>/dev/null; then
    if bats tests/*.bats; then
        ok "All Bats tests passed"
    else
        fail "Some Bats tests failed"
    fi
else
    echo "  Bats not installed. Install with:"
    echo "    brew install bats-core  (macOS)"
    echo "    npm install -g bats     (with npm)"
    echo ""
    echo "  Skipping Bats tests..."
fi

# ── Summary ──────────────────────────────────────────────────────────────────

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo "  Test Results:"
echo "    Passed: $passed"
echo "    Failed: $failed"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

if [ $failed -eq 0 ]; then
    echo -e "  ${GREEN}✅ All tests passed!${NC}"
    exit 0
else
    echo -e "  ${RED}❌ Some tests failed${NC}"
    exit 1
fi
