# Workflow & Script Validation Quick Reference Checklist

---

## PRE-EXECUTION VALIDATION

Use this checklist before deploying any workflow or running any deployment script.

### GitHub Actions Workflow Checks

**File:** `.github/workflows/build-installer.yml`

#### YAML Syntax
- [ ] Run: `yamllint .github/workflows/build-installer.yml`
- [ ] No indentation errors (2 spaces for YAML)
- [ ] All strings with special characters are quoted
- [ ] Environment variables use `${{ }}` syntax
- [ ] Job names and step names are unique

#### Build Step
- [ ] Script `installer/create-bundle.sh` exists and is executable
- [ ] Syntax check with `bash -n installer/create-bundle.sh` passes
- [ ] Script returns exit code 0 on success
- [ ] Bundle file path matches SHA256 calculation step

#### SHA256 Validation Step
- [ ] Expected file `installer/dist/pdev-complete-v1.0.0.tar.gz` is created
- [ ] SHA256 output format is 64 lowercase hex characters
- [ ] Variable properly escaped for sed usage in next step
- [ ] Test locally: `sha256sum installer/dist/pdev-complete-v1.0.0.tar.gz`

#### Wrapper Script Update Step
- [ ] Original pattern in script: `INSTALLER_SHA256="..."`
- [ ] sed command has escaped special characters
- [ ] Backup file created before modification
- [ ] Wrapper script syntax validated after update
- [ ] Backup removed if verification succeeds

#### SSH Setup Step
- [ ] Secret `VYXENAI_DEPLOY_KEY` defined in GitHub
- [ ] Key is Ed25519 format: `-----BEGIN OPENSSH PRIVATE KEY-----`
- [ ] Secret `ACME_HOST_KEY` defined in GitHub with IP-based host key (194.32.107.30)
- [ ] Key file has restrictive permissions (600)
- [ ] Host key scanned with timeout (10 seconds)
- [ ] SSH config created with `StrictHostKeyChecking accept-new`
- [ ] Private key removed after step (cleanup)

#### Upload Step
- [ ] Retry logic implemented (3 attempts)
- [ ] Exponential backoff between retries (5, 10, 15 seconds)
- [ ] SCP uses connection timeout (10 seconds)
- [ ] Upload checksum verified remotely
- [ ] Temp file cleaned up on failure

#### Move to Final Location Step
- [ ] Backup created before move
- [ ] Atomic move (no partial uploads)
- [ ] Permissions set correctly (644, www-data:www-data)
- [ ] File exists and is readable after move
- [ ] Checksum verified after move

#### Git Commit Step
- [ ] Branch is main or expected branch
- [ ] Only modified files are committed
- [ ] Multi-line commit message uses heredoc syntax
- [ ] Commit message includes workflow run link
- [ ] Pull with rebase before push (conflict handling)
- [ ] Push retry logic implemented

---

### Bash Script Checks (All Scripts)

#### Error Handling
- [ ] First line: `#!/usr/bin/env bash`
- [ ] Line 2-3: `set -euo pipefail` present
- [ ] Trap handler for cleanup: `trap cleanup EXIT`
- [ ] All error paths call `die()` or similar
- [ ] No silent failures or ignoring errors

#### Variable Usage
- [ ] All variables quoted: `"$var"` not `$var`
- [ ] No unset variable expansion without defaults
- [ ] Syntax: `${VAR:-default}` for safe defaults
- [ ] Configuration loaded from `.pdev-defaults.sh`
- [ ] Environment variables validated before use

#### Functions
- [ ] All functions have clear purpose statement
- [ ] Function arguments validated at start
- [ ] Return codes used consistently (0=success, 1=failure)
- [ ] Subshell safety: functions don't modify global state
- [ ] Error handling inside functions (not just exit)

#### SSH Operations
- [ ] SSH key setup with restricted permissions (600)
- [ ] Host key validation with timeout
- [ ] Connection timeout specified (10 seconds)
- [ ] Quoted variable expansion in SSH commands
- [ ] Cleanup of credentials after use

