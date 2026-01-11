#!/bin/bash
# Sync wizard instructions from PDEV_PIPELINE.md to install-wizard.html
# Run this automatically via git pre-commit hook

set -e

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PDEV_PIPELINE="/Users/dolovdev/.claude/PDEV_PIPELINE.md"
WIZARD_HTML="$REPO_ROOT/frontend/install-wizard.html"

# Extract format from PDEV_PIPELINE.md (between ```markers)
if ! grep -q "After all 7 questions" "$PDEV_PIPELINE"; then
    echo "❌ PDEV_PIPELINE.md format section not found"
    exit 1
fi

# Extract the format block (between first two ``` markers after "After all 7 questions")
FORMAT_BLOCK=$(sed -n '/After all 7 questions/,/^---/p' "$PDEV_PIPELINE" | sed -n '/^```$/,/^```$/p' | sed '1d;$d')

if [ -z "$FORMAT_BLOCK" ]; then
    echo "❌ Could not extract format block from PDEV_PIPELINE.md"
    exit 1
fi

# Create temp files
TEMP_WIZARD=$(mktemp)
TEMP_FORMAT=$(mktemp)

# Write format block to temp file
echo "$FORMAT_BLOCK" > "$TEMP_FORMAT"

# Replace format section in wizard HTML
awk -v format_file="$TEMP_FORMAT" '
BEGIN { in_format = 0 }
/3\. Output EXACTLY this format:/ {
    print
    print ""
    while ((getline line < format_file) > 0) {
        print line
    }
    close(format_file)
    print "</code></pre>"
    in_format = 1
    next
}
/<\/code><\/pre>/ && in_format {
    in_format = 0
    next
}
!in_format {
    print
}
' "$WIZARD_HTML" > "$TEMP_WIZARD"

# Cleanup temp format file
rm -f "$TEMP_FORMAT"

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
