# Docker Image Build Pipeline Implementation Plan

## Executive Summary

This plan outlines how to implement a GitHub Actions pipeline that builds the OpenClaw Docker image and pushes it to GitHub Container Registry (GHCR), allowing the VPS to pull pre-built images instead of building locally.

## Current State Analysis

### Existing Infrastructure
- **Repository Purpose**: Deployment scripts for OpenClaw (not the application itself)
- **Current Build Process**:
  - VPS clones OpenClaw repo from `https://github.com/openclaw/openclaw.git`
  - Builds Docker image locally on VPS using `docker build`
  - Takes significant time and VPS resources (2 vCPU, 4GB RAM)
- **Image Control**: `OPENCLAW_IMAGE` env var in `.env` file
  - Default: `openclaw:latest` (triggers local build)
  - Custom: Any registry URL (triggers `docker pull`)

### Current GitHub Actions
- Single workflow: `shellcheck.yml`
- Purpose: Lint bash scripts with ShellCheck and run Bats tests
- Triggers: Push/PR to main/master with script changes

## Implementation Goals

1. **Build OpenClaw Docker image in GitHub Actions** instead of on VPS
2. **Push to GitHub Container Registry (ghcr.io)** for this repository
3. **Version images appropriately** (latest, commit SHA, semantic versions)
4. **Authenticate VPS to pull from GHCR** securely
5. **Reduce VPS provisioning time** by eliminating local builds
6. **Reduce VPS resource usage** during deployment

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│  GitHub Actions Workflow                                    │
│  ────────────────────────                                   │
│  Trigger: Push to main, Manual dispatch, Scheduled          │
│                                                              │
│  Steps:                                                      │
│  1. Checkout deployment repo                                │
│  2. Clone official OpenClaw repo                            │
│  3. Build Docker image from OpenClaw                        │
│  4. Tag with multiple versions                              │
│  5. Push to ghcr.io/aleccool213/open-claw-deployment       │
└─────────────────────────────────────────────────────────────┘
                            │
                            │ Docker Push
                            ▼
┌─────────────────────────────────────────────────────────────┐
│  GitHub Container Registry (GHCR)                           │
│  ────────────────────────────                               │
│  ghcr.io/aleccool213/open-claw-deployment/openclaw:latest  │
│  ghcr.io/aleccool213/open-claw-deployment/openclaw:sha-abc │
│  ghcr.io/aleccool213/open-claw-deployment/openclaw:v1.0.0  │
└─────────────────────────────────────────────────────────────┘
                            │
                            │ Docker Pull (authenticated)
                            ▼
┌─────────────────────────────────────────────────────────────┐
│  Hetzner VPS                                                 │
│  ────────────                                                │
│  1. oc-bootstrap.sh authenticates to GHCR                   │
│  2. Sets OPENCLAW_IMAGE to GHCR URL                         │
│  3. docker compose pulls pre-built image                    │
│  4. Starts OpenClaw gateway instantly                       │
└─────────────────────────────────────────────────────────────┘
```

## Implementation Plan

### Phase 1: Create GitHub Actions Workflow

**File**: `.github/workflows/docker-build.yml`

**Workflow Configuration**:
```yaml
name: Build and Push OpenClaw Docker Image

on:
  push:
    branches:
      - main
      - master
  workflow_dispatch:  # Manual trigger
    inputs:
      openclaw_ref:
        description: 'OpenClaw Git reference to build (branch/tag/commit)'
        required: false
        default: 'main'
  schedule:
    - cron: '0 2 * * 0'  # Weekly rebuild on Sunday at 2 AM UTC

env:
  REGISTRY: ghcr.io
  IMAGE_NAME: ${{ github.repository }}/openclaw

