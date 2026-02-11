# OpenClaw Hetzner Deployment

Deploy [OpenClaw](https://github.com/openclaw/openclaw) — an AI agent gateway — on a $5/month Hetzner VPS with sensible defaults and cost-optimized configuration.

## What This Does

This repo provides automated scripts to:

1. **Provision a secure VPS** on Hetzner Cloud with hardened SSH, firewall, and fail2ban
2. **Deploy OpenClaw Gateway** as a Docker container with persistent state
3. **Configure integrations** using free/cheap AI models via OpenCode Zen
4. **Set up secure secret management** with 1Password integration
5. **Enable notifications** via Telegram bot and email (Himalaya CLI)

## Quick Start

```bash
# 1. Provision VPS (install hcloud CLI first)
hcloud server create --name openclaw --type cx22 --image ubuntu-24.04 \
  --location fsn1 --ssh-key your-key

# 2. Bootstrap the server (run as root)
ssh root@$(hcloud server ip openclaw) 'bash -s' < oc-bootstrap.sh

# 3a. (Optional) Load secrets from 1Password
source ./oc-load-secrets.sh  # Pre-load secrets to skip manual entry

# 3b. Configure integrations (run as deploy user)
ssh deploy@$(hcloud server ip openclaw) 'bash -s' < oc-configure.sh

# 4. Open SSH tunnel to access gateway
ssh -N -L 18789:127.0.0.1:18789 deploy@$(hcloud server ip openclaw)

# 5. Access OpenClaw at http://localhost:18789
```

## Why This Setup?

### Cost Optimization

| Component | Cost |
|-----------|------|
| **Model Provider** (OpenCode Zen) | **$0-15/month** |
| **VPS** (Hetzner cx22) | $5/month |
| **Total** | **$5-20/month** |

Cost savings achieved by:
- Using OpenCode Zen (free models during beta: Grok Code Fast 1, GLM 4.7)
- Reducing heartbeat frequency from 30min to 2h (75% fewer API calls)
- No platform fees

### Security-First Design

- **SSH hardening**: Key-only auth, root disabled, fail2ban monitoring
- **Network isolation**: Gateway only accessible via SSH tunnel (port 18789 bound to localhost)
- **Secret management**: All credentials stored in 1Password, never in plaintext
- **Automatic backups**: Daily encrypted backups of all state
- **Security updates**: Unattended-upgrades enabled

## Architecture

```
┌─────────────────┐
│   Your Laptop   │
│  (SSH tunnel)   │
└────────┬────────┘
         │
         ▼
┌─────────────────┐     ┌─────────────────┐
│  Hetzner VPS    │────▶│  1Password      │
│  Ubuntu 24.04   │     │  (secrets)      │
│  - Docker       │     └─────────────────┘
│  - UFW firewall │
│  - fail2ban     │     ┌─────────────────┐
└────────┬────────┘────▶│  OpenCode Zen   │
         │              │  (AI models)    │
         ▼              └─────────────────┘
┌─────────────────┐
│ OpenClaw Gateway│     ┌─────────────────┐
│  - Telegram bot │────▶│  Telegram API   │
│  - Email (SMTP) │     └─────────────────┘
│  - Notion API   │
└─────────────────┘     ┌─────────────────┐
                        │  Gmail/Fastmail │
                        │  (IMAP/SMTP)    │
                        └─────────────────┘
```

## Required Integrations

Scripts will prompt for these required credentials:

1. **OpenCode Zen API key** — Model provider (free tier available)
2. **Telegram bot token** — Chat interface (@BotFather)
3. **1Password service account** — Secure secret storage
4. **Email account** — Gmail/Fastmail with app password
5. **Tailscale auth key** — Secure network access (generate at https://login.tailscale.com/admin/settings/keys)

### Generating a Tailscale Auth Key

To create a reusable Tailscale auth key:

1. Visit https://login.tailscale.com/admin/settings/keys
2. Click "Generate auth key"
3. Enable "Reusable" option for deploying multiple servers
4. Optionally set an expiration (or leave as ephemeral for testing)
5. Copy the auth key (format: `tskey-auth-xxxxx`)
6. Store it in 1Password or provide it when prompted during configuration

## Optional Integrations

6. **Notion API key** — Document management (can skip)

## 1Password Integration (Optional but Recommended)

For faster setup and centralized secret management, you can use the `oc-load-secrets.sh` script to fetch credentials from 1Password CLI:

### Setup

1. **Create a 1Password vault** named `OpenClaw` (or use `OP_VAULT` env var for custom name)
2. **Add these items to the vault:**
   - "OpenCode Zen API Key" (field: credential)
   - "Telegram Bot Token" (field: credential)
   - "1Password Service Account" (field: credential)
   - "Tailscale Auth Key" (field: credential)
   - "Notion API Key" (field: credential) — optional
   - "Email App Password" (field: password) — used by Himalaya at runtime
3. **Install 1Password CLI**: https://developer.1password.com/docs/cli/get-started/
4. **Authenticate**: `op signin` or export `OP_SERVICE_ACCOUNT_TOKEN`

### Usage

```bash
# Load secrets from 1Password before configuring
source ./oc-load-secrets.sh

# Now run configure - it will use the pre-loaded secrets
./oc-configure.sh
```

**Benefits:**
- Skip manual secret entry during configuration
- Centralized secret storage and rotation
- Audit trail of secret access
- Share secrets securely with team members

## Repository Structure

```
.
├── oc-bootstrap.sh           # Run once as root on fresh VPS
├── oc-configure.sh           # Run as deploy user for integrations
├── oc-load-secrets.sh        # (Optional) Load secrets from 1Password CLI
├── openclaw.json.example     # Gateway configuration template
├── lint-scripts.sh           # ShellCheck linting
├── AGENTS.md                 # Detailed documentation
└── .github/workflows/        # CI/CD for script validation
```

## Development

```bash
# Validate bash scripts
./lint-scripts.sh

# Run tests locally
shellcheck oc-bootstrap.sh oc-configure.sh
```

## Documentation

- [AGENTS.md](AGENTS.md) — Complete deployment guide, cost breakdown, troubleshooting
- [openclaw-hetzner-checklist.md](openclaw-hetzner-checklist.md) — Step-by-step terminal checklist
- [OpenClaw Docs](https://docs.openclaw.ai) — Official OpenClaw documentation

## License

MIT — See repository for details.

---

**Note**: This is a deployment template. Review and customize scripts for your specific security requirements before production use.
