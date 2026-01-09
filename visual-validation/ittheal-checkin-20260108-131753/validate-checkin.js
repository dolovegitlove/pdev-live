const playwright = require('playwright');
const fs = require('fs');
const path = require('path');

const SESSION_DIR = '/Users/dolovdev/projects/pdev-live/visual-validation/ittheal-checkin-20260108-131753';
const TARGET_URL = 'https://ittheal.com/admin/check-in.html';
const LOGIN_URL = 'https://ittheal.com/admin/login.html';

// Test credentials from existing admin session
const ADMIN_EMAIL = 'admin@ittheal.com';
const ADMIN_PASSWORD = 'AdminPass123!';

const VIEWPORTS = [
  { name: 'mobile-320', width: 320, height: 568 },
  { name: 'mobile-344', width: 344, height: 812 },
  { name: 'mobile-375', width: 375, height: 667 },
  { name: 'tablet-768', width: 768, height: 1024 },
  { name: 'desktop-1280', width: 1280, height: 800 },
  { name: 'desktop-1920', width: 1920, height: 1080 }
];

const validationResults = {
  sessionId: Date.now(),
  timestamp: new Date().toISOString(),
  url: TARGET_URL,
  technical: {},
  design: {},
  responsive: {},
  auth: {},
  functional: {},
  screenshots: []
};

async function captureConsoleErrors(page) {
  const consoleErrors = [];
  const consoleWarnings = [];

  page.on('console', msg => {
    if (msg.type() === 'error') {
      consoleErrors.push(msg.text());
    } else if (msg.type() === 'warning') {
      consoleWarnings.push(msg.text());
    }
  });

  page.on('pageerror', error => {
    consoleErrors.push(`PageError: ${error.message}`);
  });

  page.on('requestfailed', request => {
    consoleErrors.push(`RequestFailed: ${request.url()} - ${request.failure().errorText}`);
  });

  return { consoleErrors, consoleWarnings };
}

async function performLogin(page) {
  console.log('🔐 Performing login...');

  await page.goto(LOGIN_URL, { waitUntil: 'networkidle' });
  await page.waitForTimeout(1000);

  // Check if already logged in (redirect to check-in page)
  if (page.url().includes('check-in.html')) {
    console.log('✓ Already authenticated');
    return true;
  }

  // Fill login form with authentic typing
  const emailInput = await page.locator('input[type="email"]');
  await emailInput.click();
  await page.keyboard.type(ADMIN_EMAIL, { delay: 100 });
  await page.waitForTimeout(500);

  const passwordInput = await page.locator('input[type="password"]');
  await passwordInput.click();
  await page.keyboard.type(ADMIN_PASSWORD, { delay: 100 });
  await page.waitForTimeout(500);

  // Click login button
  const loginButton = await page.locator('button[type="submit"]');
  await loginButton.click();
  await page.waitForTimeout(2000);

  // Wait for redirect to check-in page
  await page.waitForURL('**/check-in.html', { timeout: 5000 }).catch(() => {
    console.warn('⚠ Did not redirect to check-in page after login');
  });

  return page.url().includes('check-in.html');
}

async function extractDesignTokens(page) {
  return await page.evaluate(() => {
    const tokens = {
      colors: [],
      fontSizes: [],
      spacing: []
    };

    // Extract computed colors from key elements
    const elements = document.querySelectorAll('button, .appointment-card, .badge, h1, h2, input');
    elements.forEach(el => {
      const computed = window.getComputedStyle(el);
      const bgColor = computed.backgroundColor;
      const color = computed.color;

      if (bgColor && bgColor !== 'rgba(0, 0, 0, 0)') {
        tokens.colors.push({ element: el.tagName, property: 'background', value: bgColor });
      }
      if (color) {
        tokens.colors.push({ element: el.tagName, property: 'color', value: color });
      }

      tokens.fontSizes.push({ element: el.tagName, fontSize: computed.fontSize });
      tokens.spacing.push({ element: el.tagName, padding: computed.padding, margin: computed.margin });
    });

    return tokens;
  });
}

async function checkTouchTargets(page) {
  return await page.evaluate(() => {
    const interactiveElements = document.querySelectorAll('button, a, input, select, [role="button"]');
    const violations = [];
    const MIN_SIZE = 44;

    interactiveElements.forEach(el => {
      const rect = el.getBoundingClientRect();
      if (rect.width < MIN_SIZE || rect.height < MIN_SIZE) {
        violations.push({
          element: el.tagName,
          selector: el.className || el.id || el.textContent?.substring(0, 20),
          width: rect.width,
          height: rect.height,
          required: MIN_SIZE
        });
      }
    });

    return violations;
  });
}

async function checkOverflow(page) {
  return await page.evaluate(() => {
    const body = document.body;
    const html = document.documentElement;

    return {
      bodyScrollWidth: body.scrollWidth,
      bodyClientWidth: body.clientWidth,
      htmlScrollWidth: html.scrollWidth,
      htmlClientWidth: html.clientWidth,
      hasHorizontalOverflow: body.scrollWidth > body.clientWidth || html.scrollWidth > html.clientWidth
    };
  });
}

