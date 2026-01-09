# PDev-Live Partner Onboarding Checklist

**Purpose:** Step-by-step guide for partners deploying PDev-Live
**Audience:** Technical staff setting up PDev-Live on their infrastructure
**Estimated Time:** 2-4 hours (first deployment)

---

## Prerequisites

### System Requirements
- [ ] Ubuntu 22.04 LTS or newer
- [ ] Root/sudo access
- [ ] 2GB+ RAM, 20GB+ disk space
- [ ] Domain name pointed to server IP
- [ ] Ports 80, 443 open (for nginx)
- [ ] Port 3077 available (internal API)

### Technical Knowledge
- [ ] Basic Linux command line
- [ ] SSH access configuration
- [ ] PostgreSQL basics (helpful but not required)
- [ ] Nginx/web server basics

### Pre-Installation Decisions

**Question 1: What is your company's domain?**
- Example: `acme-corp.com`, `mycompany.io`
- Used for: SSL certificates, API URLs, frontend access
- **Action:** Record domain: `________________________`

**Question 2: What server name do you want?**
- Example: `prod-server`, `pdev-01`, `main`
- Used for: Session tagging, CLI auto-detection
- **Action:** Record server name: `________________________`

**Question 3: What are your server IP addresses?**
- Used for: API access whitelist (security)
- Include all servers that will POST to PDev Live API
- **Action:** List IP addresses:
  ```
  1. ________________________ (primary server)
  2. ________________________ (secondary server, if any)
  3. ________________________ (development server, if any)
  ```

**Question 4: Where will files be deployed?**
- Default: `/var/www/YOUR-DOMAIN/pdev` (frontend)
- Default: `/opt/services/pdev-live` (backend)
- **Action:** Use defaults? [ ] Yes [ ] No (specify custom paths below)
  - Frontend path: `________________________`
  - Backend path: `________________________`

**Question 5: What deployment user will be used?**
- Default: `deploy` (recommended)
- This user needs sudo access for installation
- **Action:** Record user: `________________________`

**Question 6: Database credentials**
- PostgreSQL will be installed automatically
- **Action:** Choose a strong password (min 32 characters):
  ```bash
  # Generate secure password:
  openssl rand -base64 32
  ```
- Record password: `________________________`

**Question 7: HTTP Basic Auth credentials**
- Protects web interface from unauthorized access
- **Action:** Choose credentials:
  - Username: `________________________` (default: `pdev`)
  - Password: `________________________` (generate: `openssl rand -base64 24`)

**Question 8: Session secret**
- Used for Express session encryption
- **Action:** Generate:
  ```bash
  openssl rand -base64 32
  ```
- Record secret: `________________________`

---

## Phase 1: Preparation (30 minutes)

### Step 1.1: Clone Repository
```bash
cd ~
git clone https://github.com/dolovegitlove/pdev-live.git
cd pdev-live
```

- [ ] Repository cloned successfully

### Step 1.2: Create Configuration File
```bash
cd ~/pdev-live
cp .env.partner.example .env
nano .env
```

**Configure these critical values:**

```bash
# REQUIRED - Replace with your values
PARTNER_DOMAIN=your-company.com
PARTNER_NAME="Your Company Name"
PARTNER_SERVER_NAME=prod-server-01

# REQUIRED - Server inventory (comma-separated)
VALID_SERVERS=prod-server-01,dev-server,staging

# REQUIRED - IP addresses for API whitelist
ALLOWED_IPS=127.0.0.1,::1,YOUR_SERVER_IP_1,YOUR_SERVER_IP_2

# REQUIRED - Database password
DB_PASSWORD=YOUR_SECURE_32_CHAR_PASSWORD

# REQUIRED - Authentication
PDEV_AUTH_USER=pdev
PDEV_AUTH_PASSWORD=YOUR_SECURE_24_CHAR_PASSWORD
SESSION_SECRET=YOUR_SECURE_32_CHAR_SESSION_SECRET

# OPTIONAL - Deployment paths (defaults usually OK)
# DEPLOY_USER=deploy
# FRONTEND_DEPLOY_PATH=/var/www/${PARTNER_DOMAIN}/pdev
# BACKEND_SERVICE_PATH=/opt/services/pdev-live
```

