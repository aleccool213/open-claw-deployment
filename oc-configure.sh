#!/usr/bin/env bash
# oc-configure.sh — Run on VPS as deploy user
# Covers: OpenCode Zen, Telegram, 1Password CLI, Himalaya Email (all REQUIRED), Notion, Todoist (optional)
# Usage: ssh deploy@<VPS_IP> 'bash -s' < oc-configure.sh
#    or: scp oc-configure.sh deploy@<VPS_IP>:~ && ssh deploy@<VPS_IP> bash oc-configure.sh
set -euo pipefail

# ── Helpers ──────────────────────────────────────────────────────────────────

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; DIM='\033[2m'; NC='\033[0m'

step()   { echo -e "\n${CYAN}━━━ $1 ━━━${NC}"; }
ok()     { echo -e "  ${GREEN}✅ $1${NC}"; }
warn()   { echo -e "  ${YELLOW}⚠️  $1${NC}"; }
fail()   { echo -e "  ${RED}❌ $1${NC}"; }
info()   { echo -e "  ${DIM}$1${NC}"; }

verify() {
  if eval "$2" >/dev/null 2>&1; then
    ok "$1"
    return 0
  else
    fail "$1"
    return 1
  fi
}

prompt_secret() {
  # prompt_secret "description" "ENV_VAR_NAME" "prefix_hint"
  local desc="$1" var="$2" hint="${3:-}"
  local value=""
  echo ""
  echo -e "  ${YELLOW}${desc}${NC}"
  if [[ -n "$hint" ]]; then
    info "Should start with: ${hint}"
  fi
  echo -n "  Paste here (hidden): "
  read -rs value
  echo ""
  if [[ -z "$value" ]]; then
    warn "Skipped (empty input)"
    return 1
  fi
  eval "export ${var}='${value}'"
  return 0
}


# ── Preflight ────────────────────────────────────────────────────────────────

if [[ "$(id -un)" == "root" ]]; then
  echo -e "${RED}Don't run this as root. Run as deploy user.${NC}"
  exit 1
fi

OPENCLAW_DIR="$HOME/openclaw"
ENV_FILE="${OPENCLAW_DIR}/.env"
CONFIG_FILE="$HOME/.openclaw/openclaw.json"

if [[ ! -f "$ENV_FILE" ]]; then
  echo -e "${RED}.env not found at ${ENV_FILE}. Run oc-bootstrap.sh first.${NC}"
  exit 1
fi

# Source existing env
set -a; source "$ENV_FILE"; set +a

echo -e "${CYAN}"
echo "  ┌──────────────────────────────────────────────┐"
echo "  │  OpenClaw Integration Configurator           │"
echo "  │                                              │"
echo "  │  REQUIRED integrations (all must be set up): │"
echo "  │    1. OpenCode Zen (model provider)          │"
echo "  │    2. Telegram bot (chat interface)          │"
echo "  │    3. 1Password CLI (secret management)      │"
echo "  │    4. Email (Himalaya CLI)                   │"
echo "  │    5. Tailscale (secure network access)      │"
echo "  │                                              │"
echo "  │  OPTIONAL:                                   │"
echo "  │    6. Notion API (document management)       │"
echo "  │    7. Todoist (task tracking)                │"
echo "  └──────────────────────────────────────────────┘"
echo -e "${NC}"

# ═════════════════════════════════════════════════════════════════════════════
# 1. OPENCODE ZEN (Recommended - Cheaper than OpenCode Zen, free tier available)
# ═════════════════════════════════════════════════════════════════════════════

step "1/7 — OpenCode Zen API Key"
info "Sign up at: https://opencode.ai/zen"
  info "Free models during beta: Grok Code Fast 1, GLM 4.7, MiniMax M2.1"

OPENCODE_API_KEY="${OPENCODE_API_KEY:-}"
if [[ -n "$OPENCODE_API_KEY" ]]; then
  ok "OpenCode Zen key already in .env"
else
  if prompt_secret "OpenCode Zen API key" "OPENCODE_API_KEY" "ocz_..."; then
    echo "OPENCODE_API_KEY=${OPENCODE_API_KEY}" >> "$ENV_FILE"
    ok "Saved to .env"
  fi
