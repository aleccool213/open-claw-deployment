#!/usr/bin/env bash
# oc-bootstrap.sh — Run on fresh Hetzner VPS as root
# Covers: Docker, OpenClaw clone, deploy user, security hardening, backups
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
  else
    fail "$1 — command failed: $2"
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
# PHASE 1: BASE SYSTEM
# ═════════════════════════════════════════════════════════════════════════════

step "1/9 — Installing Docker"
apt-get update -qq
apt-get install -y -qq git curl ca-certificates jq > /dev/null

if command -v docker &>/dev/null; then
  warn "Docker already installed, skipping"
else
  curl -fsSL https://get.docker.com | sh
fi

verify "Docker installed"          "docker --version"
verify "Docker Compose installed"  "docker compose version"

# ═════════════════════════════════════════════════════════════════════════════
# PHASE 2: OPENCLAW
# ═════════════════════════════════════════════════════════════════════════════

# IMPORTANT: Pin to v2026.2.6 (v2026.2.9 has Telegram bug where polling never starts)
# See: https://github.com/openclaw/openclaw/issues/15082
OPENCLAW_VERSION="v2026.2.6"
OPENCLAW_IMAGE="openclaw:${OPENCLAW_VERSION}"

step "2/9 — Building OpenClaw ${OPENCLAW_VERSION}"
DEPLOY_HOME="/home/deploy"
OPENCLAW_DIR="${DEPLOY_HOME}/openclaw"
OPENCLAW_DATA="${DEPLOY_HOME}/.openclaw"

# Create deploy user first (need home dir for clone location)
if id deploy &>/dev/null; then
  warn "User 'deploy' already exists, skipping creation"
else
  adduser --disabled-password --gecos "OpenClaw Deploy" deploy
  ok "Created user 'deploy'"
fi

usermod -aG sudo deploy 2>/dev/null || true
usermod -aG docker deploy 2>/dev/null || true

# Set up SSH key for deploy user
mkdir -p "${DEPLOY_HOME}/.ssh"
if [[ -f /root/.ssh/authorized_keys ]]; then
  cp /root/.ssh/authorized_keys "${DEPLOY_HOME}/.ssh/"
fi
chown -R deploy:deploy "${DEPLOY_HOME}/.ssh"
chmod 700 "${DEPLOY_HOME}/.ssh"
chmod 600 "${DEPLOY_HOME}/.ssh/authorized_keys" 2>/dev/null || true
ok "SSH keys copied to deploy user"

# Download and build pinned version from source
if [[ -d "$OPENCLAW_DIR" ]]; then
  warn "OpenClaw already exists at ${OPENCLAW_DIR}, checking version..."
else
  echo "  Downloading OpenClaw ${OPENCLAW_VERSION} source..."
  cd /tmp
  curl -sL "https://github.com/openclaw/openclaw/archive/refs/tags/${OPENCLAW_VERSION}.tar.gz" -o openclaw.tar.gz
  tar xzf openclaw.tar.gz
  mv "openclaw-${OPENCLAW_VERSION#v}" "$OPENCLAW_DIR"
  rm -f openclaw.tar.gz
  chown -R deploy:deploy "$OPENCLAW_DIR"
  ok "Downloaded OpenClaw ${OPENCLAW_VERSION}"
fi

verify "Source directory exists" "test -f ${OPENCLAW_DIR}/docker-compose.yml"

step "3/9 — Persistent directories & secrets"

mkdir -p "${OPENCLAW_DATA}" "${OPENCLAW_DATA}/workspace"
chown -R 1000:1000 "${OPENCLAW_DATA}"

# Generate .env if it doesn't exist
ENV_FILE="${OPENCLAW_DIR}/.env"
if [[ -f "$ENV_FILE" ]]; then
  warn ".env already exists, not overwriting"
else
  GATEWAY_TOKEN=$(openssl rand -hex 32)
  KEYRING_PASSWORD=$(openssl rand -hex 32)

  cat > "$ENV_FILE" <<EOF
# IMPORTANT: Use v2026.2.6 (v2026.2.9 has Telegram bug - polling never starts)
# See: https://github.com/openclaw/openclaw/issues/15082
OPENCLAW_IMAGE=${OPENCLAW_IMAGE}
OPENCLAW_GATEWAY_TOKEN=${GATEWAY_TOKEN}
OPENCLAW_GATEWAY_BIND=lan
OPENCLAW_GATEWAY_PORT=18789

OPENCLAW_CONFIG_DIR=${OPENCLAW_DATA}
OPENCLAW_WORKSPACE_DIR=${OPENCLAW_DATA}/workspace