- [ ] `.env` file created
- [ ] `PARTNER_DOMAIN` configured
- [ ] `PARTNER_SERVER_NAME` configured
- [ ] `VALID_SERVERS` list configured
- [ ] `ALLOWED_IPS` configured with your server IPs
- [ ] `DB_PASSWORD` set (32+ characters)
- [ ] `PDEV_AUTH_PASSWORD` set (24+ characters)
- [ ] `SESSION_SECRET` set (32+ characters)
- [ ] File saved: `Ctrl+O`, `Enter`, `Ctrl+X`

### Step 1.3: Validate Configuration
```bash
node -e "const cfg = require('./config'); console.log('Partner:', cfg.partner); console.log('Servers:', cfg.servers.valid); console.log('Allowed IPs:', cfg.servers.allowedIps);"
```

**Expected output:**
```
Partner: { domain: 'your-company.com', serverName: 'prod-server-01', ... }
Servers: [ 'prod-server-01', 'dev-server', 'staging' ]
Allowed IPs: [ '127.0.0.1', '::1', 'YOUR_SERVER_IP_1', ... ]
```

- [ ] Configuration validates successfully
- [ ] Domain shows correctly
- [ ] Server names show correctly
- [ ] IP addresses show correctly

---

## Phase 2: Installation (60 minutes)

### Step 2.1: Run Installer
```bash
cd ~/pdev-live/installer
sudo ./pdl-installer.sh --domain your-company.com
```

