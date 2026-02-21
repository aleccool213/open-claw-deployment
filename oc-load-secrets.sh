#!/usr/bin/env bash
#
# oc-load-secrets.sh — Load OpenClaw secrets from 1Password into environment variables
#
# DESCRIPTION:
#   This optional script fetches secrets from 1Password CLI and exports them as
#   environment variables. It can be run either locally or on the VPS.
#
# USAGE:
#
#   Option 1: Run locally, then copy to VPS
#     # On your local machine:
#     source ./oc-load-secrets.sh
#     
#     # Create .env file and copy to VPS:
#     cat > .env << EOF
#     OPENCODE_API_KEY=$OPENCODE_API_KEY
#     TELEGRAM_BOT_TOKEN=$TELEGRAM_BOT_TOKEN
#     OP_SERVICE_ACCOUNT_TOKEN=$OP_SERVICE_ACCOUNT_TOKEN
#     TAILSCALE_AUTH_KEY=$TAILSCALE_AUTH_KEY
#     GITHUB_TOKEN=${GITHUB_TOKEN:-}
#     NOTION_API_KEY=${NOTION_API_KEY:-}
#     TODOIST_API_KEY=${TODOIST_API_KEY:-}
#     EMAIL_APP_PASSWORD=${EMAIL_APP_PASSWORD:-}
#     EOF
#     scp .env deploy@<VPS_IP>:~/.openclaw/.env
#
#   Option 2: Run directly on VPS (RECOMMENDED)
#     # After bootstrap, copy script to VPS:
#     scp oc-load-secrets.sh deploy@<VPS_IP>:~/
#     
#     # SSH to VPS and run:
#     ssh deploy@<VPS_IP>
#     source ~/oc-load-secrets.sh
#
# PREREQUISITES:
#   - 1Password CLI (op) installed and configured
#   - A 1Password vault (e.g., "OpenClaw") containing the required items
#   - Service account token or authenticated session
#
# REQUIRED 1PASSWORD ITEMS (case-insensitive):
#   - "opencode zen api key" — field: credential
#   - "telegram bot token" — field: credential
#   - "1password service account" — field: credential
#   - "tailscale auth key" — field: credential
#
# OPTIONAL 1PASSWORD ITEMS:
#   - "github pat" — field: credential
#   - "notion api key" — field: credential
#   - "todoist api token" — field: credential
#   - "google service account" — field: app password (used by Himalaya at runtime)
#
# ENVIRONMENT VARIABLES EXPORTED:
#   - OPENCODE_API_KEY
#   - TELEGRAM_BOT_TOKEN
#   - OP_SERVICE_ACCOUNT_TOKEN
#   - TAILSCALE_AUTH_KEY
#   - GITHUB_TOKEN (optional)
#   - NOTION_API_KEY (optional)
#   - TODOIST_API_KEY (optional)
#   - EMAIL_APP_PASSWORD (optional)
#
# TROUBLESHOOTING:
#   - If items aren't found, check that your 1Password item names match exactly
#     (the script tries lowercase variations automatically)
#   - Use --reveal flag for concealed fields (app passwords, tokens)
#   - Ensure your service account has access to the vault

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

# Check if script is being sourced (compatible with bash and zsh)
check_sourced() {
    # In bash, check if BASH_SOURCE[0] equals $0
    if [[ -n "${BASH_SOURCE:-}" ]]; then
        if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
            return 1  # Not sourced
        fi
    fi
    
    # In zsh, check if ZSH_EVAL_CONTEXT contains 'file' (indicates sourced)
    if [[ -n "${ZSH_VERSION:-}" ]]; then
        if [[ "${ZSH_EVAL_CONTEXT}" == *":file:"* ]]; then
            return 0  # Sourced
        fi
        if [[ "${0}" == "${ZSH_ARGZERO:-}" ]]; then
            return 1  # Not sourced
        fi
    fi
    
    # Default: assume sourced if we can't determine
    return 0
}

# ================================================================
# Preflight Checks
# ================================================================

step "Checking prerequisites"

# Check if sourced
if ! check_sourced; then
    fail "This script must be sourced, not executed directly."
    echo "  Usage:"
    echo "    Bash: source ./oc-load-secrets.sh"
    echo "    Zsh:  . ./oc-load-secrets.sh"
    exit 1
fi

# Check if op CLI is installed
if ! command -v op &> /dev/null; then
    fail "1Password CLI (op) not found. Install it first:"
    echo "  https://developer.1password.com/docs/cli/get-started/"
    echo ""
    echo "  Quick install (macOS):"
    echo "    brew install --cask 1password-cli"
    return 1
fi

ok "1Password CLI found: $(op --version)"

# Check if authenticated
if ! op vault list &> /dev/null; then
    fail "Not authenticated with 1Password."
    echo "  Options:"
    echo "    1. Sign in interactively: op signin"
    echo "    2. Use service account: export OP_SERVICE_ACCOUNT_TOKEN=ops_..."
    echo ""
    echo "  To create a service account:"
    echo "    1. Go to https://1password.com → Developer → Service Accounts"
    echo "    2. Create service account with access to '$OP_VAULT' vault"
    return 1
fi

ok "Authenticated with 1Password"

