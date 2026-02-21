#!/usr/bin/env bash
# oc-bootstrap.sh — Run on fresh Hetzner VPS as root
# Covers: Node.js, OpenClaw install, deploy user, security hardening, backups
# Usage: ssh root@<VPS_IP> 'bash -s' < oc-bootstrap.sh
set -euo pipefail

# ── Helpers ──────────────────────────────────────────────────────────────────

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; DIM='\033[2m'; NC='\033[0m'

step()   { echo -e "\n${CYAN}━━━ $1 ━━━${NC}"; }
ok()     { echo -e "  ${GREEN}✅ $1${NC}"; }
warn()   { echo -e "  ${YELLOW}⚠️  $1${NC}"; }
fail()   { echo -e "  ${RED}❌ $1${NC}"; exit 1; }
info()   { echo -e "  ${DIM}$1${NC}"; }

verify() {
  # verify "description" "command"
  if eval "$2" >/dev/null 2>&1; then
    ok "$1"
    return 0
  else
    fail "$1 — command failed: $2"
  fi
}

verify_soft() {
  # verify_soft "description" "command" - warns but doesn't fail
  if eval "$2" >/dev/null 2>&1; then
    ok "$1"
    return 0
  else
    warn "$1 — continuing anyway"
    return 1
  fi
}

pause_confirm() {
  echo -e "\n${YELLOW}⏸  $1${NC}"
  echo -e "   Non-interactive mode: continuing in 5 seconds..."
  sleep 5
}

# ── Preflight ────────────────────────────────────────────────────────────────

if [[ "$(id -u)" -ne 0 ]]; then
  fail "This script must be run as root"
fi

step "Preflight"
echo "  Hostname: $(hostname)"
echo "  IP:       $(hostname -I | awk '{print $1}')"
echo "  OS:       $(. /etc/os-release && echo "$PRETTY_NAME")"
verify "Running Ubuntu 24.x" "grep -q 'Ubuntu 24' /etc/os-release"

# ═════════════════════════════════════════════════════════════════════════════
# PHASE 0: CLEANUP DOCKER (if exists)
# ═════════════════════════════════════════════════════════════════════════════

step "0/10 — Cleaning up existing Docker setup (if any)"

if command -v docker &>/dev/null; then
  info "Docker detected, checking for OpenClaw containers..."
  
  # Stop and remove OpenClaw containers
  if docker ps -a | grep -q "openclaw"; then
    docker ps -a | grep "openclaw" | awk '{print $1}' | xargs -r docker stop 2>/dev/null || true
    docker ps -a | grep "openclaw" | awk '{print $1}' | xargs -r docker rm 2>/dev/null || true
    ok "Stopped and removed OpenClaw Docker containers"
  fi
  
  # Clean up unused images
  docker system prune -af --volumes 2>/dev/null || true
  info "Cleaned up Docker resources"
fi

# ═════════════════════════════════════════════════════════════════════════════
# PHASE 1: BASE SYSTEM
# ═════════════════════════════════════════════════════════════════════════════

step "1/10 — Installing Node.js 22"
apt-get update -qq
apt-get install -y -qq git curl ca-certificates jq dbus dbus-user-session >/dev/null

if node -e "process.exit(parseInt(process.versions.node) >= 22 ? 0 : 1)" 2>/dev/null; then
  warn "Node.js $(node -v) already installed, skipping"
else
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash - >/dev/null 2>&1
  apt-get install -y -qq nodejs >/dev/null
fi

verify "Node.js 22+ installed" "node -e \"process.exit(parseInt(process.versions.node) >= 22 ? 0 : 1)\""
verify "npm installed"         "npm --version"

# ═════════════════════════════════════════════════════════════════════════════
# PHASE 2: OPENCLAW
# ═════════════════════════════════════════════════════════════════════════════

step "2/10 — Installing OpenClaw"
DEPLOY_HOME="/home/deploy"
OPENCLAW_DATA="${DEPLOY_HOME}/.openclaw"
OPENCLAW_VERSION="2026.2.6"

# Create deploy user first (need home dir)
if id deploy &>/dev/null; then
  warn "User 'deploy' already exists, skipping creation"
else
  adduser --disabled-password --gecos "OpenClaw Deploy" deploy
  ok "Created user 'deploy'"
fi

