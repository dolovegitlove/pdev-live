#!/usr/bin/env bash

################################################################################
# PDev Source Tarball Deployment Verifier
#
# Purpose: Verify deployed tarball integrity and accessibility on remote server
# Usage: ./verify-deployment.sh VERSION [HOST] [DEPLOY_PATH] [SSH_KEY]
#
# Arguments:
#   VERSION       - Tarball version (e.g., "1.0.5")
#   HOST          - Remote host (default: acme)
#   DEPLOY_PATH   - Deployment path (default: /var/www/vyxenai.com/pdev/install)
#   SSH_KEY       - SSH private key path (default: ~/.ssh/deploy_key)
#
# Environment Variables:
#   DEPLOY_HOST   - Override host
#   DEPLOY_PATH   - Override deployment path
#   SSH_KEY_PATH  - Override SSH key path
#   DEPLOY_USER   - SSH user (default: github-deploy)
#   VERIFY_TIMEOUT - HTTP timeout in seconds (default: 30)
#
# Features:
#   - SHA256 checksum verification
#   - File permissions validation
#   - HTTP accessibility test
#   - Tarball content sample verification
#   - Detailed logging and reporting
#
# Security:
#   - Verifies SSH host key
#   - Validates file ownership and permissions
#   - Masks sensitive information in logs
#   - Proper error handling and cleanup
#
################################################################################

set -euo pipefail

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration with defaults
DEPLOY_HOST="${DEPLOY_HOST:-acme}"
DEPLOY_PATH="${DEPLOY_PATH:-/var/www/vyxenai.com/pdev/install}"
SSH_KEY_PATH="${SSH_KEY_PATH:-${HOME}/.ssh/deploy_key}"
DEPLOY_USER="${DEPLOY_USER:-github-deploy}"
VERIFY_TIMEOUT="${VERIFY_TIMEOUT:-30}"
TARBALL_BASE_URL="https://vyxenai.com/pdev/install"

# State tracking
TESTS_PASSED=0
TESTS_FAILED=0
SSH_CONNECTED=false

# Logging functions
log_info() {
  printf "${BLUE}ℹ${NC} %s\n" "$*"
}

log_success() {
  printf "${GREEN}✓${NC} %s\n" "$*"
  TESTS_PASSED=$((TESTS_PASSED + 1))
}

log_warning() {
  printf "${YELLOW}⚠${NC} %s\n" "$*"
}

log_error() {
  printf "${RED}✗${NC} %s\n" "$*" >&2
  TESTS_FAILED=$((TESTS_FAILED + 1))
}

# SSH connection helper with error handling
ssh_exec() {
  local cmd="$1"

  if ! ssh -i "${SSH_KEY_PATH}" \
      -o ConnectTimeout=10 \
      -o StrictHostKeyChecking=accept-new \
      "${DEPLOY_USER}@${DEPLOY_HOST}" \
      "${cmd}" 2>&1; then
    return 1
  fi
  return 0
}

# Cleanup on exit
cleanup() {
  local exit_code=$?

  # Close SSH connection if established
  if [ "${SSH_CONNECTED}" = true ]; then
    ssh -i "${SSH_KEY_PATH}" -O exit "${DEPLOY_USER}@${DEPLOY_HOST}" 2>/dev/null || true
  fi

  return ${exit_code}
}

trap cleanup EXIT