# Check if vault exists
if ! op vault get "$OP_VAULT" &> /dev/null; then
    fail "Vault '$OP_VAULT' not found."
    echo "  Available vaults:"
    op vault list --format=json 2>/dev/null | jq -r '.[].name' 2>/dev/null | sed 's/^/    - /' || echo "    (Unable to list vaults)"
    echo ""
    echo "  Set a different vault: export OP_VAULT='YourVaultName'"
    return 1
fi

ok "Using vault: $OP_VAULT"

# ================================================================
# Fetch Secrets from 1Password
# ================================================================

step "Fetching secrets from 1Password vault '$OP_VAULT'"

# Function to fetch a secret with fallback to lowercase
fetch_secret() {
    local item_name="$1"
    local field_name="${2:-credential}"
    local env_var="$3"
    local optional="${4:-false}"
    local value=""
    
    # Try exact case first, then lowercase
    local item_names=("$item_name" "${item_name,,}")
    local found=false
    
    for try_name in "${item_names[@]}"; do
        if op item get "$try_name" --vault "$OP_VAULT" &> /dev/null; then
            item_name="$try_name"
            found=true
            break
        fi
    done
    
    if [[ "$found" == "false" ]]; then
        if [[ "$optional" == "true" ]]; then
            warn "Item '${item_names[0]}' not found in vault (optional)"
            return 0
        else
            fail "Item '${item_names[0]}' not found in vault '$OP_VAULT'"
            echo "  Create this item in 1Password with:"
            echo "    Title: ${item_names[0]}"
            echo "    Field: $field_name"
            return 1
        fi
    fi
    
    # Fetch the field value with --reveal for concealed fields
    value=$(op item get "$item_name" --vault "$OP_VAULT" --fields "$field_name" --reveal 2>/dev/null || true)
    
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
            echo "  Ensure the item has a field named exactly: $field_name"
            return 1
        fi
    fi
}

# Fetch required secrets
fetch_secret "opencode zen api key" "credential" "OPENCODE_API_KEY" || return 1
fetch_secret "telegram bot token" "credential" "TELEGRAM_BOT_TOKEN" || return 1
fetch_secret "1password service account" "credential" "OP_SERVICE_ACCOUNT_TOKEN" || return 1
fetch_secret "tailscale auth key" "credential" "TAILSCALE_AUTH_KEY" || return 1

# Fetch optional secrets
fetch_secret "github pat" "credential" "GITHUB_TOKEN" "true"
fetch_secret "notion api key" "credential" "NOTION_API_KEY" "true"
fetch_secret "todoist api token" "credential" "TODOIST_API_KEY" "true"
fetch_secret "google service account" "app password" "EMAIL_APP_PASSWORD" "true"

# ================================================================
# Validation
# ================================================================

step "Validating secrets"

# Validate OpenCode Zen key
if [[ -n "${OPENCODE_API_KEY:-}" ]]; then
    MODELS_COUNT=$(curl -sf https://opencode.ai/zen/v1/models \
        -H "Authorization: Bearer ${OPENCODE_API_KEY}" 2>/dev/null \
        | jq '.data | length' 2>/dev/null || echo "0")
    if [[ "$MODELS_COUNT" -gt 0 ]]; then
        ok "OpenCode Zen API key valid — ${MODELS_COUNT} models available"
    else
        warn "OpenCode Zen API key may be invalid or network error"
    fi
fi

# Validate Telegram token
if [[ -n "${TELEGRAM_BOT_TOKEN:-}" ]]; then
    BOT_NAME=$(curl -sf "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getMe" \
        | jq -r '.result.username // empty' 2>/dev/null || true)
    if [[ -n "$BOT_NAME" ]]; then
        ok "Telegram bot verified: @${BOT_NAME}"
    else
        warn "Telegram token may be invalid"
    fi
fi

# ================================================================
# Summary
# ================================================================

step "Summary"

echo "Environment variables exported:"
echo "  ✓ OPENCODE_API_KEY=${OPENCODE_API_KEY:0:12}..."
echo "  ✓ TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN:0:12}..."
echo "  ✓ OP_SERVICE_ACCOUNT_TOKEN=${OP_SERVICE_ACCOUNT_TOKEN:0:12}..."
echo "  ✓ TAILSCALE_AUTH_KEY=${TAILSCALE_AUTH_KEY:0:12}..."

if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    echo "  ✓ GITHUB_TOKEN=${GITHUB_TOKEN:0:12}..."
else
    echo "  − GITHUB_TOKEN (not set, optional for GitHub integration)"
fi

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

if [[ -n "${EMAIL_APP_PASSWORD:-}" ]]; then
    echo "  ✓ EMAIL_APP_PASSWORD=${EMAIL_APP_PASSWORD:0:12}..."
else
    echo "  − EMAIL_APP_PASSWORD (not set, will prompt during configure)"
fi

echo ""
ok "All secrets loaded successfully!"
echo ""
echo "Next steps:"
echo "  1. Copy the secrets to your VPS:"
echo "     scp .env deploy@<VPS_IP>:~/.openclaw/.env"
echo "  2. SSH to your VPS: ssh deploy@<VPS_IP>"
echo "  3. Run: ./oc-configure.sh"
echo ""
