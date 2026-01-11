#!/bin/bash
# Sync wizard instructions from PDEV_PIPELINE.md to install-wizard.html
# Run this automatically via git pre-commit hook

set -e

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PDEV_PIPELINE="$HOME/.claude/PDEV_PIPELINE.md"
WIZARD_HTML="$REPO_ROOT/frontend/install-wizard.html"

# Extract format from PDEV_PIPELINE.md (between ```markers)
if ! grep -q "After all 7 questions" "$PDEV_PIPELINE"; then
    echo "❌ PDEV_PIPELINE.md format section not found"
    exit 1
fi

# Extract the format block
FORMAT_BLOCK=$(awk '/^```$/,/^```$/ {
    if (!/^```$/) print
}' "$PDEV_PIPELINE" | sed '/^$/d')

if [ -z "$FORMAT_BLOCK" ]; then
    echo "❌ Could not extract format block from PDEV_PIPELINE.md"
    exit 1
fi

# Create temp file with updated wizard HTML
TEMP_WIZARD=$(mktemp)

# Replace format section in wizard HTML
awk -v format="$FORMAT_BLOCK" '
BEGIN { in_format = 0; format_replaced = 0 }
/3\. Output EXACTLY this format:/ {
    print
    print ""
    print format "</code></pre>"
    in_format = 1
    format_replaced = 1
    next
}
/<\/code><\/pre>/ && in_format {
    in_format = 0
    next
}
!in_format || format_replaced == 0 {
    print
}
' "$WIZARD_HTML" > "$TEMP_WIZARD"

# Check if changes were made
if ! diff -q "$WIZARD_HTML" "$TEMP_WIZARD" > /dev/null 2>&1; then
    cp "$TEMP_WIZARD" "$WIZARD_HTML"
    echo "✅ Wizard instructions synced from PDEV_PIPELINE.md"
    rm "$TEMP_WIZARD"
    exit 0
else
    echo "✓ Wizard instructions already in sync"
    rm "$TEMP_WIZARD"
    exit 0
fi
