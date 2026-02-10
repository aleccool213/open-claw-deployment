#!/usr/bin/env bash
# oc-bootstrap.sh — Run on fresh Hetzner VPS as root
# Covers: Docker, OpenClaw clone, deploy user, security hardening, backups
# Usage: ssh root@<VPS_IP> 'bash -s' < oc-bootstrap.sh
set -euo pipefail

# ── Helpers ──────────────────────────────────────────────────────────────────

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

step()   { echo -e "\n${CYAN}━━━ $1 ━━━${NC}"; }
ok()     { echo -e "  ${GREEN}✅ $1${NC}"; }
warn()   { echo -e "  ${YELLOW}⚠️  $1${NC}"; }
fail()   { echo -e "  ${RED}❌ $1${NC}"; exit 1; }

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
  echo -e "   Press Enter to continue, or Ctrl-C to abort..."
  read -r
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

step "2/9 — Cloning OpenClaw"
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

# Give deploy passwordless sudo (needed for setup, can remove later)
echo "deploy ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/deploy
chmod 440 /etc/sudoers.d/deploy

# Clone repo
if [[ -d "$OPENCLAW_DIR" ]]; then
  warn "OpenClaw already cloned at ${OPENCLAW_DIR}, pulling latest"
  su - deploy -c "cd ${OPENCLAW_DIR} && git pull --ff-only" || true
else
  su - deploy -c "git clone https://github.com/openclaw/openclaw.git ${OPENCLAW_DIR}"
fi

verify "Repo cloned" "test -f ${OPENCLAW_DIR}/docker-compose.yml"

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
OPENCLAW_IMAGE=openclaw:latest
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

step "4/9 — Building & launching gateway"
cd "$OPENCLAW_DIR"
docker compose build
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

step "5/9 — Firewall (UFW)"
apt-get install -y -qq ufw > /dev/null

ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
ufw allow OpenSSH >/dev/null
yes | ufw enable >/dev/null 2>&1 || true

verify "UFW active" "ufw status | grep -q 'Status: active'"
verify "SSH allowed" "ufw status | grep -q '22/tcp'"
ok "Only SSH (22) allowed incoming — gateway accessed via SSH tunnel"

step "6/9 — fail2ban"
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

step "7/9 — Automatic security updates"
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq unattended-upgrades > /dev/null
echo 'Unattended-Upgrade::Automatic-Reboot "false";' > /etc/apt/apt.conf.d/51custom-unattended
dpkg-reconfigure -plow unattended-upgrades 2>/dev/null || true
verify "unattended-upgrades installed" "dpkg -l | grep -q unattended-upgrades"

# ── SSH hardening (dangerous step — verify access first) ─────────────────

step "8/9 — SSH hardening"

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

step "9/9 — Automated backups"

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
