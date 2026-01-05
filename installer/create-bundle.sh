#!/usr/bin/env bash
#
# PDev Live Bundle Creator
# Creates distributable zip bundle with all installer components
#
# Usage: ./create-bundle.sh [VERSION]
#

set -euo pipefail

VERSION="${1:-1.0.0}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_DIR="$SCRIPT_DIR/bundle"
OUTPUT_DIR="$SCRIPT_DIR/dist"
BUNDLE_NAME="pdev-complete-v${VERSION}"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "PDev Live Bundle Creator"
echo "Version: $VERSION"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Create output directory
mkdir -p "$OUTPUT_DIR"

# Create temporary bundle directory
TEMP_BUNDLE=$(mktemp -d)
trap "rm -rf $TEMP_BUNDLE" EXIT

echo "📦 Preparing bundle structure..."

# Copy bundled installer orchestrator script
cp "$SCRIPT_DIR/pdev-bundled-installer.sh" "$TEMP_BUNDLE/"
chmod +x "$TEMP_BUNDLE/pdev-bundled-installer.sh"

# Copy server installer
cp "$SCRIPT_DIR/install.sh" "$TEMP_BUNDLE/"
chmod +x "$TEMP_BUNDLE/install.sh"

# Copy documentation
mkdir -p "$TEMP_BUNDLE/docs"
cp "$BUNDLE_DIR/README-INSTALL.md" "$TEMP_BUNDLE/"
cp "$BUNDLE_DIR/docs/TROUBLESHOOTING.md" "$TEMP_BUNDLE/docs/"

# Create desktop directory (binaries downloaded during install)
mkdir -p "$TEMP_BUNDLE/desktop"
cat > "$TEMP_BUNDLE/desktop/README.txt" <<EOF
Desktop App Binaries

These files are downloaded automatically during installation from:
https://vyxenai.com/pdev/releases/

Files:
- PDev-Live-${VERSION}.dmg (macOS)
- PDev-Live-${VERSION}.exe (Windows)
- PDev-Live-${VERSION}.deb (Linux)

You don't need to download them manually.
The installer handles this automatically.
EOF

# Generate checksums
echo "🔒 Generating checksums..."
cd "$TEMP_BUNDLE"
find . -type f \( -name "*.sh" -o -name "*.md" \) -exec shasum -a 256 {} \; > SHA256SUMS
cd - > /dev/null

# Create version file
cat > "$TEMP_BUNDLE/VERSION" <<EOF
PDev Live Bundle
Version: $VERSION
Build Date: $(date -u +"%Y-%m-%d %H:%M:%S UTC")
EOF

echo "✅ Bundle structure created"
echo ""

# Create tarball
echo "📚 Creating tarball..."
cd "$TEMP_BUNDLE"
tar -czf "$OUTPUT_DIR/${BUNDLE_NAME}.tar.gz" .
cd - > /dev/null

# Create zip (for Windows users)
echo "📚 Creating zip..."
cd "$TEMP_BUNDLE"
zip -r "$OUTPUT_DIR/${BUNDLE_NAME}.zip" . > /dev/null
cd - > /dev/null

echo "✅ Archives created"
echo ""

# Show results
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ Bundle creation complete!"
echo ""
echo "Output files:"
echo "  📦 $OUTPUT_DIR/${BUNDLE_NAME}.tar.gz"
echo "  📦 $OUTPUT_DIR/${BUNDLE_NAME}.zip"
echo ""
echo "File sizes:"
du -h "$OUTPUT_DIR/${BUNDLE_NAME}".*
echo ""
echo "Upload to:"
echo "  https://vyxenai.com/pdev/install/${BUNDLE_NAME}.zip"
echo "  https://vyxenai.com/pdev/install/${BUNDLE_NAME}.tar.gz"
echo ""
echo "Single download URL:"
echo "  https://vyxenai.com/pdev/install/pdev-complete-latest.zip"
echo "  (symlink to latest version)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
