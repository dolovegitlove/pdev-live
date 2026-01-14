# GitHub Actions Build & Deploy Workflow Guide

## Overview

This guide documents the production-ready GitHub Actions workflow for building and deploying PDev Source Tarballs. The system provides automated version management, comprehensive validation, and secure deployment to production servers.

**Key Features:**
- Automatic tarball creation with proper content inclusion/exclusion
- Version auto-increment with manual override support
- Pre-deployment version conflict detection
- Post-deployment integrity verification
- Secure SSH key handling and host key verification
- Automated GitHub Release creation
- Comprehensive error handling and logging

## Architecture

### Components

1. **GitHub Actions Workflow** (`.github/workflows/build-source-tarball.yml`)
   - Orchestrates the entire build and deploy pipeline
   - Manages version detection and increment
   - Coordinates SSH deployments and verifications

2. **Build Script** (`installer/scripts/build-source-tarball.sh`)
   - Creates production-ready tarballs
   - Generates SHA256 checksums
   - Validates tarball content
   - Can be run locally or via GitHub Actions

3. **Verification Script** (`installer/scripts/verify-deployment.sh`)
   - Validates deployed tarball integrity
   - Performs HTTP accessibility checks
   - Verifies file permissions and ownership
   - Ensures installer can discover the version

### Workflow Triggers

The workflow is triggered by:
- **Push to main** with changes in:
  - `installer/**`
  - `server/**`
  - `frontend/**`
  - `client/**`
  - `.github/workflows/build-source-tarball.yml`

- **Manual dispatch** via GitHub Actions UI
  - Optional version override (e.g., `1.0.5`)
  - If empty, auto-increments from current version

## Setup Instructions

### 1. GitHub Secrets Configuration

The workflow requires these secrets to be configured in GitHub:

#### `VYXENAI_DEPLOY_KEY` (CRITICAL)
SSH private key for deployment user (typically `github-deploy`)
- Generate key: `ssh-keygen -t ed25519 -f deploy_key -N ""`
- Add to `~/.ssh/authorized_keys` on target server
- Permissions: 600 on local machine, added to `authorized_keys` on server

#### `ACME_HOST_KEY` (CRITICAL)
SSH host public key fingerprint for strict host key verification
- Generate: `ssh-keyscan -t ed25519 194.32.107.30` (IP-based, not hostname)
- Format: `194.32.107.30 ssh-ed25519 AAAA...` (full key)
- Prevents man-in-the-middle attacks
- **IMPORTANT:** Use IP address (194.32.107.30), not hostname, for GitHub Actions compatibility

### 2. Target Server Requirements

Ensure the deployment user (`github-deploy` by default) has:

```bash
# SSH access configured
ssh github-deploy@acme "echo 'SSH works'"

# Deployment directory accessible
ssh github-deploy@acme "ls -la /var/www/vyxenai.com/pdev/install/"

# sudo access (with NOPASSWD) for permission changes
# Add to sudoers: github-deploy ALL=(ALL) NOPASSWD: /bin/chown, /bin/chmod
visudo
# Add line: github-deploy ALL=(ALL) NOPASSWD: /bin/chown,/bin/chmod

# Web server user permission
# Files deployed as www-data:www-data with 644 permissions
```

### 3. nginx Configuration

Ensure nginx is configured to serve the installation directory:

```nginx
server {
  server_name vyxenai.com;

  location /pdev/install/ {
    alias /var/www/vyxenai.com/pdev/install/;
    autoindex off;

    # Cache headers for tarballs
    location ~ \.(tar\.gz|sha256)$ {
      expires 30d;
      add_header Cache-Control "public, immutable";
    }
  }
}
```

## Version Management

### Version Format
Versions follow semantic versioning: `X.Y.Z`
- Example: `1.0.4` → `1.1.0` (auto-incremented)

### Version Detection
Current version is read from `installer/pdl-installer.sh`:
```bash
TARBALL_VERSION="1.0.4"  # Line 86 (approximately)
```

### Version Incrementing
- **Auto-increment**: Minor version increases, patch resets to 0
  - `1.0.4` → `1.1.0`
  - `2.3.7` → `2.4.0`

- **Manual version**: Specify via `workflow_dispatch` input
  - Allows hotfixes: `1.0.4` → `1.0.5`

- **Version conflict detection**: Workflow fails if version already exists on acme

## Tarball Contents

### Included Directories
- `server/` - Backend API and services
- `installer/` - Installation scripts and configuration
- `frontend/` - Web UI components
- `client/` - CLI tools

### Excluded Items
- `.git/`, `.github/` - Version control
- `node_modules/` - Dependencies (reinstalled on target)
- `.env`, `.env.*` - Secrets and configuration
- `*.log`, `*.tmp`, `*.bak` - Temporary files
- `desktop/`, `tests/`, `visual-validation/` - Development directories

