const { app, BrowserWindow, Tray, Menu, shell, session, nativeImage, ipcMain } = require('electron');
const { autoUpdater } = require('electron-updater');
const log = require('electron-log');
const path = require('path');
const fs = require('fs');

// Configure logging
log.transports.file.level = 'info';
autoUpdater.logger = log;

// Default configuration
const DEFAULT_CONFIG = {
  serverUrl: 'http://localhost:3016'
};

// Load configuration from user data directory
function loadConfig() {
  const configPath = path.join(app.getPath('userData'), 'config.json');

  try {
    const data = fs.readFileSync(configPath, 'utf8');
    const loaded = JSON.parse(data);

    if (loaded.serverUrl) {
      try {
        const parsed = new URL(loaded.serverUrl);
        if (!['http:', 'https:'].includes(parsed.protocol)) {
          log.error(`Invalid protocol in config: ${parsed.protocol}`);
          return DEFAULT_CONFIG;
        }
        return { serverUrl: parsed.origin };
      } catch (urlError) {
        log.error('Invalid serverUrl format:', urlError.message);
        return DEFAULT_CONFIG;
      }
    }

    return DEFAULT_CONFIG;
  } catch (e) {
    if (e.code !== 'ENOENT') {
      log.warn('Config load failed:', e.message);
    }
    return DEFAULT_CONFIG;
  }
}

// Build Content Security Policy for configured origin
function buildCSP(origin, wsOrigin) {
  return [
    `default-src 'self' ${origin}; ` +
    `script-src 'self' 'unsafe-inline' ${origin}; ` +
    `style-src 'self' 'unsafe-inline' ${origin}; ` +
    "img-src 'self' https: data:; " +
    `connect-src 'self' ${origin} ${wsOrigin}; ` +
    `font-src 'self' ${origin} https://fonts.gstatic.com; ` +
    "frame-ancestors 'none';"
  ];
}

// App configuration (populated after app ready)
let appConfig = null;

// Single instance lock
const gotTheLock = app.requestSingleInstanceLock();
if (!gotTheLock) {
  app.quit();
}

let mainWindow = null;
let tray = null;

function createWindow() {
  // Use configured origin
  const ALLOWED_ORIGIN = appConfig.serverUrl;
  const LOAD_URL = `${ALLOWED_ORIGIN}/`;
  const isSecure = ALLOWED_ORIGIN.startsWith('https');
  const wsProtocol = isSecure ? 'wss' : 'ws';
  const wsOrigin = ALLOWED_ORIGIN.replace(/^https?/, wsProtocol);

  mainWindow = new BrowserWindow({
    width: 1200,
    height: 800,
    minWidth: 800,
    minHeight: 600,
    title: 'PDev Live',
    icon: path.join(__dirname, 'assets', 'icon.png'),
    webPreferences: {
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
      webSecurity: true,
      allowRunningInsecureContent: false,
      webviewTag: false,
      preload: path.join(__dirname, 'preload.js')
    }
  });

  // Dynamic Content Security Policy based on configured server
  const csp = buildCSP(ALLOWED_ORIGIN, wsOrigin);
  session.defaultSession.webRequest.onHeadersReceived((details, callback) => {
    callback({
      responseHeaders: {
        ...details.responseHeaders,
        'Content-Security-Policy': csp
      }
    });
  });

  // Deny unnecessary permissions
  session.defaultSession.setPermissionRequestHandler((webContents, permission, callback) => {
    const allowedPermissions = ['notifications'];
    if (allowedPermissions.includes(permission)) {
      callback(true);
    } else {
      log.warn('Denied permission request:', permission);
      callback(false);
    }
  });

  // Navigation security - restrict to configured origin
  mainWindow.webContents.on('will-navigate', (event, url) => {
    try {
      const urlObj = new URL(url);
      if (urlObj.origin !== ALLOWED_ORIGIN) {
        event.preventDefault();
        log.warn('Blocked navigation to:', url);
      }
    } catch (e) {
      event.preventDefault();
      log.error('Invalid navigation URL:', url);
    }
  });

  // Block new windows, open external links in browser
  mainWindow.webContents.setWindowOpenHandler(({ url }) => {
    try {
      shell.openExternal(url);
    } catch (e) {
      log.error('Invalid window open URL:', url);
    }
    return { action: 'deny' };
  });

  // Load error handling - show offline page
  mainWindow.webContents.on('did-fail-load', (event, errorCode, errorDescription) => {
    log.error(`Load failed: ${errorCode} - ${errorDescription}`);
    mainWindow.loadFile(path.join(__dirname, 'renderer', 'offline.html'));
  });

  // Handle HTTP Basic Auth with prompt dialogs
  app.on('login', async (event, webContents, details, authInfo, callback) => {
    event.preventDefault();
    const prompt = require('electron-prompt');

    try {
      const username = await prompt({
        title: 'PDev Live - Login',
        label: 'Username:',
        inputAttrs: { type: 'text', required: true },
        type: 'input',
        alwaysOnTop: true,
        width: 370,
        height: 150
      }, mainWindow);

      if (!username) {
        callback(); // Cancelled
        return;
      }

      const password = await prompt({
        title: 'PDev Live - Login',
        label: 'Password:',
        inputAttrs: { type: 'password', required: true },
        type: 'input',
        alwaysOnTop: true,
        width: 370,
        height: 150
      }, mainWindow);

      if (!password) {
        callback(); // Cancelled
        return;
      }

      callback(username, password);
    } catch (err) {
      log.error('Auth prompt error:', err);
      callback(); // Cancel on error
    }
  });

  // Load the app
  mainWindow.loadURL(LOAD_URL);

  // Hide to tray instead of close (except on quit)
  mainWindow.on('close', (event) => {
    if (!app.isQuitting) {
      event.preventDefault();
      mainWindow.hide();
    }
  });
}