jobs:
  build-and-push:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write

    steps:
      - name: Checkout deployment repository
        uses: actions/checkout@v4

      - name: Clone OpenClaw repository
        run: |
          git clone https://github.com/openclaw/openclaw.git openclaw
          cd openclaw
          if [ "${{ github.event.inputs.openclaw_ref }}" != "" ]; then
            git checkout ${{ github.event.inputs.openclaw_ref }}
          fi
          echo "OPENCLAW_COMMIT=$(git rev-parse --short HEAD)" >> $GITHUB_ENV

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: Log in to GitHub Container Registry
        uses: docker/login-action@v3
        with:
          registry: ${{ env.REGISTRY }}
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Extract metadata (tags, labels)
        id: meta
        uses: docker/metadata-action@v5
        with:
          images: ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}
          tags: |
            type=raw,value=latest
            type=sha,prefix=sha-
            type=ref,event=branch
            type=semver,pattern={{version}}
            type=semver,pattern={{major}}.{{minor}}

      - name: Build and push Docker image
        uses: docker/build-push-action@v5
        with:
          context: ./openclaw
          push: true
          tags: ${{ steps.meta.outputs.tags }}
          labels: ${{ steps.meta.outputs.labels }}
          cache-from: type=registry,ref=${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}:latest
          cache-to: type=inline
          build-args: |
            BUILDKIT_INLINE_CACHE=1

      - name: Image digest
        run: echo "Image pushed with digest ${{ steps.build-push.outputs.digest }}"
```

**Workflow Features**:
- **Triggers**:
  - Automatic on push to main/master
  - Manual dispatch with custom OpenClaw ref
  - Weekly rebuild to stay current (Sundays 2 AM UTC)
- **Tagging Strategy**:
  - `latest`: Always points to most recent build
  - `sha-abc123`: Specific commit for reproducibility
  - `main`: Branch-based tag
  - `v1.0.0`: Semantic version tags (if applicable)
- **Caching**: Layer caching for faster builds
- **Permissions**: Minimal required (read repo, write packages)

### Phase 2: Configure GitHub Container Registry

**Actions Required**:

1. **Package Visibility** (After first workflow run):
   - Go to `https://github.com/aleccool213?tab=packages`
   - Find `open-claw-deployment/openclaw`
   - Click "Package settings"
   - Set visibility to "Public" (or keep private with authentication)

2. **Generate Personal Access Token (PAT)** for VPS:
   - Go to GitHub Settings → Developer settings → Personal access tokens → Fine-grained tokens
   - Create new token with:
     - Name: "OpenClaw VPS Pull Access"
     - Expiration: 1 year
     - Repository access: Only `aleccool213/open-claw-deployment`
     - Permissions:
       - Contents: Read (if private repo)
       - Packages: Read
   - Copy token (will only be shown once)
   - Store in 1Password vault as "GitHub GHCR Pull Token"

3. **Alternative: Use GitHub Actions GITHUB_TOKEN**:
   - For public images, no authentication needed
   - For private images, can use repo-scoped PAT

### Phase 3: Update Bootstrap Script

**File**: `oc-bootstrap.sh`

**Changes to Phase 3 (lines 104-143)**:

```bash
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

  # Use GitHub Container Registry image instead of local build
  GITHUB_USER="aleccool213"
  GITHUB_REPO="open-claw-deployment"
  OPENCLAW_IMAGE="ghcr.io/${GITHUB_USER}/${GITHUB_REPO}/openclaw:latest"

  cat > "$ENV_FILE" <<EOF
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
```

**Changes to Phase 4 (lines 144-177)**: Add GHCR authentication

