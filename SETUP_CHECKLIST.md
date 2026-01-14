# GitHub Actions Build System - Setup Checklist

## Pre-Deployment Checklist

Use this checklist to ensure the GitHub Actions workflow is properly configured before the first deployment.

### Phase 1: GitHub Configuration

- [ ] **Create SSH Deployment Key**
  ```bash
  ssh-keygen -t ed25519 -f deploy_key -N "" -C "github-deploy@pdev-live"
  cat deploy_key
  ```
  - Save output (starts with `-----BEGIN OPENSSH PRIVATE KEY-----`)
  - Action: Will be added to GitHub Secret

- [ ] **Create Host Key Secret**
  ```bash
  ssh-keyscan -t rsa acme
  ```
  - Save full output (e.g., `acme ssh-rsa AAAA...`)
  - Action: Will be added to GitHub Secret

- [ ] **Add VYXENAI_DEPLOY_KEY Secret**
  1. Go to GitHub repository Settings
  2. Click "Secrets and variables" → "Actions"
  3. Click "New repository secret"
  4. Name: `VYXENAI_DEPLOY_KEY`
  5. Value: Paste entire SSH private key (including `-----BEGIN...-----END-----`)
  6. Click "Add secret"

- [ ] **Add ACME_HOST_KEY Secret**
  1. Go to GitHub repository Settings
  2. Click "Secrets and variables" → "Actions"
  3. Click "New repository secret"
  4. Name: `ACME_HOST_KEY`
  5. Value: Paste SSH host key (e.g., `194.32.107.30 ssh-ed25519 AAAA...`)
  6. Click "Add secret"

- [ ] **Verify Secrets Added**
  ```bash
  # In GitHub: Settings → Secrets and variables → Actions
  # Should see:
  # - VYXENAI_DEPLOY_KEY ✓
  # - ACME_HOST_KEY ✓
  ```

### Phase 2: Target Server (acme) Configuration

- [ ] **Add SSH Public Key to Authorized Keys**
  1. Generate public key from private key (if needed):
     ```bash
     ssh-keygen -y -f deploy_key > deploy_key.pub
     cat deploy_key.pub
     ```
  2. On acme server:
     ```bash
     # Switch to github-deploy user
     sudo su - github-deploy

     # Create .ssh directory if needed
     mkdir -p ~/.ssh
     chmod 700 ~/.ssh

     # Add public key
     echo "PASTE_PUBLIC_KEY_HERE" >> ~/.ssh/authorized_keys
     chmod 600 ~/.ssh/authorized_keys
     ```
  3. Test SSH access:
     ```bash
     ssh -i deploy_key github-deploy@acme "echo 'SSH works!'"
     ```

- [ ] **Configure sudoers for Permission Changes**
  1. On acme server as root:
     ```bash
     visudo
     ```
  2. Add this line at the end:
     ```
     github-deploy ALL=(ALL) NOPASSWD: /bin/chown,/bin/chmod
     ```
  3. Save and exit
  4. Test:
     ```bash
     sudo -u github-deploy sudo chown --help
     sudo -u github-deploy sudo chmod --help
     ```

- [ ] **Create/Verify Deployment Directory**
  ```bash
  ssh github-deploy@acme "sudo mkdir -p /var/www/vyxenai.com/pdev/install && \
    sudo chown www-data:www-data /var/www/vyxenai.com/pdev/install && \
    sudo chmod 755 /var/www/vyxenai.com/pdev/install && \
    ls -la /var/www/vyxenai.com/pdev/install"
  ```
  - Expected: Directory exists with www-data:www-data ownership

- [ ] **Verify www-data User Exists**
  ```bash
  ssh github-deploy@acme "id www-data"
  ```
  - Expected: Output showing www-data UID and GID

### Phase 3: Web Server (nginx) Configuration

- [ ] **Create nginx Configuration**
  1. On acme server:
     ```bash
     sudo tee /etc/nginx/sites-available/pdev-install.conf > /dev/null << 'EOF'
     server {
       server_name vyxenai.com;

       location /pdev/install/ {
         alias /var/www/vyxenai.com/pdev/install/;
         autoindex off;

         # Tarball serving
         location ~ \.(tar\.gz|sha256)$ {
           expires 30d;
           add_header Cache-Control "public, immutable";
           # Allow large file downloads
           client_max_body_size 100M;
         }
       }
     }
     EOF
     ```

- [ ] **Enable nginx Site**
  ```bash
  ssh github-deploy@acme "sudo ln -sf /etc/nginx/sites-available/pdev-install.conf \
    /etc/nginx/sites-enabled/pdev-install.conf"
  ```

- [ ] **Test nginx Configuration**
  ```bash
  ssh github-deploy@acme "sudo nginx -t"
  ```
  - Expected: `nginx: configuration file test is successful`

- [ ] **Reload nginx**
  ```bash
  ssh github-deploy@acme "sudo systemctl reload nginx"
  ```

- [ ] **Verify Web Access**
  ```bash
  curl -I https://vyxenai.com/pdev/install/
  ```
  - Expected: HTTP 200 (after successful deployment)
  - Note: Will show 404 until first tarball is deployed

