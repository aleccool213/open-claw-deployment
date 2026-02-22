#!/usr/bin/env bash
# oc-update.sh — Safely update OpenClaw to the latest version
# Preserves Telegram pairing state. Run as deploy user.
# Usage: ssh deploy@<VPS_IP> 'bash -s' < oc-update.sh
#    or: Place on server and run: bash oc-update.sh
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; DIM='\033[2m'; NC='\033[0m'

step()  { echo -e "\n${CYAN}━━━ $1 ━━━${NC}"; }
ok()    { echo -e "  ${GREEN}✅ $1${NC}"; }
warn()  { echo -e "  ${YELLOW}⚠️  $1${NC}"; }
fail()  { echo -e "  ${RED}❌ $1${NC}"; exit 1; }
info()  { echo -e "  ${DIM}$1${NC}"; }

# ── Preflight ────────────────────────────────────────────────────────────────

if [[ "$(id -un)" == "root" ]]; then
  fail "Run this as the deploy user, not root."
fi

OPENCLAW_DATA="$HOME/.openclaw"
ENV_FILE="${OPENCLAW_DATA}/.env"

if [[ ! -f "$ENV_FILE" ]]; then
  fail ".env not found at ${ENV_FILE} — run oc-bootstrap.sh and oc-configure.sh first."
fi

# Source environment (provides XDG_RUNTIME_DIR, DBUS_SESSION_BUS_ADDRESS, etc.)
set -a; source "$ENV_FILE"; set +a
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=/run/user/$(id -u)/bus}"

echo -e "${CYAN}"
echo "  ┌──────────────────────────────────────────────┐"
echo "  │  OpenClaw Self-Update                        │"
echo "  │  Preserves Telegram pairing state            │"
echo "  └──────────────────────────────────────────────┘"
echo -e "${NC}"

# ═════════════════════════════════════════════════════════════════════════════
# STEP 1: CURRENT VERSION
# ═════════════════════════════════════════════════════════════════════════════

step "1/4 — Current state"

CURRENT_VERSION=$(openclaw --version 2>/dev/null || echo "unknown")
info "Installed version: ${CURRENT_VERSION}"

# Verify service is running before we do anything
if systemctl --user is-active --quiet openclaw-gateway.service; then
  ok "Gateway service is currently running"
else
  warn "Gateway service is NOT running before update"
fi

# ═════════════════════════════════════════════════════════════════════════════
# STEP 2: BACKUP STATE
# ═════════════════════════════════════════════════════════════════════════════

step "2/4 — Backing up state"

BACKUP_DIR="/var/backups/openclaw"
TS="$(date +%F-%H%M%S)"
BACKUP_FILE="${BACKUP_DIR}/openclaw-pre-update-${TS}.tar.gz"

if [[ -d "$BACKUP_DIR" ]]; then
  sudo tar -C / -czf "$BACKUP_FILE" home/deploy/.openclaw
  sudo tar -tzf "$BACKUP_FILE" >/dev/null 2>&1
  ok "State backed up to ${BACKUP_FILE}"
else
  warn "Backup directory ${BACKUP_DIR} not found — skipping backup"
  warn "Consider running oc-bootstrap.sh to set up automated backups"
fi

# ═════════════════════════════════════════════════════════════════════════════
# STEP 3: UPDATE
# ═════════════════════════════════════════════════════════════════════════════

step "3/4 — Updating OpenClaw"

# Update to latest version
info "Running: npm install -g openclaw@latest"
sudo npm install -g openclaw@latest

NEW_VERSION=$(openclaw --version 2>/dev/null || echo "unknown")
if [[ "$NEW_VERSION" != "$CURRENT_VERSION" ]]; then
  ok "Updated: ${CURRENT_VERSION} → ${NEW_VERSION}"
else
  ok "Already on latest version (${NEW_VERSION})"
fi

# ═════════════════════════════════════════════════════════════════════════════
# STEP 4: RESTART AND VERIFY
# ═════════════════════════════════════════════════════════════════════════════

step "4/4 — Restarting gateway"

# Ensure dbus session is available (required for keyring access)
if [ ! -S "/run/user/$(id -u)/bus" ]; then
  info "Starting D-Bus session daemon..."
  dbus-daemon --session --address=unix:path=/run/user/"$(id -u)"/bus --fork --nopidfile 2>/dev/null || true
fi

systemctl --user daemon-reload
systemctl --user restart openclaw-gateway.service

info "Waiting for gateway to initialize..."
for i in 1 2 3 4 5; do
  sleep 2
  if curl -sf http://127.0.0.1:18789/ >/dev/null 2>&1; then
    ok "Gateway responding on http://127.0.0.1:18789/"
    break
  fi
  if [[ "$i" -eq 5 ]]; then
    warn "Gateway not responding after restart — checking logs:"
    journalctl --user -u openclaw-gateway.service --no-pager -n 20
    echo ""
    warn "If Telegram pairing is lost, restore from backup:"
    warn "  sudo tar -xzf ${BACKUP_FILE} -C /"
    warn "  systemctl --user restart openclaw-gateway.service"
  fi
done

# ═════════════════════════════════════════════════════════════════════════════
# DONE
# ═════════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  ✅ Update complete! OpenClaw ${NEW_VERSION} is running.${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  Tip: To permanently avoid re-pairing after updates,"
echo "  switch Telegram to allowlist mode. Run oc-configure.sh"
echo "  and enter your Telegram user ID when prompted."
echo "  (Find your ID by messaging @userinfobot in Telegram)"
echo ""