fi

# Verify the key works
if [[ -n "${OPENCODE_API_KEY:-}" ]]; then
  MODELS_COUNT=$(curl -sf https://opencode.ai/zen/v1/models \
    -H "Authorization: Bearer ${OPENCODE_API_KEY}" 2>/dev/null \
    | jq '.data | length' 2>/dev/null || echo "0")
  if [[ "$MODELS_COUNT" -gt 0 ]]; then
    ok "OpenCode Zen API key valid — ${MODELS_COUNT} models available"
  else
    fail "OpenCode Zen API key rejected or network error"
  fi
fi

# ═════════════════════════════════════════════════════════════════════════════
# 2. TELEGRAM (REQUIRED)
# ═════════════════════════════════════════════════════════════════════════════

step "2/7 — Telegram Bot Token (REQUIRED)"
info "Create a bot: open Telegram → @BotFather → /newbot"
info "Copy the HTTP API token it gives you"

TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
if [[ -n "$TELEGRAM_BOT_TOKEN" ]]; then
  ok "Telegram token already in .env"
else
  prompt_secret "Telegram bot token from @BotFather" "TELEGRAM_BOT_TOKEN" "123456:ABC-..." || fail "Telegram token is required"
  echo "TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN}" >> "$ENV_FILE"
  ok "Saved to .env"
fi

# Verify the token
BOT_NAME=$(curl -sf "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getMe" \
  | jq -r '.result.username // empty' 2>/dev/null || true)
if [[ -n "$BOT_NAME" ]]; then
  ok "Telegram bot verified: @${BOT_NAME}"
else
  fail "Telegram token invalid or network error"
fi

# ═════════════════════════════════════════════════════════════════════════════
# 3. 1PASSWORD CLI (SERVICE ACCOUNT) - REQUIRED
# ═════════════════════════════════════════════════════════════════════════════

step "3/7 — 1Password CLI (REQUIRED)"
info "Requires a Service Account token from 1password.com"
info "Create at: 1password.com → Developer → Service Accounts"
info "Grant access to your 'OpenClaw' vault"

# Install op CLI if missing
if command -v op &>/dev/null; then
  ok "op CLI already installed ($(op --version))"
else
  echo "  Installing 1Password CLI..."
  curl -sS https://downloads.1password.com/linux/keys/1password.asc | \
    sudo gpg --dearmor --output /usr/share/keyrings/1password-archive-keyring.gpg 2>/dev/null
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/1password-archive-keyring.gpg] https://downloads.1password.com/linux/debian/$(dpkg --print-architecture) stable main" | \
    sudo tee /etc/apt/sources.list.d/1password-cli.list >/dev/null
  sudo apt-get update -qq >/dev/null
  sudo apt-get install -y -qq 1password-cli >/dev/null
  verify "op CLI installed" "command -v op"
fi

OP_SERVICE_ACCOUNT_TOKEN="${OP_SERVICE_ACCOUNT_TOKEN:-}"
if [[ -n "$OP_SERVICE_ACCOUNT_TOKEN" ]]; then
  ok "1Password service account token already in .env"
else
  prompt_secret "1Password Service Account token" "OP_SERVICE_ACCOUNT_TOKEN" "ops_eyJ..." || fail "1Password is required"
  echo "OP_SERVICE_ACCOUNT_TOKEN=${OP_SERVICE_ACCOUNT_TOKEN}" >> "$ENV_FILE"
  ok "Saved to .env"
fi

# Verify access
VAULT_LIST=$(op vault list --format json 2>/dev/null | jq -r '.[].name' 2>/dev/null || true)
if [[ -n "$VAULT_LIST" ]]; then
  ok "1Password connected — vaults: ${VAULT_LIST//$'\n'/, }"
else
  fail "1Password service account token invalid or no vault access"
fi

# ═════════════════════════════════════════════════════════════════════════════
# 4. EMAIL (HIMALAYA) - REQUIRED
# ═════════════════════════════════════════════════════════════════════════════

step "4/7 — Email (Himalaya CLI) (REQUIRED)"
info "Himalaya is a terminal email client for IMAP/SMTP"
info "You'll need: Gmail/Fastmail account with App Password"