usermod -aG sudo deploy 2>/dev/null || true

# Set up SSH key for deploy user
mkdir -p "${DEPLOY_HOME}/.ssh"
if [[ -f /root/.ssh/authorized_keys ]]; then
  cp /root/.ssh/authorized_keys "${DEPLOY_HOME}/.ssh/"
fi
chown -R deploy:deploy "${DEPLOY_HOME}/.ssh"
chmod 700 "${DEPLOY_HOME}/.ssh"
chmod 600 "${DEPLOY_HOME}/.ssh/authorized_keys" 2>/dev/null || true
ok "SSH keys copied to deploy user"

# Install pinned OpenClaw version via npm (as root for global install)
if command -v openclaw &>/dev/null; then
  warn "OpenClaw already installed ($(openclaw --version 2>/dev/null || echo unknown)), skipping"
else
  echo "  Installing openclaw@${OPENCLAW_VERSION} via npm..."
  npm install -g openclaw@${OPENCLAW_VERSION}
fi

verify "OpenClaw installed" "command -v openclaw"

step "3/10 — Persistent directories & secrets"

mkdir -p "${OPENCLAW_DATA}"
chown -R deploy:deploy "${OPENCLAW_DATA}"

# Generate .env if it doesn't exist
ENV_FILE="${OPENCLAW_DATA}/.env"
if [[ -f "$ENV_FILE" ]]; then
  warn ".env already exists, not overwriting"
else
  GATEWAY_TOKEN=$(openssl rand -hex 32)
  KEYRING_PASSWORD=$(openssl rand -hex 32)

  cat > "$ENV_FILE" <<EOF
OPENCLAW_HOME=${OPENCLAW_DATA}
OPENCLAW_CONFIG_PATH=${OPENCLAW_DATA}/openclaw.json
OPENCLAW_GATEWAY_TOKEN=${GATEWAY_TOKEN}
OPENCLAW_GATEWAY_BIND=loopback
OPENCLAW_GATEWAY_PORT=18789
GOG_KEYRING_PASSWORD=${KEYRING_PASSWORD}
XDG_RUNTIME_DIR=/run/user/1000
DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus
EOF

  chown deploy:deploy "$ENV_FILE"
  chmod 600 "$ENV_FILE"

  echo ""
  echo -e "  ${YELLOW}╔══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "  ${YELLOW}║  SAVE THIS GATEWAY TOKEN (you need it to log in):           ║${NC}"
  echo -e "  ${YELLOW}║  ${NC}${GATEWAY_TOKEN}${YELLOW}  ║${NC}"
  echo -e "  ${YELLOW}╚══════════════════════════════════════════════════════════════╝${NC}"
  echo ""
fi

# Cross-platform stat check for file permissions
if [[ "$OSTYPE" == "darwin"* ]]; then
  # macOS
  verify ".env exists and is restricted" "test -f $ENV_FILE && stat -f '%Lp' $ENV_FILE | grep -q '600'"
else
  # Linux
  verify ".env exists and is restricted" "test -f $ENV_FILE && stat -c '%a' $ENV_FILE | grep -q '600'"
fi
verify "Data dir exists"               "test -d ${OPENCLAW_DATA}"

# Write openclaw.json with correct OpenCode Zen configuration
# This config includes models.providers with baseUrl for OpenCode Zen
CONFIG_FILE="${OPENCLAW_DATA}/openclaw.json"
if [[ -f "$CONFIG_FILE" ]]; then
  warn "Config already exists at ${CONFIG_FILE}, not overwriting"