### File Permissions
- Tarball: `644` (www-data:www-data)
- Checksum: `644` (www-data:www-data)
- Symlinks: Dereferenced to actual files

## Deployment Process

### Step-by-Step Workflow

1. **Checkout** - Clone repository with full history
2. **Parse Version** - Read current TARBALL_VERSION from pdl-installer.sh
3. **Calculate Version** - Auto-increment or use manual override
4. **Validate Target** - Ensure deployment directory exists on acme
5. **Setup SSH** - Configure SSH key and host verification
6. **Check Version** - Fail if version already exists (prevents overwrites)
7. **Build Tarball** - Create gzipped tarball with proper exclusions
8. **Verify Contents** - Ensure all required files are present
9. **Verify Excluded** - Ensure secrets/cache are not included
10. **Upload Artifacts** - Store tarball in GitHub artifacts (30-day retention)
11. **Deploy Tarball** - SCP files to acme server
12. **Set Permissions** - Configure 644 permissions and www-data ownership
13. **Verify Deployed** - Download and verify SHA256 matches local
14. **Update Installer** - Auto-commit TARBALL_VERSION update to main
15. **Create Release** - Generate GitHub Release with tarball files
16. **Notify** - Display deployment summary with verification status

### Security Features

**SSH Key Handling**
- Uses `shimataro/ssh-key-action@v2` for secure key management
- Keys never logged or displayed in output
- Automatic cleanup after deployment
- Fails if key already exists (prevents conflicts)

**Host Key Verification**
- SSH connects with `-o StrictHostKeyChecking=accept-new`
- Host key pre-configured from GitHub Secret
- Prevents man-in-the-middle attacks

**Error Handling**
- `set -euo pipefail` in all shell scripts
- Exit on first error, no silent failures
- Comprehensive logging of all operations
- Cleanup trap ensures SSH connections close on failure

**Secrets Protection**
- No credentials in logs or error messages
- Deployment user configurable (not hardcoded)
- Host keys stored in GitHub Secrets

## Local Usage

### Build Tarball Locally

```bash
# Navigate to project root
cd /path/to/pdev-live

# Run build script (auto-increments version)
./installer/scripts/build-source-tarball.sh

# Specify custom version
./installer/scripts/build-source-tarball.sh "1.0.5"

# Specify output directory
./installer/scripts/build-source-tarball.sh "1.0.5" "/tmp/builds"
```

### Script Output
```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
PDev Source Tarball Builder
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

ℹ Validating build environment...
✓ Environment validation passed
ℹ Validating required directories...
✓ Found: server/
✓ Found: installer/
✓ Found: frontend/
✓ Found: client/
✓ All required directories found
ℹ Current TARBALL_VERSION: 1.0.4
ℹ Auto-incrementing to version: 1.1.0
ℹ Creating tarball: pdev-source-v1.1.0.tar.gz
✓ Tarball created: pdev-source-v1.1.0.tar.gz (2.1M)
[... verification steps ...]
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Build Successful
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Version:     v1.1.0
Tarball:     ./pdev-source-v1.1.0.tar.gz
Checksum:    ./pdev-source-v1.1.0.tar.gz.sha256
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

### Verify Deployment

```bash
# Verify deployed tarball on acme
./installer/scripts/verify-deployment.sh "1.1.0"

# Specify custom host/path/key
./installer/scripts/verify-deployment.sh "1.1.0" "acme" "/var/www/vyxenai.com/pdev/install" "~/.ssh/deploy_key"
```

### Manual Deployment

```bash
# Build locally
VERSION="1.0.5"
./installer/scripts/build-source-tarball.sh "${VERSION}"

# Upload to server
scp -i ~/.ssh/deploy_key \
  "pdev-source-v${VERSION}.tar.gz" \
  "pdev-source-v${VERSION}.tar.gz.sha256" \
  github-deploy@acme:/var/www/vyxenai.com/pdev/install/

# Fix permissions
ssh -i ~/.ssh/deploy_key github-deploy@acme \
  "cd /var/www/vyxenai.com/pdev/install && \
   sudo chown www-data:www-data pdev-source-v*.tar.gz* && \
   sudo chmod 644 pdev-source-v*.tar.gz*"