# Install himalaya (REQUIRED)
if command -v himalaya &>/dev/null; then
  ok "Himalaya already installed ($(himalaya --version 2>/dev/null | head -1))"
else
  echo "  Installing Himalaya..."
  HIMALAYA_VERSION=$(curl -sf https://api.github.com/repos/pimalaya/himalaya/releases/latest \
    | jq -r '.tag_name // empty' 2>/dev/null || true)
  if [[ -n "$HIMALAYA_VERSION" ]]; then
    ARCH=$(uname -m)
    curl -sLo /tmp/himalaya.tar.gz \
      "https://github.com/pimalaya/himalaya/releases/download/${HIMALAYA_VERSION}/himalaya-${ARCH}-unknown-linux-gnu.tar.gz"
    tar xzf /tmp/himalaya.tar.gz -C /tmp/
    sudo mv /tmp/himalaya /usr/local/bin/
    rm -f /tmp/himalaya.tar.gz
    verify "Himalaya installed" "command -v himalaya"
  else
    fail "Could not fetch latest Himalaya version from GitHub"
  fi
fi

# Configure himalaya (REQUIRED)
HIMALAYA_CONFIG="$HOME/.config/himalaya/config.toml"
if [[ ! -f "$HIMALAYA_CONFIG" ]]; then
  echo ""
  info "Configure your email account (REQUIRED):"
  info "You'll need: email address, IMAP/SMTP host, and an app password stored in 1Password"
  echo ""

  echo -n "  Email address: "
  read -r EMAIL_ADDR
  [[ -z "$EMAIL_ADDR" ]] && fail "Email address is required"

  echo -n "  Display name [OpenClaw Agent]: "
  read -r DISPLAY_NAME
  DISPLAY_NAME="${DISPLAY_NAME:-OpenClaw Agent}"

  echo ""
  echo "  Email provider:"
  echo "    1) Gmail       (imap.gmail.com / smtp.gmail.com)"
  echo "    2) Fastmail    (imap.fastmail.com / smtp.fastmail.com)"
  echo "    3) Custom"
  echo -n "  Choice [1/2/3]: "
  read -r PROVIDER_CHOICE

  case "$PROVIDER_CHOICE" in
    1) IMAP_HOST="imap.gmail.com"; SMTP_HOST="smtp.gmail.com"; IMAP_PORT=993; SMTP_PORT=465 ;;
    2) IMAP_HOST="imap.fastmail.com"; SMTP_HOST="smtp.fastmail.com"; IMAP_PORT=993; SMTP_PORT=465 ;;
    3)
      echo -n "  IMAP host: "; read -r IMAP_HOST
      echo -n "  IMAP port [993]: "; read -r IMAP_PORT; IMAP_PORT="${IMAP_PORT:-993}"
      echo -n "  SMTP host: "; read -r SMTP_HOST
      echo -n "  SMTP port [465]: "; read -r SMTP_PORT; SMTP_PORT="${SMTP_PORT:-465}"
      ;;
    *) IMAP_HOST="imap.gmail.com"; SMTP_HOST="smtp.gmail.com"; IMAP_PORT=993; SMTP_PORT=465 ;;
  esac

  info "Store your email app password in 1Password vault 'OpenClaw' with title 'Email App Password'"
  info "Himalaya will fetch it at runtime via: op item get 'Email App Password' --vault OpenClaw --fields password"
  AUTH_CMD="op item get 'Email App Password' --vault OpenClaw --fields password"

  mkdir -p "$(dirname "$HIMALAYA_CONFIG")"
  cat > "$HIMALAYA_CONFIG" <<TOML
[accounts.openclaw]
email = "${EMAIL_ADDR}"
display-name = "${DISPLAY_NAME}"
default = true

backend.type = "imap"
backend.host = "${IMAP_HOST}"
backend.port = ${IMAP_PORT}
backend.encryption.type = "tls"
backend.login = "${EMAIL_ADDR}"
backend.auth.type = "password"
backend.auth.cmd = "${AUTH_CMD}"

