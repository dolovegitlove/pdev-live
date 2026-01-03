const { app, BrowserWindow, Tray, Menu, shell, session, nativeImage, ipcMain } = require('electron');
const { autoUpdater } = require('electron-updater');
const log = require('electron-log');
const path = require('path');

// Configure logging
log.transports.file.level = 'info';
autoUpdater.logger = log;

// Constants
const ALLOWED_ORIGIN = 'https://walletsnack.com';
const LOAD_URL = `${ALLOWED_ORIGIN}/pdev/live/`;

// Single instance lock
const gotTheLock = app.requestSingleInstanceLock();
if (!gotTheLock) {
  app.quit();
}

let mainWindow = null;
let tray = null;

function createWindow() {
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

  // Content Security Policy
  session.defaultSession.webRequest.onHeadersReceived((details, callback) => {
    callback({
      responseHeaders: {
        ...details.responseHeaders,
        'Content-Security-Policy': [
          "default-src 'self' https://walletsnack.com; " +
          "script-src 'self' 'unsafe-inline' https://walletsnack.com; " +
          "style-src 'self' 'unsafe-inline' https://walletsnack.com; " +
          "img-src 'self' https: data:; " +
          "connect-src 'self' https://walletsnack.com wss://walletsnack.com; " +
          "font-src 'self' https://walletsnack.com https://fonts.gstatic.com; " +
          "frame-ancestors 'none';"
        ]
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

  // Navigation security - restrict to allowed origin
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
      const urlObj = new URL(url);
      if (urlObj.origin === ALLOWED_ORIGIN) {
        shell.openExternal(url);
      } else {
        shell.openExternal(url);
      }
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