#### File Operations
- [ ] All file paths are absolute (not relative)
- [ ] File existence checked before reading
- [ ] Directory existence checked before cd
- [ ] Temporary files created in secure locations
- [ ] Temporary files cleaned up on exit

#### Network Operations
- [ ] Retry logic for transient failures
- [ ] Exponential backoff between retries
- [ ] Clear error messages with actionable guidance
- [ ] Timeouts specified for all network operations
- [ ] Checksum or other verification after transfer

#### Git Operations
- [ ] Working directory checked: `git rev-parse --git-dir`
- [ ] Branch verified before deploy
- [ ] Uncommitted changes detected
- [ ] Remote fetched and compared with local
- [ ] Merge conflicts detected and reported
- [ ] Git credentials/config properly scoped

#### Logging
- [ ] Successful operations logged with timestamp
- [ ] Failures logged before exit
- [ ] Log file location clear and accessible
- [ ] Sensitive data NOT logged (passwords, keys, tokens)
- [ ] Log entries include context (user, PWD, commit)

---

## POST-EXECUTION VALIDATION

Use this checklist after deployment to verify success.

### Bundle Deployment

- [ ] Bundle file exists at remote location
- [ ] Bundle file size is > 1MB (not empty)
- [ ] Bundle file owned by www-data:www-data
- [ ] Bundle file permissions are 644 (readable)
- [ ] Bundle file accessible via HTTPS
- [ ] SHA256 matches workflow-calculated value

```bash
# Test from local:
curl -I https://walletsnack.com/pdev/install/pdev-complete-v1.0.0.tar.gz

# Verify size and checksum:
ssh acme 'ls -lh /var/www/html/pdev/install/pdev-complete-v1.0.0.tar.gz'
ssh acme 'sha256sum /var/www/html/pdev/install/pdev-complete-v1.0.0.tar.gz'
```

### Installer Script Deployment

- [ ] Script file exists on remote
- [ ] Script owned by deploy user (executable)
- [ ] Script permissions are 755
- [ ] Script syntax valid: `bash -n` passes remotely
- [ ] Script accessible via HTTPS
- [ ] Backup file created before deployment

```bash
# Test from local:
curl -I https://walletsnack.com/pdev/install/pdl-installer.sh

# Verify syntax:
ssh acme 'bash -n /var/www/vyxenai.com/pdev/install/pdl-installer.sh'

# Check backup:
ssh acme 'ls -lh /var/www/vyxenai.com/pdev/install/.backups/'
```

### Frontend Deployment

- [ ] All HTML files deployed (index.html, dashboard.html, etc.)
- [ ] All CSS files deployed (pdev-live.css, etc.)
- [ ] Files owned by www-data:www-data
- [ ] Files permissions are 644 (readable)
- [ ] Files accessible via HTTPS
- [ ] Backup files created before deployment

```bash
# Test from local:
curl -I https://walletsnack.com/pdev/dashboard.html

# Verify on server:
ssh acme 'ls -lh /var/www/vyxenai.com/pdev/'
ssh acme 'ls -lh /var/www/vyxenai.com/pdev-backups/'
```

### Server Deployment

- [ ] server.js file deployed to correct location
- [ ] PM2 service restarted successfully
- [ ] PM2 service status is "online"
- [ ] Service uptime > 5 seconds (stable)
- [ ] No recent restarts (not in restart loop)
- [ ] Application logs show successful startup

```bash
# Test from local:
ssh acme 'pm2 status | grep pdev-live'
ssh acme 'pm2 logs pdev-live --lines 50'
ssh acme 'pm2 show pdev-live | grep -E "status|uptime|restarts"'

# Check API health:
curl https://walletsnack.com/pdev/api/health
```

### Git Repository

- [ ] Wrapper script update committed to main
- [ ] Commit includes SHA256 in message
- [ ] Commit authored by "GitHub Actions" or "PDev Automation"
- [ ] Commit pushed to origin/main
- [ ] No uncommitted changes remaining
- [ ] Branch main is current