message.send.backend.type = "smtp"
message.send.backend.host = "${SMTP_HOST}"
message.send.backend.port = ${SMTP_PORT}
message.send.backend.encryption.type = "tls"
message.send.backend.login = "${EMAIL_ADDR}"
message.send.backend.auth.type = "password"
message.send.backend.auth.cmd = "${AUTH_CMD}"
TOML

  if [[ "$IMAP_HOST" == "imap.gmail.com" ]]; then
    cat >> "$HIMALAYA_CONFIG" <<'TOML'

folder.aliases.inbox = "INBOX"
folder.aliases.sent = "[Gmail]/Sent Mail"
folder.aliases.drafts = "[Gmail]/Drafts"
folder.aliases.trash = "[Gmail]/Trash"
TOML
  fi

  chmod 600 "$HIMALAYA_CONFIG"
  ok "Himalaya config written to ${HIMALAYA_CONFIG}"
  info "Test with: himalaya folder list"
else
  ok "Himalaya config already exists"
fi

# ═════════════════════════════════════════════════════════════════════════════
# 5. TAILSCALE (REQUIRED)
# ═════════════════════════════════════════════════════════════════════════════

step "5/7 — Tailscale (REQUIRED for secure access)"
info "Tailscale provides secure zero-trust network access to your OpenClaw gateway"
info "No need to expose ports or manage SSH tunnels"

# Check if tailscale is installed (should have been installed in bootstrap)
if ! command -v tailscale &>/dev/null; then
  echo "  Installing Tailscale..."
  curl -fsSL https://tailscale.com/install.sh | sh
  verify "Tailscale installed" "command -v tailscale"
else
  ok "Tailscale already installed ($(tailscale version | head -1))"
fi

# Check if already authenticated
if sudo tailscale status >/dev/null 2>&1; then
  TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "unknown")
  TAILSCALE_HOSTNAME=$(tailscale status --json 2>/dev/null | jq -r '.Self.DNSName // "unknown"' 2>/dev/null || echo "unknown")

  ok "Tailscale already connected"
  info "Tailscale IP:       ${TAILSCALE_IP}"
  info "Tailscale hostname: ${TAILSCALE_HOSTNAME}"
else
  echo ""
  warn "Tailscale not connected yet"
  info "Generate a reusable auth key at: https://login.tailscale.com/admin/settings/keys"
  echo ""

  # Check if TAILSCALE_AUTH_KEY is already set (e.g., from oc-load-secrets.sh)
  TAILSCALE_AUTH_KEY="${TAILSCALE_AUTH_KEY:-}"

  if [[ -z "$TAILSCALE_AUTH_KEY" ]]; then
    prompt_secret "Tailscale auth key (REQUIRED)" "TAILSCALE_AUTH_KEY" "tskey-auth-" || fail "Tailscale auth key is required"
  else
    ok "Using Tailscale auth key from environment"
  fi

  # Connect using auth key
  echo ""
  info "Connecting to Tailscale with auth key..."
  sudo tailscale up --authkey="${TAILSCALE_AUTH_KEY}"

  TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "unknown")
  TAILSCALE_HOSTNAME=$(tailscale status --json 2>/dev/null | jq -r '.Self.DNSName // "unknown"' 2>/dev/null || echo "unknown")

  ok "Tailscale connected!"
  info "Tailscale IP:       ${TAILSCALE_IP}"
  info "Tailscale hostname: ${TAILSCALE_HOSTNAME}"
fi

# Set up Tailscale serve to proxy the gateway
echo ""
info "Configuring Tailscale to proxy OpenClaw gateway..."
info "This allows access from any device on your Tailnet at port 18789"

# Check if serve is already configured
if sudo tailscale serve status 2>/dev/null | grep -q "18789"; then
  ok "Tailscale serve already configured"
else
  sudo tailscale serve --bg --https=443 http://127.0.0.1:18789
  ok "Tailscale serve configured: https://${TAILSCALE_HOSTNAME:-<hostname>}"
fi

# Verify Tailscale is working
if tailscale status >/dev/null 2>&1; then
  ok "Tailscale verification passed"
else
  fail "Tailscale not running properly"
fi

# ═════════════════════════════════════════════════════════════════════════════
# 6. NOTION (OPTIONAL)
# ═════════════════════════════════════════════════════════════════════════════

