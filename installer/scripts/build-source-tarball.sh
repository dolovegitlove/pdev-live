#!/usr/bin/env bash

################################################################################
# PDev Source Tarball Builder
#
# Purpose: Create production-ready source tarball for PDev Live distribution
# Usage: ./build-source-tarball.sh [VERSION] [OUTPUT_DIR]
#
# Environment Variables:
#   TARBALL_VERSION - Current version from pdl-installer.sh (auto-detected)
#   GIT_COMMIT - Git commit hash (auto-detected)
#   BUILD_DATE - Build timestamp (auto-generated)
#
# Features:
#   - Automatic version detection and increment
#   - Comprehensive content validation
#   - SHA256 checksum generation
#   - Detailed logging and error reporting
#   - Cross-platform compatibility (Linux/macOS)
#
# Security:
#   - Excludes secrets (.env, .git)
#   - Verifies file permissions
#   - Validates tarball integrity
#   - Error handling with cleanup
#
################################################################################

set -euo pipefail

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
  printf '%s\n' "${BLUE}ℹ${NC} $*"
}

log_success() {
  printf '%s\n' "${GREEN}✓${NC} $*"
}

log_warning() {
  printf '%s\n' "${YELLOW}⚠${NC} $*"
}

log_error() {
  printf '%s\n' "${RED}✗${NC} $*" >&2
}