### Phase 4: Local Script Testing

- [ ] **Test Build Script**
  1. Navigate to project root:
     ```bash
     cd /path/to/pdev-live
     ```
  2. Run build script:
     ```bash
     ./installer/scripts/build-source-tarball.sh
     ```
  3. Verify output:
     ```bash
     ls -lh pdev-source-v*.tar.gz*
     ```
  4. Verify contents:
     ```bash
     tar -tzf pdev-source-v*.tar.gz | head -20
     ```

- [ ] **Test Verification Script (After Deployment)**
  1. After first deployment, test:
     ```bash
     ./installer/scripts/verify-deployment.sh "1.0.4"
     ```
  2. Verify all tests pass

### Phase 5: GitHub Actions Workflow Testing

- [ ] **Trigger Manual Workflow Dispatch**
  1. Go to GitHub repository
  2. Click "Actions" tab
  3. Select "Build & Deploy PDev Source Tarball"
  4. Click "Run workflow" button
  5. Leave version empty (will auto-increment)
  6. Click green "Run workflow" button

- [ ] **Monitor Workflow Execution**
  1. Watch workflow run in Actions tab
  2. All steps should turn green
  3. Expected duration: ~45 seconds

- [ ] **Check Workflow Logs**
  1. Click on completed workflow run
  2. Expand each step and verify:
     - "Parse version from pdl-installer.sh" ✓
     - "Calculate new version" ✓
     - "Build pdev-source tarball" ✓
     - "Verify tarball contents" ✓
     - "Deploy tarball to acme" ✓
     - "Verify deployed tarball" ✓
     - "Update TARBALL_VERSION in pdl-installer.sh" ✓
     - "Create GitHub Release" ✓

- [ ] **Verify Deployment on acme**
  ```bash
  ssh github-deploy@acme "ls -lh /var/www/vyxenai.com/pdev/install/"
  ```
  - Should show: `pdev-source-vX.Y.Z.tar.gz` and `.sha256` file

- [ ] **Verify Web Accessibility**
  ```bash
  curl -I https://vyxenai.com/pdev/install/pdev-source-v1.1.0.tar.gz
  ```
  - Expected: HTTP 200 OK

- [ ] **Verify GitHub Release Created**
  1. Go to GitHub repository
  2. Click "Releases" (right sidebar)
  3. Should see new release: `pdev-source-vX.Y.Z`
  4. Verify files attached (tarball, checksum)
  5. Verify release notes generated

### Phase 6: Version Update Verification

- [ ] **Check pdl-installer.sh Update**
  ```bash
  grep TARBALL_VERSION installer/pdl-installer.sh
  ```
  - Should show new version (e.g., `TARBALL_VERSION="1.1.0"`)

- [ ] **Verify Git Commit**
  ```bash
  git log --oneline -3 | grep "Update TARBALL_VERSION"
  ```
  - Should show recent commit with version update

- [ ] **Pull Latest Changes**
  ```bash
  git pull origin main
  grep TARBALL_VERSION installer/pdl-installer.sh
  ```
  - Should show version from GitHub

### Phase 7: Integration Testing

- [ ] **Test Installer Script Can Find Tarball**
  1. On a clean system:
     ```bash
     bash /dev/null  # Verify bash works
     source installer/pdl-installer.sh
     echo "${TARBALL_VERSION}"
     # Should show: 1.1.0 (or current version)
     ```
  2. Verify installer can construct URL:
     ```bash
     TARBALL_URL="https://vyxenai.com/pdev/install/pdev-source-v${TARBALL_VERSION}.tar.gz"
     curl -I "${TARBALL_URL}"
     # Should return HTTP 200
     ```

- [ ] **Test Manual Installation from Deployed Tarball**
  1. Download tarball:
     ```bash
     curl -O https://vyxenai.com/pdev/install/pdev-source-v1.1.0.tar.gz
     ```
  2. Verify checksum:
     ```bash
     curl -O https://vyxenai.com/pdev/install/pdev-source-v1.1.0.tar.gz.sha256
     sha256sum -c pdev-source-v1.1.0.tar.gz.sha256
     # Expected: pdev-source-v1.1.0.tar.gz: OK
     ```
  3. Extract:
     ```bash
     tar -xzf pdev-source-v1.1.0.tar.gz
     ```
  4. Verify structure:
     ```bash
     ls -la | grep -E "server|installer|frontend|client"
     ```

### Phase 8: Security Verification

- [ ] **Verify SSH Key Permissions**
  ```bash
  stat ~/.ssh/deploy_key
  # Expected: Access: (0600/-rw-------)
  ```

- [ ] **Verify No Secrets in Logs**
  1. Go to GitHub Actions workflow logs
  2. Search for partial SSH key
  3. Should find NO results (masked)

- [ ] **Verify File Permissions After Deployment**
  ```bash
  ssh github-deploy@acme "ls -la /var/www/vyxenai.com/pdev/install/"
  ```
  - Tarball: `-rw-r--r--` (644) ✓
  - Checksum: `-rw-r--r--` (644) ✓
  - Owner: `www-data:www-data` ✓