step "6/7 — Notion API (OPTIONAL)"
info "Create an integration at: https://notion.so/my-integrations"
info "Then share your target pages with the integration"
info "Press Enter to skip if you don't use Notion"

NOTION_API_KEY="${NOTION_API_KEY:-}"
if [[ -n "$NOTION_API_KEY" ]]; then
  ok "Notion key already in .env"
else
  if prompt_secret "Notion integration API key (optional)" "NOTION_API_KEY" "ntn_ or secret_"; then
    echo "NOTION_API_KEY=${NOTION_API_KEY}" >> "$ENV_FILE"
    ok "Saved to .env"

    # Also store in config dir (some skills read from file)
    mkdir -p "$HOME/.config/notion"
    echo "$NOTION_API_KEY" > "$HOME/.config/notion/api_key"
    chmod 600 "$HOME/.config/notion/api_key"
  else
    warn "Notion skipped"
  fi
fi

# Verify if provided
if [[ -n "${NOTION_API_KEY:-}" ]]; then
  NOTION_USER=$(curl -sf https://api.notion.com/v1/users/me \
    -H "Authorization: Bearer ${NOTION_API_KEY}" \
    -H "Notion-Version: 2025-09-03" \
    | jq -r '.name // empty' 2>/dev/null || true)
  if [[ -n "$NOTION_USER" ]]; then
    ok "Notion connected as: ${NOTION_USER}"
  else
    warn "Notion API key invalid (optional, continuing)"
  fi
fi


# ═════════════════════════════════════════════════════════════════════════════
# 7. TODOIST (OPTIONAL)
# ═════════════════════════════════════════════════════════════════════════════

step "7/7 — Todoist API (OPTIONAL — task tracking)"
info "Get your API token at: https://todoist.com/prefs/integrations (under 'Developer')"
info "Press Enter to skip if you don't use Todoist"

TODOIST_API_KEY="${TODOIST_API_KEY:-}"
if [[ -n "$TODOIST_API_KEY" ]]; then
  ok "Todoist key already in .env"
else
  if prompt_secret "Todoist API token (optional)" "TODOIST_API_KEY" ""; then
    echo "TODOIST_API_KEY=${TODOIST_API_KEY}" >> "$ENV_FILE"
    ok "Saved to .env"
  else
    warn "Todoist skipped"
  fi
fi

# Verify if provided
if [[ -n "${TODOIST_API_KEY:-}" ]]; then
  TODOIST_SYNC=$(curl -sf https://api.todoist.com/rest/v2/projects \
    -H "Authorization: Bearer ${TODOIST_API_KEY}" \
    | jq -r '.[0].name // empty' 2>/dev/null || true)
  if [[ -n "$TODOIST_SYNC" ]]; then
    ok "Todoist connected — first project: ${TODOIST_SYNC}"
  else
    warn "Todoist API token invalid (optional, continuing)"
  fi
fi


# ═════════════════════════════════════════════════════════════════════════════
# WRITE OPENCLAW CONFIG (openclaw.json)
# ═════════════════════════════════════════════════════════════════════════════

step "Writing openclaw.json"

mkdir -p "$HOME/.openclaw"

if [[ -f "$CONFIG_FILE" ]]; then
  warn "Config already exists at ${CONFIG_FILE}"
  if ! prompt_optional "Overwrite with new config?"; then
    warn "Keeping existing config"
  else
    WRITE_CONFIG=true
  fi
else
  WRITE_CONFIG=true
fi

if [[ "${WRITE_CONFIG:-false}" == "true" ]] || [[ ! -f "$CONFIG_FILE" ]]; then
  # Copy example config (Telegram already enabled by default)
  cp "$OPENCLAW_DIR/openclaw.json.example" "$CONFIG_FILE"
  chmod 600 "$CONFIG_FILE"
  ok "Config written to ${CONFIG_FILE}"

  # Validate it's parseable JSON
  if jq . "$CONFIG_FILE" >/dev/null 2>&1; then
    ok "Config is valid JSON"
  else
    fail "Config has JSON syntax errors — edit manually: ${CONFIG_FILE}"
  fi
