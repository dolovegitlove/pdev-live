#!/bin/bash
# PDev Live Update Script
cd ~/pdev-live
git pull origin main
cp server/server.js /opt/services/pdev-live/server.js
cp server/doc-contract.json /opt/services/pdev-live/doc-contract.json
pm2 restart pdev-live
echo "✅ pdev-live updated and restarted"
