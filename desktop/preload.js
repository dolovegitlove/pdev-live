const { contextBridge, ipcRenderer } = require('electron');

// Expose minimal, secure API to renderer
contextBridge.exposeInMainWorld('pdevLive', {
  // App info
  getVersion: () => ipcRenderer.invoke('get-version'),

  // Update controls
  checkForUpdates: () => ipcRenderer.invoke('check-updates'),

  // Platform detection
  platform: process.platform,

  // Update event listeners with cleanup functions
  onUpdateAvailable: (callback) => {
    const handler = (_event, info) => callback(info);
    ipcRenderer.on('update-available', handler);
    return () => ipcRenderer.removeListener('update-available', handler);
  },

  onUpdateProgress: (callback) => {
    const handler = (_event, progress) => callback(progress);
    ipcRenderer.on('update-progress', handler);
    return () => ipcRenderer.removeListener('update-progress', handler);
  },

  onUpdateDownloaded: (callback) => {
    const handler = (_event, info) => callback(info);
    ipcRenderer.on('update-downloaded', handler);
    return () => ipcRenderer.removeListener('update-downloaded', handler);
  }
});

// Freeze API to prevent tampering
Object.freeze(window.pdevLive);