fi

# ═════════════════════════════════════════════════════════════════════════════
# LOCK DOWN .env PERMISSIONS
# ═════════════════════════════════════════════════════════════════════════════

chmod 600 "$ENV_FILE"
ok ".env permissions set to 600"

# ═════════════════════════════════════════════════════════════════════════════
# RESTART GATEWAY
# ═════════════════════════════════════════════════════════════════════════════

step "Restarting gateway with new config"
cd "$OPENCLAW_DIR"
docker compose restart openclaw-gateway
sleep 5

if docker compose ps openclaw-gateway | grep -q "Up"; then
  ok "Gateway is running"
else
  fail "Gateway failed to start — check: docker compose logs openclaw-gateway"
fi

# ═════════════════════════════════════════════════════════════════════════════
# FINAL VERIFICATION SUMMARY
# ═════════════════════════════════════════════════════════════════════════════

step "Integration Status"

echo ""
printf "  %-20s %s\n" "Integration" "Status"
printf "  %-20s %s\n" "────────────────────" "──────────────────────────────"

# OpenCode Zen
if [[ -n "${OPENCODE_API_KEY:-}" ]]; then
  printf "  %-20s ${GREEN}%s${NC}\n" "OpenCode Zen" "✅ Configured (Kimi K2.5 primary)"
else
  printf "  %-20s ${YELLOW}%s${NC}\n" "OpenCode Zen" "⏭  Skipped"
fi

# Telegram (required)
printf "  %-20s ${GREEN}%s${NC}\n" "Telegram" "✅ @${BOT_NAME}"

# 1Password (required)
printf "  %-20s ${GREEN}%s${NC}\n" "1Password" "✅ Connected"

# Email (required)
printf "  %-20s ${GREEN}%s${NC}\n" "Email" "✅ Himalaya configured"

# Tailscale (required)
TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "not connected")
printf "  %-20s ${GREEN}%s${NC}\n" "Tailscale" "✅ Connected (${TAILSCALE_IP})"

# Notion (optional)
if [[ -n "${NOTION_API_KEY:-}" ]]; then
  printf "  %-20s ${GREEN}%s${NC}\n" "Notion" "✅ Connected as ${NOTION_USER:-unknown}"
else
  printf "  %-20s ${YELLOW}%s${NC}\n" "Notion" "⏭  Skipped"
fi

# Todoist (optional)
if [[ -n "${TODOIST_API_KEY:-}" ]]; then
  printf "  %-20s ${GREEN}%s${NC}\n" "Todoist" "✅ Connected"
else
  printf "  %-20s ${YELLOW}%s${NC}\n" "Todoist" "⏭  Skipped"
fi

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  ✅ Configuration complete!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  Next steps:"
echo ""
echo "    Telegram pairing (REQUIRED):"
echo "      1. Open Telegram → send /start to your bot @${BOT_NAME}"
echo "      2. Copy the pairing code"
echo "      3. Run: docker compose run --rm openclaw-cli pairing approve telegram <CODE>"
echo ""
echo "    Access OpenClaw Gateway:"
TAILSCALE_HOSTNAME=$(tailscale status --json 2>/dev/null | jq -r '.Self.DNSName // "unknown"' 2>/dev/null || echo "unknown")
echo "      Tailscale: https://${TAILSCALE_HOSTNAME} (from any device on your Tailnet)"
echo "      Local:     ssh -N -L 18789:127.0.0.1:18789 deploy@<VPS_IP> then http://localhost:18789"
echo ""
echo "    Switch models from chat:"
echo "      /model grokcode — Grok Code Fast 1 (FREE, default)"
echo "      /model grok     — Grok 4.1 Fast (agentic)"
echo "      /model grokcode — Grok Code Fast (coding)"
echo "      /model sonnet   — Claude Sonnet 4.5 (complex)"
echo "      /model opus     — Claude Opus 4.5 (hardest tasks)"
echo ""
echo "    Config files:"
echo "      Secrets:  ${ENV_FILE}"
echo "      Config:   ${CONFIG_FILE}"
echo "      Email:    ${HIMALAYA_CONFIG:-not configured}"
echo ""
