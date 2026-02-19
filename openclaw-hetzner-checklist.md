# OpenClaw on Hetzner — Terminal-First Deployment Checklist

> ⚠️ **Deprecated**: This checklist reflects the old Docker-based deployment approach.
> The current setup runs OpenClaw directly on the VPS via Node.js + systemd.
> Use `oc-bootstrap.sh` → `oc-configure.sh` for the current approach.

> Based on the [official docs](https://docs.openclaw.ai/platforms/hetzner) and community hardening guides.
> Goal: OpenClaw Gateway running 24/7 on a ~$5/mo Hetzner VPS via Docker, accessed over SSH tunnel.

---

## Prerequisites (local machine)

- [ ] Install the Hetzner CLI: `brew install hcloud` (or see [hcloud releases](https://github.com/hetznercloud/cli/releases))
- [ ] Authenticate: `hcloud context create openclaw` → paste an API token from Hetzner Cloud Console (this is the one unavoidable UI step — generate a token at https://console.hetzner.cloud under your project → Security → API Tokens)
- [ ] Have an SSH key ready (`ssh-keygen -t ed25519` if not)
- [ ] Upload it to Hetzner: `hcloud ssh-key create --name openclaw-key --public-key-from-file ~/.ssh/id_ed25519.pub`

---

## 1. Provision the VPS

```bash
hcloud server create \
  --name openclaw \
  --type cx22 \
  --image ubuntu-24.04 \
  --location fsn1 \
  --ssh-key openclaw-key
```

- [ ] Note the IP from the output (or `hcloud server ip openclaw`)
- [ ] SSH in: `ssh root@$(hcloud server ip openclaw)`

---

## 2. Install Docker

```bash
apt-get update
apt-get install -y git curl ca-certificates
curl -fsSL https://get.docker.com | sh
```

- [ ] Verify: `docker --version && docker compose version`

---

## 3. Clone OpenClaw

```bash
git clone https://github.com/openclaw/openclaw.git
cd openclaw
```

---

## 4. Create persistent host directories

```bash
mkdir -p /root/.openclaw /root/.openclaw/workspace
chown -R 1000:1000 /root/.openclaw /root/.openclaw/workspace
```

> UID 1000 matches the `node` user inside the container. All durable state lives here, not in the container.

---

## 5. Generate secrets & write `.env`

```bash
# Generate tokens
GATEWAY_TOKEN=$(openssl rand -hex 32)
KEYRING_PASSWORD=$(openssl rand -hex 32)

cat > .env <<EOF
OPENCLAW_IMAGE=openclaw:latest
OPENCLAW_GATEWAY_TOKEN=${GATEWAY_TOKEN}
OPENCLAW_GATEWAY_BIND=lan
OPENCLAW_GATEWAY_PORT=18789

OPENCLAW_CONFIG_DIR=/root/.openclaw
OPENCLAW_WORKSPACE_DIR=/root/.openclaw/workspace

GOG_KEYRING_PASSWORD=${KEYRING_PASSWORD}
XDG_CONFIG_HOME=/home/node/.openclaw
EOF

chmod 600 .env
```

- [ ] **Save `GATEWAY_TOKEN` somewhere safe** — you'll need it to log in to the Control UI
- [ ] Optionally add provider creds (e.g. `CLAUDE_AI_SESSION_KEY`, Telegram bot token, etc.)

---

## 6. Docker Compose config

The repo ships a `docker-compose.yml`. Confirm it has:

- [ ] `127.0.0.1:${OPENCLAW_GATEWAY_PORT}:18789` port binding (loopback only — access via SSH tunnel)
- [ ] Volume mounts for `${OPENCLAW_CONFIG_DIR}` and `${OPENCLAW_WORKSPACE_DIR}`
- [ ] `restart: unless-stopped`

If you need to customize, the full reference is in the [official docs](https://docs.openclaw.ai/platforms/hetzner#6-docker-compose-configuration).

---

## 7. Bake binaries into the Docker image (if needed)

Any external binaries your skills need (e.g. `gog`, `goplaces`, `wacli`) must be installed at **build time**, not runtime. Add `RUN curl ...` lines to the `Dockerfile` before building.

- [ ] Review which skills/binaries you need
- [ ] Update `Dockerfile` with any additional `RUN` install lines

---

## 8. Build & launch

```bash
docker compose build
docker compose up -d openclaw-gateway
```

- [ ] Verify binaries are present:
  ```bash
  docker compose exec openclaw-gateway which gog
  docker compose exec openclaw-gateway which goplaces
  docker compose exec openclaw-gateway which wacli
  ```

---

## 9. Verify the Gateway

```bash
docker compose logs -f openclaw-gateway
```

- [ ] Confirm you see: `[gateway] listening on ws://0.0.0.0:18789`

---

## 10. Connect from your laptop

```bash
ssh -N -L 18789:127.0.0.1:18789 root@$(hcloud server ip openclaw)
```

- [ ] Open `http://127.0.0.1:18789/` in browser
- [ ] Paste your gateway token to authenticate

---

## Security Hardening (on the VPS)

All commands below assume you're SSH'd into the VPS.

### 11. Create a non-root `deploy` user

Running everything as root is unnecessary risk. Do this early so all subsequent state lives under `/home/deploy/`.

```bash
adduser deploy
usermod -aG sudo deploy

# Copy your SSH key over
mkdir -p /home/deploy/.ssh
cp ~/.ssh/authorized_keys /home/deploy/.ssh/
chown -R deploy:deploy /home/deploy/.ssh
chmod 700 /home/deploy/.ssh && chmod 600 /home/deploy/.ssh/authorized_keys

# Add deploy to the docker group so it can run docker without sudo
usermod -aG docker deploy
```

- [ ] Verify you can log in: `ssh deploy@YOUR_VPS_IP` (from a **second** terminal — don't close root yet)
- [ ] Move openclaw data if you already set it up under root:
  ```bash
  mv /root/.openclaw /home/deploy/.openclaw
  chown -R 1000:1000 /home/deploy/.openclaw
  ```
- [ ] Update `.env` paths to `/home/deploy/.openclaw` and `/home/deploy/.openclaw/workspace`

### 12. Harden SSH

```bash
sudo sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sudo sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
echo "AllowUsers deploy" | sudo tee -a /etc/ssh/sshd_config
sudo systemctl restart sshd
```

- [ ] **Test from a second terminal before closing your current session!**

### 13. Firewall (UFW)

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow OpenSSH
sudo ufw --force enable
sudo ufw status verbose
```

- [ ] Confirm only SSH (22) is allowed incoming. Port 18789 is NOT exposed — access is via SSH tunnel only.

> ⚠️ **Docker bypasses UFW** for published container ports. This is why `127.0.0.1:` in the compose port binding is critical — it's your real firewall for the gateway, not UFW.

### 14. fail2ban

```bash
sudo apt-get install -y fail2ban

cat <<'EOF' | sudo tee /etc/fail2ban/jail.local
[sshd]
enabled = true
port = ssh
maxretry = 5
bantime = 3600
findtime = 600
EOF

sudo systemctl enable --now fail2ban
sudo fail2ban-client status sshd
```

- [ ] Verify jail is active and monitoring SSH

### 15. Automatic security updates

```bash
sudo apt-get install -y unattended-upgrades
sudo dpkg-reconfigure -plow unattended-upgrades
```

### 16. Docker Compose hardening

Add these options to your `openclaw-gateway` service in `docker-compose.yml`:

```yaml
    security_opt:
      - no-new-privileges:true
    mem_limit: "1g"
    pids_limit: 256
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
```

- [ ] `no-new-privileges` prevents privilege escalation inside the container
- [ ] `mem_limit` prevents a runaway process from OOM-killing the whole VPS
- [ ] Log rotation keeps disk from filling up
- [ ] **Never mount `/var/run/docker.sock`** into the container — it's equivalent to root on the host

### 17. Tailscale (REQUIRED — secure zero-trust network access)

Tailscale provides secure access to your OpenClaw gateway from any device without exposing ports or managing SSH tunnels.

**Installation and setup are automated in the bootstrap and configure scripts**, but for manual setup:

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
sudo ufw allow in on tailscale0

# Proxy the gateway through Tailscale (keeps Docker binding on 127.0.0.1)
sudo tailscale serve --bg --https=443 http://127.0.0.1:18789
```

- [ ] Access from any tailnet device at `https://<your-machine-name>.tailnet-name.ts.net/`
- [ ] Do NOT change Docker port binding from `127.0.0.1` to `0.0.0.0` — use `tailscale serve` instead
- [ ] Tailscale provides encrypted connections and zero-trust access control

### 18. Automated backups

```bash
sudo mkdir -p /var/backups/openclaw

cat <<'SCRIPT' | sudo tee /usr/local/bin/openclaw-backup.sh
#!/bin/bash
set -euo pipefail
BACKUP_DIR="/var/backups/openclaw"
TS="$(date +%F-%H%M%S)"

tar -C / -czf "${BACKUP_DIR}/openclaw-${TS}.tar.gz" home/deploy/.openclaw

# Verify the tarball is readable
tar -tzf "${BACKUP_DIR}/openclaw-${TS}.tar.gz" > /dev/null 2>&1

# Keep 14 days
find "$BACKUP_DIR" -type f -mtime +14 -delete
SCRIPT

sudo chmod +x /usr/local/bin/openclaw-backup.sh
```

Set up a systemd timer:

```bash
cat <<'EOF' | sudo tee /etc/systemd/system/openclaw-backup.service
[Unit]
Description=OpenClaw Backup

[Service]
Type=oneshot
ExecStart=/usr/local/bin/openclaw-backup.sh
EOF

cat <<'EOF' | sudo tee /etc/systemd/system/openclaw-backup.timer
[Timer]
OnCalendar=*-*-* 03:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

sudo systemctl enable --now openclaw-backup.timer
```

- [ ] Test it once manually: `sudo /usr/local/bin/openclaw-backup.sh && ls -lh /var/backups/openclaw/`

### 19. Token rotation

Rotate your gateway token quarterly. Runbook:

```bash
NEW_TOKEN="$(openssl rand -hex 32)"
# Update .env with the new OPENCLAW_GATEWAY_TOKEN
# Then:
cd /home/deploy/openclaw && docker compose up -d --force-recreate openclaw-gateway
# Re-authenticate all clients with the new token
```

### 20. Security scorecard

After deployment, verify:

- [ ] SSH: key-only, root login disabled, fail2ban active
- [ ] Firewall: UFW enabled, default deny, only SSH allowed, Tailscale interface permitted
- [ ] Tailscale: connected and serving gateway on HTTPS
- [ ] Docker: ports bound to `127.0.0.1`, `no-new-privileges`, no socket mount
- [ ] Secrets: `.env` is `chmod 600`, not committed to git
- [ ] Backups: timer running, manually tested at least once
- [ ] Updates: `unattended-upgrades` active
- [ ] Container runs as non-root (`docker compose exec openclaw-gateway id` → uid=1000)

---

## Local Convenience Scripts & Aliases

Add these to your `~/.zshrc` or `~/.bashrc` on your **local machine**.

### Core aliases

```bash
# ── OpenClaw VPS shortcuts ──────────────────────────────────────────
export OPENCLAW_VPS="openclaw"  # hcloud server name

# Get the VPS IP (cached for the session)
_oc_ip() { hcloud server ip "$OPENCLAW_VPS" 2>/dev/null; }

# SSH into the VPS
alias ocs='ssh deploy@$(_oc_ip)'

# SSH tunnel to the gateway (run in background, access at localhost:18789)
alias oct='ssh -f -N -L 18789:127.0.0.1:18789 deploy@$(_oc_ip) && echo "Tunnel open → http://127.0.0.1:18789/"'

# Kill the SSH tunnel
alias octk='pkill -f "ssh -f -N -L 18789:127.0.0.1:18789" 2>/dev/null && echo "Tunnel closed" || echo "No tunnel running"'

# Tail gateway logs
alias ocl='ssh deploy@$(_oc_ip) "cd ~/openclaw && docker compose logs -f --tail 100 openclaw-gateway"'

# Gateway status (is it running?)
alias ocst='ssh deploy@$(_oc_ip) "cd ~/openclaw && docker compose ps openclaw-gateway"'

# Restart the gateway
alias ocr='ssh deploy@$(_oc_ip) "cd ~/openclaw && docker compose restart openclaw-gateway"'

# Rebuild and relaunch (after git pull on the VPS)
alias ocb='ssh deploy@$(_oc_ip) "cd ~/openclaw && git pull --ff-only && docker compose build && docker compose up -d openclaw-gateway"'

# Quick health check
alias och='ssh deploy@$(_oc_ip) "curl -sf http://127.0.0.1:18789/ > /dev/null && echo \"✅ Gateway UP\" || echo \"❌ Gateway DOWN\""'
```

### Power-user functions

```bash
# Full deploy: pull → build → restart → verify
ocdeploy() {
  local ip=$(_oc_ip)
  echo "🔄 Pulling latest..."
  ssh deploy@"$ip" "cd ~/openclaw && git pull --ff-only"
  echo "🔨 Building image..."
  ssh deploy@"$ip" "cd ~/openclaw && docker compose build"
  echo "🚀 Restarting gateway..."
  ssh deploy@"$ip" "cd ~/openclaw && docker compose up -d openclaw-gateway"
  sleep 3
  echo "🏥 Health check..."
  ssh deploy@"$ip" "curl -sf http://127.0.0.1:18789/ > /dev/null && echo '✅ Gateway UP' || echo '❌ Gateway DOWN'"
}

# Run a backup now
ocbackup() {
  ssh deploy@$(_oc_ip) "sudo /usr/local/bin/openclaw-backup.sh && echo '✅ Backup done' && ls -lh /var/backups/openclaw/ | tail -3"
}

# Show VPS resource usage (disk, memory, CPU)
ocinfo() {
  ssh deploy@$(_oc_ip) bash -s <<'REMOTE'
echo "── Disk ──"
df -h / | tail -1 | awk '{printf "  %s used of %s (%s)\n", $3, $2, $5}'
echo "── Memory ──"
free -h | awk '/Mem:/{printf "  %s used of %s (%s free)\n", $3, $2, $7}'
echo "── Docker ──"
docker compose -f ~/openclaw/docker-compose.yml ps --format "table {{.Name}}\t{{.Status}}"
echo "── Uptime ──"
uptime
REMOTE
}

# Hetzner server power management
alias ocon='hcloud server poweron $OPENCLAW_VPS && echo "Powering on..."'
alias ocoff='hcloud server poweroff $OPENCLAW_VPS && echo "Powered off"'
alias ocsnap='hcloud server create-image $OPENCLAW_VPS --type snapshot --description "manual-$(date +%F)" && echo "Snapshot created"'
```

### SSH config (add to `~/.ssh/config`)

This avoids typing IPs and makes the aliases above even simpler:

```bash
# Append to ~/.ssh/config (run once)
cat >> ~/.ssh/config <<'EOF'

Host openclaw-vps
  HostName <YOUR_VPS_IP>
  User deploy
  IdentityFile ~/.ssh/id_ed25519
  # Keep tunnel connections alive
  ServerAliveInterval 60
  ServerAliveCountMax 3
EOF
```

Then simplify aliases — replace `deploy@$(_oc_ip)` with `openclaw-vps`:

```bash
alias ocs='ssh openclaw-vps'
alias oct='ssh -f -N -L 18789:127.0.0.1:18789 openclaw-vps && echo "Tunnel open → http://127.0.0.1:18789/"'
alias ocl='ssh openclaw-vps "cd ~/openclaw && docker compose logs -f --tail 100 openclaw-gateway"'
```

> **Tip:** If your Hetzner IP changes (e.g. after a rebuild), update `~/.ssh/config` or stick with the `_oc_ip` function version which queries `hcloud` dynamically.

---

## Quick reference

| What | Where |
|---|---|
| All durable state | `/home/deploy/.openclaw/` on host |
| Gateway config | `/home/deploy/.openclaw/openclaw.json` |
| Agent workspace | `/home/deploy/.openclaw/workspace/` |
| Baked binaries | `/usr/local/bin/` inside image |
| Logs | `docker compose logs -f openclaw-gateway` |
| Restart | `docker compose restart openclaw-gateway` |
| Rebuild after changes | `docker compose build && docker compose up -d` |
| Destroy & recreate | `docker compose down && docker compose up -d` (state survives on host) |

| Local alias | What it does |
|---|---|
| `ocs` | SSH into the VPS |
| `oct` / `octk` | Open / kill the SSH tunnel |
| `ocl` | Tail gateway logs |
| `ocst` | Gateway container status |
| `ocr` | Restart the gateway |
| `ocb` | Pull, build, relaunch |
| `och` | Quick health check |
| `ocdeploy` | Full deploy pipeline |
| `ocbackup` | Trigger a backup |
| `ocinfo` | Disk, memory, Docker status |
| `ocon` / `ocoff` | Power on/off the VPS via hcloud |
| `ocsnap` | Create a Hetzner snapshot |

---

## Phase 4 — Integrations (~45 min)

### 4A. Telegram Bot

**Goal:** Send/receive messages to OpenClaw via Telegram DM.

**1. Create the bot (local machine, one-time):**

```bash
# In Telegram, message @BotFather:
#   /newbot → pick a name → pick a username (must end in "bot")
#   Copy the HTTP API token it gives you
```

**2. Add token to VPS `.env`:**

```bash
ssh oc
echo 'TELEGRAM_BOT_TOKEN=123456:ABC-...' >> /home/deploy/.openclaw/.env
chmod 600 /home/deploy/.openclaw/.env
```

**3. Enable in OpenClaw config** (`settings.json` or `openclaw.json`):

```jsonc
{
  "channels": {
    "telegram": {
      "enabled": true,
      "dmPolicy": "pairing"          // requires approval on first contact
      // "customCommands": []         // optional slash commands
    }
  }
}
```

**4. Restart and pair:**

```bash
ssh oc
cd /home/deploy/.openclaw && docker compose restart

# In Telegram, send /start to your bot → receive a pairing code
# Approve it:
docker compose run --rm openclaw-cli pairing approve telegram <CODE>
```

**5. Verify:** Send a message to the bot and confirm a response.

**Notes:**
- Gateway uses grammY with long-polling (no inbound ports needed — works behind NAT/firewall)
- Draft streaming works in DMs if you enable "Threaded Mode" in @BotFather (`/mybots → Bot Settings → Group Settings → Threaded Mode`)
- Group messages require @mentioning the bot by default
- If Telegram API calls fail, check IPv6 routing: `curl -6 https://api.telegram.org` — disable IPv6 in Docker if broken

---

### 4B. 1Password (Service Account for Headless VPS)

**Goal:** Dedicated vault OpenClaw can read/write secrets from on a headless server.

The VPS has no desktop app, so use a **Service Account** instead of `op signin`.

**1. Create a dedicated vault (1password.com, one-time):**

- Log in → Vaults → New Vault → name it `OpenClaw`
- Add any initial secrets you want the agent to access

**2. Create a service account (1password.com):**

- Developer → Service Accounts → Create Service Account
- Name: `openclaw-vps`
- Grant access to the `OpenClaw` vault (read + write)
- **Save the token immediately** — it's shown only once
- Store the token in your personal 1Password vault for safekeeping

**3. Install `op` CLI on VPS:**

```bash
ssh oc

# Add 1Password APT repo
curl -sS https://downloads.1password.com/linux/keys/1password.asc | \
  sudo gpg --dearmor --output /usr/share/keyrings/1password-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/1password-archive-keyring.gpg] https://downloads.1password.com/linux/debian/$(dpkg --print-architecture) stable main" | \
  sudo tee /etc/apt/sources.list.d/1password-cli.list
sudo apt update && sudo apt install -y 1password-cli

op --version  # verify
```

**4. Add token to `.env`:**

```bash
# Append to the same .env file (never commit this)
echo 'OP_SERVICE_ACCOUNT_TOKEN=ops_eyJ...' >> /home/deploy/.openclaw/.env
chmod 600 /home/deploy/.openclaw/.env
```

**5. Verify from VPS:**

```bash
export OP_SERVICE_ACCOUNT_TOKEN=ops_eyJ...
op vault list                          # should show "OpenClaw"
op item list --vault OpenClaw          # should list items
```

**6. Usage patterns (how OpenClaw will call it):**

```bash
# Read a secret
op item get "My API Key" --vault OpenClaw --fields password

# Inject secrets into a template
op inject -i config.tpl -o config.yml

# Run a command with secrets in env
op run --env-file=secrets.env -- ./my-script.sh
```

**Security notes:**
- Service accounts **cannot** access Personal/Private/Employee vaults — only explicitly granted vaults
- Token can be revoked instantly from 1password.com → Developer → Service Accounts
- You can create up to 100 service accounts; one per deployment is fine
- Never paste secrets into logs/chat/code; prefer `op run` / `op inject`
- The OpenClaw `1password` skill is bundled — it will auto-detect `op` in PATH

---

### 4C. Notion

**Goal:** OpenClaw can create/read/update Notion pages and databases.

**1. Create an integration (one-time):**

- Go to [notion.so/my-integrations](https://notion.so/my-integrations)
- "New integration" → name it `OpenClaw` → select your workspace
- Copy the API key (starts with `ntn_` or `secret_`)

**2. Share pages with the integration:**

- Open any Notion page/database you want OpenClaw to access
- Click `...` → "Connect to" → select `OpenClaw`
- Repeat for each top-level page (children inherit access)

**3. Store API key on VPS:**

```bash
ssh oc
mkdir -p /home/deploy/.config/notion
echo "ntn_YOUR_KEY_HERE" > /home/deploy/.config/notion/api_key
chmod 600 /home/deploy/.config/notion/api_key
```

Make sure this path is mounted into the Docker container, or add to `.env`:

```bash
echo 'NOTION_API_KEY=ntn_YOUR_KEY_HERE' >> /home/deploy/.openclaw/.env
```

**4. Verify:**

```bash
export NOTION_API_KEY=$(cat /home/deploy/.config/notion/api_key)
curl -s https://api.notion.com/v1/users/me \
  -H "Authorization: Bearer $NOTION_API_KEY" \
  -H "Notion-Version: 2025-09-03" | jq .name
```

**5. Usage examples (what OpenClaw can do):**

```bash
# Search pages
curl -X POST https://api.notion.com/v1/search \
  -H "Authorization: Bearer $NOTION_API_KEY" \
  -H "Notion-Version: 2025-09-03" \
  -H "Content-Type: application/json" \
  -d '{"query": "meeting notes"}'

# Create a page
curl -X POST https://api.notion.com/v1/pages \
  -H "Authorization: Bearer $NOTION_API_KEY" \
  -H "Notion-Version: 2025-09-03" \
  -H "Content-Type: application/json" \
  -d '{
    "parent": {"page_id": "YOUR_PAGE_ID"},
    "properties": {"title": [{"text": {"content": "New Note"}}]},
    "children": [{"paragraph": {"rich_text": [{"text": {"content": "Hello from OpenClaw"}}]}}]
  }'
```

**Notes:**
- The `notion` skill is bundled in OpenClaw — auto-detected when API key is available
- API version `2025-09-03` is current (required in `Notion-Version` header)
- You must explicitly share each top-level page with the integration

---

### 4D. Email (Himalaya CLI via Gmail)

**Goal:** OpenClaw can send, read, search, and manage email from the terminal.

Himalaya is a CLI email client that speaks IMAP/SMTP. The OpenClaw `himalaya` skill is bundled and auto-activates when the binary is in PATH.

**Option A: Gmail with App Password (simpler)**

**1. Generate a Gmail App Password:**

- Go to [myaccount.google.com/apppasswords](https://myaccount.google.com/apppasswords)
- Requires 2FA enabled on the account
- Create an app password → copy the 16-char code

**2. Install Himalaya on VPS:**

```bash
ssh oc

# Download latest release
HIMALAYA_VERSION=$(curl -s https://api.github.com/repos/pimalaya/himalaya/releases/latest | grep tag_name | cut -d'"' -f4)
curl -sLo himalaya.tar.gz "https://github.com/pimalaya/himalaya/releases/download/${HIMALAYA_VERSION}/himalaya-$(uname -m)-unknown-linux-gnu.tar.gz"
tar xzf himalaya.tar.gz
sudo mv himalaya /usr/local/bin/
rm himalaya.tar.gz
himalaya --version
```

**3. Configure (`~/.config/himalaya/config.toml`):**

```toml
[accounts.openclaw]
email = "your-openclaw-email@gmail.com"
display-name = "OpenClaw Agent"
default = true

backend.type = "imap"
backend.host = "imap.gmail.com"
backend.port = 993
backend.encryption.type = "tls"
backend.login = "your-openclaw-email@gmail.com"
backend.auth.type = "password"
backend.auth.cmd = "op item get 'Gmail App Password' --vault OpenClaw --fields password"

message.send.backend.type = "smtp"
message.send.backend.host = "smtp.gmail.com"
message.send.backend.port = 465
message.send.backend.encryption.type = "tls"
message.send.backend.login = "your-openclaw-email@gmail.com"
message.send.backend.auth.type = "password"
message.send.backend.auth.cmd = "op item get 'Gmail App Password' --vault OpenClaw --fields password"
```

Note: The `auth.cmd` pulls the password from 1Password at runtime — no plaintext secrets on disk. Store the Gmail App Password in your `OpenClaw` 1Password vault first.

**4. Verify:**

```bash
export OP_SERVICE_ACCOUNT_TOKEN=ops_eyJ...
himalaya folder list                    # should show INBOX, [Gmail]/Sent Mail, etc.
himalaya envelope list                  # recent emails
```

**5. Send a test email:**

```bash
cat << 'EOF' | himalaya template send
From: your-openclaw-email@gmail.com
To: your-personal-email@example.com
Subject: Test from OpenClaw

Hello from the VPS!
EOF
```

**Option B: Dedicated agent email (recommended for isolation)**

Instead of using your personal Gmail, consider:

- **New Google account** just for OpenClaw (free, full IMAP/SMTP)
- **Fastmail** ($3/mo, excellent JMAP API, MCP server available)
- **Migadu** ($9/yr Micro plan, unlimited aliases, clean IMAP)
- **AgentMail** (agentmail.to — purpose-built email API for AI agents, worth evaluating)

The Himalaya config is identical regardless of provider — just change the host/port/login.

**Gmail folder aliases** (add to config if using Gmail):

```toml
folder.aliases.inbox = "INBOX"
folder.aliases.sent = "[Gmail]/Sent Mail"
folder.aliases.drafts = "[Gmail]/Drafts"
folder.aliases.trash = "[Gmail]/Trash"
```

---

### 4E. Integration Verification Checklist

Run these after all integrations are configured:

```bash
ssh oc
cd /home/deploy/.openclaw

# Source environment
set -a; source .env; set +a

# 1. Telegram
echo "Telegram token set: $([ -n "$TELEGRAM_BOT_TOKEN" ] && echo YES || echo NO)"

# 2. 1Password
op vault list 2>/dev/null && echo "1Password: OK" || echo "1Password: FAIL"

# 3. Notion
curl -s https://api.notion.com/v1/users/me \
  -H "Authorization: Bearer $NOTION_API_KEY" \
  -H "Notion-Version: 2025-09-03" | jq -r '.name // "FAIL"'

# 4. Email
himalaya folder list 2>/dev/null | head -3 && echo "Email: OK" || echo "Email: FAIL"

# 5. OpenCode Zen
curl -s https://opencode.ai/zen/v1/models \
  -H "Authorization: Bearer $OPENCODE_ZEN_API_KEY" | jq '.data | length' && echo "OpenCode Zen: OK"
```

---

## Phase 5 — OpenCode Zen & Model Routing (~15 min)

### 5A. OpenCode Zen Setup

**Goal:** Use OpenCode Zen as the model provider — cheaper than alternatives with free tier models available during beta.

OpenCode Zen provides curated, tested models optimized for coding agents. During beta, several models are free including Grok Code Fast 1 and GLM 4.7.

**1. Get your API key:**

- Sign up at [opencode.ai/zen](https://opencode.ai/zen)
- Add $20 balance to your account
- Copy your API key (starts with `ocz_...`)
- Auto-top-up at $5 when balance runs low

**2. Add key to VPS `.env`:**

```bash
ssh oc
echo 'OPENCODE_ZEN_API_KEY=ocz_...' >> /home/deploy/.openclaw/.env
chmod 600 /home/deploy/.openclaw/.env
```

---

### 5B. Model Configuration

**Your setup:** Kimi K2.5 primary, Grok for speed/tool-calling, Claude for complex reasoning.

Edit `~/.openclaw/openclaw.json` (or `/home/deploy/.openclaw/openclaw.json` on VPS):

```jsonc
{
  "env": {
    "OPENCODE_ZEN_API_KEY": "ocz_..."
  },
  "agents": {
    "defaults": {
      // Primary model with fallback chain (using FREE models)
      "model": {
        "primary": "zen/x-ai/grok-code-fast-1",
        "fallbacks": [
          "zen/zai/glm-4.7"
        ]
      },

      // Named models for quick /model switching
      "models": {
        "zen/x-ai/grok-code-fast-1":  { "alias": "grokcode" },
        "zen/x-ai/grok-4.1-fast":      { "alias": "grok" },
        "zen/zai/glm-4.7":             { "alias": "glm4" },
        "zen/anthropic/claude-sonnet-4-5": { "alias": "sonnet" },
        "zen/anthropic/claude-opus-4-5":   { "alias": "opus" },
        "zen/google/gemini-2.5-flash-lite": { "alias": "flash" },
        "zen/deepseek/deepseek-chat":   { "alias": "ds" }
      },

      // Free model for heartbeats (every 2 hours)
      "heartbeat": {
        "every": "2h",
        "model": "zen/zai/glm-4.7",
        "target": "last"
      },

      // Sub-agents use free model
      "subagents": {
        "model": "zen/x-ai/grok-code-fast-1",
        "maxConcurrent": 1,
        "archiveAfterMinutes": 60
      },

      // Vision tasks
      "imageModel": {
        "primary": "zen/x-ai/grok-code-fast-1",
        "fallbacks": ["zen/zai/glm-4.7"]
      },

      "contextTokens": 131072
    }
  }
}
```

---

### 5C. Model Slugs Quick Reference

| Alias | Model Slug | Cost | Best for |
|-------|-----------|------|----------|
| `grokcode` | `zen/x-ai/grok-code-fast-1` | **FREE** (beta) | Daily driver, coding, default |
| `glm4` | `zen/zai/glm-4.7` | **FREE** (beta) | Fallback, heartbeats |
| `grok` | `zen/x-ai/grok-4.1-fast` | ~$0.70/M | Tool calling, agentic tasks |
| `sonnet` | `zen/anthropic/claude-sonnet-4-5` | ~$18.00/M | Complex analysis, writing |
| `opus` | `zen/anthropic/claude-opus-4-5` | ~$30.00/M | Hardest problems only |
| `flash` | `zen/google/gemini-2.5-flash-lite` | ~$0.50/M | Simple lookups |
| `ds` | `zen/deepseek/deepseek-chat` | ~$0.53/M | Cheap fallback |

**Cost logic:** Use free models (grokcode, glm4) for 90% of tasks. Only upgrade to paid models (sonnet, opus) for tasks that genuinely need frontier reasoning.

---

### 5D. Switching Models on the Fly

From Telegram (or any channel), use the `/model` command:

```
/model              # show picker with all configured models
/model kimi         # switch back to Kimi (default)
/model grok         # switch to Grok 4.1 Fast
/model grokcode     # switch to Grok Code Fast (coding session)
/model sonnet       # switch to Claude Sonnet (complex task)
/model opus         # switch to Opus (hardest problems)
/model flash        # switch to Flash (quick questions, save money)
```

The alias names come from your config. Switch as needed — it applies to the current session.

---

### 5E. Cost Optimization Notes

**Why this config saves money:**

- **Heartbeats** run every 30 min and are pure overhead — Flash-Lite at $0.50/M vs Kimi at ~$1.10/M (or worse, Opus at $30/M)
- **Sub-agents** spawn for parallel tasks — Grok 4 Fast at $0.70/M is excellent value with strong tool calling
- **Fallbacks cross providers** — if Moonshot is down, it falls to xAI, then Anthropic. Different providers rarely go down simultaneously
- **You manually escalate** to Sonnet/Opus only when a task demands it via `/model`

**Rough monthly cost estimates:**

| Usage Level | Without tiering | With this config |
|------------|----------------|-----------------|
| Light (10 queries/day) | ~$50/mo | ~$15/mo |
| Moderate (30 queries/day) | ~$150/mo | ~$40/mo |
| Heavy (100 queries/day) | ~$500/mo | ~$100/mo |

**Note:** Free models (Grok Code Fast 1, GLM 4.7) are available during OpenCode Zen beta. These are reliable for production use. Paid models are available if you need additional capabilities.

---

### 5F. Verify OpenCode Zen is Working

```bash
ssh oc
cd /home/deploy/.openclaw

# Quick API test
curl -s https://opencode.ai/zen/v1/chat/completions \
  -H "Authorization: Bearer $OPENCODE_ZEN_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "x-ai/grok-code-fast-1",
    "messages": [{"role": "user", "content": "Say hello in 5 words"}]
  }' | jq '.choices[0].message.content'

# Check model availability
openclaw models status

# Live auth probe (uses real tokens)
openclaw models status --probe
```

Then restart the gateway and send a test message via Telegram:

```bash
docker compose restart
# In Telegram → send "What model are you?" to your bot
```