```bash
# Test locally:
git log -1 --oneline
git branch -vv
git status
```

---

## EMERGENCY PROCEDURES

### If Build Fails

1. Check GitHub Actions logs for specific error
2. Manually verify build locally:
   ```bash
   cd installer && bash -n create-bundle.sh && ./create-bundle.sh
   ```
3. If syntax error, fix script and commit
4. Re-run workflow or manually trigger
5. Check bundle file size and checksum
6. Do NOT push incomplete bundle to remote

### If SSH Connection Fails

1. Verify remote host is online:
   ```bash
   ssh acme 'echo "Connection OK"'
   ```
2. Check SSH key in GitHub secrets:
   ```bash
   # Cannot view secrets, but check if key configured
   ```
3. Verify known_hosts if using GitHub runner:
   ```bash
   ssh-keyscan -H walletsnack.com >> ~/.ssh/known_hosts
   ```
4. Check firewall/network connectivity from runner
5. Increase timeout values if intermittent failures

### If Bundle Upload Fails

1. Verify bundle file exists:
   ```bash
   ls -lh installer/dist/pdev-complete-v1.0.0.tar.gz
   ```
2. Check remote disk space:
   ```bash
   ssh acme 'df -h /var/www/html/'
   ```
3. Retry with exponential backoff
4. If persistent, check network logs on both ends
5. Consider smaller bundle or staged uploads

### If Deployment Verification Fails

1. Manually check remote file:
   ```bash
   ssh acme 'ls -lh /var/www/html/pdev/install/pdev-complete-v1.0.0.tar.gz'
   ssh acme 'sha256sum /var/www/html/pdev/install/pdev-complete-v1.0.0.tar.gz'
   ```
2. Compare with local:
   ```bash
   sha256sum installer/dist/pdev-complete-v1.0.0.tar.gz
   ```
3. If mismatch, rollback:
   ```bash
   ssh acme 'cp /var/www/html/pdev/install/pdev-complete-v1.0.0.tar.gz.backup /var/www/html/pdev/install/pdev-complete-v1.0.0.tar.gz'
   ```
4. Re-upload and verify checksum
5. Contact infrastructure team if persistent

### If Service Fails to Start

1. Check PM2 logs:
   ```bash
   ssh acme 'pm2 logs pdev-live --lines 100'
   ```
2. Check application logs:
   ```bash
   ssh acme 'tail -f /var/log/pdev-live/app.log'
   ```
3. Verify configuration:
   ```bash
   ssh acme 'cat /opt/services/pdev-live/server/server.js | head -20'
   ```
4. Check for syntax errors:
   ```bash
   ssh acme 'node -c /opt/services/pdev-live/server/server.js'
   ```
5. Rollback if necessary:
   ```bash
   ssh acme './deploy-server.sh --rollback'
   ```
6. Restart PM2:
   ```bash
   ssh acme 'pm2 restart pdev-live'
   ```

---

## CONFIGURATION VALIDATION

### .pdev-defaults.sh

Run before any deployment:

```bash
# Source the config
source .pdev-defaults.sh

# Verify values are set
echo "DEPLOY_USER: ${DEPLOY_USER:-UNSET}"
echo "FRONTEND_DEPLOY_PATH: ${FRONTEND_DEPLOY_PATH:-UNSET}"
echo "BACKEND_SERVICE_PATH: ${BACKEND_SERVICE_PATH:-UNSET}"
echo "PM2_APP_NAME: ${PM2_APP_NAME:-UNSET}"

# Verify paths are absolute
for path in "$FRONTEND_DEPLOY_PATH" "$BACKEND_SERVICE_PATH"; do
  if [[ ! "$path" =~ ^/ ]]; then
    echo "WARNING: Path is not absolute: $path"
  fi
done

# Test connectivity
ssh "$DEPLOY_USER" "echo 'SSH OK' && whoami"
```

### GitHub Secrets

Required secrets in GitHub Actions:
- [ ] `VYXENAI_DEPLOY_KEY` - Private SSH key (Ed25519 format)
- [ ] `ACME_HOST_KEY` - SSH host public key (IP-based, not hostname)

