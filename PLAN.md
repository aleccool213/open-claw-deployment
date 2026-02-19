# Plan: Remove Docker from Bootstrap

## Background

Currently, `oc-bootstrap.sh` installs Docker, clones OpenClaw source, builds a Docker image from the Dockerfile, and runs the gateway with `docker compose up`. This makes secrets and configuration awkward because env vars must be threaded through Docker rather than being available directly on the VPS.

The goal is to run OpenClaw directly on the VPS using the official installer + a systemd service. This means:
- Secrets in `~/.openclaw/.env` are sourced directly by systemd — no volume mounts or Docker env plumbing needed.
- `oc-load-secrets.sh` writes to the same `.env` file that OpenClaw reads at startup.
- Updates are `npm update -g openclaw` rather than rebuilding an image.

## Research Findings

From official docs and community guides:
- OpenClaw requires **Node.js >= 22**
- Official installer: `curl -fsSL https://openclaw.ai/install.sh | bash`
- Key env vars (bare metal):
  - `OPENCLAW_HOME` — base directory for state
  - `OPENCLAW_STATE_DIR` — mutable state (overrides OPENCLAW_HOME for state)
  - `OPENCLAW_CONFIG_PATH` — path to `openclaw.json`
  - `OPENCLAW_GATEWAY_TOKEN` — gateway auth token (unchanged)
  - `OPENCLAW_GATEWAY_PORT` — port (unchanged, 18789)
  - `OPENCLAW_GATEWAY_BIND` — change from `lan` to `loopback` (bare metal, no Docker network)
  - `GOG_KEYRING_PASSWORD` — keyring password (unchanged)
- Gateway runs as a systemd service: `systemctl start openclaw`
- Logs via: `journalctl -u openclaw -f`
- Pairing command changes from `docker compose run --rm openclaw-cli pairing approve` to just `openclaw pairing approve`

## Files That Change

### 1. `oc-bootstrap.sh` — Major rework

**Phase 1 (currently "Installing Docker") → "Installing Node.js 22"**
- Remove: `curl https://get.docker.com | sh`, Docker Compose verification
- Add: Install Node.js 22 via NodeSource (`curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && apt-get install -y nodejs`)
- Add: Verify `node -v` and `npm -v`

**Phase 2 (currently "Building OpenClaw from Docker source") → "Installing OpenClaw via official installer"**
- Remove: Downloading source tarball, `docker build`, `chown -R 1000:1000`
- Remove: `usermod -aG docker deploy`
- Add: Run official installer as `deploy` user: `sudo -u deploy bash -c 'curl -fsSL https://openclaw.ai/install.sh | bash -s -- --no-onboard'`
- The `--no-onboard` flag skips interactive onboarding (we configure via `openclaw.json`)
- This installs the `openclaw` binary into the deploy user's path

**Phase 3 (persistent directories & .env) — Update env vars**
- Remove Docker-specific vars: `OPENCLAW_IMAGE`, `XDG_CONFIG_HOME=/home/node/.openclaw`
- Change: `OPENCLAW_GATEWAY_BIND=lan` → `OPENCLAW_GATEWAY_BIND=loopback`
- Change: `OPENCLAW_CONFIG_DIR` → `OPENCLAW_HOME` (points to `~/.openclaw`)
- Remove: `OPENCLAW_WORKSPACE_DIR` (handled by `OPENCLAW_HOME`)
- Keep: `OPENCLAW_GATEWAY_TOKEN`, `OPENCLAW_GATEWAY_PORT`, `GOG_KEYRING_PASSWORD`
- Add: `OPENCLAW_CONFIG_PATH=/home/deploy/.openclaw/openclaw.json`
- New env file location: `/home/deploy/.openclaw/.env` (instead of `~/openclaw/.env`)
- `chown deploy:deploy` instead of `chown 1000:1000` (no Docker UID mapping needed)

**Phase 4 (currently "Building & launching gateway via docker compose") → "Creating systemd service"**
- Remove: `docker build`, `docker compose up -d`, `docker compose ps` checks
- Add: Create `/etc/systemd/system/openclaw.service`:
  ```
  [Unit]
  Description=OpenClaw Gateway
  After=network.target
  Wants=network.target

  [Service]
  Type=simple
  User=deploy
  EnvironmentFile=/home/deploy/.openclaw/.env
  ExecStart=/home/deploy/.local/bin/openclaw gateway start
  Restart=on-failure
  RestartSec=10
  NoNewPrivileges=true
  PrivateTmp=true

  [Install]
  WantedBy=multi-user.target
  ```
- Add: `systemctl daemon-reload && systemctl enable --now openclaw`
- Add: Health check via `systemctl is-active openclaw` and `curl -sf http://127.0.0.1:18789/`

**Summary section update**
- Change "Docker + OpenClaw gateway running" → "OpenClaw gateway running via systemd"
- Update next steps (no docker compose commands)

### 2. `oc-configure.sh` — Minor updates

- **Gateway restart**: `docker compose restart openclaw-gateway` → `sudo systemctl restart openclaw`
- **Gateway status check**: `docker compose ps | grep -q "Up"` → `systemctl is-active --quiet openclaw`
- **Failure message**: Update to reference `journalctl -u openclaw` instead of `docker compose logs`
- **Pairing instructions**: Change from `docker compose run --rm openclaw-cli pairing approve telegram <CODE>` → `openclaw pairing approve telegram <CODE>`
- **Env file path**: Update reference from `~/openclaw/.env` to `~/.openclaw/.env`
- **Config dir reference**: Update `OPENCLAW_DIR` usage (no longer needed for docker compose commands)

## Files That Stay the Same

- Security hardening phases (SSH, UFW, fail2ban, unattended-upgrades) — no change
- Tailscale installation and configuration — no change
- Automated backup system — no change (still backs up `~/.openclaw`)
- `oc-load-secrets.sh` — no change (it writes to `.env`, still works)
- `oc-provision.sh` — no change
- `openclaw.json` / `openclaw.json.example` — no change (config format is the same)

## Files Deleted

- `monitor.sh` — removed entirely; OpenClaw has built-in heartbeats and health monitoring

## Sequence of Implementation

1. Update `oc-bootstrap.sh` (major changes)
2. Update `oc-configure.sh` (minor changes)
3. Update documentation strings in `README.md` and `AGENTS.md` if needed