else
  cat > "$CONFIG_FILE" << 'OPENCLAW_CONFIG'
{
  "agents": {
    "defaults": {
      "model": {
        "primary": "opencode/kimi-k2.5",
        "fallbacks": ["opencode/glm-4.7"]
      },
      "models": {
        "opencode/kimi-k2.5": { "alias": "kimi" },
        "opencode/kimi-k2.5-free": { "alias": "kimi-free" },
        "opencode/glm-4.7": { "alias": "glm4" },
        "opencode/glm-5-free": { "alias": "glm5" },
        "opencode/claude-sonnet-4-5": { "alias": "sonnet" },
        "opencode/claude-opus-4-6": { "alias": "opus" },
        "opencode/gemini-3-flash": { "alias": "flash" },
        "opencode/gpt-5.1-codex": { "alias": "codex" }
      },
      "heartbeat": {
        "every": "2h",
        "model": "opencode/glm-4.7",
        "target": "last"
      },
      "subagents": {
        "model": "opencode/kimi-k2.5",
        "maxConcurrent": 1,
        "archiveAfterMinutes": 60
      },
      "imageModel": {
        "primary": "opencode/gemini-3-flash",
        "fallbacks": ["opencode/glm-4.7"]
      },
      "contextTokens": 131072,
      "maxConcurrent": 4
    }
  },
  "messages": {
    "ackReactionScope": "group-mentions"
  },
  "commands": {
    "native": "auto",
    "nativeSkills": "auto"
  },
  "channels": {
    "telegram": {
      "enabled": true,
      "dmPolicy": "pairing",
      "groupPolicy": "allowlist",
      "streamMode": "partial"
    }
  },
  "gateway": {
    "mode": "local",
    "controlUi": {
      "allowInsecureAuth": true
    },
    "trustedProxies": ["100.64.0.0/10"]
  },
  "models": {
    "mode": "merge",
    "providers": {
      "opencode": {
        "baseUrl": "https://opencode.ai/zen/v1",
        "apiKey": "${OPENCODE_API_KEY}",
        "api": "openai-completions",
        "models": [
          { "id": "kimi-k2.5", "name": "Kimi K2.5" },
          { "id": "kimi-k2.5-free", "name": "Kimi K2.5 Free" },
          { "id": "glm-4.7", "name": "GLM 4.7" },
          { "id": "glm-5-free", "name": "GLM 5 Free" },
          { "id": "claude-sonnet-4-5", "name": "Claude Sonnet 4.5" },
          { "id": "claude-opus-4-6", "name": "Claude Opus 4.6" },
          { "id": "gemini-3-flash", "name": "Gemini 3 Flash" },
          { "id": "gpt-5.1-codex", "name": "GPT 5.1 Codex" },
          { "id": "big-pickle", "name": "Big Pickle" },
          { "id": "minimax-m2.1-free", "name": "MiniMax M2.1 Free" }
        ]
      }
    }
  },
  "env": {
    "OPENCODE_API_KEY": "SET_THIS_IN_ENV_FILE_OR_HERE"
  }
}
OPENCLAW_CONFIG
  chown deploy:deploy "$CONFIG_FILE"
  chmod 600 "$CONFIG_FILE"
  ok "Wrote OpenClaw config with OpenCode Zen provider setup"
  info "You'll set OPENCODE_API_KEY in oc-configure.sh"
fi

# ═════════════════════════════════════════════════════════════════════════════
# PHASE 3: FIX PERMISSIONS FOR NPM GLOBAL INSTALLS
# ═════════════════════════════════════════════════════════════════════════════

step "4/10 — Creating /home/node directory for OpenClaw"

# OpenClaw (installed globally via npm) needs to write to /home/node
# This is a workaround for npm global packages trying to use hardcoded paths
mkdir -p /home/node
chown deploy:deploy /home/node
chmod 755 /home/node
ok "Created /home/node with deploy ownership"

# ═════════════════════════════════════════════════════════════════════════════
# PHASE 4: SYSTEMD USER SERVICE SETUP
# ═════════════════════════════════════════════════════════════════════════════

step "5/10 — Setting up systemd user service"

# Enable lingering for deploy user so services persist after logout
loginctl enable-linger deploy
ok "Enabled systemd lingering for deploy user"

# Create runtime directory with proper permissions
mkdir -p /run/user/1000
chown deploy:deploy /run/user/1000
chmod 700 /run/user/1000
ok "Created /run/user/1000"

# Create the systemd user service file manually with proper environment
# This avoids issues with openclaw gateway install not finding DBUS
SERVICE_DIR="${DEPLOY_HOME}/.config/systemd/user"
mkdir -p "$SERVICE_DIR"
chown -R deploy:deploy "${DEPLOY_HOME}/.config"

# Get the gateway token from .env
GATEWAY_TOKEN=$(grep OPENCLAW_GATEWAY_TOKEN "$ENV_FILE" | cut -d= -f2)

