#!/usr/bin/env bash
# oc-provision.sh — Provision Hetzner VPS for OpenClaw
# Creates cx22 VPS in fsn1, sets up SSH key, outputs IP and bootstrap command
# Usage: ./oc-provision.sh
set -euo pipefail

# ── Helpers ──────────────────────────────────────────────────────────────────

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

step()   { echo -e "\n${CYAN}━━━ $1 ━━━${NC}"; }
ok()     { echo -e "  ${GREEN}✅ $1${NC}"; }
warn()   { echo -e "  ${YELLOW}⚠️  $1${NC}"; }
fail()   { echo -e "  ${RED}❌ $1${NC}"; exit 1; }

# ── Check hcloud CLI ─────────────────────────────────────────────────────────

step "Checking hcloud CLI"

if ! command -v hcloud &>/dev/null; then
  echo ""
  echo "  hcloud CLI not found. Install it first:"
  echo ""
  echo "    macOS:    brew install hcloud"
  echo "    Linux:    curl -fsSL https://raw.githubusercontent.com/hetznercloud/cli/main/install.sh | bash"
  echo ""
  fail "Please install hcloud CLI and try again"
fi

ok "hcloud CLI found ($(hcloud version | head -1))"

# ── Get API Token ────────────────────────────────────────────────────────────

step "Hetzner API Token"

if [[ -n "${HCLOUD_TOKEN:-}" ]]; then
  ok "Found HCLOUD_TOKEN in environment"
  HCLOUD_TOKEN_CONFIRM="$HCLOUD_TOKEN"
else
  warn "HCLOUD_TOKEN not set in environment"
  echo ""
  echo "  Get your token from: https://console.hetzner.cloud/projects → Security → API Tokens"
  echo ""
  echo -n "  Paste your Hetzner API token: "
  read -rs HCLOUD_TOKEN_CONFIRM
  echo ""
  
  if [[ -z "$HCLOUD_TOKEN_CONFIRM" ]]; then
    fail "API token is required"
  fi
fi

# Export for hcloud CLI
export HCLOUD_TOKEN="$HCLOUD_TOKEN_CONFIRM"

# Quick test of the token
if ! hcloud project list >/dev/null 2>&1; then
  fail "API token invalid or network error — check HCLOUD_TOKEN"
fi

ok "API token is valid"

# ── SSH Key Setup ────────────────────────────────────────────────────────────

step "SSH Key Setup"

SSH_KEY_NAME="openclaw-key"
LOCAL_KEY_PATH="$HOME/.ssh/${SSH_KEY_NAME}"

# Check if key already exists locally
if [[ -f "${LOCAL_KEY_PATH}" ]]; then
  ok "Found local SSH key: ${LOCAL_KEY_PATH}"
else
  echo ""
  echo "  Creating new SSH key: ${SSH_KEY_NAME}"
  echo ""
  
  # Ensure .ssh directory exists
  mkdir -p "$HOME/.ssh"
  chmod 700 "$HOME/.ssh"
  
  ssh-keygen -t ed25519 -C "openclaw-deploy" -f "${LOCAL_KEY_PATH}" -N ""
  chmod 600 "${LOCAL_KEY_PATH}"
  chmod 644 "${LOCAL_KEY_PATH}.pub"
  
  ok "Created SSH key: ${LOCAL_KEY_PATH}"
fi

# Check if key exists in Hetzner
if hcloud ssh-key describe "$SSH_KEY_NAME" >/dev/null 2>&1; then
  ok "SSH key '${SSH_KEY_NAME}' already exists in Hetzner"
  
    # Verify fingerprint matches
    LOCAL_FINGERPRINT=$(ssh-keygen -E md5 -lf "${LOCAL_KEY_PATH}.pub" | awk '{print $2}' | sed 's/MD5://')
    REMOTE_FINGERPRINT=$(hcloud ssh-key describe "$SSH_KEY_NAME" -o format='{{.Fingerprint}}')

  
  if [[ "$LOCAL_FINGERPRINT" == "$REMOTE_FINGERPRINT" ]]; then
    ok "Local and remote SSH key fingerprints match"
  else
    warn "SSH key fingerprint mismatch!"
    echo ""
    echo "  Local:  $LOCAL_FINGERPRINT"
    echo "  Remote: $REMOTE_FINGERPRINT"
    echo ""
    echo "  Delete the remote key and re-run, or use a different key name:"
    echo "    hcloud ssh-key delete ${SSH_KEY_NAME}"
    exit 1
  fi
