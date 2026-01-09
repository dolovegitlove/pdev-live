const playwright = require('playwright');
const fs = require('fs');
const path = require('path');

const SESSION_DIR = '/Users/dolovdev/projects/pdev-live/visual-validation/ittheal-checkin-20260108-131753';
const LOGIN_URL = 'https://ittheal.com/admin/login.html';

const VIEWPORTS = [
  { name: 'mobile-344', width: 344, height: 812 },
  { name: 'tablet-768', width: 768, height: 1024 },
  { name: 'desktop-1920', width: 1920, height: 1080 }
];

async function validateLoginPage(browser, viewport) {
  console.log(`\n📱 Capturing ${viewport.name} (${viewport.width}x${viewport.height})`);

  const context = await browser.newContext({
    viewport: { width: viewport.width, height: viewport.height },
    deviceScaleFactor: 1
  });

  const page = await context.newPage();

  // Track console messages
  const consoleErrors = [];
  page.on('console', msg => {
    if (msg.type() === 'error') {
      consoleErrors.push(msg.text());
    }
  });

  page.on('pageerror', error => {
    consoleErrors.push(`PageError: ${error.message}`);
  });

  try {
    const startTime = Date.now();
    await page.goto(LOGIN_URL, { waitUntil: 'networkidle', timeout: 10000 });
    const loadTime = Date.now() - startTime;

    await page.waitForTimeout(2000);

    // Capture screenshot
    const screenshotPath = path.join(SESSION_DIR, `login-${viewport.name}.png`);
    await page.screenshot({ path: screenshotPath, fullPage: true });
    console.log(`  📸 Screenshot: ${screenshotPath}`);

    // Check page structure
    const pageInfo = await page.evaluate(() => {
      return {
        title: document.title,
        hasEmailInput: !!document.querySelector('input[type="email"]'),
        hasPasswordInput: !!document.querySelector('input[type="password"]'),
        hasSubmitButton: !!document.querySelector('button[type="submit"]'),
        bodyScrollWidth: document.body.scrollWidth,
        bodyClientWidth: document.body.clientWidth,
        hasHorizontalOverflow: document.body.scrollWidth > document.body.clientWidth
      };
    });

    console.log(`  ⏱ Load time: ${loadTime}ms`);
    console.log(`  🔍 Email input: ${pageInfo.hasEmailInput ? '✓' : '❌'}`);
    console.log(`  🔍 Password input: ${pageInfo.hasPasswordInput ? '✓' : '❌'}`);
    console.log(`  🔍 Submit button: ${pageInfo.hasSubmitButton ? '✓' : '❌'}`);
    console.log(`  📐 Overflow: ${pageInfo.hasHorizontalOverflow ? '❌ YES' : '✓ NO'}`);
    console.log(`  🐛 Console errors: ${consoleErrors.length}`);

    if (consoleErrors.length > 0) {
      console.log(`    ${consoleErrors.join('\n    ')}`);
    }

    return {
      viewport: viewport.name,
      loadTime,
      consoleErrors,
      pageInfo,
      screenshot: screenshotPath
    };

  } catch (error) {
    console.error(`  ❌ Error: ${error.message}`);
    return {
      viewport: viewport.name,
      error: error.message
    };
  } finally {
    await context.close();
  }
}

async function main() {
  console.log('═══════════════════════════════════════════════');
  console.log('  ITT HEAL LOGIN PAGE VISUAL VALIDATION');
  console.log('═══════════════════════════════════════════════');
  console.log(`\nNote: Validating login page since check-in requires authentication`);
  console.log('Session ID:', Date.now());

  const browser = await playwright.chromium.launch({ headless: true });
  const results = [];

  try {
    for (const viewport of VIEWPORTS) {
      const result = await validateLoginPage(browser, viewport);
      results.push(result);
    }

    console.log('\n───────────────────────────────────────────────');
    console.log('  VALIDATION SUMMARY');
    console.log('───────────────────────────────────────────────');

    let hasErrors = false;
    let hasOverflow = false;

    results.forEach(r => {
      if (r.error) {
        console.log(`\n${r.viewport}: ❌ ERROR`);
        console.log(`  ${r.error}`);
        hasErrors = true;
      } else {
        console.log(`\n${r.viewport}:`);
        console.log(`  Load Time: ${r.loadTime}ms ${r.loadTime > 3000 ? '⚠ SLOW' : '✓'}`);
        console.log(`  Console Errors: ${r.consoleErrors.length} ${r.consoleErrors.length > 0 ? '❌' : '✓'}`);
        console.log(`  Horizontal Overflow: ${r.pageInfo.hasHorizontalOverflow ? '❌' : '✓'}`);
        console.log(`  Form Elements: ${r.pageInfo.hasEmailInput && r.pageInfo.hasPasswordInput && r.pageInfo.hasSubmitButton ? '✓' : '❌'}`);

        if (r.consoleErrors.length > 0) hasErrors = true;
        if (r.pageInfo.hasHorizontalOverflow) hasOverflow = true;
      }
    });

    console.log('\n───────────────────────────────────────────────');
    console.log('  VERDICT');
    console.log('───────────────────────────────────────────────');

    let verdict = 'PASS';
    if (hasErrors) verdict = 'BLOCK';
    else if (hasOverflow) verdict = 'WARN';

    console.log(`\nStatus: ${verdict}`);
    console.log(`Screenshots: ${results.length} captured`);
    console.log('\n═══════════════════════════════════════════════\n');

    // Save report
    const reportPath = path.join(SESSION_DIR, 'login-validation-report.json');
    fs.writeFileSync(reportPath, JSON.stringify(results, null, 2));
    console.log(`📄 Report saved: ${reportPath}\n`);

  } finally {
    await browser.close();
  }
}

main();