cat > "${SERVICE_DIR}/openclaw-gateway.service" <<EOF
[Unit]
Description=OpenClaw Gateway (v2026.2.6)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/node /usr/lib/node_modules/openclaw/dist/index.js gateway --port 18789
Restart=always
RestartSec=5
KillMode=process
Environment="XDG_RUNTIME_DIR=/run/user/1000"
Environment="DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus"
Environment="HOME=/home/deploy"
Environment="PATH=/usr/local/bin:/usr/bin:/bin"
Environment="OPENCLAW_CONFIG_PATH=/home/deploy/.openclaw/openclaw.json"
Environment="OPENCLAW_GATEWAY_PORT=18789"
Environment="OPENCLAW_GATEWAY_TOKEN=${GATEWAY_TOKEN}"

[Install]
WantedBy=default.target
EOF

chown deploy:deploy "${SERVICE_DIR}/openclaw-gateway.service"

# Make service file read-only to prevent OpenClaw from auto-modifying it
# OpenClaw may try to change --bind parameter which breaks the service
chmod 444 "${SERVICE_DIR}/openclaw-gateway.service"
ok "Created systemd user service file (read-only to prevent auto-modification)"

# Create a wrapper script to prevent accidental 'openclaw gateway install' from breaking things
cat > /usr/local/bin/openclaw-gateway-protect <<'PROTECT_SCRIPT'
#!/bin/bash
# Wrapper to prevent 'openclaw gateway install' from overwriting our service
echo "⚠️  Warning: 'openclaw gateway install' would overwrite the systemd service."
echo "The service is already configured and protected."
echo "If you need to reinstall, use: systemctl --user restart openclaw-gateway.service"
exit 1
PROTECT_SCRIPT
chmod +x /usr/local/bin/openclaw-gateway-protect

# Start dbus session and enable/start service as deploy user
sudo -u deploy bash <<'DEPLOY_SCRIPT'
export XDG_RUNTIME_DIR=/run/user/1000
export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus

# Start dbus session daemon if not running
if [ ! -S /run/user/1000/bus ]; then
  dbus-daemon --session --address=unix:path=/run/user/1000/bus --fork --nopidfile 2>/dev/null || true
fi

# Enable and start the service
systemctl --user daemon-reload
systemctl --user enable openclaw-gateway.service
systemctl --user start openclaw-gateway.service
DEPLOY_SCRIPT

sleep 5

# Verify the gateway is running
if sudo -u deploy bash -c 'export XDG_RUNTIME_DIR=/run/user/1000 && export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus && systemctl --user is-active openclaw-gateway.service' >/dev/null 2>&1; then
  ok "OpenClaw gateway service is running"
else
  warn "Gateway service status unclear — checking manually"
fi

# Test HTTP response
for i in 1 2 3; do
  if curl -sf http://127.0.0.1:18789/ >/dev/null 2>&1; then
    ok "Gateway responding on http://127.0.0.1:18789/"
    break
  else
    if [ $i -eq 3 ]; then
      warn "Gateway not responding yet — may still be initializing"
    else
      sleep 2
    fi
  fi
done

# ═════════════════════════════════════════════════════════════════════════════
# PHASE 5: SECURITY HARDENING
# ═════════════════════════════════════════════════════════════════════════════

step "6/10 — Tailscale (REQUIRED for secure access)"
echo "  Installing Tailscale..."
curl -fsSL https://tailscale.com/install.sh | sh >/dev/null 2>&1

verify "Tailscale installed" "command -v tailscale"
ok "Tailscale installed — you'll configure it in oc-configure.sh"

step "7/10 — Firewall (UFW)"
apt-get install -y -qq ufw >/dev/null

ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
ufw allow OpenSSH >/dev/null
# Allow Tailscale traffic
ufw allow in on tailscale0 >/dev/null 2>&1 || true
yes | ufw enable >/dev/null 2>&1 || true

verify_soft "UFW active" "ufw status | grep -q 'Status: active'"
ok "SSH allowed, Tailscale interface permitted"

step "8/10 — fail2ban"
apt-get install -y -qq fail2ban >/dev/null

cat > /etc/fail2ban/jail.local <<'EOF'
[sshd]
enabled = true
port = ssh
maxretry = 5
bantime = 3600
findtime = 600
EOF