else
  echo "  Uploading SSH key to Hetzner..."
  hcloud ssh-key create --name "$SSH_KEY_NAME" --public-key-from-file "${LOCAL_KEY_PATH}.pub"
  ok "Uploaded SSH key '${SSH_KEY_NAME}' to Hetzner"
fi

# ── Create Server ────────────────────────────────────────────────────────────

step "Creating VPS"

SERVER_NAME="openclaw"
SERVER_TYPE="cx22"
SERVER_IMAGE="ubuntu-24.04"
SERVER_LOCATION="fsn1"

# Check if server already exists
if hcloud server describe "$SERVER_NAME" >/dev/null 2>&1; then
  warn "Server '${SERVER_NAME}' already exists"
  
  SERVER_IP=$(hcloud server ip "$SERVER_NAME")
  SERVER_STATUS=$(hcloud server describe "$SERVER_NAME" -o format='{{.Status}}')
  
  echo ""
  echo "  Status: ${SERVER_STATUS}"
  echo "  IP:     ${SERVER_IP}"
  echo ""
  
  read -p "  Delete and recreate? [y/N]: " -n 1 -r
  echo ""
  
  if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "  Deleting existing server..."
    hcloud server delete "$SERVER_NAME"
    echo "  Waiting for deletion..."
    sleep 5
  else
    echo "  Using existing server. To use a different name, set SERVER_NAME env var."
    echo ""
    echo "  To run bootstrap on existing server:"
    echo "    ssh root@${SERVER_IP} 'bash -s' < oc-bootstrap.sh"
    exit 0
  fi
fi

echo ""
echo "  Configuration:"
echo "    Name:     ${SERVER_NAME}"
echo "    Type:     ${SERVER_TYPE} (~\$5/month)"
echo "    Image:    ${SERVER_IMAGE}"
echo "    Location: ${SERVER_LOCATION}"
echo "    SSH Key:  ${SSH_KEY_NAME}"
echo ""
echo "  Creating server (this takes ~30 seconds)..."
echo ""

hcloud server create \
  --name "$SERVER_NAME" \
  --type "$SERVER_TYPE" \
  --image "$SERVER_IMAGE" \
  --location "$SERVER_LOCATION" \
  --ssh-key "$SSH_KEY_NAME" \
  --label "app=openclaw" \

SERVER_IP=$(hcloud server ip "$SERVER_NAME")

ok "Server created successfully!"

# ── Wait for SSH ─────────────────────────────────────────────────────────────

step "Waiting for SSH"

echo "  Waiting for SSH to become available (this may take 30-60 seconds)..."

for i in {1..30}; do
  if ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 -o BatchMode=yes "root@${SERVER_IP}" echo "OK" >/dev/null 2>&1; then
    ok "SSH is ready"
    break
  fi
  
  if [[ $i -eq 30 ]]; then
    warn "SSH not ready after 30 attempts. Server may still be booting."
    echo "  You can check status manually: ssh root@${SERVER_IP}"
  else
    echo -n "."
    sleep 2
  fi
done

# ── Output ───────────────────────────────────────────────────────────────────

step "Provisioning Complete!"

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  ✅ VPS Provisioned Successfully${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  Server Details:"
echo "    Name:     ${SERVER_NAME}"
echo "    IP:       ${SERVER_IP}"
echo "    Type:     ${SERVER_TYPE}"
echo "    Location: ${SERVER_LOCATION}"
echo ""
echo "  SSH Access:"
echo "    ssh root@${SERVER_IP}"
echo "    ssh deploy@${SERVER_IP}  (after bootstrap)"
echo ""
echo "  ──────────────────────────────────────────────────────────────"
echo ""
echo -e "  ${CYAN}➡️  NEXT: Run the bootstrap script:${NC}"
echo ""
echo -e "  ${CYAN}ssh root@${SERVER_IP} 'bash -s' < oc-bootstrap.sh${NC}"
echo ""
echo "  ──────────────────────────────────────────────────────────────"
echo ""
echo "  After bootstrap completes, run configure:"
echo -e "  ${CYAN}ssh deploy@${SERVER_IP} 'bash -s' < oc-configure.sh${NC}"
echo ""
echo "  Aliases for ~/.zshrc or ~/.bashrc:"
echo "    alias ocs='ssh deploy@${SERVER_IP}'"
echo "    alias oct='ssh -N -L 18789:127.0.0.1:18789 deploy@${SERVER_IP}'"
echo "    alias ocl='ssh deploy@${SERVER_IP} \"cd ~/openclaw && docker compose logs -f openclaw-gateway\"'"
echo ""
