#!/bin/bash
# PDev-Live Frontend Deployment Script
# Deploys frontend files to production server after git push

set -e  # Exit on error

PROJECT_DIR="$HOME/projects/pdev-live"
SERVER="acme"
DEPLOY_PATH="/var/www/vyxenai.com/pdev"
FRONTEND_DIR="$PROJECT_DIR/frontend"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}🚀 PDev-Live Frontend Deployment${NC}"
echo "=================================="

# Step 1: Check if we're in the right directory
cd "$PROJECT_DIR" || {
    echo -e "${RED}❌ Could not find project directory: $PROJECT_DIR${NC}"
    exit 1
}

# Step 2: Check for uncommitted changes
if ! git diff --quiet || ! git diff --cached --quiet; then
    echo -e "${YELLOW}⚠️  You have uncommitted changes${NC}"
    echo ""
    git status --short
    echo ""
    read -p "Do you want to commit these changes? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        read -p "Enter commit message: " COMMIT_MSG
        git add -A
        git commit -m "$COMMIT_MSG

Co-Authored-By: Claude Sonnet 4.5 <noreply@anthropic.com>"
        echo -e "${GREEN}✅ Changes committed${NC}"
    else
        echo -e "${RED}❌ Deployment cancelled${NC}"
        exit 1
    fi
fi

# Step 3: Push to GitHub
echo -e "${YELLOW}📤 Pushing to GitHub...${NC}"
if git push origin main; then
    echo -e "${GREEN}✅ Pushed to GitHub${NC}"
else
    echo -e "${RED}❌ Failed to push to GitHub${NC}"
    exit 1
fi

# Step 4: Deploy frontend files to server
echo -e "${YELLOW}🚀 Deploying to $SERVER...${NC}"

# List of frontend files to deploy
FILES=(
    "install-wizard.html"
    "install-wizard-specific.css"
    "index.html"
    "dashboard.html"
    "session.html"
    "pdev-live.css"
)

# Deploy each file
for file in "${FILES[@]}"; do
    if [ -f "$FRONTEND_DIR/$file" ]; then
        echo "  → Deploying $file..."
        scp "$FRONTEND_DIR/$file" "$SERVER:/tmp/$file" || {
            echo -e "${RED}❌ Failed to upload $file${NC}"
            exit 1
        }
        ssh "$SERVER" "sudo mv /tmp/$file $DEPLOY_PATH/$file && sudo chown www-data:www-data $DEPLOY_PATH/$file" || {
            echo -e "${RED}❌ Failed to move $file to deployment directory${NC}"
            exit 1
        }
    else
        echo -e "${YELLOW}⚠️  Skipping $file (not found)${NC}"
    fi
done

# Step 5: Verify deployment
echo -e "${YELLOW}🔍 Verifying deployment...${NC}"
ssh "$SERVER" "ls -lh $DEPLOY_PATH/install-wizard.html" || {
    echo -e "${RED}❌ Verification failed${NC}"
    exit 1
}

echo ""
echo -e "${GREEN}✅ Deployment complete!${NC}"
echo ""
echo "Deployed files to: $SERVER:$DEPLOY_PATH"
echo "Access at: https://vyxenai.com/pdev/install-wizard.html"
echo ""
echo -e "${YELLOW}💡 Tip: Hard refresh browser (Cmd+Shift+R) to see changes${NC}"