Verify in GitHub: Settings → Secrets and variables → Actions

---

## METRICS TO MONITOR

After deployment, monitor these metrics:

### Success Indicators
- [ ] All files deployed within 5 minutes
- [ ] Checksum verification passes
- [ ] HTTP endpoints respond with 200-399 status
- [ ] Application logs show no errors
- [ ] PM2 service uptime > 1 hour
- [ ] Database connections healthy
- [ ] No spike in 5xx errors

### Failure Indicators
- [ ] Deployment takes > 10 minutes
- [ ] Checksum mismatch detected
- [ ] HTTP endpoints return 5xx errors
- [ ] Application logs show exceptions
- [ ] PM2 service restarting frequently
- [ ] Database connection errors
- [ ] Traffic spike in 5xx errors after deploy

---

## COMMON ERRORS & SOLUTIONS

| Error | Cause | Fix |
|-------|-------|-----|
| `bash: ./create-bundle.sh: No such file or directory` | Script path wrong or missing | Verify `installer/create-bundle.sh` exists |
| `sha256sum: No such file or directory` | Bundle not created | Check build step output for errors |
| `ssh: Permission denied (publickey)` | SSH key wrong or permissions wrong | Verify `VYXENAI_DEPLOY_KEY` secret, check `chmod 600` |
| `Host key verification failed` | ACME_HOST_KEY doesn't match target | Verify `ACME_HOST_KEY` is IP-based (194.32.107.30) |
| `scp: command not found` | scp not in PATH on runner | Use `ssh-keyscan` first to populate known_hosts |
| `sed: invalid option` | sed variant different on macOS/Linux | Use `sed -i ''` on macOS, `sed -i` on Linux |
| `Checksum mismatch` | File corrupted during transfer | Retry upload with clean temp file |
| `pm2: command not found` | PM2 not installed or PATH wrong | Verify PM2 installed: `ssh acme 'pm2 -v'` |
| `No space left on device` | Remote disk full | Clean old backups: `ssh acme 'rm -rf /var/www/html/pdev/install/.backups/*'` |

---

## ROLLBACK PROCEDURES

### To Rollback Bundle

```bash
# Use previous version
ssh acme 'ls -t /var/www/html/pdev/install/pdev-complete-v1.0.0.tar.gz.* | head -1'

# Restore previous version
SSH_BACKUP=$(ssh acme 'ls -t /var/www/html/pdev/install/pdev-complete-v1.0.0.tar.gz.* 2>/dev/null | head -1')
ssh acme "cp $SSH_BACKUP /var/www/html/pdev/install/pdev-complete-v1.0.0.tar.gz"

# Verify
ssh acme 'sha256sum /var/www/html/pdev/install/pdev-complete-v1.0.0.tar.gz'
```

### To Rollback Frontend

```bash
# List available backups
ssh acme 'ls /var/www/vyxenai.com/pdev-backups/'

# Restore specific file
ssh acme 'sudo cp /var/www/vyxenai.com/pdev-backups/index.html.20260114_093000 /var/www/vyxenai.com/pdev/index.html'

# Or use deployed script
./scripts/deploy-frontend.sh --rollback
```

### To Rollback Server

```bash
# Revert to previous commit
git log -1 origin/main
git revert <commit-hash>
git push

# Or rollback immediately
./scripts/deploy-server.sh --rollback

# Or manually restart previous version
ssh acme 'pm2 restart pdev-live'
```

---

## SIGN-OFF CHECKLIST

Before marking deployment as complete:

- [ ] All files deployed successfully
- [ ] All checksums verified
- [ ] All services online and responding
- [ ] No errors in application logs (last 100 lines)
- [ ] Deployment logged in `.deploy-log`
- [ ] Git history clean (no merge conflicts)
- [ ] Team notified of deployment
- [ ] Monitoring alerts configured
- [ ] Rollback procedure tested
- [ ] Documentation updated if needed