- [ ] **Verify No .env or Secrets in Tarball**
  ```bash
  tar -tzf pdev-source-v*.tar.gz | grep -E "\.env|\.git|node_modules"
  # Should find nothing (or only node_modules from server/)
  ```

### Phase 9: Documentation & Training

- [ ] **Review Setup Documentation**
  - [ ] Read: GITHUB_ACTIONS_BUILD_GUIDE.md
  - [ ] Read: IMPLEMENTATION_SUMMARY.md
  - [ ] Understand: Workflow triggers and version management
  - [ ] Understand: Security model and SSH key handling

- [ ] **Create Team Documentation**
  - [ ] Add links to guides in project README
  - [ ] Share with development team
  - [ ] Train team on workflow triggers

- [ ] **Document Custom Configuration**
  - [ ] Note any modifications to default paths
  - [ ] Document any custom versions used
  - [ ] Record nginx configuration details

### Phase 10: Ongoing Monitoring

- [ ] **Set Up Email Notifications**
  1. GitHub: Settings → Email notifications
  2. Ensure "Failed workflow run" is enabled
  3. Verify email address is current

- [ ] **Monitor First 5 Deployments**
  - [ ] Each should complete successfully
  - [ ] Version should increment correctly
  - [ ] Tarball should be accessible
  - [ ] No errors in logs

- [ ] **Schedule Quarterly Security Review**
  - [ ] Review GitHub Actions logs
  - [ ] Rotate SSH keys
  - [ ] Audit deployment user access
  - [ ] Update documentation

## Troubleshooting During Setup

### SSH Connection Fails
**Symptom:** `Permission denied (publickey)`
**Solution:**
1. Verify public key added to authorized_keys
2. Verify file permissions: `chmod 600 ~/.ssh/authorized_keys`
3. Check SSH key format (should be ed25519 or RSA)
4. Verify github-deploy user exists: `id github-deploy`

### Checksum Mismatch
**Symptom:** Workflow fails with "Checksum mismatch"
**Solution:**
1. Check network connectivity to acme
2. Verify no firewall intercepting SCP
3. Check disk space on acme
4. Re-run workflow (may be transient error)

### Permission Denied on Deployment
**Symptom:** `sudo: command not found` or permission error
**Solution:**
1. Verify sudoers entry: `visudo` and check chown/chmod line
2. Verify NOPASSWD is set correctly
3. Test manually: `sudo -u github-deploy sudo chown --help`

### GitHub Secret Issues
**Symptom:** `$DEPLOY_KEY` is empty or null
**Solution:**
1. Verify secret is added in GitHub Settings
2. Verify secret name is exact: `VYXENAI_DEPLOY_KEY`
3. Re-add secret if unsure
4. Secrets are immutable (cannot view after creation)

### nginx 404 Errors
**Symptom:** `curl: (22) HTTP error 404`
**Solution:**
1. Verify nginx site is enabled: `ls -la /etc/nginx/sites-enabled/`
2. Verify nginx loaded config: `sudo nginx -t`
3. Verify directory exists: `ls -la /var/www/vyxenai.com/pdev/install/`
4. Check nginx logs: `sudo tail -f /var/log/nginx/error.log`

## Rollback Procedure

If something goes wrong during setup:

1. **Disable Workflow**
   ```bash
   # In GitHub: Actions → Build & Deploy → ... → Disable workflow
   ```

2. **Restore Previous Version**
   ```bash
   git checkout HEAD~1 installer/pdl-installer.sh
   git push origin main
   ```

3. **Clean Up Server**
   ```bash
   ssh github-deploy@acme "rm /var/www/vyxenai.com/pdev/install/pdev-source-v*.tar.gz*"
   ```

4. **Fix Issues** - Refer to troubleshooting above

5. **Re-Enable Workflow**
   ```bash
   # In GitHub: Actions → Build & Deploy → ... → Enable workflow
   ```

## Success Criteria

The setup is complete when:

- [x] All GitHub Secrets added
- [x] SSH key-pair generated and distributed
- [x] acme server has deployment directory
- [x] nginx configured and reloaded
- [x] First workflow run succeeds
- [x] Tarball deployed and accessible
- [x] GitHub Release created
- [x] All tests pass

## Next Steps After Setup

1. **Monitor First Week**
   - Watch for any errors in logs
   - Verify daily deployments work correctly
   - Check for any permission issues

2. **Document Lessons Learned**
   - Note any customizations made
   - Document any issues encountered
   - Update this checklist for future reference

3. **Plan Maintenance**
   - Set quarterly key rotation reminders
   - Schedule security reviews
   - Plan documentation updates

4. **Extend System**
   - Consider automatic nightly builds
   - Add additional verification tests
   - Plan for disaster recovery procedures

---

**Setup Started:** _________
**Setup Completed:** _________
**Completed By:** _________
**Reviewed By:** _________

For questions or issues, refer to GITHUB_ACTIONS_BUILD_GUIDE.md or contact the development team.