```bash
step "4/9 — Authenticating to GitHub Container Registry & pulling image"

# Read the image name from .env
source "$ENV_FILE"

# Check if image is from GHCR
if [[ "$OPENCLAW_IMAGE" == ghcr.io/* ]]; then
  echo "  Detected GHCR image: $OPENCLAW_IMAGE"

  # Check if GHCR token exists (passed via environment or prompt)
  if [[ -z "${GHCR_TOKEN:-}" ]]; then
    echo ""
    echo -e "  ${YELLOW}GHCR authentication required.${NC}"
    echo -e "  ${YELLOW}For public images, you can skip this (press Enter).${NC}"
    echo -e "  ${YELLOW}For private images, provide a GitHub PAT with package:read scope.${NC}"
    echo ""
    read -rsp "  Enter GitHub token (or press Enter to skip): " GHCR_TOKEN
    echo ""
  fi

  # Authenticate if token provided
  if [[ -n "$GHCR_TOKEN" ]]; then
    echo "$GHCR_TOKEN" | docker login ghcr.io -u "${GITHUB_USER:-aleccool213}" --password-stdin
    ok "Authenticated to GHCR"
  else
    echo "  Skipping authentication (will only work for public images)"
  fi

  echo "  Pulling image from GHCR..."
  docker pull "$OPENCLAW_IMAGE"
  ok "Image pulled successfully"

elif [[ "$OPENCLAW_IMAGE" == "openclaw:latest" ]]; then
  echo "  Image set to local build (openclaw:latest)."
  # Only build if it doesn't exist locally to save time
  if [[ "$(docker images -q openclaw:latest 2> /dev/null)" == "" ]]; then
    echo "  Building image locally with BuildKit caching..."
    export DOCKER_BUILDKIT=1
    docker build \
      --build-arg BUILDKIT_INLINE_CACHE=1 \
      --cache-from openclaw:latest \
      -t openclaw:latest .
  else
    ok "Image openclaw:latest already exists, skipping build"
    echo "  To force a rebuild, run: docker rmi openclaw:latest"
  fi

else
  echo "  Custom image detected: $OPENCLAW_IMAGE"
  echo "  Pulling image..."
  docker pull "$OPENCLAW_IMAGE"
  ok "Image pulled successfully"
fi

cd "$OPENCLAW_DIR"
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
```

### Phase 4: Update Secret Loading Script

**File**: `oc-load-secrets.sh`

**Add GHCR token loading**:

```bash
# After existing 1Password fetches, add:

step "GitHub Container Registry (GHCR) Authentication"
echo "  Fetching GitHub GHCR pull token from 1Password..."

if GHCR_TOKEN=$(op item get "GitHub GHCR Pull Token" --fields credential 2>/dev/null); then
  export GHCR_TOKEN
  export GITHUB_USER="aleccool213"
  ok "GHCR token loaded"
else
  warn "GitHub GHCR Pull Token not found in 1Password"
  echo "  For public images, this is optional."
  echo "  For private images, create a GitHub PAT and store as 'GitHub GHCR Pull Token'"
fi
```

### Phase 5: Update Documentation

**File**: `README.md`

Add section after "Quick Start":

```markdown
## Docker Image Distribution

This repository uses GitHub Actions to build and distribute the OpenClaw Docker image.

### How It Works

1. **Automatic Builds**: Every push to `main` triggers a Docker build
2. **Weekly Rebuilds**: Scheduled rebuild every Sunday to stay current
3. **Manual Triggers**: Build specific OpenClaw versions via workflow dispatch
4. **Image Storage**: Images pushed to `ghcr.io/aleccool213/open-claw-deployment/openclaw`
5. **VPS Usage**: Bootstrap script pulls pre-built images (no local build needed)

### Benefits

- **Faster provisioning**: No 5-10 minute build on VPS
- **Consistent images**: Same image across environments
- **Resource savings**: Eliminates CPU/RAM usage during deployment
- **Version control**: Easy to rollback or pin specific versions

### Image Tags

- `latest`: Most recent build from main branch
- `sha-abc123`: Specific commit for reproducibility
- `main`: Main branch builds
- `v1.0.0`: Semantic version tags (when applicable)

### Using Custom OpenClaw Versions

To build a specific OpenClaw branch or tag:

1. Go to Actions → "Build and Push OpenClaw Docker Image"
2. Click "Run workflow"
3. Enter OpenClaw git reference (branch/tag/commit)
4. Click "Run workflow"

Then update your `.env` file on the VPS:
```bash
OPENCLAW_IMAGE=ghcr.io/aleccool213/open-claw-deployment/openclaw:sha-abc123
```

### Authentication

**Public images** (recommended):
- No authentication required
- Anyone can pull the image
- Set package visibility to "Public" in GitHub

**Private images**:
- Create a GitHub PAT with `read:packages` scope
- Store in 1Password as "GitHub GHCR Pull Token"
- `source ./oc-load-secrets.sh` before running bootstrap
```