GOG_KEYRING_PASSWORD=${KEYRING_PASSWORD}
XDG_CONFIG_HOME=/home/node/.openclaw
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

verify ".env exists and is restricted" "test -f $ENV_FILE && stat -c '%a' $ENV_FILE | grep -q '600'"
verify "Data dir writable by node user" "test -d ${OPENCLAW_DATA}/workspace"

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
  chown 1000:1000 "$CONFIG_FILE"
  chmod 600 "$CONFIG_FILE"
  ok "Wrote OpenClaw config with OpenCode Zen provider setup"
  info "You'll set OPENCODE_API_KEY in oc-configure.sh"
fi

step "4/9 — Building & launching gateway"
cd "$OPENCLAW_DIR"

# Build from source (pinned version)
echo "  Building OpenClaw ${OPENCLAW_VERSION} from source..."
echo "  This may take a few minutes on first run..."
export DOCKER_BUILDKIT=1
docker build \
  --build-arg BUILDKIT_INLINE_CACHE=1 \
  -t "${OPENCLAW_IMAGE}" .
ok "Built ${OPENCLAW_IMAGE}"

docker compose up -d openclaw-gateway
sleep 5

# Verify gateway is running
if docker compose ps openclaw-gateway | grep -q "Up"; then
  ok "Gateway container is running"
else
  warn "Gateway may still be starting — check: docker compose logs -f openclaw-gateway"
fi

# Quick health check
if curl -sf http://127.0.0.1:18789/ >/dev/null 2>&1; then
  ok "Gateway responding on http://127.0.0.1:18789/"
else
  warn "Gateway not responding yet (may still be initializing)"
fi

# ═════════════════════════════════════════════════════════════════════════════
# PHASE 3: SECURITY HARDENING
# ═════════════════════════════════════════════════════════════════════════════

step "5/9 — Tailscale (REQUIRED for secure access)"
echo "  Installing Tailscale..."
curl -fsSL https://tailscale.com/install.sh | sh >/dev/null 2>&1

verify "Tailscale installed" "command -v tailscale"
ok "Tailscale installed — you'll configure it in oc-configure.sh"

step "6/9 — Firewall (UFW)"
apt-get install -y -qq ufw > /dev/null

ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
ufw allow OpenSSH >/dev/null
# Allow Tailscale traffic
ufw allow in on tailscale0 >/dev/null 2>&1 || true
yes | ufw enable >/dev/null 2>&1 || true

verify "UFW active" "ufw status | grep -q 'Status: active'"
verify "SSH allowed" "ufw status | grep -q '22/tcp'"
ok "SSH allowed, Tailscale interface permitted"

step "7/9 — fail2ban"
apt-get install -y -qq fail2ban > /dev/null

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
verify "fail2ban running" "systemctl is-active fail2ban"
verify "sshd jail active" "fail2ban-client status sshd 2>/dev/null | grep -q 'Currently failed'"

step "8/9 — Automatic security updates"
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq unattended-upgrades > /dev/null
echo 'Unattended-Upgrade::Automatic-Reboot "false";' > /etc/apt/apt.conf.d/51custom-unattended
dpkg-reconfigure -plow unattended-upgrades 2>/dev/null || true
verify "unattended-upgrades installed" "dpkg -l | grep -q unattended-upgrades"

# ── SSH hardening (dangerous step — verify access first) ─────────────────

step "9/9 — SSH hardening"

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
# PHASE 4: BACKUPS
# ═════════════════════════════════════════════════════════════════════════════

step "10/10 — Automated backups"

mkdir -p /var/backups/openclaw

cat > /usr/local/bin/openclaw-backup.sh <<'SCRIPT'
#!/bin/bash
set -euo pipefail
BACKUP_DIR="/var/backups/openclaw"
TS="$(date +%F-%H%M%S)"
tar -C / -czf "${BACKUP_DIR}/openclaw-${TS}.tar.gz" home/deploy/.openclaw
tar -tzf "${BACKUP_DIR}/openclaw-${TS}.tar.gz" > /dev/null 2>&1
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
verify "Backup script works" "ls /var/backups/openclaw/*.tar.gz 2>/dev/null | head -1"
verify "Backup timer enabled" "systemctl is-enabled openclaw-backup.timer"

# ═════════════════════════════════════════════════════════════════════════════
# DONE
# ═════════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  ✅ Bootstrap complete!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  Summary:"
echo "    • Docker + OpenClaw gateway running"
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
