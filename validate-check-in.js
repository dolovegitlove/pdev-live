const { chromium } = require('playwright');
const fs = require('fs');
const path = require('path');

(async () => {
  const browser = await chromium.launch({
    headless: false,
    slowMo: 100
  });

  const context = await browser.newContext({
    viewport: { width: 1920, height: 1080 },
    deviceScaleFactor: 1
  });

  const page = await context.newPage();

  // Storage for validation results
  const validationResults = {
    consoleErrors: [],
    consoleWarnings: [],
    networkErrors: [],
    apiCalls: [],
    pageContent: {},
    screenshots: []
  };

  // Monitor console messages
  page.on('console', msg => {
    const type = msg.type();
    const text = msg.text();

    if (type === 'error') {
      validationResults.consoleErrors.push({
        type: 'error',
        text: text,
        timestamp: new Date().toISOString()
      });
      console.log(`❌ Console Error: ${text}`);
    } else if (type === 'warning') {
      validationResults.consoleWarnings.push({
        type: 'warning',
        text: text,
        timestamp: new Date().toISOString()
      });
      console.log(`⚠️  Console Warning: ${text}`);
    }
  });

  // Monitor page errors
  page.on('pageerror', error => {
    validationResults.consoleErrors.push({
      type: 'pageerror',
      text: error.message,
      stack: error.stack,
      timestamp: new Date().toISOString()
    });
    console.log(`❌ Page Error: ${error.message}`);
  });

  // Monitor network requests
  page.on('requestfailed', request => {
    validationResults.networkErrors.push({
      url: request.url(),
      method: request.method(),
      failure: request.failure().errorText,
      timestamp: new Date().toISOString()
    });
    console.log(`❌ Request Failed: ${request.url()} - ${request.failure().errorText}`);
  });

  // Monitor API calls (especially /api/admin/bookings)
  page.on('response', async response => {
    const url = response.url();

    if (url.includes('/api/')) {
      const apiCall = {
        url: url,
        status: response.status(),
        statusText: response.statusText(),
        method: response.request().method(),
        timestamp: new Date().toISOString()
      };

      // Try to get response body for API calls
      try {
        const contentType = response.headers()['content-type'];
        if (contentType && contentType.includes('application/json')) {
          apiCall.responseBody = await response.json();
        }
      } catch (e) {
        // Response body already consumed or not JSON
      }

      validationResults.apiCalls.push(apiCall);

      const statusEmoji = response.status() >= 200 && response.status() < 300 ? '✓' : '❌';
      console.log(`${statusEmoji} API Call: ${response.request().method()} ${url} → ${response.status()}`);
    }
  });

  try {
    console.log('\n🔍 VALIDATION: ITT Heal Check-In Page');
    console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n');

    // Step 1: Check if we need to login first
    console.log('Step 1: Checking authentication...');
    await page.goto('https://ittheal.com/admin/check-in.html', {
      waitUntil: 'networkidle',
      timeout: 30000
    });

    await page.waitForTimeout(2000);

    // Check if redirected to login
    const currentUrl = page.url();
    console.log(`Current URL: ${currentUrl}`);

    if (currentUrl.includes('login.html')) {
      console.log('\n🔐 Login required - proceeding with authentication...\n');

      // Take screenshot of login page
      const loginScreenshot = path.join(__dirname, 'validation-login.png');
      await page.screenshot({ path: loginScreenshot, fullPage: true });
      validationResults.screenshots.push(loginScreenshot);
      console.log(`📸 Login page screenshot: ${loginScreenshot}`);

      // Perform login with actual admin credentials
      // Username field (already has "admin" prefilled, clear and re-enter)
      const usernameInput = page.locator('input').first();
      await usernameInput.click({ clickCount: 3 }); // Select all
      await usernameInput.fill('admin');

      // Password field
      const passwordInput = page.locator('input').nth(1);
      await passwordInput.click();
      await passwordInput.fill('admin123');

      // Click "Welcome Me In" button
      await page.locator('button:has-text("Welcome Me In")').click();

      await page.waitForTimeout(3000);

      // Navigate to check-in page after login
      await page.goto('https://ittheal.com/admin/check-in.html', {
        waitUntil: 'networkidle',
        timeout: 30000
      });

      await page.waitForTimeout(2000);
    }

    // Step 2: Capture check-in page screenshot
    console.log('\nStep 2: Capturing check-in page screenshot...');
    const checkInScreenshot = path.join(__dirname, 'validation-check-in.png');
    await page.screenshot({ path: checkInScreenshot, fullPage: true });
    validationResults.screenshots.push(checkInScreenshot);
    console.log(`📸 Check-in page screenshot: ${checkInScreenshot}`);

    // Step 3: Extract page content
    console.log('\nStep 3: Extracting page content...');

    // Check for "Today's Appointments" heading
    const appointmentsHeading = await page.locator('h2, h3, .appointments-header').first().textContent().catch(() => null);
    validationResults.pageContent.appointmentsHeading = appointmentsHeading;
    console.log(`Appointments Heading: ${appointmentsHeading || 'NOT FOUND'}`);

    // Count appointment items
    const appointmentCount = await page.locator('.appointment-item, .booking-item, tr[data-booking-id]').count();
    validationResults.pageContent.appointmentCount = appointmentCount;
    console.log(`Appointment Items Found: ${appointmentCount}`);

    // Check for patient names
    const patientNames = await page.locator('.patient-name, .booking-patient, td:has-text("Patient")').allTextContents();
    validationResults.pageContent.patientNames = patientNames;
    console.log(`Patient Names: ${patientNames.length > 0 ? patientNames.join(', ') : 'NONE FOUND'}`);

    // Check for empty state message
    const emptyMessage = await page.locator('.empty-state, .no-appointments, p:has-text("No appointments")').first().textContent().catch(() => null);
    validationResults.pageContent.emptyMessage = emptyMessage;
    if (emptyMessage) {
      console.log(`Empty State Message: ${emptyMessage}`);
    }

    // Check page title
    const pageTitle = await page.title();
    validationResults.pageContent.pageTitle = pageTitle;
    console.log(`Page Title: ${pageTitle}`);

    // Extract any error messages visible on page
    const errorMessages = await page.locator('.error, .alert-error, [role="alert"]').allTextContents();
    validationResults.pageContent.errorMessages = errorMessages;
    if (errorMessages.length > 0) {
      console.log(`⚠️  Error Messages on Page: ${errorMessages.join(', ')}`);
    }

    // Step 4: Check specific API call to /api/admin/bookings
    console.log('\nStep 4: Analyzing /api/admin/bookings API call...');
    const bookingsApiCall = validationResults.apiCalls.find(call => call.url.includes('/api/admin/bookings'));

    if (bookingsApiCall) {
      console.log(`✓ API Call Found: ${bookingsApiCall.method} ${bookingsApiCall.url}`);
      console.log(`  Status: ${bookingsApiCall.status} ${bookingsApiCall.statusText}`);

      if (bookingsApiCall.status === 401) {
        console.log(`  ❌ AUTHENTICATION FAILED - 401 Unauthorized`);
      } else if (bookingsApiCall.status >= 200 && bookingsApiCall.status < 300) {
        console.log(`  ✓ SUCCESS`);
        if (bookingsApiCall.responseBody) {
          console.log(`  Response: ${JSON.stringify(bookingsApiCall.responseBody, null, 2)}`);
        }
      } else {
        console.log(`  ❌ FAILED with status ${bookingsApiCall.status}`);
      }
    } else {
      console.log(`❌ No API call to /api/admin/bookings detected`);
    }

    // Step 5: Summary report
    console.log('\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
    console.log('📊 VALIDATION SUMMARY');
    console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n');

    console.log(`Console Errors: ${validationResults.consoleErrors.length}`);
    if (validationResults.consoleErrors.length > 0) {
      validationResults.consoleErrors.forEach((err, idx) => {
        console.log(`  ${idx + 1}. ${err.text}`);
      });
    }

    console.log(`\nConsole Warnings: ${validationResults.consoleWarnings.length}`);
    if (validationResults.consoleWarnings.length > 0) {
      validationResults.consoleWarnings.forEach((warn, idx) => {
        console.log(`  ${idx + 1}. ${warn.text}`);
      });
    }

    console.log(`\nNetwork Errors: ${validationResults.networkErrors.length}`);
    if (validationResults.networkErrors.length > 0) {
      validationResults.networkErrors.forEach((err, idx) => {
        console.log(`  ${idx + 1}. ${err.url} - ${err.failure}`);
      });
    }

    console.log(`\nAPI Calls: ${validationResults.apiCalls.length}`);
    validationResults.apiCalls.forEach((call, idx) => {
      const statusEmoji = call.status >= 200 && call.status < 300 ? '✓' : '❌';
      console.log(`  ${idx + 1}. ${statusEmoji} ${call.method} ${call.url} → ${call.status}`);
    });

    console.log(`\nPage Content:`);
    console.log(`  Appointments Heading: ${validationResults.pageContent.appointmentsHeading || 'NOT FOUND'}`);
    console.log(`  Appointment Count: ${validationResults.pageContent.appointmentCount}`);
    console.log(`  Patient Names: ${validationResults.pageContent.patientNames.length > 0 ? validationResults.pageContent.patientNames.join(', ') : 'NONE'}`);

    console.log(`\nScreenshots:`);
    validationResults.screenshots.forEach((screenshot, idx) => {
      console.log(`  ${idx + 1}. ${screenshot}`);
    });

    // Save validation results to JSON
    const resultsPath = path.join(__dirname, 'validation-results.json');
    fs.writeFileSync(resultsPath, JSON.stringify(validationResults, null, 2));
    console.log(`\n💾 Full results saved to: ${resultsPath}`);

    console.log('\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n');

  } catch (error) {
    console.error('\n❌ VALIDATION FAILED:', error.message);
    console.error(error.stack);

    // Take error screenshot
    try {
      const errorScreenshot = path.join(__dirname, 'validation-error.png');
      await page.screenshot({ path: errorScreenshot, fullPage: true });
      console.log(`📸 Error screenshot: ${errorScreenshot}`);
    } catch (screenshotError) {
      console.error('Could not capture error screenshot:', screenshotError.message);
    }
  } finally {
    await browser.close();
  }
})();