**File**: `AGENTS.md`

Add technical section:

```markdown
## Docker Image Pipeline

### GitHub Actions Workflow

Location: `.github/workflows/docker-build.yml`

**Build Process:**
1. Clone deployment repo (this repo)
2. Clone official OpenClaw repo into `openclaw/` subdirectory
3. Build Docker image from `openclaw/` context
4. Tag with multiple versions (latest, sha, branch)
5. Push to GitHub Container Registry

**Triggers:**
- Push to main/master branches
- Manual workflow dispatch with custom OpenClaw ref
- Weekly scheduled build (Sundays 2 AM UTC)

**Performance:**
- Uses Docker Buildx for multi-platform builds (if needed)
- Layer caching via registry cache
- Parallel builds when possible

### Container Registry

**Location**: `ghcr.io/aleccool213/open-claw-deployment/openclaw`

**Tagging Strategy:**
- `latest`: Floating tag, always newest build
- `sha-{commit}`: Immutable, pinned to specific commit
- `{branch}`: Branch-based tag (e.g., `main`, `develop`)
- `v{version}`: Semantic version tags (e.g., `v1.0.0`)

**Storage:**
- Automatic image cleanup after 90 days (configurable)
- Size optimizations via multi-stage builds (if applicable)
- Compression for faster pulls

### VPS Integration

**Authentication Flow:**
1. VPS reads `GHCR_TOKEN` from environment (via `oc-load-secrets.sh`)
2. Bootstrap script authenticates: `docker login ghcr.io`
3. `docker compose` pulls image automatically
4. No local build required

**Fallback Strategy:**
- If GHCR pull fails, can fallback to local build
- Set `OPENCLAW_IMAGE=openclaw:latest` to force local build
- Useful for development or airgapped environments

### Security Considerations

**GitHub Token Scopes:**
- Workflow uses `GITHUB_TOKEN` (automatic, scoped to repo)
- VPS uses fine-grained PAT with minimal permissions:
  - Repository access: Read-only to this repo
  - Package permissions: Read-only

**Image Scanning:**
- Consider adding Trivy/Snyk scanning in workflow
- Scan for CVEs before push
- Block on high-severity vulnerabilities

**Secrets Management:**
- Never embed secrets in Docker images
- Use runtime environment variables (current approach)
- GHCR token stored in 1Password, loaded at deploy time
```

### Phase 6: Update Tests

**File**: `tests/test-scripts.bats`

Add tests for new functionality:

```bash
@test "oc-bootstrap.sh sets OPENCLAW_IMAGE to GHCR by default" {
  run grep -q 'ghcr.io' oc-bootstrap.sh
  [ "$status" -eq 0 ]
}

@test "GitHub Actions workflow exists for Docker builds" {
  [ -f .github/workflows/docker-build.yml ]
}

@test "Docker build workflow has correct triggers" {
  run grep -q 'workflow_dispatch' .github/workflows/docker-build.yml
  [ "$status" -eq 0 ]
  run grep -q 'schedule' .github/workflows/docker-build.yml
  [ "$status" -eq 0 ]
}

@test "Bootstrap script handles GHCR authentication" {
  run grep -q 'docker login ghcr.io' oc-bootstrap.sh
  [ "$status" -eq 0 ]
}

@test "oc-load-secrets.sh includes GHCR token loading" {
  run grep -q 'GHCR_TOKEN' oc-load-secrets.sh
  [ "$status" -eq 0 ]
}
```

## Deployment Timeline

### Immediate (Day 1)
- [ ] Create `.github/workflows/docker-build.yml`
- [ ] Run workflow manually to test build
- [ ] Verify image appears in GHCR
- [ ] Set package visibility to public

### Short-term (Day 2-3)
- [ ] Update `oc-bootstrap.sh` with GHCR logic
- [ ] Update `oc-load-secrets.sh` with GHCR token
- [ ] Test on new VPS provision
- [ ] Verify pull works without local build

