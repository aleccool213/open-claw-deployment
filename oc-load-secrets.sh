#!/usr/bin/env bash
#
# oc-load-secrets.sh — Load OpenClaw secrets from 1Password into environment variables
#
# DESCRIPTION:
#   This optional script fetches secrets from 1Password CLI and exports them as
#   environment variables, allowing you to run oc-configure.sh non-interactively
#   with pre-populated credentials from your 1Password vault.
#
# USAGE:
#   source ./oc-load-secrets.sh
#   # Then run oc-configure.sh which will use the exported variables
#
# PREREQUISITES:
#   - 1Password CLI (op) installed and configured
#   - A 1Password vault (e.g., "OpenClaw") containing the required items
#   - Service account token or authenticated session
#
# REQUIRED 1PASSWORD ITEMS:
#   - "OpenCode Zen API Key" — field: credential
#   - "Telegram Bot Token" — field: credential
#   - "1Password Service Account" — field: credential
#   - "Tailscale Auth Key" — field: credential
#
# OPTIONAL 1PASSWORD ITEMS:
#   - "Notion API Key" — field: credential
#   - "Todoist API Token" — field: credential
#   - "Email App Password" — field: password (used by Himalaya at runtime)
#
# ENVIRONMENT VARIABLES EXPORTED:
#   - OPENCODE_ZEN_API_KEY
#   - TELEGRAM_BOT_TOKEN
#   - OP_SERVICE_ACCOUNT_TOKEN
#   - NOTION_API_KEY (optional)
#   - TODOIST_API_KEY (optional)
#   - TAILSCALE_AUTH_KEY (optional)
#

set -euo pipefail

# ================================================================
# Configuration
# ================================================================

# Default vault name (can be overridden with OP_VAULT env var)
OP_VAULT="${OP_VAULT:-OpenClaw}"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# ================================================================
# Helper Functions
# ================================================================

ok() {
    echo -e "${GREEN}✓${NC} $*"
}

warn() {
    echo -e "${YELLOW}⚠${NC} $*" >&2
}

fail() {
    echo -e "${RED}✗${NC} $*" >&2
    return 1
}

step() {
    echo -e "\n${CYAN}▶${NC} $*"
}

# ================================================================
# Preflight Checks
# ================================================================

step "Checking prerequisites"

# Check if running with source
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    fail "This script must be sourced, not executed directly."
    echo "  Usage: source ./oc-load-secrets.sh"
    exit 1
fi

# Check if op CLI is installed
if ! command -v op &> /dev/null; then
    fail "1Password CLI (op) not found. Install it first:"
    echo "  https://developer.1password.com/docs/cli/get-started/"
    return 1
fi

ok "1Password CLI found: $(op --version)"

# Check if authenticated
if ! op vault list &> /dev/null; then
    fail "Not authenticated with 1Password."
    echo "  Options:"
    echo "    1. Sign in interactively: op signin"
    echo "    2. Use service account: export OP_SERVICE_ACCOUNT_TOKEN=ops_..."
    return 1
fi

ok "Authenticated with 1Password"

# Check if vault exists
if ! op vault get "$OP_VAULT" &> /dev/null; then
    fail "Vault '$OP_VAULT' not found."
    echo "  Available vaults:"
    op vault list --format=json | jq -r '.[].name' | sed 's/^/    - /'
    echo ""
    echo "  Set a different vault: export OP_VAULT='YourVaultName'"
    return 1
fi

ok "Using vault: $OP_VAULT"

# ================================================================
# Fetch Secrets from 1Password
# ================================================================

step "Fetching secrets from 1Password vault '$OP_VAULT'"

# Function to fetch a secret
fetch_secret() {
    local item_name="$1"
    local field_name="${2:-credential}"
    local env_var="$3"
    local optional="${4:-false}"

    if op item get "$item_name" --vault "$OP_VAULT" &> /dev/null; then
        local value
        value=$(op item get "$item_name" --vault "$OP_VAULT" --fields "$field_name" 2>/dev/null)

        if [[ -n "$value" ]]; then
            export "$env_var=$value"
            ok "Loaded $env_var from '$item_name'"
            return 0
        else
            if [[ "$optional" == "true" ]]; then
                warn "Field '$field_name' not found in '$item_name' (optional)"
                return 0
            else
                fail "Field '$field_name' not found in '$item_name'"
                return 1
            fi
        fi
    else
        if [[ "$optional" == "true" ]]; then
            warn "Item '$item_name' not found in vault (optional)"
            return 0
        else
            fail "Item '$item_name' not found in vault '$OP_VAULT'"
            echo "  Create this item in 1Password with the required field: $field_name"
            return 1
        fi
    fi
}

# Fetch required secrets
fetch_secret "OpenCode Zen API Key" "credential" "OPENCODE_ZEN_API_KEY" || return 1
fetch_secret "Telegram Bot Token" "credential" "TELEGRAM_BOT_TOKEN" || return 1
fetch_secret "1Password Service Account" "credential" "OP_SERVICE_ACCOUNT_TOKEN" || return 1
fetch_secret "Tailscale Auth Key" "credential" "TAILSCALE_AUTH_KEY" || return 1

# Fetch optional secrets
fetch_secret "Notion API Key" "credential" "NOTION_API_KEY" "true"
fetch_secret "Todoist API Token" "credential" "TODOIST_API_KEY" "true"

# ================================================================
# Summary
# ================================================================

step "Summary"

echo "Environment variables exported:"
echo "  ✓ OPENCODE_ZEN_API_KEY=${OPENCODE_ZEN_API_KEY:0:12}..."
echo "  ✓ TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN:0:12}..."
echo "  ✓ OP_SERVICE_ACCOUNT_TOKEN=${OP_SERVICE_ACCOUNT_TOKEN:0:12}..."
echo "  ✓ TAILSCALE_AUTH_KEY=${TAILSCALE_AUTH_KEY:0:12}..."

if [[ -n "${NOTION_API_KEY:-}" ]]; then
    echo "  ✓ NOTION_API_KEY=${NOTION_API_KEY:0:12}..."
else
    echo "  − NOTION_API_KEY (not set, will prompt during configure)"
fi

if [[ -n "${TODOIST_API_KEY:-}" ]]; then
    echo "  ✓ TODOIST_API_KEY=${TODOIST_API_KEY:0:12}..."
else
    echo "  − TODOIST_API_KEY (not set, will prompt during configure)"
fi

echo ""
ok "All secrets loaded successfully!"
echo ""
echo "Next steps:"
echo "  1. Run: ./oc-configure.sh"
echo "  2. The configure script will use the exported environment variables"
echo "  3. You'll skip manual secret entry for the loaded credentials"
echo ""
echo "Note: Email App Password is fetched at runtime by Himalaya from:"
echo "      1Password item 'Email App Password' in vault '$OP_VAULT'"