async function checkUIElements(page) {
  return await page.evaluate(() => {
    const elements = {
      searchInput: !!document.querySelector('input[type="search"], input[placeholder*="search" i]'),
      appointmentCount: !!document.querySelector('.appointment-count, .count, [class*="count"]'),
      appointmentCards: document.querySelectorAll('.appointment-card, [class*="appointment"]').length,
      checkInButtons: document.querySelectorAll('button:has-text("Check In"), button.check-in').length,
      checkedInBadges: document.querySelectorAll('.badge:has-text("Checked In"), [class*="checked"]').length,
      hamburgerMenu: !!document.querySelector('.hamburger, .menu-toggle, [class*="menu-icon"]')
    };

    // Extract appointment data
    const appointments = [];
    document.querySelectorAll('.appointment-card, [class*="appointment"]').forEach(card => {
      const patientName = card.querySelector('[class*="patient"], [class*="name"]')?.textContent;
      const time = card.querySelector('[class*="time"]')?.textContent;
      const service = card.querySelector('[class*="service"]')?.textContent;
      const status = card.querySelector('.badge, [class*="status"]')?.textContent;

      appointments.push({ patientName, time, service, status });
    });

    elements.appointments = appointments;

    return elements;
  });
}

async function testKeyboardNavigation(page) {
  const focusableElements = await page.evaluate(() => {
    const elements = document.querySelectorAll('button, a, input, select, [tabindex="0"]');
    return elements.length;
  });

  // Tab through first 5 elements
  const focusStates = [];
  for (let i = 0; i < Math.min(5, focusableElements); i++) {
    await page.keyboard.press('Tab');
    await page.waitForTimeout(300);

    const focusVisible = await page.evaluate(() => {
      const activeEl = document.activeElement;
      const computed = window.getComputedStyle(activeEl);
      return {
        tagName: activeEl.tagName,
        hasFocusVisible: computed.outline !== 'none' || computed.boxShadow.includes('rgb'),
        outlineStyle: computed.outline
      };
    });

    focusStates.push(focusVisible);
  }

  return { totalFocusable: focusableElements, focusStates };
}

async function measurePageLoad(page, url) {
  const startTime = Date.now();
  await page.goto(url, { waitUntil: 'networkidle' });
  const loadTime = Date.now() - startTime;

  // Measure CLS (Cumulative Layout Shift)
  const cls = await page.evaluate(() => {
    return new Promise((resolve) => {
      let clsValue = 0;
      const observer = new PerformanceObserver((list) => {
        for (const entry of list.getEntries()) {
          if (!entry.hadRecentInput) {
            clsValue += entry.value;
          }
        }
      });
      observer.observe({ type: 'layout-shift', buffered: true });

      setTimeout(() => {
        observer.disconnect();
        resolve(clsValue);
      }, 3000);
    });
  });

  return { loadTime, cls };
}

async function validateAtViewport(browser, viewport) {
  console.log(`\n📱 Validating at ${viewport.name} (${viewport.width}x${viewport.height})`);

  const context = await browser.newContext({
    viewport: { width: viewport.width, height: viewport.height },
    deviceScaleFactor: 1
  });

  const page = await context.newPage();
  const errorTracking = await captureConsoleErrors(page);

  try {
    // Measure page load
    const { loadTime, cls } = await measurePageLoad(page, TARGET_URL);
    console.log(`  ⏱ Page load: ${loadTime}ms, CLS: ${cls.toFixed(3)}`);

    // Check if redirected to login
    if (page.url().includes('login.html')) {
      console.log('  🔐 Redirected to login - performing authentication...');
      const loginSuccess = await performLogin(page);

      if (!loginSuccess) {
        console.error('  ❌ Login failed');
        validationResults.auth[viewport.name] = { status: 'FAIL', reason: 'Login failed' };
        await context.close();
        return;
      }

      // Navigate back to check-in page
      await page.goto(TARGET_URL, { waitUntil: 'networkidle' });
      await page.waitForTimeout(2000);
    }

    // Wait for appointments to load
    await page.waitForTimeout(2000);

    // Capture screenshot
    const screenshotPath = path.join(SESSION_DIR, `checkin-${viewport.name}.png`);
    await page.screenshot({ path: screenshotPath, fullPage: true });
    console.log(`  📸 Screenshot: ${screenshotPath}`);
    validationResults.screenshots.push(screenshotPath);

    // Technical validation
    const uiElements = await checkUIElements(page);
    const overflow = await checkOverflow(page);
    const touchTargets = await checkTouchTargets(page);
    const designTokens = await extractDesignTokens(page);
    const keyboardNav = await testKeyboardNavigation(page);

    console.log(`  🔍 UI Elements: ${JSON.stringify(uiElements, null, 2)}`);
    console.log(`  📐 Overflow: ${overflow.hasHorizontalOverflow ? '❌ YES' : '✓ NO'}`);
    console.log(`  👆 Touch target violations: ${touchTargets.length}`);
    console.log(`  ⌨️  Keyboard navigation: ${keyboardNav.totalFocusable} focusable elements`);

    // Store results
    validationResults.technical[viewport.name] = {
      loadTime,
      cls,
      consoleErrors: errorTracking.consoleErrors,
      consoleWarnings: errorTracking.consoleWarnings,
      uiElements
    };

    validationResults.responsive[viewport.name] = {
      overflow,
      touchTargets
    };

    validationResults.design[viewport.name] = {
      designTokens,
      keyboardNav
    };

  } catch (error) {
    console.error(`  ❌ Error at ${viewport.name}: ${error.message}`);
    validationResults.technical[viewport.name] = { status: 'ERROR', error: error.message };
  } finally {
    await context.close();
  }
}