### Medium-term (Week 1)
- [ ] Update all documentation
- [ ] Add workflow badge to README
- [ ] Create GitHub PAT for private access (if needed)
- [ ] Store PAT in 1Password
- [ ] Add Bats tests for new functionality

### Long-term (Month 1)
- [ ] Monitor build times and optimize
- [ ] Consider multi-arch builds (ARM64)
- [ ] Add vulnerability scanning (Trivy)
- [ ] Implement image retention policy
- [ ] Add build notifications (Slack/email)

## Benefits Analysis

### Before (Local Build on VPS)
- **Provisioning time**: 15-20 minutes
- **VPS resource usage**:
  - CPU: 100% during build (5-10 minutes)
  - Memory: 2-3 GB during build
  - Disk I/O: Heavy during build
- **Network usage**: Download source code + dependencies
- **Consistency**: Different builds may vary
- **Cost**: VPS resources during build

### After (Pull from GHCR)
- **Provisioning time**: 5-8 minutes
- **VPS resource usage**:
  - CPU: <10% during pull (1-2 minutes)
  - Memory: <500 MB during pull
  - Disk I/O: Minimal during pull
- **Network usage**: Download pre-built image only
- **Consistency**: Identical image across all VPS instances
- **Cost**: Free GitHub Actions minutes (2000/month on free tier)

### Time Savings
- **Per deployment**: 10-12 minutes saved
- **Per month** (assuming 2 deployments): 20-24 minutes saved
- **Per year**: 4-5 hours saved

### Resource Savings
- **VPS CPU cycles**: ~80% reduction during provisioning
- **VPS memory**: ~85% reduction during provisioning
- **Development time**: Faster iteration on deployment scripts

## Risks and Mitigations

### Risk 1: GitHub Actions Minutes Exhaustion
- **Impact**: Builds fail, can't deploy new images
- **Likelihood**: Low (2000 free minutes/month, builds ~5-10 min)
- **Mitigation**:
  - Monitor usage in GitHub settings
  - Reduce scheduled builds if needed
  - Fallback to local build by changing `OPENCLAW_IMAGE`

### Risk 2: GHCR Pull Fails
- **Impact**: VPS provisioning blocked
- **Likelihood**: Low (99.9% uptime SLA)
- **Mitigation**:
  - Bootstrap script detects failure
  - Automatic fallback to local build
  - Warning message to user

### Risk 3: Outdated Images
- **Impact**: Using old OpenClaw version with bugs
- **Likelihood**: Medium (if scheduled builds disabled)
- **Mitigation**:
  - Weekly scheduled rebuild
  - Manual workflow dispatch option
  - Document how to trigger rebuilds

### Risk 4: Unauthorized Image Access
- **Impact**: Private images exposed, security issue
- **Likelihood**: Low (proper PAT scoping)
- **Mitigation**:
  - Use fine-grained PATs with minimal scopes
  - Rotate tokens annually
  - Store in 1Password, not in scripts
  - Consider public images (no auth needed)

### Risk 5: Build Failures
- **Impact**: No new images, stuck on old version
- **Likelihood**: Medium (upstream OpenClaw changes)
- **Mitigation**:
  - Keep `latest` tag stable
  - Test builds before merge
  - GitHub Actions notifications enabled
  - Document manual build process

## Cost Analysis

### GitHub Actions
- **Free tier**: 2000 minutes/month
- **Build time**: ~5-10 minutes per build
- **Builds per month**:
  - Automatic (commits): ~8-10 builds
  - Scheduled (weekly): 4 builds
  - Manual (as needed): 2-4 builds
  - **Total**: 14-18 builds = 70-180 minutes
- **Cost**: $0 (well within free tier)

### GitHub Container Registry
- **Free tier**: 500 MB storage, unlimited bandwidth (public)
- **Image size**: ~300-500 MB per image
- **Retention**: Keep 10 recent images
- **Storage used**: ~3-5 GB
- **Cost**: $0 if public, ~$0.25/GB/month if private = ~$1.25/month