# Cleanup on exit
CLEANUP_FILES=()
cleanup() {
  local exit_code=$?
  if [ ${exit_code} -ne 0 ] && [ ${#CLEANUP_FILES[@]} -gt 0 ]; then
    log_warning "Build failed, cleaning up temporary files..."
    for file in "${CLEANUP_FILES[@]}"; do
      if [ -f "${file}" ]; then
        rm -f "${file}" || log_warning "Failed to remove ${file}"
      fi
    done
  fi
  return ${exit_code}
}

trap cleanup EXIT

# Validate environment
validate_environment() {
  log_info "Validating build environment..."

  # Check required tools
  local required_tools=(tar gzip sha256sum sed)
  for tool in "${required_tools[@]}"; do
    if ! command -v "${tool}" &> /dev/null; then
      log_error "Required tool not found: ${tool}"
      exit 1
    fi
  done

  # Check we're in project root
  if [ ! -f "installer/pdl-installer.sh" ]; then
    log_error "Not in project root. Must run from directory containing installer/"
    exit 1
  fi

  log_success "Environment validation passed"
}

# Get current version from pdl-installer.sh
get_current_version() {
  if [ ! -f "installer/pdl-installer.sh" ]; then
    log_error "installer/pdl-installer.sh not found"
    exit 1
  fi

  local version
  version=$(sed -n 's/.*TARBALL_VERSION="\([0-9.]*\)".*/\1/p' installer/pdl-installer.sh | head -1 || echo "1.0.0")
  version="${version:-1.0.0}"

  if [ -z "${version}" ]; then
    log_warning "Could not parse TARBALL_VERSION, using default 1.0.0"
    version="1.0.0"
  fi

  echo "${version}"
}

# Calculate next version (increment minor)
increment_version() {
  local current="$1"
  local major minor patch

  major=$(echo "${current}" | cut -d. -f1)
  minor=$(echo "${current}" | cut -d. -f2)
  patch=$(echo "${current}" | cut -d. -f3)

  # Increment minor, reset patch
  minor=$((minor + 1))
  patch=0

  echo "${major}.${minor}.${patch}"
}

# Validate directories exist
validate_directories() {
  log_info "Validating required directories..."

  local required_dirs=(server installer frontend client)
  local missing=0

  for dir in "${required_dirs[@]}"; do
    if [ -d "${dir}" ]; then
      log_success "Found: ${dir}/"
    else
      log_error "Missing: ${dir}/"
      missing=$((missing + 1))
    fi
  done

  if [ ${missing} -gt 0 ]; then
    log_error "${missing} required directories missing"
    exit 1
  fi

  log_success "All required directories found"
}

# Create tarball
create_tarball() {
  local version="$1"
  local output_dir="$2"
  local tarball_name="pdev-source-v${version}.tar.gz"
  local tarball_path="${output_dir}/${tarball_name}"

  log_info "Creating tarball: ${tarball_name}"

  # List of directories to include
  local include_dirs=(server installer frontend client)
  # Root-level files to include (config.js required by server/server.js)
  local include_files=(config.js)

  # Create tarball with comprehensive exclusions
  if tar -czf "${tarball_path}" \
      --dereference \
      --exclude='.git' \
      --exclude='.gitignore' \
      --exclude='.github' \
      --exclude='node_modules' \
      --exclude='node_modules/.cache' \
      --exclude='*.log' \
      --exclude='*.tmp' \
      --exclude='*.bak' \
      --exclude='*.backup' \
      --exclude='.DS_Store' \
      --exclude='.env' \
      --exclude='.env.*' \
      --exclude='installer/dist' \
      --exclude='installer/bundle/node_modules' \
      --exclude='installer/*.backup*' \
      --exclude='desktop' \
      --exclude='tests' \
      --exclude='visual-validation' \
      --exclude='.cache' \
      --exclude='.npm' \
      --exclude='.vscode' \
      --exclude='.idea' \
      "${include_files[@]}" \
      "${include_dirs[@]}"; then
    log_success "Tarball created: ${tarball_path}"
  else
    log_error "Failed to create tarball"
    exit 1
  fi

  # Verify file exists and has content
  if [ ! -f "${tarball_path}" ]; then
    log_error "Tarball file was not created"
    exit 1
  fi

  local tarball_size
  tarball_size=$(stat -f%z "${tarball_path}" 2>/dev/null || stat -c%s "${tarball_path}" 2>/dev/null || echo 0)

  if [ "$((tarball_size))" -lt 100000 ]; then
    log_error "Tarball size ${tarball_size} bytes is suspiciously small (minimum 100KB expected)"
    exit 1
  fi

  # Human-readable size
  local readable_size
  if command -v numfmt &> /dev/null; then
    readable_size=$(numfmt --to=iec-i --suffix=B "${tarball_size}")
  else
    # Fallback for systems without numfmt
    if [ "$((tarball_size / 1024 / 1024))" -gt 0 ]; then
      readable_size="$((tarball_size / 1024 / 1024))M"
    else
      readable_size="$((tarball_size / 1024))K"
    fi
  fi

  log_success "Tarball size: ${readable_size} (${tarball_size} bytes)"

  echo "${tarball_name}"
}

# Generate SHA256 checksum (cross-platform: Linux + macOS)
generate_checksum() {
  local tarball_path="$1"
  local checksum_file="${tarball_path}.sha256"

  # Input validation
  if [[ -z "${tarball_path}" ]]; then
    log_error "generate_checksum: No tarball path provided"
    return 1
  fi

  if [[ ! -f "${tarball_path}" ]]; then
    log_error "generate_checksum: File not found: ${tarball_path}"
    return 1
  fi

  log_info "Generating SHA256 checksum..."

  # Cross-platform: Use sha256sum on Linux, shasum on macOS
  if command -v sha256sum >/dev/null 2>&1; then
    if sha256sum "${tarball_path}" > "${checksum_file}"; then
      log_success "Checksum file created: ${checksum_file}"
    else
      log_error "Failed to generate checksum"
      return 1
    fi
  elif command -v shasum >/dev/null 2>&1; then
    if shasum -a 256 "${tarball_path}" > "${checksum_file}"; then
      log_success "Checksum file created: ${checksum_file}"
    else
      log_error "Failed to generate checksum"
      return 1
    fi
  else
    log_error "No SHA256 tool found (sha256sum or shasum)"
    return 1
  fi

  # Output checksum content for visibility
  cat "${checksum_file}"

  # Return the checksum file path
  printf '%s\n' "${checksum_file}"
}

# Verify tarball contents
verify_tarball_contents() {
  local tarball_path="$1"

  log_info "Verifying tarball contents..."

  # Load required files from manifest (single source of truth)
  local manifest_file="$SCRIPT_DIR/../TARBALL_MANIFEST.txt"

  if [ ! -f "$manifest_file" ]; then
    log_error "Manifest file not found: $manifest_file"
    exit 1
  fi

  log_info "Loading required files from TARBALL_MANIFEST.txt..."

  # Read manifest, skip comments and empty lines
  local missing=0
  local total=0

  while IFS= read -r item || [ -n "$item" ]; do
    # Skip comments and empty lines
    [[ "$item" =~ ^#.*$ ]] && continue
    [[ -z "$item" ]] && continue

    total=$((total + 1))

    # Use line-start and line-end anchors for exact path matching
    if tar -tzf "${tarball_path}" | grep -q "^${item}$"; then
      log_success "Found: ${item}"
    else
      log_error "MISSING CRITICAL FILE: ${item}"
      missing=$((missing + 1))
    fi
  done < "$manifest_file"

  echo ""
  log_info "Validation: ${total} files checked, ${missing} missing"

  if [ ${missing} -gt 0 ]; then
    log_error "${missing} required items missing from tarball"
    exit 1
  fi

  log_success "All required items verified in tarball"
}

# Verify no excluded content
verify_excluded_content() {
  local tarball_path="$1"

  log_info "Verifying excluded content is not present..."

  local excluded_patterns=(
    "\.git/"
    "\.github/"
    "node_modules/"
    "\.env"
    "\.log$"
    "\.bak$"
    "\.backup"
    "\.DS_Store"
  )

  local found_excluded=0
  for pattern in "${excluded_patterns[@]}"; do
    if tar -tzf "${tarball_path}" 2>/dev/null | grep -E "${pattern}" | head -3; then
      log_warning "Found excluded pattern: ${pattern}"
      found_excluded=$((found_excluded + 1))
    fi
  done

  if [ ${found_excluded} -gt 0 ]; then
    log_warning "${found_excluded} excluded patterns found in tarball"
    log_warning "This may indicate incomplete exclusion configuration"
    return 1
  fi

  log_success "No excluded content detected"
  return 0
}

# Extract and verify structure
verify_extracted_structure() {
  local tarball_path="$1"
  local temp_extract_dir
  temp_extract_dir=$(mktemp -d)

  log_info "Extracting tarball to temporary directory for structure verification..."

  if ! tar -xzf "${tarball_path}" -C "${temp_extract_dir}"; then
    log_error "Failed to extract tarball"
    rm -rf "${temp_extract_dir}"
    exit 1
  fi

  # Verify critical files are readable
  local critical_files=(
    "installer/pdl-installer.sh"
    "installer/installer-server.js"
    "installer/package.installer.json"
  )

  local unreadable=0
  for file in "${critical_files[@]}"; do
    local full_path="${temp_extract_dir}/${file}"
    if [ ! -r "${full_path}" ]; then
      log_error "Extracted file not readable: ${file}"
      unreadable=$((unreadable + 1))
    fi
  done

  # Verify pdl-installer.sh is executable
  if [ ! -x "${temp_extract_dir}/installer/pdl-installer.sh" ]; then
    log_warning "Extracted pdl-installer.sh is not executable, fixing permissions..."
    chmod +x "${temp_extract_dir}/installer/pdl-installer.sh" || log_warning "Could not set executable bit"
  fi

  rm -rf "${temp_extract_dir}"

  if [ ${unreadable} -gt 0 ]; then
    log_error "${unreadable} extracted files are not readable"
    exit 1
  fi

  log_success "Extracted structure verified successfully"
}

# Main build function
main() {
  local version="${1:-}"
  local output_dir="${2:-.}"

  printf '%s\n' "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  printf '%s\n' "${BLUE}PDev Source Tarball Builder${NC}"
  printf '%s\n\n' "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

  # Validate environment
  validate_environment

  # Validate directories exist
  validate_directories

  # Get current version
  local current_version
  current_version=$(get_current_version)
  log_info "Current TARBALL_VERSION: ${current_version}"

  # Determine version to build
  if [ -z "${version}" ]; then
    version=$(increment_version "${current_version}")
    log_info "Auto-incrementing to version: ${version}"
  else
    log_info "Using specified version: ${version}"
  fi

  # Create output directory if needed
  if [ ! -d "${output_dir}" ]; then
    log_info "Creating output directory: ${output_dir}"
    mkdir -p "${output_dir}"
  fi

  # Build tarball
  local tarball_name
  tarball_name=$(create_tarball "${version}" "${output_dir}")

  local tarball_path="${output_dir}/${tarball_name}"
  CLEANUP_FILES+=("${tarball_path}" "${tarball_path}.sha256")

  # Generate checksum
  generate_checksum "${tarball_path}"

  # Verify tarball contents
  verify_tarball_contents "${tarball_path}"

  # Verify excluded content
  verify_excluded_content "${tarball_path}" || log_warning "Excluding content check had issues"

  # Extract and verify structure
  verify_extracted_structure "${tarball_path}"

  printf '%s\n' "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  printf '%s\n' "${GREEN}Build Successful${NC}"
  printf '%s\n' "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  printf '%s\n' "Version:     ${GREEN}v${version}${NC}"
  printf '%s\n' "Tarball:     ${GREEN}${tarball_path}${NC}"
  printf '%s\n' "Checksum:    ${GREEN}${tarball_path}.sha256${NC}"
  printf '%s\n\n' "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

  # Clear cleanup list since build was successful
  CLEANUP_FILES=()
}

# Run main function with all arguments
main "$@"