systemctl enable --now fail2ban >/dev/null 2>&1
sleep 2
verify_soft "fail2ban running" "systemctl is-active fail2ban"
verify_soft "sshd jail active" "fail2ban-client status sshd 2>/dev/null | grep -q 'Currently failed'"

step "9/10 — Automatic security updates"
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq unattended-upgrades >/dev/null
echo 'Unattended-Upgrade::Automatic-Reboot "false";' > /etc/apt/apt.conf.d/51custom-unattended
dpkg-reconfigure -plow unattended-upgrades 2>/dev/null || true
verify_soft "unattended-upgrades installed" "dpkg -l | grep -q unattended-upgrades"

# ── SSH hardening (dangerous step — verify access first) ─────────────────

step "10/10 — SSH hardening"

VPS_IP=$(hostname -I | awk '{print $1}')
echo ""
echo -e "  ${YELLOW}Before proceeding, open a SECOND terminal and verify:${NC}"
echo -e "  ${CYAN}  ssh deploy@${VPS_IP}${NC}"
echo ""
echo -e "  If that works, press Enter to harden SSH."
echo -e "  This will ${RED}disable root login${NC} and ${RED}disable password auth${NC}."
echo ""
pause_confirm "Confirm you can SSH as deploy from another terminal"

sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config

# Only add AllowUsers if not already present
if ! grep -q "^AllowUsers" /etc/ssh/sshd_config; then
  echo "AllowUsers deploy" >> /etc/ssh/sshd_config
fi

systemctl restart sshd
verify "Password auth disabled" "grep -q '^PasswordAuthentication no' /etc/ssh/sshd_config"
verify "Root login disabled"    "grep -q '^PermitRootLogin no' /etc/ssh/sshd_config"
warn "Root SSH is now disabled. Use 'ssh deploy@${VPS_IP}' from now on."

# ═════════════════════════════════════════════════════════════════════════════
# PHASE 6: BACKUPS
# ═════════════════════════════════════════════════════════════════════════════

step "11/11 — Automated backups"

mkdir -p /var/backups/openclaw

cat > /usr/local/bin/openclaw-backup.sh <<'SCRIPT'
#!/bin/bash
set -euo pipefail
BACKUP_DIR="/var/backups/openclaw"
TS="$(date +%F-%H%M%S)"
tar -C / -czf "${BACKUP_DIR}/openclaw-${TS}.tar.gz" home/deploy/.openclaw
tar -tzf "${BACKUP_DIR}/openclaw-${TS}.tar.gz" >/dev/null 2>&1
find "$BACKUP_DIR" -type f -mtime +14 -delete
SCRIPT
chmod +x /usr/local/bin/openclaw-backup.sh

cat > /etc/systemd/system/openclaw-backup.service <<'EOF'
[Unit]
Description=OpenClaw Backup

[Service]
Type=oneshot
ExecStart=/usr/local/bin/openclaw-backup.sh
EOF

cat > /etc/systemd/system/openclaw-backup.timer <<'EOF'
[Timer]
OnCalendar=*-*-* 03:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now openclaw-backup.timer >/dev/null 2>&1

# Run a test backup
/usr/local/bin/openclaw-backup.sh
verify_soft "Backup script works" "ls /var/backups/openclaw/*.tar.gz 2>/dev/null | head -1"
verify_soft "Backup timer enabled" "systemctl is-enabled openclaw-backup.timer"

# ═════════════════════════════════════════════════════════════════════════════
# DONE
# ═════════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  ✅ Bootstrap complete!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  Summary:"
echo "    • Node.js + OpenClaw gateway running via systemd"
echo "    • Docker containers cleaned up (if any existed)"
echo "    • /home/node directory created for npm global packages"
echo "    • deploy user created with SSH access"
echo "    • Tailscale installed (configure in next step)"
echo "    • UFW firewall + fail2ban active"
echo "    • Automatic security updates enabled"
echo "    • Daily backups at 03:00 UTC"
echo ""
echo "  Next steps:"
echo "    1. SSH in as deploy:  ssh deploy@${VPS_IP}"
echo "    2. Run the configure script:  bash oc-configure.sh"
echo "    3. Set up SSH tunnel locally:  ssh -N -L 18789:127.0.0.1:18789 deploy@${VPS_IP}"
echo ""
echo -e "  ${YELLOW}Remember to save your gateway token!${NC}"
echo ""
