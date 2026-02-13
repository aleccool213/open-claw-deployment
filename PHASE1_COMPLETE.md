# Phase 1 Complete: GitHub Actions Workflow

## ✅ What Was Implemented

Created `.github/workflows/docker-build.yml` - a GitHub Actions workflow that:

1. **Clones the official OpenClaw repository** from `https://github.com/openclaw/openclaw.git`
2. **Builds the Docker image** using Docker Buildx with caching
3. **Pushes to GitHub Container Registry** at `ghcr.io/aleccool213/open-claw-deployment/openclaw`
4. **Creates multiple image tags**:
   - `latest` - always points to most recent build
   - `sha-abc123` - specific commit SHA for reproducibility
   - `main` / `master` - branch-based tags
   - `v1.0.0` - semantic version tags (when applicable)

## 🚀 Workflow Triggers

The workflow runs automatically when:

- **Push to main/master** - Builds whenever code is merged
- **Manual dispatch** - Manually trigger with custom OpenClaw git reference
- **Weekly schedule** - Sundays at 2 AM UTC to stay current with upstream

## 📋 Next Steps to Test

### Step 1: Merge this branch to main/master

Once this PR is merged, the workflow will trigger automatically.

```bash
# Create a pull request (if not already created)
gh pr create --title "Add Docker image build pipeline" \
  --body "Implements Phase 1 of Docker pipeline - GitHub Actions workflow for building and pushing OpenClaw images to GHCR"

# Or merge directly if you have permission
git checkout main
git merge claude/docker-github-actions-pipeline-UXdou
git push origin main
```

### Step 2: Monitor the workflow run

1. Go to: `https://github.com/aleccool213/open-claw-deployment/actions`
2. Click on "Build and Push OpenClaw Docker Image"
3. Watch the workflow execute (takes ~5-10 minutes)
4. Verify all steps complete successfully

### Step 3: Verify the image was pushed to GHCR

After the workflow completes:

1. Go to: `https://github.com/aleccool213?tab=packages`
2. Look for package: `open-claw-deployment/openclaw`
3. Click on it to see available tags
4. Verify tags include: `latest`, `sha-abc123`, etc.

### Step 4: Configure package visibility

**For public images (recommended - no auth needed):**

1. Go to package settings
2. Click "Change visibility"
3. Select "Public"
4. Confirm the change

**For private images (requires authentication):**

1. Keep visibility as "Private"
2. Create a GitHub Personal Access Token:
   - Settings → Developer settings → Personal access tokens → Fine-grained tokens
   - Name: "OpenClaw VPS Pull Access"
   - Expiration: 1 year
   - Repository access: `aleccool213/open-claw-deployment`
   - Permissions: `packages:read`
3. Store token in 1Password as "GitHub GHCR Pull Token"

### Step 5: Test pulling the image locally

```bash
# For public images
docker pull ghcr.io/aleccool213/open-claw-deployment/openclaw:latest

# For private images (authenticate first)
echo $GITHUB_PAT | docker login ghcr.io -u aleccool213 --password-stdin
docker pull ghcr.io/aleccool213/open-claw-deployment/openclaw:latest
```

### Step 6: Test manual workflow dispatch (optional)

To build a specific OpenClaw version:

1. Go to: `https://github.com/aleccool213/open-claw-deployment/actions/workflows/docker-build.yml`
2. Click "Run workflow"
3. Select branch: `main`
4. Enter OpenClaw ref (optional): e.g., `develop`, `v1.2.3`, or specific commit SHA
5. Click "Run workflow"
6. Monitor the run and verify the custom ref was checked out

## 🔍 Troubleshooting

### Workflow fails on push step

**Error**: `denied: permission_denied`

**Solution**:
- Ensure the workflow has `packages: write` permission (already configured)
- Check that GITHUB_TOKEN has not been restricted in repository settings
- Go to Settings → Actions → General → Workflow permissions
- Select "Read and write permissions"

### Can't find the package in GHCR

**Issue**: Package doesn't appear after workflow succeeds

**Solution**:
- Check GitHub user packages: `https://github.com/aleccool213?tab=packages`
- Package may be private by default - check organization packages too
- First push creates the package, may take a minute to appear

### Image pull fails on VPS

**Error**: `Error response from daemon: pull access denied`

**Solution**:
- For public images: Change package visibility to "Public"
- For private images: Authenticate with `docker login ghcr.io`
- Verify image name is correct: `ghcr.io/aleccool213/open-claw-deployment/openclaw:latest`

## 📊 Expected Workflow Output

When the workflow runs successfully, you should see:

```
✓ Checkout deployment repository
✓ Clone OpenClaw repository
✓ Set up Docker Buildx
✓ Log in to GitHub Container Registry
✓ Extract metadata (tags, labels)
✓ Build and push Docker image
✓ Output image information
```

The summary will show:

```
### Docker Image Build Summary 🚀

**Image pushed successfully!**

**Registry:** `ghcr.io`
**Repository:** `aleccool213/open-claw-deployment/openclaw`
**OpenClaw Commit:** `abc1234`
**Digest:** `sha256:...`

**Available Tags:**
ghcr.io/aleccool213/open-claw-deployment/openclaw:latest
ghcr.io/aleccool213/open-claw-deployment/openclaw:sha-abc1234
ghcr.io/aleccool213/open-claw-deployment/openclaw:main

**Pull the image:**
docker pull ghcr.io/aleccool213/open-claw-deployment/openclaw:latest
```

## 🎯 Success Criteria

Phase 1 is considered successful when:

- [x] Workflow file created and committed
- [ ] Workflow runs without errors on main/master push
- [ ] Image appears in GitHub Container Registry
- [ ] Image can be pulled with `docker pull ghcr.io/aleccool213/open-claw-deployment/openclaw:latest`
- [ ] Multiple tags are created (latest, sha-*, branch)
- [ ] Weekly scheduled builds work

## ⏭️ What's Next?

After verifying Phase 1 works:

**Phase 2**: Configure GHCR package visibility and authentication
**Phase 3**: Update `oc-bootstrap.sh` to pull from GHCR instead of building locally
**Phase 4**: Update `oc-load-secrets.sh` to load GHCR token from 1Password
**Phase 5**: Update documentation (README.md, AGENTS.md)
**Phase 6**: Add Bats tests for new functionality

## 📝 Workflow Details

**File location**: `.github/workflows/docker-build.yml`

**Key features**:
- Uses official GitHub Actions (checkout, setup-buildx, login-action, build-push-action)
- Implements layer caching for faster subsequent builds
- Builds from cloned OpenClaw repo (not this deployment repo)
- Uses GitHub's built-in `GITHUB_TOKEN` (no manual secret setup needed)
- Outputs detailed summary with pull commands
- Supports custom OpenClaw versions via manual dispatch

**Build time**: ~5-10 minutes per build
**Cost**: $0 (within GitHub free tier - 2000 minutes/month)

## 💡 Tips

1. **Watch the first build closely** to catch any issues early
2. **Set package to public** if you don't need private images (simpler VPS setup)
3. **Enable GitHub Actions notifications** to get alerts on build failures
4. **Pin specific tags in production** (sha-* tags) for reproducibility
5. **Use workflow dispatch** to build specific OpenClaw versions when needed

## 🔗 Useful Links

- Workflow runs: `https://github.com/aleccool213/open-claw-deployment/actions`
- Package registry: `https://github.com/aleccool213?tab=packages`
- Workflow file: `.github/workflows/docker-build.yml`
- Implementation plan: `DOCKER_PIPELINE_PLAN.md`
