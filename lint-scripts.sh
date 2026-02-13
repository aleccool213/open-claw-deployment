#!/usr/bin/env bash
# lint-scripts.sh - Run all linting and integration checks on bash scripts

set -euo pipefail

cd "$(dirname "$0")"

SCRIPTS=(oc-provision.sh oc-bootstrap.sh oc-configure.sh oc-load-secrets.sh)
ALL_SCRIPTS=("${SCRIPTS[@]}" lint-scripts.sh)
ERRORS=0

fail_check() {
    echo "  ❌ $1"
    ERRORS=$((ERRORS + 1))
}

pass_check() {
    echo "  ✅ $1"
}

# ── 1. ShellCheck ────────────────────────────────────────────────────────────

echo ""
echo "▸ ShellCheck"
if ! command -v shellcheck &>/dev/null; then
    echo "  ⚠ shellcheck not installed, skipping"
    echo "  Install with: brew install shellcheck (macOS) or apt install shellcheck (Linux)"
else
    if shellcheck --exclude=SC1090,SC1091 --severity=warning "${ALL_SCRIPTS[@]}"; then
        pass_check "All scripts passed ShellCheck"
    else
        fail_check "ShellCheck found issues"
    fi
fi

# ── 2. Syntax check (bash -n) ───────────────────────────────────────────────

echo ""
echo "▸ Syntax check"
for script in "${ALL_SCRIPTS[@]}"; do
    if bash -n "$script"; then
        pass_check "$script"
    else
        fail_check "$script has syntax errors"
    fi
done

# ── 3. Executable permissions ────────────────────────────────────────────────

echo ""
echo "▸ Executable permissions"
for script in "${ALL_SCRIPTS[@]}"; do
    if [[ -x "$script" ]]; then
        pass_check "$script"
    else
        fail_check "$script is not executable"
    fi
done

# ── 4. Shebang line ─────────────────────────────────────────────────────────

echo ""
echo "▸ Shebang line"
for script in "${ALL_SCRIPTS[@]}"; do
    if head -1 "$script" | grep -q "^#!/usr/bin/env bash"; then
        pass_check "$script"
    else
        fail_check "$script missing #!/usr/bin/env bash"
    fi
done

# ── 5. set -euo pipefail ────────────────────────────────────────────────────

echo ""
echo "▸ Strict mode (set -euo pipefail)"
for script in "${ALL_SCRIPTS[@]}"; do
    if grep -q "set -euo pipefail" "$script"; then
        pass_check "$script"
    else
        fail_check "$script missing 'set -euo pipefail'"
    fi
done

# ── 6. Hardcoded secrets ────────────────────────────────────────────────────

echo ""
echo "▸ Hardcoded secrets"
matches=$(grep -r "password.*=" oc-*.sh | grep -v "read.*password\|PASSWORD.*read\|example\|# " || true)
if [[ -n "$matches" ]]; then
    fail_check "Possible hardcoded password detected:"
    echo "$matches"
else
    pass_check "No hardcoded passwords found"
fi

# ── 7. TODO/FIXME markers ───────────────────────────────────────────────────

echo ""
echo "▸ TODO/FIXME markers"
if grep -rPn '\bTODO\b|\bFIXME\b|\bXXX\b' oc-*.sh | grep -v "# TODO:\|# FIXME:\|Check for TODO"; then
    fail_check "Found TODO/FIXME markers (see above)"
else
    pass_check "No stray TODO/FIXME markers"
fi

# ── 8. Bats tests ───────────────────────────────────────────────────────────

echo ""
echo "▸ Bats tests"
if ! command -v bats &>/dev/null; then
    echo "  ⚠ bats not installed, skipping"
    echo "  Install with: brew install bats-core (macOS) or see https://github.com/bats-core/bats-core"
else
    if bats tests/*.bats; then
        pass_check "All bats tests passed"
    else
        fail_check "Bats tests failed"
    fi
fi

# ── Summary ──────────────────────────────────────────────────────────────────

echo ""
if [[ $ERRORS -gt 0 ]]; then
    echo "💥 $ERRORS check(s) failed"
    exit 1
else
    echo "✅ All checks passed"
fi
