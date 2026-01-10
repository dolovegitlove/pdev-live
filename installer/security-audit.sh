#!/bin/bash
# ============================================================================
# PDev-Live Security Audit Script
# ============================================================================
# Post-installation security validation for partner deployments
#
# Usage: sudo ./security-audit.sh
# ============================================================================

set -euo pipefail

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
INSTALL_DIR="/opt/pdev-live"
APP_USER="pdev-user"
DB_NAME="pdev_live"
DB_USER="pdev_app"

PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0

# Helper functions
print_header() {
    echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

check_pass() {
    echo -e "${GREEN}✓ $1${NC}"
    ((PASS_COUNT++))
}

check_fail() {
    echo -e "${RED}✗ $1${NC}"
    ((FAIL_COUNT++))
}

check_warn() {
    echo -e "${YELLOW}⚠ $1${NC}"
    ((WARN_COUNT++))
}

# Security checks
check_file_permissions() {
    print_header "File Permissions"

    # Check .env file permissions
    if [[ -f "$INSTALL_DIR/server/.env" ]]; then
        local perm=$(stat -c "%a" "$INSTALL_DIR/server/.env" 2>/dev/null || stat -f "%A" "$INSTALL_DIR/server/.env")
        if [[ "$perm" == "600" ]]; then
            check_pass ".env file permissions: $perm (correct)"
        else
            check_fail ".env file permissions: $perm (should be 600)"
        fi
    else
        check_fail ".env file not found at $INSTALL_DIR/server/.env"
    fi

    # Check .htpasswd permissions
    if [[ -f "/etc/nginx/.htpasswd" ]]; then
        local perm=$(stat -c "%a" "/etc/nginx/.htpasswd" 2>/dev/null || stat -f "%A" "/etc/nginx/.htpasswd")
        if [[ "$perm" == "644" ]]; then
            check_pass ".htpasswd permissions: $perm (correct)"
        else
            check_warn ".htpasswd permissions: $perm (should be 644 with root:www-data ownership)"
        fi
    else
        check_fail ".htpasswd file not found"
    fi

    # Check app directory ownership
    local owner=$(stat -c "%U" "$INSTALL_DIR" 2>/dev/null || stat -f "%Su" "$INSTALL_DIR")
    if [[ "$owner" == "$APP_USER" ]]; then
        check_pass "App directory owner: $owner (correct)"
    else
        check_fail "App directory owner: $owner (should be $APP_USER)"
    fi
}

check_ssl_configuration() {
    print_header "SSL/TLS Configuration"

    # Check if SSL certificate exists
    local domain=$(grep "PDEV_BASE_URL" "$INSTALL_DIR/server/.env" | cut -d'=' -f2 | sed 's|https://||' | sed 's|http://||' | tr -d ' ')

    if [[ -f "/etc/letsencrypt/live/$domain/fullchain.pem" ]]; then
        check_pass "SSL certificate found for $domain"

        # Check certificate expiration
        local expiry=$(openssl x509 -enddate -noout -in "/etc/letsencrypt/live/$domain/fullchain.pem" | cut -d'=' -f2)
        local expiry_epoch=$(date -d "$expiry" +%s 2>/dev/null || date -j -f "%b %d %T %Y %Z" "$expiry" +%s)
        local now_epoch=$(date +%s)
        local days_until_expiry=$(( ($expiry_epoch - $now_epoch) / 86400 ))

        if [[ $days_until_expiry -gt 30 ]]; then
            check_pass "SSL certificate valid for $days_until_expiry days"
        elif [[ $days_until_expiry -gt 0 ]]; then
            check_warn "SSL certificate expires in $days_until_expiry days (renew soon)"
        else
            check_fail "SSL certificate EXPIRED"
        fi
    else
        check_fail "SSL certificate not found for $domain"
    fi

    # Check certbot auto-renewal
    if systemctl is-enabled certbot.timer &>/dev/null; then
        check_pass "Certbot auto-renewal enabled"
    else
        check_warn "Certbot auto-renewal not enabled"
    fi
}

check_firewall() {
    print_header "Firewall Configuration"

    # Check if UFW is active
    if ufw status | grep -q "Status: active"; then
        check_pass "UFW firewall is active"

        # Check required ports
        if ufw status | grep -q "22/tcp.*ALLOW"; then
            check_pass "SSH port 22 allowed"
        else
            check_warn "SSH port 22 not explicitly allowed"
        fi

        if ufw status | grep -q "80/tcp.*ALLOW"; then
            check_pass "HTTP port 80 allowed"
        else
            check_fail "HTTP port 80 not allowed (needed for Let's Encrypt)"
        fi

        if ufw status | grep -q "443/tcp.*ALLOW"; then
            check_pass "HTTPS port 443 allowed"
        else
            check_fail "HTTPS port 443 not allowed"
        fi
    else
        check_fail "UFW firewall is not active"
    fi
}

check_fail2ban() {
    print_header "Fail2Ban Status"

    if systemctl is-active fail2ban &>/dev/null; then
        check_pass "Fail2Ban is running"

        # Check jails
        if fail2ban-client status | grep -q "nginx-auth"; then
            check_pass "Nginx auth jail configured"
        else
            check_warn "Nginx auth jail not found"
        fi

        if fail2ban-client status | grep -q "sshd"; then
            check_pass "SSH jail configured"
        else
            check_warn "SSH jail not configured"
        fi
    else
        check_fail "Fail2Ban is not running"
    fi
}

check_database_security() {
    print_header "Database Security"

    # Check PostgreSQL is listening on localhost only
    if ss -tulpn | grep postgres | grep -q "127.0.0.1:5432"; then
        check_pass "PostgreSQL listening on localhost only"
    else
        check_warn "PostgreSQL may be exposed to network"
    fi

    # Check database connection
    if sudo -u postgres psql -d "$DB_NAME" -c "SELECT 1" &>/dev/null; then
        check_pass "Database connection successful"
    else
        check_fail "Database connection failed"
    fi

    # Check database user privileges (should not be superuser)
    local is_superuser=$(sudo -u postgres psql -t -c "SELECT rolsuper FROM pg_roles WHERE rolname='$DB_USER';" | tr -d ' ')
    if [[ "$is_superuser" == "f" ]]; then
        check_pass "Database user is not superuser (correct)"
    else
        check_fail "Database user has superuser privileges (security risk)"
    fi
}

check_application_health() {
    print_header "Application Health"

    # Check PM2 process
    if sudo -u "$APP_USER" pm2 list | grep -q "pdev-live.*online"; then
        check_pass "PM2 process is running"
    else
        check_fail "PM2 process is not running"
    fi

    # Check HTTP health endpoint
    local http_status=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:3016/health)
    if [[ "$http_status" == "200" ]]; then
        check_pass "HTTP health endpoint responding (200)"
    else
        check_fail "HTTP health endpoint failed ($http_status)"
    fi

    # Check environment variables
    if [[ -f "$INSTALL_DIR/server/.env" ]]; then
        source "$INSTALL_DIR/server/.env"

        if [[ "$NODE_ENV" == "production" ]]; then
            check_pass "NODE_ENV set to production"
        else
            check_warn "NODE_ENV not set to production ($NODE_ENV)"
        fi

        if [[ -n "$PDEV_ADMIN_KEY" ]] && [[ ${#PDEV_ADMIN_KEY} -ge 32 ]]; then
            check_pass "PDEV_ADMIN_KEY configured (${#PDEV_ADMIN_KEY} chars)"
        else
            check_fail "PDEV_ADMIN_KEY too short or missing"
        fi

        if [[ "$PDEV_BASE_URL" == https://* ]]; then
            check_pass "PDEV_BASE_URL uses HTTPS"
        else
            check_fail "PDEV_BASE_URL not using HTTPS ($PDEV_BASE_URL)"
        fi

        if [[ "$PDEV_HTTP_AUTH" == "true" ]]; then
            check_pass "HTTP Basic Auth enabled (defense-in-depth)"
        else
            check_warn "HTTP Basic Auth disabled (relying only on nginx)"
        fi
    else
        check_fail ".env file not found"
    fi
}

check_nginx_security() {
    print_header "Nginx Security"

    # Check if nginx is running
    if systemctl is-active nginx &>/dev/null; then
        check_pass "Nginx is running"
    else
        check_fail "Nginx is not running"
    fi

    # Check nginx configuration
    if nginx -t 2>&1 | grep -q "syntax is ok"; then
        check_pass "Nginx configuration valid"
    else
        check_fail "Nginx configuration has errors"
    fi

    # Check for security headers in config
    local nginx_config="/etc/nginx/sites-available/pdev-live"
    if [[ -f "$nginx_config" ]]; then
        if grep -q "Strict-Transport-Security" "$nginx_config"; then
            check_pass "HSTS header configured"
        else
            check_warn "HSTS header missing"
        fi

        if grep -q "X-Frame-Options" "$nginx_config"; then
            check_pass "X-Frame-Options header configured"
        else
            check_warn "X-Frame-Options header missing"
        fi

        if grep -q "auth_basic" "$nginx_config"; then
            check_pass "HTTP Basic Auth configured in nginx"
        else
            check_fail "HTTP Basic Auth not configured in nginx"
        fi
    else
        check_fail "Nginx config file not found"
    fi
}

check_system_updates() {
    print_header "System Updates"

    # Check for available security updates
    if command -v apt &>/dev/null; then
        apt-get update -qq
        local security_updates=$(apt-get -s upgrade | grep -i security | wc -l)

        if [[ $security_updates -eq 0 ]]; then
            check_pass "No security updates available"
        else
            check_warn "$security_updates security updates available (run apt-get upgrade)"
        fi
    fi

    # Check if unattended-upgrades is installed
    if dpkg -l | grep -q unattended-upgrades; then
        check_pass "Unattended upgrades installed"
    else
        check_warn "Unattended upgrades not installed (recommend installing)"
    fi
}

check_open_ports() {
    print_header "Open Ports"

    # List all listening ports
    echo "Listening ports:"
    ss -tulpn | grep LISTEN | while read line; do
        echo "  $line"
    done

    # Check for unexpected open ports
    local unexpected_ports=$(ss -tulpn | grep LISTEN | grep -v "127.0.0.1" | grep -v ":22" | grep -v ":80" | grep -v ":443" | grep -v ":5432" | wc -l)

    if [[ $unexpected_ports -eq 0 ]]; then
        check_pass "No unexpected open ports"
    else
        check_warn "$unexpected_ports unexpected open ports detected"
    fi
}

# Generate final report
generate_report() {
    print_header "Security Audit Summary"

    local total=$((PASS_COUNT + WARN_COUNT + FAIL_COUNT))

    echo -e "${GREEN}✓ Passed: $PASS_COUNT${NC}"
    echo -e "${YELLOW}⚠ Warnings: $WARN_COUNT${NC}"
    echo -e "${RED}✗ Failed: $FAIL_COUNT${NC}"
    echo ""
    echo "Total checks: $total"
    echo ""

    if [[ $FAIL_COUNT -eq 0 ]]; then
        echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${GREEN}✓ Security audit PASSED${NC}"
        echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        exit 0
    elif [[ $FAIL_COUNT -le 2 ]] && [[ $WARN_COUNT -le 5 ]]; then
        echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${YELLOW}⚠ Security audit completed with warnings${NC}"
        echo -e "${YELLOW}Please address the failed checks above${NC}"
        echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        exit 1
    else
        echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${RED}✗ Security audit FAILED${NC}"
        echo -e "${RED}Critical security issues detected - please fix immediately${NC}"
        echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        exit 2
    fi
}

# Main execution
main() {
    clear

    cat <<'EOF'
╔═══════════════════════════════════════════════════════════════╗
║                                                               ║
║           PDev-Live Security Audit                            ║
║                                                               ║
╚═══════════════════════════════════════════════════════════════╝
EOF

    echo ""
    echo "Starting security audit..."
    echo "Timestamp: $(date)"
    echo ""

    check_file_permissions
    check_ssl_configuration
    check_firewall
    check_fail2ban
    check_database_security
    check_application_health
    check_nginx_security
    check_system_updates
    check_open_ports

    generate_report
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root (use sudo)"
    exit 1
fi

main "$@"