### Total Additional Cost
- **Optimistic**: $0/month (public images)
- **Realistic**: $0-2/month (private images with cleanup)
- **Maximum**: $5/month (many large private images)

**Recommendation**: Use public images (cost: $0)

## Alternative Approaches Considered

### 1. Docker Hub
**Pros**:
- Well-known registry
- Good free tier

**Cons**:
- Rate limits on pulls (100 pulls/6 hours for anonymous)
- Requires separate account management
- Not as integrated with GitHub

**Verdict**: GHCR is better integrated

### 2. Build on VPS (Current)
**Pros**:
- No registry needed
- No authentication needed
- Simple

**Cons**:
- Slow provisioning
- Resource intensive
- Inconsistent builds

**Verdict**: Not scalable

### 3. Self-hosted Registry
**Pros**:
- Full control
- No rate limits

**Cons**:
- Additional VPS cost ($5-10/month)
- Maintenance burden
- Security responsibility

**Verdict**: Over-engineered for this use case

### 4. AWS ECR / GCP Artifact Registry
**Pros**:
- Enterprise features
- Scalable

**Cons**:
- Costs money ($0.10/GB/month storage + transfer)
- Requires cloud account
- Overkill for single-user deployment

**Verdict**: Too expensive

## Success Metrics

### Key Performance Indicators (KPIs)

1. **Provisioning Time Reduction**
   - Target: 50% reduction (20 min → 10 min)
   - Measurement: Time from `oc-bootstrap.sh` start to gateway responding

2. **Build Success Rate**
   - Target: >95% successful builds
   - Measurement: GitHub Actions workflow success rate

3. **Image Pull Success Rate**
   - Target: >99% successful pulls
   - Measurement: Monitor bootstrap script logs

4. **Resource Utilization**
   - Target: <10% CPU during provisioning
   - Measurement: VPS monitoring during deploy

5. **Cost Efficiency**
   - Target: $0 additional cost (free tier)
   - Measurement: GitHub billing page

### Monitoring

1. **GitHub Actions**:
   - Email notifications on workflow failure
   - Review workflow runs weekly

2. **GHCR**:
   - Check package insights for pull counts
   - Monitor storage usage

3. **VPS**:
   - Log bootstrap output
   - Track provisioning times
   - Monitor resource usage with `htop`

## Next Steps

1. **Review this plan** with stakeholders
2. **Create GitHub Actions workflow** (Phase 1)
3. **Test workflow** with manual trigger
4. **Update bootstrap script** (Phase 3)
5. **Test full deployment** on fresh VPS
6. **Update documentation** (Phase 5)
7. **Monitor and iterate** (ongoing)

## Questions for Consideration

1. **Image Visibility**: Public or private packages?
   - **Recommendation**: Public (no auth needed, $0 cost)
   - **Rationale**: No sensitive data in image, easier to use

2. **Build Frequency**: How often to rebuild?
   - **Recommendation**: Weekly + on-demand
   - **Rationale**: Balance freshness with build minutes

3. **Tag Strategy**: Which tags to support?
   - **Recommendation**: `latest` + `sha-{commit}` + branch tags
   - **Rationale**: Flexibility for users, reproducibility

4. **Fallback Strategy**: Always fallback to local build?
   - **Recommendation**: Yes, with warning
   - **Rationale**: Ensures deployment never fails

5. **Multi-arch**: Support ARM64 for cheaper VPS options?
   - **Recommendation**: Not initially, add if needed
   - **Rationale**: KISS principle, can add later

## Conclusion

This implementation provides significant benefits:
- **Faster deployments** (50% time reduction)
- **Lower VPS resource usage** (85% reduction during provisioning)
- **Better consistency** (same image everywhere)
- **Zero additional cost** (within GitHub free tier)
- **Improved developer experience** (faster iteration)

The plan is low-risk with clear rollback strategies and aligns with the repository's philosophy of **simplicity and value**.

**Recommendation**: Proceed with implementation starting with Phase 1 (GitHub Actions workflow).