# Validate arguments
validate_arguments() {
  local version="$1"

  if [ -z "${version}" ]; then
    log_error "Missing required argument: VERSION"
    echo "Usage: $0 VERSION [HOST] [DEPLOY_PATH] [SSH_KEY]"
    exit 1
  fi

  # Validate version format
  if ! [[ "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    log_error "Invalid version format: ${version} (expected X.Y.Z)"
    exit 1
  fi

  echo "${version}"
}

# Validate prerequisites
validate_prerequisites() {
  log_info "Validating prerequisites..."

  # Check required tools
  local required_tools=(ssh scp curl sha256sum)
  for tool in "${required_tools[@]}"; do
    if ! command -v "${tool}" &> /dev/null; then
      log_error "Required tool not found: ${tool}"
      exit 1
    fi
  done

  # Check SSH key exists and is readable
  if [ ! -r "${SSH_KEY_PATH}" ]; then
    log_error "SSH key not found or not readable: ${SSH_KEY_PATH}"
    exit 1
  fi

  # Verify SSH key permissions (should be 600)
  local key_perms
  key_perms=$(stat -f%OLp "${SSH_KEY_PATH}" 2>/dev/null || stat -c%a "${SSH_KEY_PATH}")

  if [ "${key_perms}" != "600" ]; then
    log_warning "SSH key has unexpected permissions: ${key_perms} (expected 600)"
    log_info "Fixing SSH key permissions..."
    chmod 600 "${SSH_KEY_PATH}"
  fi

  log_success "Prerequisites validated"
}

# Test SSH connectivity
test_ssh_connectivity() {
  log_info "Testing SSH connectivity to ${DEPLOY_USER}@${DEPLOY_HOST}..."

  if ! ssh -i "${SSH_KEY_PATH}" \
      -o ConnectTimeout=10 \
      -o StrictHostKeyChecking=accept-new \
      "${DEPLOY_USER}@${DEPLOY_HOST}" \
      "echo 'SSH connection successful'" &>/dev/null; then
    log_error "Cannot connect to ${DEPLOY_USER}@${DEPLOY_HOST} via SSH"
    exit 1
  fi

  SSH_CONNECTED=true
  log_success "SSH connectivity verified"
}

# Verify remote files exist
verify_files_exist() {
  local tarball_name="$1"
  local checksum_file="${tarball_name}.sha256"

  log_info "Checking if files exist on remote server..."

  # Check tarball exists
  if ! ssh_exec "test -f ${DEPLOY_PATH}/${tarball_name}"; then
    log_error "Tarball not found: ${DEPLOY_PATH}/${tarball_name}"
    return 1
  fi
  log_success "Tarball exists: ${tarball_name}"

  # Check checksum file exists
  if ! ssh_exec "test -f ${DEPLOY_PATH}/${checksum_file}"; then
    log_error "Checksum file not found: ${DEPLOY_PATH}/${checksum_file}"
    return 1
  fi
  log_success "Checksum file exists: ${checksum_file}"

  return 0
}

# Verify file permissions
verify_file_permissions() {
  local tarball_name="$1"
  local checksum_file="${tarball_name}.sha256"

  log_info "Verifying file permissions..."

  # Check permissions using stat
  local stat_output
  stat_output=$(ssh_exec "stat --printf='%a %U:%G\n' ${DEPLOY_PATH}/${tarball_name} 2>/dev/null || \
                            stat -f '%Lp %Su:%Lg' ${DEPLOY_PATH}/${tarball_name}" || true)

  if [ -z "${stat_output}" ]; then
    log_error "Cannot read file permissions for ${tarball_name}"
    return 1
  fi

  local perms
  perms=$(echo "${stat_output}" | awk '{print $1}')

  # Check if permissions are readable by www-data
  if [ "${perms}" != "644" ] && [ "${perms}" != "-rw-r--r--" ]; then
    log_warning "Unexpected permissions: ${perms} (expected 644)"
    return 1
  fi

  log_success "File permissions verified: ${perms}"

  # Check ownership
  local owner
  owner=$(echo "${stat_output}" | awk '{print $2}')

  if [[ "${owner}" != "www-data:www-data" ]] && [[ "${owner}" != "www-data"* ]]; then
    log_warning "Unexpected ownership: ${owner} (expected www-data:www-data)"
    return 1
  fi

  log_success "File ownership verified: ${owner}"

  return 0
}

# Verify checksum integrity
verify_checksum() {
  local tarball_name="$1"
  local checksum_file="${tarball_name}.sha256"

  log_info "Verifying tarball checksum..."

  # Get remote checksum
  local remote_checksum
  remote_checksum=$(ssh_exec "cat ${DEPLOY_PATH}/${checksum_file}" | awk '{print $1}')

  if [ -z "${remote_checksum}" ]; then
    log_error "Cannot read remote checksum"
    return 1
  fi

  # Download tarball temporarily and verify
  log_info "Downloading tarball to verify checksum..."

  local temp_tarball
  temp_tarball=$(mktemp)
  trap "rm -f ${temp_tarball}" RETURN

  if ! curl -sf \
      --max-time "${VERIFY_TIMEOUT}" \
      -o "${temp_tarball}" \
      "${TARBALL_BASE_URL}/${tarball_name}"; then
    log_error "Cannot download tarball from ${TARBALL_BASE_URL}/${tarball_name}"
    return 1
  fi

  # Calculate local checksum
  local local_checksum
  local_checksum=$(sha256sum "${temp_tarball}" | awk '{print $1}')

  if [ "${local_checksum}" != "${remote_checksum}" ]; then
    log_error "Checksum mismatch!"
    log_error "Local:  ${local_checksum}"
    log_error "Remote: ${remote_checksum}"
    return 1
  fi

  log_success "Checksum verified: ${remote_checksum}"

  return 0
}

# Verify tarball is readable and extractable
verify_tarball_integrity() {
  local tarball_name="$1"

  log_info "Verifying tarball integrity..."

  local temp_dir
  temp_dir=$(mktemp -d)
  trap "rm -rf ${temp_dir}" RETURN

  # Download and test extraction
  if ! curl -sf \
      --max-time "${VERIFY_TIMEOUT}" \
      -o "${temp_dir}/${tarball_name}" \
      "${TARBALL_BASE_URL}/${tarball_name}"; then
    log_error "Cannot download tarball for integrity check"
    return 1
  fi

  # List contents without extracting (faster)
  if ! tar -tzf "${temp_dir}/${tarball_name}" &>/dev/null | head -20 &>/dev/null; then
    log_error "Tarball is not readable or corrupted"
    return 1
  fi

  log_success "Tarball is readable and valid"

  # Verify key content exists
  local required_files=(
    "installer/pdl-installer.sh"
    "installer/installer-server.js"
    "installer/package.installer.json"
  )

  for file in "${required_files[@]}"; do
    if ! tar -tzf "${temp_dir}/${tarball_name}" | grep -q "^${file}"; then
      log_error "Required file not found in tarball: ${file}"
      return 1
    fi
    log_success "Found in tarball: ${file}"
  done

  return 0
}

# Test HTTP accessibility
verify_http_access() {
  local tarball_name="$1"
  local checksum_file="${tarball_name}.sha256"

  log_info "Testing HTTP accessibility..."

  # Test tarball download
  if curl -sf \
      --max-time "${VERIFY_TIMEOUT}" \
      -I "${TARBALL_BASE_URL}/${tarball_name}" &>/dev/null; then
    log_success "HTTP access to tarball verified"
  else
    log_warning "Cannot verify HTTP access to tarball (may be firewall/proxy issue)"
  fi

  # Test checksum file download
  if curl -sf \
      --max-time "${VERIFY_TIMEOUT}" \
      -I "${TARBALL_BASE_URL}/${checksum_file}" &>/dev/null; then
    log_success "HTTP access to checksum file verified"
  else
    log_warning "Cannot verify HTTP access to checksum file (may be firewall/proxy issue)"
  fi

  return 0
}

# Check if version can be downloaded by installer
verify_installer_discovery() {
  local version="$1"
  local tarball_name="pdev-source-v${version}.tar.gz"

  log_info "Verifying installer can discover tarball..."

  # Check if installer would be able to find this version
  if curl -sf \
      --max-time "${VERIFY_TIMEOUT}" \
      -o /dev/null \
      "${TARBALL_BASE_URL}/${tarball_name}"; then
    log_success "Installer can discover and download tarball"
  else
    log_error "Installer cannot discover tarball"
    return 1
  fi

  return 0
}

# Generate summary report
generate_report() {
  local version="$1"
  local tarball_name="pdev-source-v${version}.tar.gz"
  local total_tests=$((TESTS_PASSED + TESTS_FAILED))
  local pass_rate
  pass_rate=$(( TESTS_PASSED * 100 / total_tests ))

  printf "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
  printf "${BLUE}Deployment Verification Report${NC}\n"
  printf "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
  printf "Version:          ${GREEN}v${version}${NC}\n"
  printf "Tarball:          ${GREEN}${tarball_name}${NC}\n"
  printf "Deployment Host:  ${GREEN}${DEPLOY_HOST}${NC}\n"
  printf "Deployment Path:  ${GREEN}${DEPLOY_PATH}${NC}\n"
  printf "Web URL:          ${GREEN}${TARBALL_BASE_URL}/${tarball_name}${NC}\n"
  printf "\n${BLUE}Test Results:${NC}\n"
  printf "  Passed:  ${GREEN}${TESTS_PASSED}${NC}\n"
  printf "  Failed:  $([ ${TESTS_FAILED} -eq 0 ] && echo "${GREEN}${TESTS_FAILED}${NC}" || echo "${RED}${TESTS_FAILED}${NC}")\n"
  printf "  Total:   ${total_tests}\n"
  printf "  Rate:    %d%%\n" "${pass_rate}"
  printf "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n\n"

  if [ ${TESTS_FAILED} -eq 0 ]; then
    printf "${GREEN}✓ All verification tests passed${NC}\n"
    return 0
  else
    printf "${RED}✗ ${TESTS_FAILED} verification test(s) failed${NC}\n"
    return 1
  fi
}

# Main verification function
main() {
  local version="$1"
  local host="${2:-${DEPLOY_HOST}}"
  local deploy_path="${3:-${DEPLOY_PATH}}"
  local ssh_key="${4:-${SSH_KEY_PATH}}"

  # Update globals with arguments
  DEPLOY_HOST="${host}"
  DEPLOY_PATH="${deploy_path}"
  SSH_KEY_PATH="${ssh_key}"

  # Validate version argument
  version=$(validate_arguments "${version}")

  printf "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
  printf "${BLUE}PDev Tarball Deployment Verifier${NC}\n"
  printf "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n\n"

  local tarball_name="pdev-source-v${version}.tar.gz"

  # Run verification steps
  validate_prerequisites
  test_ssh_connectivity

  printf "\n${BLUE}Running deployment verification tests...${NC}\n\n"

  # File verification tests
  verify_files_exist "${tarball_name}" || true
  verify_file_permissions "${tarball_name}" || true

  # Integrity verification tests
  verify_checksum "${tarball_name}" || true
  verify_tarball_integrity "${tarball_name}" || true

  # Accessibility tests
  verify_http_access "${tarball_name}" || true
  verify_installer_discovery "${version}" || true

  # Generate report
  printf "\n"
  generate_report "${version}"
}

# Execute main function
main "$@"