**Installer will:**
1. Install PostgreSQL (if not present)
2. Create `pdev_live` database
3. Install Node.js (if not present)
4. Install nginx (if not present)
5. Configure nginx with SSL (Let's Encrypt)
6. Install PM2 process manager
7. Deploy frontend files
8. Deploy backend service
9. Start services

**Common prompts:**
- `Enter email for Let's Encrypt:` - Your email for SSL cert notifications
- `Agree to Let's Encrypt ToS? (Y/n):` - Type `Y`

- [ ] Installer completed without errors
- [ ] PostgreSQL installed
- [ ] Database created
- [ ] Nginx configured
- [ ] SSL certificates obtained
- [ ] PM2 installed
- [ ] Services started

### Step 2.2: Deploy Configuration to Server
```bash
# Copy .env to production server
scp ~/pdev-live/.env your-server:/opt/services/pdev-live/.env

# Set correct permissions
ssh your-server "chmod 600 /opt/services/pdev-live/.env"

# Restart services to load config
ssh your-server "pm2 restart pdev-live"
```

- [ ] `.env` copied to server
- [ ] Permissions set (600)
- [ ] PM2 restarted successfully

### Step 2.3: Verify Services Running
```bash
ssh your-server "pm2 status pdev-live"
```

**Expected output:**
```
┌─────┬────────────┬─────────┬─────────┬──────────┐
│ id  │ name       │ status  │ restart │ uptime   │
├─────┼────────────┼─────────┼─────────┼──────────┤
│ 0   │ pdev-live  │ online  │ 0       │ 30s      │
└─────┴────────────┴─────────┴─────────┴──────────┘
```

- [ ] Status shows `online`
- [ ] Restart count is low (< 5)
- [ ] Uptime > 10s

---

## Phase 3: Verification (30 minutes)

### Step 3.1: Test API Endpoint
```bash
curl -I https://your-company.com/pdev/api/health
```

**Expected:**
```
HTTP/2 200
content-type: application/json
```

- [ ] Returns `200 OK`
- [ ] No SSL errors
- [ ] Response time < 2s

### Step 3.2: Test Frontend Access
```bash
curl -I -u pdev:YOUR_PASSWORD https://your-company.com/pdev/live/
```

**Expected:**
```
HTTP/2 200
content-type: text/html
```

- [ ] Returns `200 OK`
- [ ] HTTP Basic Auth works
- [ ] HTML content returned

### Step 3.3: Test CLI Client
```bash
# Set environment variables
export PDEV_LIVE_URL=https://your-company.com/pdev/api
export PDEV_BASE_URL=https://your-company.com/pdev

# Test session creation
~/pdev-live/client/client.sh start test-project idea "Test deployment"
```

**Expected:**
- Session created
- Session ID returned
- Stream starts

- [ ] CLI client connects
- [ ] Session created successfully
- [ ] Stream begins

### Step 3.4: View in Browser
1. Open browser: `https://your-company.com/pdev/live/`
2. Enter HTTP Basic Auth credentials
3. View dashboard

- [ ] Browser loads dashboard
- [ ] Authentication successful
- [ ] Test session appears in list
- [ ] Session can be viewed

### Step 3.5: Test IP Whitelist
```bash
# From an UNAUTHORIZED IP (not in ALLOWED_IPS), run:
curl https://your-company.com/pdev/api/health
```

**Expected:**
```
HTTP/2 403
{"error": "Access denied"}
```

- [ ] Returns `403 Forbidden`
- [ ] Error message shows "Access denied"
- [ ] Logs show blocked IP (check with: `ssh your-server "pm2 logs pdev-live --lines 10"`)

---

## Phase 4: Desktop Client (Optional, 60 minutes)

### Step 4.1: Configure Desktop App
```bash
cd ~/pdev-live/desktop
nano package.json
```

**Update these lines:**
```json
{
  "homepage": "https://your-company.com/pdev/live/",
  "publish": {
    "url": "https://your-company.com/pdev/releases/"
  }
}
```

- [ ] `homepage` URL updated
- [ ] `publish.url` updated
- [ ] File saved

### Step 4.2: Build Desktop App
```bash
cd ~/pdev-live/desktop
npm install
npm run build:linux  # For Linux
npm run build:mac    # For macOS
npm run build:win    # For Windows
```

- [ ] Dependencies installed
- [ ] Build completed
- [ ] Output in `dist/` directory

### Step 4.3: Deploy Desktop Releases
```bash
scp dist/*.deb your-server:/var/www/your-company.com/pdev/releases/
scp dist/*.dmg your-server:/var/www/your-company.com/pdev/releases/
scp dist/*.exe your-server:/var/www/your-company.com/pdev/releases/
```

- [ ] Linux package uploaded
- [ ] macOS package uploaded (if built)
- [ ] Windows package uploaded (if built)

---

## Phase 5: Client Deployment (30 minutes per client server)

For each additional server that will POST to PDev Live:

### Step 5.1: Install CLI Client
```bash
# On client server
ssh client-server
cd ~
git clone https://github.com/dolovegitlove/pdev-live.git

# Create client config
cat > ~/.pdev-live-config <<EOF
PDEV_LIVE_URL=https://your-company.com/pdev/api
PDEV_BASE_URL=https://your-company.com/pdev
PDEV_SERVER=$(hostname -s)
EOF

chmod 600 ~/.pdev-live-config
```

- [ ] Repository cloned on client server
- [ ] `.pdev-live-config` created
- [ ] Permissions set

### Step 5.2: Add Client IP to Whitelist

**On main server, edit `.env`:**
```bash
ssh your-server
nano /opt/services/pdev-live/.env

# Add client IP to ALLOWED_IPS
ALLOWED_IPS=127.0.0.1,::1,EXISTING_IPS,NEW_CLIENT_IP

# Restart to load new config
pm2 restart pdev-live
```

- [ ] Client IP added to whitelist
- [ ] Service restarted
- [ ] No errors in logs

### Step 5.3: Test from Client Server
```bash
ssh client-server
~/pdev-live/client/client.sh start test-project idea "Test from client"
```

- [ ] Session creates successfully
- [ ] Shows in dashboard with correct `server_origin` tag

---

## Phase 6: Security Hardening (30 minutes)

### Step 6.1: Firewall Configuration
```bash
ssh your-server
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw enable
sudo ufw status
```

- [ ] UFW enabled
- [ ] Port 80 allowed (HTTP)
- [ ] Port 443 allowed (HTTPS)
- [ ] Port 3077 NOT exposed (internal only)

### Step 6.2: File Permissions Audit
```bash
ssh your-server
ls -la /opt/services/pdev-live/.env
# Should show: -rw------- (600)

ls -la /var/www/your-company.com/pdev/
# Should show: drwxr-xr-x (755) for directories
# Should show: -rw-r--r-- (644) for files
```

- [ ] `.env` is `600` (owner read/write only)
- [ ] Frontend files are `644`
- [ ] Directories are `755`

### Step 6.3: SSL Certificate Renewal
```bash
ssh your-server
sudo certbot renew --dry-run
```

**Expected:** `Congratulations, all simulated renewals succeeded`

- [ ] Dry run succeeds
- [ ] Auto-renewal configured (certbot timer active)

### Step 6.4: Database Access Restriction
```bash
ssh your-server
sudo nano /etc/postgresql/*/main/pg_hba.conf
```

**Ensure only local access:**
```
local   pdev_live   pdev_user   scram-sha-256
host    pdev_live   pdev_user   127.0.0.1/32   scram-sha-256
```

- [ ] No remote access configured
- [ ] Only localhost allowed
- [ ] PostgreSQL restarted: `sudo systemctl restart postgresql`

---

## Phase 7: Monitoring Setup (30 minutes)

### Step 7.1: PM2 Log Rotation
```bash
ssh your-server
pm2 install pm2-logrotate
pm2 set pm2-logrotate:max_size 10M
pm2 set pm2-logrotate:retain 7
pm2 save
```

- [ ] Log rotation installed
- [ ] Max size: 10MB
- [ ] Retention: 7 days

### Step 7.2: Health Check Script
```bash
ssh your-server
cat > /opt/services/pdev-live/health-check.sh <<'EOF'
#!/bin/bash
STATUS=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:3077/health)
if [ "$STATUS" != "200" ]; then
  echo "Health check failed: $STATUS"
  pm2 restart pdev-live
fi
EOF

chmod +x /opt/services/pdev-live/health-check.sh

# Add to cron (every 5 minutes)
(crontab -l 2>/dev/null; echo "*/5 * * * * /opt/services/pdev-live/health-check.sh") | crontab -
```

- [ ] Health check script created
- [ ] Executable permissions set
- [ ] Cron job added

### Step 7.3: Disk Space Monitoring
```bash
ssh your-server
df -h /var/www/your-company.com/pdev-backups/
# Should have > 5GB free
```

- [ ] > 5GB free space
- [ ] Backup retention configured (30 days default)

---

## Phase 8: Documentation (15 minutes)

### Step 8.1: Document Configuration
Create internal wiki/doc with:

- [ ] PDev Live URL: `https://your-company.com/pdev/live/`
- [ ] API URL: `https://your-company.com/pdev/api`
- [ ] HTTP Basic Auth credentials
- [ ] Server IP addresses in whitelist
- [ ] Deployment paths
- [ ] PM2 process name: `pdev-live`
- [ ] Database name: `pdev_live`
- [ ] Log locations: `/opt/services/pdev-live/logs/`

### Step 8.2: Team Training
- [ ] Share access credentials with team
- [ ] Demonstrate dashboard usage
- [ ] Show CLI client usage: `/idea`, `/spec`, etc.
- [ ] Explain session tagging by server origin

### Step 8.3: Backup Procedures
Document:
- [ ] Database backup: `pg_dump pdev_live > backup.sql`
- [ ] Frontend backup: Stored automatically in `/var/www/.../pdev-backups/`
- [ ] Configuration backup: Copy `.env` file off-server
- [ ] Recovery procedure: Restore from backup + redeploy

---

## Troubleshooting

### Issue: 502 Bad Gateway
**Symptoms:** Nginx shows 502 error

**Fix:**
```bash
ssh your-server "pm2 logs pdev-live --lines 50"
# Look for errors
ssh your-server "pm2 restart pdev-live"
```

### Issue: Database Connection Failed
**Symptoms:** PM2 logs show `ECONNREFUSED`

**Fix:**
```bash
ssh your-server "systemctl status postgresql"
ssh your-server "psql -U pdev_user -d pdev_live -c 'SELECT 1;'"
# Check DB_PASSWORD in .env matches PostgreSQL password
```

### Issue: SSL Certificate Error
**Symptoms:** Browser shows SSL warning

**Fix:**
```bash
ssh your-server "sudo certbot renew --force-renewal"
ssh your-server "sudo systemctl reload nginx"
```

### Issue: IP Whitelist Blocking Legitimate Requests
**Symptoms:** `403 Access denied` for valid servers

**Fix:**
```bash
# Check actual IP from logs
ssh your-server "pm2 logs pdev-live --lines 20 | grep 'Blocked request'"

# Add IP to .env
ssh your-server "nano /opt/services/pdev-live/.env"
# Update ALLOWED_IPS=...
ssh your-server "pm2 restart pdev-live"
```

---

## Post-Deployment Checklist

- [ ] All services running (`pm2 status`)
- [ ] API accessible (`curl health endpoint`)
- [ ] Frontend loads in browser
- [ ] CLI client connects successfully
- [ ] IP whitelist tested (blocks unauthorized IPs)
- [ ] SSL certificates valid (check browser)
- [ ] Firewall configured (ufw status)
- [ ] Log rotation enabled
- [ ] Health checks running (cron)
- [ ] Team trained on usage
- [ ] Documentation created
- [ ] Backup procedures tested

---

## Questions You Should Be Asking

### Security
1. **Who needs access to the PDev Live dashboard?**
   - Action: Create separate HTTP Basic Auth credentials per user/team

2. **How do we rotate credentials?**
   - Action: Document password rotation procedure in internal wiki

3. **What happens if `.env` file is compromised?**
   - Action: Regenerate all secrets, update on server, restart services

4. **Are logs being shipped to external monitoring?**
   - Action: Configure Logstash/Fluentd/CloudWatch if required

### Scaling
5. **What happens when we add new servers?**
   - Action: Add server name to `VALID_SERVERS`, IP to `ALLOWED_IPS`

6. **Can we deploy to multiple environments (dev/staging/prod)?**
   - Action: Yes - separate `.env` per environment

7. **What's the database growth rate?**
   - Action: Monitor disk space, configure PostgreSQL auto-vacuum

8. **How do we handle high traffic?**
   - Action: Increase PM2 instances (`PM2_INSTANCES` in `.env`)

### Maintenance
9. **How do we update PDev Live?**
   - Action: `git pull`, run `./update.sh` deployment script

10. **What's the backup strategy?**
    - Action: Automate `pg_dump` daily, backup `.env` off-server

11. **How do we test before deploying updates?**
    - Action: Set up staging environment with separate `.env`

12. **Who is on-call for PDev Live issues?**
    - Action: Add to PagerDuty/OpsGenie rotation

### Compliance
13. **Does this store any PII/PHI/sensitive data?**
    - Answer: Session metadata only (project names, timestamps)
    - Action: Review data retention policy

14. **Do we need audit logs?**
    - Action: Configure PostgreSQL logging, ship to SIEM

15. **What's the disaster recovery plan?**
    - Action: Document RTO/RPO, test recovery procedure

---

## Success Criteria

✅ **Installation Complete When:**
- Dashboard accessible at `https://your-company.com/pdev/live/`
- API returns `200 OK` at `/health` endpoint
- CLI client creates sessions successfully
- Sessions appear in dashboard with correct `server_origin`
- IP whitelist blocks unauthorized access
- SSL certificates valid and auto-renewing
- PM2 shows status `online` with < 5 restarts
- Logs show no errors for 10+ minutes
- Team can access and use system

---

## Support

**Documentation:**
- Configuration Guide: `~/pdev-live/PARTNER_CONFIGURATION_GUIDE.md`
- Refactoring Summary: `~/pdev-live/REFACTORING_SUMMARY.md`
- Deployment Guide: `~/pdev-live/DEPLOYMENT.md`
- README: `~/pdev-live/README.md`

**Common Commands:**
```bash
# Check status
ssh your-server "pm2 status pdev-live"

# View logs
ssh your-server "pm2 logs pdev-live --lines 50"

# Restart service
ssh your-server "pm2 restart pdev-live"

# Test health
curl https://your-company.com/pdev/api/health
```

---

**Document Owner:** PDev-Live Team
**Version:** 1.0
**Last Updated:** 2026-01-08
