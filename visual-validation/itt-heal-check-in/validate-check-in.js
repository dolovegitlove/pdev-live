const { chromium } = require('playwright');
const fs = require('fs');
const path = require('path');

// Validation configuration
const CONFIG = {
  url: 'https://ittheal.com/admin/check-in.html',
  viewport: { width: 1920, height: 1080 },
  screenshotDir: '/Users/dolovdev/projects/pdev-live/visual-validation/itt-heal-check-in',
  timeout: 30000
};

// Results storage
const validationResults = {
  timestamp: new Date().toISOString(),
  url: CONFIG.url,
  consoleErrors: [],
  consoleWarnings: [],
  consoleLogs: [],
  networkRequests: [],
  moduleLoadingErrors: [],
  apiResponses: {},
  screenshots: [],
  verdict: 'PENDING'
};

async function captureScreenshot(page, name, description) {
  const filename = `${name}-${Date.now()}.png`;
  const filepath = path.join(CONFIG.screenshotDir, filename);
  await page.screenshot({ path: filepath, fullPage: true });
  validationResults.screenshots.push({ filename, description, timestamp: new Date().toISOString() });
  console.log(`📸 Screenshot captured: ${filename} - ${description}`);
  return filename;
}

async function validateCheckInPage() {
  console.log('═══════════════════════════════════════════════');
  console.log('  ITT HEAL CHECK-IN PAGE VALIDATION');
  console.log('═══════════════════════════════════════════════\n');

  const browser = await chromium.launch({
    headless: false, // Run headed to see what's happening
    devtools: true   // Open DevTools automatically
  });

  const context = await browser.newContext({
    viewport: CONFIG.viewport,
    deviceScaleFactor: 1,
    ignoreHTTPSErrors: false
  });

  const page = await context.newPage();

  // ============================================================
  // CONSOLE MONITORING SETUP
  // ============================================================
  console.log('🔍 Setting up console monitoring...\n');

  page.on('console', msg => {
    const type = msg.type();
    const text = msg.text();
    const location = msg.location();

    const entry = {
      type,
      text,
      url: location.url,
      lineNumber: location.lineNumber,
      timestamp: new Date().toISOString()
    };

    if (type === 'error') {
      validationResults.consoleErrors.push(entry);
      console.log(`❌ CONSOLE ERROR: ${text}`);
      if (location.url) console.log(`   at ${location.url}:${location.lineNumber}`);
    } else if (type === 'warning') {
      validationResults.consoleWarnings.push(entry);
      console.log(`⚠️  CONSOLE WARNING: ${text}`);
    } else if (type === 'log' || type === 'info') {
      validationResults.consoleLogs.push(entry);
      console.log(`ℹ️  CONSOLE LOG: ${text}`);
    }
  });

  page.on('pageerror', error => {
    const errorEntry = {
      type: 'pageerror',
      message: error.message,
      stack: error.stack,
      timestamp: new Date().toISOString()
    };
    validationResults.consoleErrors.push(errorEntry);
    console.log(`❌ PAGE ERROR: ${error.message}`);
    console.log(`   Stack: ${error.stack}`);
  });

  page.on('requestfailed', request => {
    const failedRequest = {
      url: request.url(),
      method: request.method(),
      failure: request.failure()?.errorText,
      timestamp: new Date().toISOString()
    };
    validationResults.networkRequests.push(failedRequest);
    console.log(`❌ REQUEST FAILED: ${request.method()} ${request.url()}`);
    console.log(`   Reason: ${request.failure()?.errorText}`);
  });

  // ============================================================
  // NETWORK MONITORING
  // ============================================================
  console.log('🌐 Setting up network monitoring...\n');

  page.on('response', async response => {
    const url = response.url();
    const status = response.status();

    // Track all requests
    const requestData = {
      url,
      status,
      method: response.request().method(),
      contentType: response.headers()['content-type'],
      timestamp: new Date().toISOString()
    };

    // Special handling for API requests
    if (url.includes('/api/')) {
      console.log(`🔗 API REQUEST: ${response.request().method()} ${url}`);
      console.log(`   Status: ${status}`);

      try {
        const body = await response.json();
        requestData.body = body;
        validationResults.apiResponses[url] = { status, body, timestamp: new Date().toISOString() };

        console.log(`   Response body:`, JSON.stringify(body, null, 2).substring(0, 500));

        // Check for flat properties in booking data
        if (url.includes('/bookings') && Array.isArray(body)) {
          console.log(`\n📊 BOOKING DATA STRUCTURE CHECK:`);
          if (body.length > 0) {
            const firstBooking = body[0];
            console.log(`   - Has patient_name: ${!!firstBooking.patient_name}`);
            console.log(`   - Has appointment_date: ${!!firstBooking.appointment_date}`);
            console.log(`   - Has checked_in: ${!!firstBooking.checked_in}`);
            console.log(`   - Has nested patient.name: ${!!(firstBooking.patient?.name)}`);
            console.log(`   - Has nested appointment.date: ${!!(firstBooking.appointment?.date)}`);

            // Flag if only nested structure exists
            if (!firstBooking.patient_name && firstBooking.patient?.name) {
              validationResults.moduleLoadingErrors.push({
                type: 'DATA_STRUCTURE_ISSUE',
                message: 'API returns nested-only structure (patient.name) without flat patient_name',
                severity: 'CRITICAL'
              });
            }
          } else {
            console.log(`   - Empty array (no appointments)`);
          }
        }
      } catch (e) {
        // Not JSON, that's fine
        requestData.parseError = e.message;
      }
    }

    validationResults.networkRequests.push(requestData);
  });

  // ============================================================
  // PAGE NAVIGATION
  // ============================================================
  console.log(`\n🌍 Navigating to ${CONFIG.url}...\n`);

  try {
    await page.goto(CONFIG.url, { waitUntil: 'networkidle', timeout: CONFIG.timeout });
    console.log('✅ Page loaded\n');
  } catch (error) {
    console.log(`❌ Navigation error: ${error.message}\n`);
    validationResults.consoleErrors.push({
      type: 'navigation_error',
      message: error.message,
      timestamp: new Date().toISOString()
    });
  }

  // Wait a bit for JavaScript to execute
  await page.waitForTimeout(3000);

  // ============================================================
  // SCREENSHOT: INITIAL STATE
  // ============================================================
  await captureScreenshot(page, 'initial-load', 'Initial page load state');

  // ============================================================
  // CHECK FOR AUTHENTICATION REDIRECT
  // ============================================================
  const currentUrl = page.url();
  console.log(`\n🔐 Current URL: ${currentUrl}`);

  if (currentUrl.includes('login') || currentUrl.includes('auth')) {
    console.log('⚠️  AUTHENTICATION REQUIRED - Page redirected to login');
    validationResults.authenticationRequired = true;
    await captureScreenshot(page, 'auth-required', 'Authentication required - redirected to login');
  } else {
    console.log('✅ No authentication redirect detected');
    validationResults.authenticationRequired = false;
  }

  // ============================================================
  // UI ELEMENT VERIFICATION
  // ============================================================
  console.log('\n🎨 Checking UI elements...\n');

  const uiChecks = {
    header: await page.locator('header').count() > 0,
    sidebar: await page.locator('.sidebar, #sidebar, nav').count() > 0,
    mainContent: await page.locator('main, .main-content, #main-content').count() > 0,
    refreshButton: await page.locator('#refresh-btn').count() > 0,
    hamburgerMenu: await page.locator('#hamburger-btn').count() > 0,
    searchInput: await page.locator('input[type="text"], input[placeholder*="Search"]').count() > 0,
    appointmentList: await page.locator('.appointment-card, .booking-card, [id*="appointment"]').count(),
    emptyState: await page.locator(':text("All patients checked in"), :text("No appointments")').count() > 0
  };

  validationResults.uiElements = uiChecks;

  console.log('UI Elements Found:');
  Object.entries(uiChecks).forEach(([key, value]) => {
    const icon = typeof value === 'boolean' ? (value ? '✅' : '❌') : '🔢';
    console.log(`  ${icon} ${key}: ${value}`);
  });

  // ============================================================
  // MODULE LOADING VERIFICATION
  // ============================================================
  console.log('\n📦 Checking JavaScript module loading...\n');

  const expectedModules = [
    'check-in-page.js',
    'check-in-handler.js',
    'toast.js',
    'auth.js',
    'confirm-dialog.js',
    'theme-loader.js'
  ];

  const loadedModules = validationResults.networkRequests.filter(req =>
    req.url.endsWith('.js') && req.status >= 200 && req.status < 300
  );

  console.log('Loaded JavaScript files:');
  loadedModules.forEach(mod => {
    const filename = mod.url.split('/').pop();
    console.log(`  ✅ ${filename} (${mod.status})`);
  });

  const failedModules = validationResults.networkRequests.filter(req =>
    req.url.endsWith('.js') && (req.status >= 400 || req.failure)
  );

  if (failedModules.length > 0) {
    console.log('\nFailed JavaScript files:');
    failedModules.forEach(mod => {
      const filename = mod.url.split('/').pop();
      console.log(`  ❌ ${filename} (${mod.status || mod.failure})`);
    });
  }

  // ============================================================
  // INTERACTIVE ELEMENT TESTING
  // ============================================================
  console.log('\n🖱️  Testing interactive elements...\n');

  // Test refresh button if exists
  if (uiChecks.refreshButton) {
    try {
      console.log('Testing refresh button...');
      await page.locator('#refresh-btn').click();
      await page.waitForTimeout(2000);
      await captureScreenshot(page, 'refresh-clicked', 'After clicking refresh button');
      console.log('✅ Refresh button clicked successfully');
    } catch (error) {
      console.log(`❌ Refresh button test failed: ${error.message}`);
    }
  }

  // Test hamburger menu if exists
  if (uiChecks.hamburgerMenu) {
    try {
      console.log('Testing hamburger menu...');
      await page.locator('#hamburger-btn').click();
      await page.waitForTimeout(1000);
      await captureScreenshot(page, 'menu-opened', 'After clicking hamburger menu');
      console.log('✅ Hamburger menu clicked successfully');
    } catch (error) {
      console.log(`❌ Hamburger menu test failed: ${error.message}`);
    }
  }

  // ============================================================
  // FINAL SCREENSHOT & CONSOLE STATE
  // ============================================================
  await page.waitForTimeout(2000);
  await captureScreenshot(page, 'final-state', 'Final rendered state');

  // ============================================================
  // VERDICT DETERMINATION
  // ============================================================
  console.log('\n═══════════════════════════════════════════════');
  console.log('  VALIDATION VERDICT');
  console.log('═══════════════════════════════════════════════\n');

  const hasCriticalErrors = validationResults.consoleErrors.some(err =>
    err.text?.includes('Cannot read property') ||
    err.text?.includes('undefined') ||
    err.text?.includes('Failed to fetch') ||
    err.message?.includes('Cannot read property')
  );

  const hasModuleLoadingErrors = failedModules.length > 0;
  const hasNestedOnlyStructure = validationResults.moduleLoadingErrors.some(err =>
    err.type === 'DATA_STRUCTURE_ISSUE'
  );

  let verdict = 'PASS';
  const issues = [];

  if (hasCriticalErrors) {
    verdict = 'FAIL';
    issues.push('Critical JavaScript errors detected');
  }

  if (hasModuleLoadingErrors) {
    verdict = 'FAIL';
    issues.push('Module loading failures detected');
  }

  if (hasNestedOnlyStructure) {
    verdict = 'FAIL';
    issues.push('API returns nested-only structure without flat properties');
  }

  if (validationResults.consoleErrors.length > 0 && !hasCriticalErrors) {
    verdict = verdict === 'PASS' ? 'CONDITIONAL_PASS' : verdict;
    issues.push(`${validationResults.consoleErrors.length} console errors (review required)`);
  }

  if (validationResults.authenticationRequired) {
    verdict = verdict === 'FAIL' ? 'FAIL' : 'CONDITIONAL_PASS';
    issues.push('Authentication required - limited validation');
  }

  validationResults.verdict = verdict;
  validationResults.issues = issues;

  console.log(`Status: ${verdict === 'PASS' ? '✅' : verdict === 'CONDITIONAL_PASS' ? '⚠️' : '❌'} ${verdict}\n`);

  if (issues.length > 0) {
    console.log('Issues:');
    issues.forEach(issue => console.log(`  - ${issue}`));
    console.log('');
  }

  console.log('Summary:');
  console.log(`  Console Errors: ${validationResults.consoleErrors.length}`);
  console.log(`  Console Warnings: ${validationResults.consoleWarnings.length}`);
  console.log(`  Network Requests: ${validationResults.networkRequests.length}`);
  console.log(`  API Responses: ${Object.keys(validationResults.apiResponses).length}`);
  console.log(`  Screenshots: ${validationResults.screenshots.length}`);

  // ============================================================
  // SAVE RESULTS
  // ============================================================
  const reportPath = path.join(CONFIG.screenshotDir, 'validation-report.json');
  fs.writeFileSync(reportPath, JSON.stringify(validationResults, null, 2));
  console.log(`\n📄 Full report saved to: ${reportPath}`);

  console.log('\n═══════════════════════════════════════════════\n');

  // Keep browser open for 10 seconds to review
  console.log('⏱️  Browser will remain open for 10 seconds for manual review...\n');
  await page.waitForTimeout(10000);

  await browser.close();

  return validationResults;
}

// Run validation
validateCheckInPage()
  .then(results => {
    console.log('✅ Validation completed');
    process.exit(results.verdict === 'PASS' ? 0 : 1);
  })
  .catch(error => {
    console.error('❌ Validation failed with error:', error);
    process.exit(1);
  });