async function generateReport() {
  console.log('\n\n═══════════════════════════════════════════════');
  console.log('  MAX VISUAL VALIDATION REPORT');
  console.log('═══════════════════════════════════════════════');
  console.log(`\nSession: ${validationResults.sessionId}`);
  console.log(`Timestamp: ${validationResults.timestamp}`);
  console.log(`Target: ${validationResults.url}`);

  console.log('\n───────────────────────────────────────────────');
  console.log('  LAYER 1 - TECHNICAL VALIDATION');
  console.log('───────────────────────────────────────────────');

  let technicalVerdict = 'PASS';

  VIEWPORTS.forEach(vp => {
    const tech = validationResults.technical[vp.name];
    if (!tech) return;

    console.log(`\n${vp.name}:`);
    console.log(`  Load Time: ${tech.loadTime}ms ${tech.loadTime > 3000 ? '⚠ SLOW' : '✓'}`);
    console.log(`  CLS: ${tech.cls?.toFixed(3)} ${tech.cls > 0.1 ? '⚠ HIGH' : '✓'}`);
    console.log(`  Console Errors: ${tech.consoleErrors?.length || 0} ${tech.consoleErrors?.length > 0 ? '❌' : '✓'}`);

    if (tech.consoleErrors?.length > 0) {
      console.log(`    Errors: ${tech.consoleErrors.slice(0, 3).join(', ')}`);
      technicalVerdict = 'BLOCK';
    }

    if (tech.uiElements) {
      console.log(`  Search Input: ${tech.uiElements.searchInput ? '✓' : '❌'}`);
      console.log(`  Appointment Cards: ${tech.uiElements.appointmentCards} found`);
      console.log(`  Check In Buttons: ${tech.uiElements.checkInButtons}`);
      console.log(`  Checked In Badges: ${tech.uiElements.checkedInBadges}`);
    }
  });

  console.log(`\nVerdict: ${technicalVerdict}`);

  console.log('\n───────────────────────────────────────────────');
  console.log('  LAYER 15 - DESIGN COMPLIANCE');
  console.log('───────────────────────────────────────────────');

  let designVerdict = 'PASS';

  VIEWPORTS.forEach(vp => {
    const resp = validationResults.responsive[vp.name];
    if (!resp) return;

    console.log(`\n${vp.name}:`);
    console.log(`  Horizontal Overflow: ${resp.overflow?.hasHorizontalOverflow ? '❌ YES' : '✓ NO'}`);
    console.log(`  Touch Target Violations: ${resp.touchTargets?.length || 0} ${resp.touchTargets?.length > 0 ? '⚠' : '✓'}`);

    if (resp.touchTargets?.length > 0) {
      console.log(`    Violations: ${resp.touchTargets.slice(0, 3).map(v => `${v.element} (${v.width}x${v.height}px)`).join(', ')}`);
      designVerdict = 'WARN';
    }

    if (resp.overflow?.hasHorizontalOverflow) {
      designVerdict = 'BLOCK';
    }
  });

  console.log(`\nVerdict: ${designVerdict}`);

  console.log('\n───────────────────────────────────────────────');
  console.log('  SCREENSHOT EVIDENCE');
  console.log('───────────────────────────────────────────────');
  validationResults.screenshots.forEach(ss => console.log(`  ${ss}`));

  console.log('\n═══════════════════════════════════════════════');
  console.log(`  OVERALL VERDICT: ${technicalVerdict === 'BLOCK' || designVerdict === 'BLOCK' ? '🔴 BLOCK' : designVerdict === 'WARN' ? '🟡 WARN' : '🟢 PASS'}`);
  console.log('═══════════════════════════════════════════════\n');

  // Write JSON report
  const reportPath = path.join(SESSION_DIR, 'validation-report.json');
  fs.writeFileSync(reportPath, JSON.stringify(validationResults, null, 2));
  console.log(`📄 Full report: ${reportPath}\n`);
}

async function main() {
  const browser = await playwright.chromium.launch({ headless: true });

  try {
    for (const viewport of VIEWPORTS) {
      await validateAtViewport(browser, viewport);
    }

    await generateReport();
  } catch (error) {
    console.error('❌ Validation failed:', error);
  } finally {
    await browser.close();
  }
}

main();