# Verify
./installer/scripts/verify-deployment.sh "${VERSION}"
```

## Monitoring & Troubleshooting

### Viewing Workflow Runs

1. Go to GitHub Actions tab in repository
2. Click "Build & Deploy PDev Source Tarball" workflow
3. View recent runs and their logs

### Common Issues

#### SSH Connection Failed
- Verify `VYXENAI_DEPLOY_KEY` is valid and added to `authorized_keys`
- Check `ACME_HOST_KEY` is IP-based (194.32.107.30) not hostname
- Ensure firewall allows SSH from GitHub Actions (outbound 22)
- If "Host key verification failed": ACME_HOST_KEY doesn't match, regenerate with IP address

#### Checksum Mismatch
- Indicates tarball corruption during transfer
- Check network connectivity and SCP process
- Verify no firewall is intercepting the upload

#### Version Already Exists
- Workflow intentionally fails to prevent overwrites
- Use manual version input to specify new version
- Or manually delete old tarball: `ssh acme "rm /var/www/vyxenai.com/pdev/install/pdev-source-vX.Y.Z.tar.gz*"`

#### Permission Denied on Deployment
- Verify deployment user has sudo access for chown/chmod
- Check `sudoers` configuration (visudo)
- Ensure www-data user exists on target system

#### Tarball Extraction Fails
- Run `tar -tzf pdev-source-vX.Y.Z.tar.gz | head` to check contents
- Verify no excluded files are present
- Check tarball isn't corrupted

### Debug Logging

Enable additional debug output:
1. In GitHub Actions: Settings → Secrets → Add `ACTIONS_STEP_DEBUG=true`
2. Re-run workflow with debug enabled
3. View detailed logs in workflow run

### Post-Deployment Checklist

```bash
# Verify on target server
ssh acme

# Check file exists and is readable
ls -lh /var/www/vyxenai.com/pdev/install/pdev-source-v1.1.0.tar.gz*

# Verify web accessibility
curl -I https://vyxenai.com/pdev/install/pdev-source-v1.1.0.tar.gz

# Verify checksum
cd /var/www/vyxenai.com/pdev/install
sha256sum -c pdev-source-v1.1.0.tar.gz.sha256

# Verify installer can find it
curl -s https://vyxenai.com/pdev/install/pdev-source-v1.1.0.tar.gz | tar -tzf - | head -10
```

## GitHub Release Integration

Each successful deployment creates a GitHub Release with:
- Tarball file
- SHA256 checksum file
- Detailed release notes
- Build information and commit link
- Installation instructions
- Package contents listing

### Download from Release
```bash
# Latest release
curl -L -o pdev-source.tar.gz \
  https://github.com/dolovegitlove/pdev-live/releases/download/pdev-source-v1.1.0/pdev-source-v1.1.0.tar.gz

# Verify and extract
sha256sum -c pdev-source-v1.1.0.tar.gz.sha256
tar -xzf pdev-source-v1.1.0.tar.gz
```

## Installer Integration

The `pdl-installer.sh` script automatically detects and downloads the tarball:

```bash
# Install from current version
./installer/pdl-installer.sh

# The installer reads TARBALL_VERSION and downloads from:
# https://vyxenai.com/pdev/install/pdev-source-v${TARBALL_VERSION}.tar.gz
```

## Performance Considerations

### Tarball Size
- Typical size: 2-3 MB gzip
- Includes: installer, server, frontend, client
- Excludes: node_modules (reinstalled), .git, cache files

### Build Time
- GitHub Actions: ~30-45 seconds for full workflow
- Local build: ~10-15 seconds on modern hardware
- Deployment: ~5-10 seconds SCP transfer

### Artifact Retention
- GitHub artifacts: 30 days (configurable)
- Server deployment: No automatic cleanup

## Security Best Practices

1. **SSH Key Management**
   - Use ed25519 keys (more secure than RSA)
   - Rotate keys quarterly
   - Never commit keys to repository
   - Use separate keys for GitHub Actions

2. **Host Key Verification**
   - Always store host key in GitHub Secrets
   - Use `-o StrictHostKeyChecking` option
   - Verify fingerprint before adding to secrets

3. **File Permissions**
   - Tarballs: 644 (readable by web server)
   - Not executable (prevent accidental execution)
   - Owned by www-data for consistency

4. **Deployment User**
   - Use separate non-admin user for deployments
   - Limit sudo access to specific commands (chown, chmod)
   - Monitor deployment user logins

5. **Secrets Rotation**
   - Rotate deployment keys quarterly
   - Immediately rotate if exposed
   - Document key rotation process

## Maintenance

### Monthly Tasks
- Review GitHub Actions logs for errors
- Check deployed tarball integrity
- Verify version numbers match expectations
- Monitor storage usage on deployment server

### Quarterly Tasks
- Rotate SSH deployment keys
- Review and update security policies
- Test disaster recovery procedures
- Audit sudo access for deployment user

### Annual Tasks
- Security audit of entire deployment system
- Performance optimization review
- Documentation updates
- Team training on procedures

## Additional Resources

- GitHub Actions Documentation: https://docs.github.com/en/actions
- SSH Key Setup: https://docs.github.com/en/authentication/connecting-to-github-with-ssh
- Semantic Versioning: https://semver.org/
- PDev Live Documentation: See DEPLOYMENT.md in repository

## Support

For issues or questions:
1. Check the Troubleshooting section above
2. Review workflow logs in GitHub Actions tab
3. Run `./installer/scripts/verify-deployment.sh` for diagnostics
4. Consult DEPLOYMENT.md for additional guidance
