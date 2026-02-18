# AGENTS.md — OpenClaw Hetzner Deployment

## Overview

This repository contains deployment scripts for running [OpenClaw](https://github.com/openclaw/openclaw) — an AI agent gateway — on a Hetzner VPS (~$5/month). Uses **OpenCode Zen** as the model provider (free tier available).

### What are Heartbeats?

Heartbeats are periodic check-ins OpenClaw does to maintain context and keep the agent "warm". By default they run every 30 minutes (48/day), which adds unnecessary cost. **Recommendation**: Set to `2h` (12/day) or disable entirely if you don't need continuous context.

## Quick Reference

| Task | Command |
|------|---------|
| Provision VPS | `hcloud server create --name openclaw --type cx22 --image ubuntu-24.04 --location fsn1 --ssh-key openclaw-key` |
| Bootstrap (root) | `ssh root@<IP> 'bash -s' < oc-bootstrap.sh` |
| Copy secrets script | `scp oc-load-secrets.sh deploy@<IP>:~/` |
| Load secrets (on VPS) | `ssh deploy@<IP> "source ~/oc-load-secrets.sh"` |
| Configure (deploy) | `ssh deploy@<IP> 'bash -s' < oc-configure.sh` |
| SSH to VPS | `ssh deploy@$(hcloud server ip openclaw)` |
| Open tunnel | `ssh -N -L 18789:127.0.0.1:18789 deploy@<IP>` |
| View logs | `ssh deploy@<IP> "cd ~/openclaw && docker compose logs -f openclaw-gateway"` |
| Restart gateway | `ssh deploy@<IP> "cd ~/openclaw && docker compose restart openclaw-gateway"` |
| Trigger backup | `sudo /usr/local/bin/openclaw-backup.sh` |
| Run health check | `ssh deploy@<IP> "~/openclaw/monitor.sh"` |
| View monitor logs | `ssh deploy@<IP> "tail -f /var/log/openclaw-monitor.log"` |

## Deployment Workflow

### Recommended Order

1. **Provision VPS** (one-time)
   ```bash
   hcloud server create --name openclaw --type cx22 --image ubuntu-24.04 --location fsn1 --ssh-key openclaw-key
   ```

2. **Bootstrap** (run as root on fresh VPS)
   ```bash
   ssh root@<IP> 'bash -s' < oc-bootstrap.sh
   ```
   This installs Docker, creates deploy user, builds OpenClaw v2026.2.6, and sets up security.

3. **Load Secrets** (run on VPS as deploy user)
   ```bash
   # First, copy the script to VPS
   scp oc-load-secrets.sh deploy@<IP>:~/
   
   # Then SSH in and run it
   ssh deploy@<IP>
   source ~/oc-load-secrets.sh
   ```

4. **Configure** (run on VPS)
   ```bash
   # Still on VPS from step 3, or:
   ssh deploy@<IP> 'bash -s' < oc-configure.sh
   ```

### Alternative: Load Secrets Locally First

If you prefer to run `oc-load-secrets.sh` on your local machine:

```bash
# On local machine
source ./oc-load-secrets.sh

# Create .env file with loaded secrets
cat > .env << EOF
OPENCODE_API_KEY=$OPENCODE_API_KEY
TELEGRAM_BOT_TOKEN=$TELEGRAM_BOT_TOKEN
OP_SERVICE_ACCOUNT_TOKEN=$OP_SERVICE_ACCOUNT_TOKEN
TAILSCALE_AUTH_KEY=$TAILSCALE_AUTH_KEY
EOF

# Copy to VPS
scp .env deploy@<IP>:~/openclaw/.env
```

**Note**: Running on the VPS is recommended because the secrets are immediately available without manual copying.

## Repository Structure

```
.
├── oc-bootstrap.sh              # Run once as root on fresh VPS
├── oc-configure.sh              # Run as deploy user to configure integrations
├── oc-load-secrets.sh           # (Optional) Load secrets from 1Password CLI
├── monitor.sh                   # Health monitoring (cron every 5 min)
├── openclaw.json.example        # OpenClaw configuration template (OpenCode Zen)
└── openclaw-hetzner-checklist.md # Complete deployment checklist
```

## Deployment Architecture

### Network Security
- **Gateway port**: 18789 bound to `127.0.0.1` only (not exposed to internet)
- **Access method**: SSH tunnel from local machine → VPS → container
- **Firewall**: UFW allows only SSH (22), denies everything else
- **SSH hardening**: Key-only auth, root login disabled, fail2ban active

### User Model
- `root`: Used only for initial bootstrap, then disabled
- `deploy`: Non-root user for running OpenClaw (member of `docker` group)
- Container runs as UID 1000 (`node` user inside)

### Data Persistence
All durable state lives on the host, not in containers:
- Config: `/home/deploy/.openclaw/openclaw.json`
- Workspace: `/home/deploy/.openclaw/workspace/`
- Secrets: `/home/deploy/openclaw/.env` (chmod 600)
- Backups: `/var/backups/openclaw/` (daily at 03:00 UTC)

## Key Configuration Files

### Environment Variables (.env)
Located at `/home/deploy/openclaw/.env`:
```bash
OPENCLAW_IMAGE=openclaw:v2026.2.6  # Use v2026.2.6 (v2026.2.9 has Telegram bug)
OPENCLAW_GATEWAY_TOKEN=<32-byte-hex>  # Save this! Used for web UI auth
OPENCLAW_GATEWAY_BIND=lan
OPENCLAW_GATEWAY_PORT=18789
OPENCLAW_CONFIG_DIR=/home/deploy/.openclaw
OPENCLAW_WORKSPACE_DIR=/home/deploy/.openclaw/workspace
GOG_KEYRING_PASSWORD=<32-byte-hex>
XDG_CONFIG_HOME=/home/node/.openclaw

# Added by oc-configure.sh (REQUIRED):
OPENCODE_API_KEY=sk-...  # OpenCode Zen API key
TELEGRAM_BOT_TOKEN=123456:ABC-...
OP_SERVICE_ACCOUNT_TOKEN=ops_eyJ...
TAILSCALE_AUTH_KEY=tskey-auth-...

# Optional:
NOTION_API_KEY=ntn_...
TODOIST_API_KEY=...
```

### OpenClaw Config (openclaw.json)
Located at `/home/deploy/.openclaw/openclaw.json`:
- **Provider**: OpenCode Zen (free tier available)
- Primary model: `opencode/kimi-k2.5` (recommended)
- Fallback model: `opencode/glm-4.7` (FREE)
- Heartbeat: Every **2 hours** (reduced from 30min to save costs)

## Integration Details

### 1. OpenCode Zen (Required)

OpenCode Zen provides curated models optimized for coding agents.

**Sign up**: https://opencode.ai/zen (create account, add $20 balance)

**Available Models** (use `opencode/` prefix):
| Model | Alias | Notes |
|-------|-------|-------|
| `opencode/kimi-k2.5` | kimi | Recommended primary model |
| `opencode/kimi-k2.5-free` | kimi-free | FREE tier |
| `opencode/glm-4.7` | glm4 | FREE, good fallback |
| `opencode/glm-5-free` | glm5 | FREE |
| `opencode/claude-sonnet-4-5` | sonnet | Paid |
| `opencode/claude-opus-4-6` | opus | Paid, best for complex tasks |
| `opencode/gemini-3-flash` | flash | Good for images |
| `opencode/gpt-5.1-codex` | codex | Great for coding |
| `opencode/minimax-m2.1-free` | - | FREE |
| `opencode/big-pickle` | - | FREE |

**IMPORTANT**: The model format is `opencode/<model>`, NOT `zen/x-ai/<model>`. Grok models are NOT available in OpenCode Zen.

### 2. Telegram Bot (REQUIRED)
- Create via @BotFather in Telegram
- Must be configured (script will fail without it)
- Pairing required: User sends any message, admin approves with pairing code
- Uses grammY with long-polling (works behind NAT/firewall)

### 3. 1Password (REQUIRED)
- Create Service Account at 1password.com → Developer → Service Accounts
- Grant access to dedicated "OpenClaw" vault only
- Service accounts cannot access Personal/Private vaults
- Use `op run` or `op inject` to avoid plaintext secrets
- **Required** for secure secret management (email passwords, API keys)

#### Pre-load Secrets with oc-load-secrets.sh

For faster configuration, use the `oc-load-secrets.sh` script to fetch secrets from 1Password before running `oc-configure.sh`:

**Setup:**
1. Install 1Password CLI: `brew install --cask 1password-cli` (macOS)
2. Create a vault named "OpenClaw" (or set `OP_VAULT` env var for custom name)
3. Add the following items to the vault (case-insensitive):
   - "opencode zen api key" (field: credential)
   - "telegram bot token" (field: credential)
   - "1password service account" (field: credential)
   - "tailscale auth key" (field: credential)
   - "notion api key" (field: credential) — optional
   - "google service account" (field: app password) — for email
4. Authenticate: `op signin` or export `OP_SERVICE_ACCOUNT_TOKEN`

**Usage:**
```bash
# Load secrets from 1Password
source ./oc-load-secrets.sh

# Run configure - will skip prompts for pre-loaded secrets
./oc-configure.sh
```

### 4. Tailscale (REQUIRED for Web UI)
- Provides secure access to the OpenClaw gateway
- No need to expose ports or manage SSH tunnels
- Web UI accessible at: `https://<hostname>.ts.net/?token=<GATEWAY_TOKEN>`

**Gateway Config for Tailscale:**
```json
{
  "gateway": {
    "controlUi": { "allowInsecureAuth": true },
    "trustedProxies": ["100.64.0.0/10"]
  }
}
```

### 5. Email via Himalaya (REQUIRED)
- CLI email client for IMAP/SMTP
- Supports Gmail (App Password), Fastmail, Migadu
- Config: `~/.config/himalaya/config.toml`
- **Required** for notifications and agent interactions
- App password stored in 1Password vault for security

### 6. Notion (Optional)
- Create integration at notion.so/my-integrations
- Must explicitly share each page with the integration
- API version: 2025-09-03

### 7. Todoist (Optional)
- Get API token at: https://todoist.com/prefs/integrations (under "Developer")
- REST API v2: https://api.todoist.com/rest/v2/
- Enables task tracking and project management via OpenClaw
- Store token in 1Password vault as "Todoist API Token" (field: credential)

## Known Issues & Workarounds

### Telegram Bug in v2026.2.9
OpenClaw v2026.2.9 has a bug where Telegram shows "configured, not enabled yet" and never starts polling.

**Workaround**: Use v2026.2.6 (built from source):
```bash
cd /tmp
curl -sL https://github.com/openclaw/openclaw/archive/refs/tags/v2026.2.6.tar.gz -o openclaw.tar.gz
tar xzf openclaw.tar.gz
cd openclaw-2026.2.6
docker build -t openclaw:v2026.2.6 .
```

Then set `OPENCLAW_IMAGE=openclaw:v2026.2.6` in `.env`.

### Web UI "pairing required" Error
If you get "disconnected (1008): pairing required", add to config:
```json
{
  "gateway": {
    "controlUi": { "allowInsecureAuth": true }
  }
}
```

### Web UI "untrusted proxy" Warning
For Tailscale access, add trusted proxies:
```json
{
  "gateway": {
    "trustedProxies": ["100.64.0.0/10"]
  }
}
```

### "unknown model" Error
Ensure model names use correct prefix:
- ✅ `opencode/kimi-k2.5` (correct)
- ❌ `zen/x-ai/grok-code-fast-1` (wrong - Grok not in OpenCode Zen)

## Local Development Aliases

Add to `~/.zshrc` or `~/.bashrc`:

```bash
export OPENCLAW_VPS="openclaw"
_oc_ip() { hcloud server ip "$OPENCLAW_VPS" 2>/dev/null; }

alias ocs='ssh deploy@$(_oc_ip)'
alias oct='ssh -f -N -L 18789:127.0.0.1:18789 deploy@$(_oc_ip) && echo "Tunnel open → http://127.0.0.1:18789/"'
alias octk='pkill -f "ssh -f -N -L 18789:127.0.0.1:18789" 2>/dev/null && echo "Tunnel closed"'
alias ocl='ssh deploy@$(_oc_ip) "cd ~/openclaw && docker compose logs -f --tail 100 openclaw-gateway"'
alias ocst='ssh deploy@$(_oc_ip) "cd ~/openclaw && docker compose ps openclaw-gateway"'
alias ocr='ssh deploy@$(_oc_ip) "cd ~/openclaw && docker compose restart openclaw-gateway"'
alias och='ssh deploy@$(_oc_ip) "curl -sf http://127.0.0.1:18789/ > /dev/null && echo ✅ || echo ❌"'
alias ocon='hcloud server poweron $OPENCLAW_VPS'
alias ocoff='hcloud server poweroff $OPENCLAW_VPS'
```

## Security Checklist

Before considering deployment complete:

- [ ] SSH key-only auth (password auth disabled)
- [ ] Root login disabled via SSH
- [ ] fail2ban active and monitoring SSH
- [ ] UFW enabled, only port 22 allowed
- [ ] Docker ports bound to 127.0.0.1 (not 0.0.0.0)
- [ ] `.env` file chmod 600, not in git
- [ ] No secrets in logs or shell history
- [ ] Container running as non-root (UID 1000)
- [ ] Automated backups tested manually
- [ ] Can SSH as deploy user from second terminal
- [ ] Health monitoring cron job configured

## Health Monitoring

The `monitor.sh` script runs every 5 minutes via cron and checks:
- Gateway container status
- HTTP response from gateway
- Heartbeat within last 3 hours

### What it does:
- **Auto-restarts** gateway if it's down
- **Sends Telegram alerts** to your paired chat if issues detected
- **Logs** to `/var/log/openclaw-monitor.log`

### Manual commands:
```bash
# Run health check manually
ssh deploy@<IP> "~/openclaw/monitor.sh"

# View monitor logs
ssh deploy@<IP> "tail -f /var/log/openclaw-monitor.log"

# Check cron job
ssh deploy@<IP> "crontab -l"
```

### Troubleshooting

If monitoring isn't working:
1. Check cron is running: `ssh deploy@<IP> "crontab -l"`
2. Check log file exists: `ssh deploy@<IP> "ls -la /var/log/openclaw-monitor.log"`
3. Run manually to debug: `ssh deploy@<IP> "bash -x ~/openclaw/monitor.sh"`

## Troubleshooting

### Gateway not responding
```bash
ssh deploy@<IP>
cd ~/openclaw
docker compose logs -f openclaw-gateway
docker compose ps
```

### Can't SSH after hardening
- Verify key is in `/home/deploy/.ssh/authorized_keys`
- Check `/var/log/auth.log` on VPS
- Ensure `AllowUsers deploy` in `/etc/ssh/sshd_config`

### Telegram bot not responding
- Check token: `curl https://api.telegram.org/bot<TOKEN>/getMe`
- Verify IPv6 routing if on Hetzner: `curl -6 https://api.telegram.org`
- Check gateway logs for pairing requests
- Ensure using v2026.2.6 (v2026.2.9 has Telegram bug)

### 1Password not working
- Verify service account token: `op vault list`
- Ensure token has access to correct vault
- Service accounts can't access Personal vaults

### Model errors
- Check available models: `curl -sf https://opencode.ai/zen/v1/models -H "Authorization: Bearer $OPENCODE_API_KEY" | jq -r '.data[].id'`
- Ensure model format is `opencode/<model>`

## Maintenance

### Rotate gateway token
```bash
NEW_TOKEN=$(openssl rand -hex 32)
# Update .env with new OPENCLAW_GATEWAY_TOKEN
cd ~/openclaw && docker compose up -d --force-recreate openclaw-gateway
```

### Update OpenClaw
```bash
ssh deploy@<IP>
cd ~/openclaw
git pull --ff-only
docker compose build
docker compose up -d openclaw-gateway
```

### Restore from backup
```bash
# List available backups
ls -lh /var/backups/openclaw/

# Extract to restore
tar -xzf /var/backups/openclaw/openclaw-YYYY-MM-DD-HHMMSS.tar.gz -C /
# This restores /home/deploy/.openclaw/
```

## Cost Estimates

**With OpenCode Zen** (using free tier models + reduced heartbeats):

| Usage | Monthly Cost | Notes |
|-------|-------------|-------|
| Light (10 queries/day) | **$0-5** | Free models sufficient |
| Moderate (30 queries/day) | **$5-15** | Mix of free + paid models |
| Heavy (100 queries/day) | **$15-30** | Mostly paid models |

VPS: ~$5/month (Hetzner cx22)

**Total estimated**: $5-35/month (VPS + API usage)

## References

- OpenClaw: https://github.com/openclaw/openclaw
- Documentation: https://docs.openclaw.ai/platforms/hetzner
- Hetzner Cloud: https://console.hetzner.cloud
- OpenCode Zen: https://opencode.ai/zen
- OpenCode Zen Models: https://docs.openclaw.ai/providers/opencode
