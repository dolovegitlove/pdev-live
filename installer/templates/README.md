# PDev-Live Installer Templates

Reusable configuration templates for deploying PDev-Live installer instances across different projects.

## Purpose

These templates allow you to create **installer instances** (like `vyxenai-installer`) that run the installation wizard for deploying pdev-live to other servers. The templates are project-agnostic and can be reused by simply substituting variable placeholders.

## Templates

### 1. `ecosystem.config.template.js`
PM2 configuration template for installer services.

**Variables:**
- `{{SERVICE_NAME}}` - PM2 process name (e.g., "myproject-installer")
- `{{INSTALL_PATH}}` - Installation directory (e.g., "/opt/services/myproject-installer/server")
- `{{VERSION}}` - Version string (e.g., "1.0.0")
- `{{PORT}}` - HTTP server port (e.g., "3078")

**Usage:**
```bash
sed -e "s|{{SERVICE_NAME}}|myproject-installer|g" \
    -e "s|{{INSTALL_PATH}}|/opt/services/myproject-installer/server|g" \
    -e "s|{{VERSION}}|1.0.0|g" \
    -e "s|{{PORT}}|3078|g" \
    ecosystem.config.template.js > ecosystem.config.js
```

### 2. `.env.installer.template`
Environment variables template for installer services.

**Variables:**
- `{{PORT}}` - HTTP server port
- `{{PDEV_BASE_URL}}` - Public-facing URL (e.g., "https://vyxenai.com/pdev")
- `{{DB_HOST}}`, `{{DB_PORT}}`, `{{DB_NAME}}`, `{{DB_USER}}`, `{{DB_PASSWORD}}` - Database credentials
- `{{ADMIN_KEY}}` - Admin API key (generate with `openssl rand -base64 32`)
- `{{HTTP_AUTH}}` - Enable HTTP Basic Auth (true/false)
- `{{VALID_SERVERS}}` - CSV list of servers that can install pdev-live

**Usage:**
```bash
sed -e "s|{{PORT}}|3078|g" \
    -e "s|{{PDEV_BASE_URL}}|https://myproject.com/pdev|g" \
    -e "s|{{DB_HOST}}|localhost|g" \
    -e "s|{{DB_PORT}}|5432|g" \
    -e "s|{{DB_NAME}}|myproject_installer|g" \
    -e "s|{{DB_USER}}|myproject_app|g" \
    -e "s|{{DB_PASSWORD}}|$(openssl rand -base64 24)|g" \
    -e "s|{{ADMIN_KEY}}|$(openssl rand -base64 32)|g" \
    -e "s|{{HTTP_AUTH}}|false|g" \
    -e "s|{{VALID_SERVERS}}|server1,server2|g" \
    .env.installer.template > .env
```

## Example: Creating vyxenai-installer

**Step 1: Generate Secrets**
```bash
DB_PASSWORD=$(openssl rand -base64 24)
ADMIN_KEY=$(openssl rand -base64 32)
```

**Step 2: Create ecosystem.config.js**
```bash
sed -e "s|{{SERVICE_NAME}}|vyxenai-installer|g" \
    -e "s|{{INSTALL_PATH}}|/opt/services/vyxenai-installer/server|g" \
    -e "s|{{VERSION}}|1.0.0|g" \
    -e "s|{{PORT}}|3078|g" \
    ecosystem.config.template.js > /opt/services/vyxenai-installer/server/ecosystem.config.js
```

**Step 3: Create .env**
```bash
sed -e "s|{{PORT}}|3078|g" \
    -e "s|{{PDEV_BASE_URL}}|https://vyxenai.com/pdev|g" \
    -e "s|{{DB_HOST}}|localhost|g" \
    -e "s|{{DB_PORT}}|5432|g" \
    -e "s|{{DB_NAME}}|vyxenai_installer|g" \
    -e "s|{{DB_USER}}|vyxenai_app|g" \
    -e "s|{{DB_PASSWORD}}|$DB_PASSWORD|g" \
    -e "s|{{ADMIN_KEY}}|$ADMIN_KEY|g" \
    -e "s|{{HTTP_AUTH}}|false|g" \
    -e "s|{{VALID_SERVERS}}|acme,ittz,cfree,djm,wdress,rmlve|g" \
    .env.installer.template > /opt/services/vyxenai-installer/server/.env

chmod 600 /opt/services/vyxenai-installer/server/.env
```

**Step 4: Start Service**
```bash
pm2 start /opt/services/vyxenai-installer/server/ecosystem.config.js
```

## Reusing for Other Projects

To create an installer for a different project:

1. **Choose unique values:**
   - Service name: `myproject-installer`
   - Port: Choose unused port (e.g., 3079)
   - Database: `myproject_installer`
   - Base URL: `https://myproject.com/pdev`

2. **Follow the example steps** above with your values

3. **Verify no conflicts:**
   - Check port not already in use: `ss -tlnp | grep 3079`
   - Verify database doesn't exist: `psql -l | grep myproject_installer`
   - Check PM2 service name unique: `pm2 list | grep myproject-installer`

## vs .env.partner.template

- **`.env.installer.template`** - For INSTALLER instances that run the wizard
- **`.env.partner.template`** - For PRODUCTION pdev-live instances deployed BY the wizard

The installer creates production instances, which use `.env.partner.template`.

## Security

- **NEVER commit .env files** - They contain secrets
- **Always use chmod 600** on .env files
- **Generate unique secrets** per installation (`openssl rand -base64 32`)
- **Use different database passwords** per instance
