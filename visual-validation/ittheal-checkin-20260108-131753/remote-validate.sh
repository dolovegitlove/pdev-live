#!/bin/bash
# Remote validation script to run on ittz server

set -euo pipefail

SESSION_DIR="/tmp/checkin-validation-$(date +%s)"
SCREENSHOTS_DIR="$SESSION_DIR/screenshots"
mkdir -p "$SCREENSHOTS_DIR"

echo "═══════════════════════════════════════════════"
echo "  ITT HEAL CHECK-IN PAGE VALIDATION"
echo "═══════════════════════════════════════════════"
echo ""
echo "Session: $SESSION_DIR"
echo "URL: https://ittheal.com/admin/check-in.html"
echo ""

# Create validation script
cat > "$SESSION_DIR/validate.js" << 'VALIDATION_SCRIPT'
const playwright = require('playwright');
const fs = require('fs');

const SCREENSHOTS_DIR = process.env.SCREENSHOTS_DIR;
const VIEWPORTS = [
  { name: 'mobile-344', width: 344, height: 812 },
  { name: 'tablet-768', width: 768, height: 1024 },
  { name: 'desktop-1920', width: 1920, height: 1080 }
];

async function validateViewport(browser, viewport) {
  console.log(`\n📱 ${viewport.name} (${viewport.width}x${viewport.height})`);

  const context = await browser.newContext({
    viewport: { width: viewport.width, height: viewport.height },
    deviceScaleFactor: 1
  });

  const page = await context.newPage();

  const consoleErrors = [];
  page.on('console', msg => {
    if (msg.type() === 'error') consoleErrors.push(msg.text());
  });

  page.on('pageerror', err => consoleErrors.push(`PageError: ${err.message}`));

  try {
    const startTime = Date.now();
    await page.goto('https://ittheal.com/admin/check-in.html', {
      waitUntil: 'networkidle',
      timeout: 10000
    });
    const loadTime = Date.now() - startTime;

    await page.waitForTimeout(3000);

    const screenshotPath = `${SCREENSHOTS_DIR}/checkin-${viewport.name}.png`;
    await page.screenshot({ path: screenshotPath, fullPage: true });

    const pageInfo = await page.evaluate(() => {
      const searchInput = document.querySelector('#patient-search');
      const todayCount = document.querySelector('#today-count');
      const appointmentsList = document.querySelector('#appointments-list');
      const appointmentCards = document.querySelectorAll('.appointment-card');
      const checkInButtons = document.querySelectorAll('button:has-text("Check In")');
      const hamburger = document.querySelector('#hamburger-btn');

      return {
        hasSearchInput: !!searchInput,
        todayCount: todayCount?.textContent || '0',
        appointmentsListExists: !!appointmentsList,
        appointmentCardsCount: appointmentCards.length,
        checkInButtonsCount: checkInButtons.length,
        hasHamburger: !!hamburger,
        bodyScrollWidth: document.body.scrollWidth,
        bodyClientWidth: document.body.clientWidth,
        hasOverflow: document.body.scrollWidth > document.body.clientWidth,
        currentUrl: window.location.href
      };
    });

    console.log(`  ⏱ Load: ${loadTime}ms ${loadTime > 3000 ? '⚠' : '✓'}`);
    console.log(`  🔍 Search input: ${pageInfo.hasSearchInput ? '✓' : '❌'}`);
    console.log(`  📊 Today count: ${pageInfo.todayCount}`);
    console.log(`  📋 Appointment cards: ${pageInfo.appointmentCardsCount}`);
    console.log(`  🔘 Check-in buttons: ${pageInfo.checkInButtonsCount}`);
    console.log(`  📐 Overflow: ${pageInfo.hasOverflow ? '❌ YES' : '✓ NO'}`);
    console.log(`  🐛 Console errors: ${consoleErrors.length} ${consoleErrors.length > 0 ? '❌' : '✓'}`);
    console.log(`  📍 URL: ${pageInfo.currentUrl}`);
    console.log(`  📸 ${screenshotPath}`);

    if (consoleErrors.length > 0) {
      console.log(`  Errors:\n    ${consoleErrors.slice(0,3).join('\n    ')}`);
    }

    return {
      viewport: viewport.name,
      loadTime,
      consoleErrors,
      pageInfo,
      screenshot: screenshotPath
    };

  } catch (error) {
    console.error(`  ❌ ${error.message}`);
    return { viewport: viewport.name, error: error.message };
  } finally {
    await context.close();
  }
}

async function main() {
  const browser = await playwright.chromium.launch({
    headless: true,
    args: ['--no-sandbox', '--disable-setuid-sandbox']
  });

  const results = [];

  try {
    for (const vp of VIEWPORTS) {
      const result = await validateViewport(browser, vp);
      results.push(result);
    }

    console.log('\n───────────────────────────────────────────────');
    console.log('  VALIDATION VERDICT');
    console.log('───────────────────────────────────────────────');

    let hasErrors = false;
    let hasOverflow = false;
    let slowLoads = 0;

    results.forEach(r => {
      if (r.error) {
        console.log(`\n${r.viewport}: ❌ ERROR - ${r.error}`);
        hasErrors = true;
      } else {
        if (r.consoleErrors.length > 0) hasErrors = true;
        if (r.pageInfo.hasOverflow) hasOverflow = true;
        if (r.loadTime > 3000) slowLoads++;
      }
    });

    let verdict = 'PASS';
    if (hasErrors) verdict = 'BLOCK';
    else if (hasOverflow || slowLoads > 0) verdict = 'WARN';

    console.log(`\nTechnical: ${hasErrors ? '🔴 BLOCK' : '🟢 PASS'}`);
    console.log(`Responsive: ${hasOverflow ? '🟡 WARN' : '🟢 PASS'}`);
    console.log(`Performance: ${slowLoads > 0 ? '🟡 WARN' : '🟢 PASS'}`);
    console.log(`\nOVERALL: ${verdict === 'BLOCK' ? '🔴 BLOCK' : verdict === 'WARN' ? '🟡 WARN' : '🟢 PASS'}`);

    // Save JSON report
    fs.writeFileSync(
      `${SCREENSHOTS_DIR}/validation-report.json`,
      JSON.stringify(results, null, 2)
    );

  } finally {
    await browser.close();
  }
}

main();
VALIDATION_SCRIPT

# Export screenshots dir for script
export SCREENSHOTS_DIR="$SCREENSHOTS_DIR"

# Run validation
cd "$SESSION_DIR"
node validate.js

# List generated files
echo ""
echo "───────────────────────────────────────────────"
echo "  GENERATED FILES"
echo "───────────────────────────────────────────────"
ls -lh "$SCREENSHOTS_DIR"

echo ""
echo "Session directory: $SESSION_DIR"
echo "═══════════════════════════════════════════════"