function createTray() {
  const iconPath = path.join(__dirname, 'assets', 'icon.png');
  const icon = nativeImage.createFromPath(iconPath).resize({ width: 16, height: 16 });

  tray = new Tray(icon);

  const contextMenu = Menu.buildFromTemplate([
    {
      label: 'Show PDev Live',
      click: () => {
        mainWindow.show();
        mainWindow.focus();
      }
    },
    {
      label: 'Check for Updates',
      click: () => autoUpdater.checkForUpdatesAndNotify()
    },
    { type: 'separator' },
    {
      label: 'Quit',
      click: () => {
        app.isQuitting = true;
        app.quit();
      }
    }
  ]);

  tray.setToolTip('PDev Live');
  tray.setContextMenu(contextMenu);
  tray.on('click', () => {
    mainWindow.show();
    mainWindow.focus();
  });
}

// IPC Handlers
ipcMain.handle('get-version', () => app.getVersion());
ipcMain.handle('check-updates', () => autoUpdater.checkForUpdatesAndNotify());

// App lifecycle
app.whenReady().then(() => {
  // Load configuration before creating window
  appConfig = loadConfig();
  log.info('Loaded config:', { serverUrl: appConfig.serverUrl });

  createWindow();
  createTray();

  // Check for updates silently on startup
  autoUpdater.checkForUpdatesAndNotify();
});

// Handle second instance - focus existing window
app.on('second-instance', () => {
  if (mainWindow) {
    if (mainWindow.isMinimized()) mainWindow.restore();
    mainWindow.show();
    mainWindow.focus();
  }
});

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') {
    app.quit();
  }
});

app.on('activate', () => {
  if (BrowserWindow.getAllWindows().length === 0) {
    createWindow();
  } else {
    mainWindow.show();
  }
});

// Auto-updater events
autoUpdater.on('checking-for-update', () => {
  log.info('Checking for updates...');
});

autoUpdater.on('update-available', (info) => {
  log.info('Update available:', info.version);
  mainWindow.webContents.send('update-available', info);
});

autoUpdater.on('update-not-available', () => {
  log.info('No updates available');
});

autoUpdater.on('download-progress', (progress) => {
  log.info(`Download progress: ${progress.percent}%`);
  mainWindow.webContents.send('update-progress', progress);
});

autoUpdater.on('update-downloaded', (info) => {
  log.info('Update downloaded:', info.version);
  mainWindow.webContents.send('update-downloaded', info);
});

autoUpdater.on('error', (err) => {
  log.error('Auto-updater error:', err);
});
