// ============================================================================
// Version Polling - Auto-Reload Detection
// ============================================================================
// Polls /health endpoint every 60 seconds to detect server updates
// Prompts user to reload if version changes
// ============================================================================

(function() {
    // Health endpoint path (proxied through /pdev/ → server root)
    const HEALTH_ENDPOINT = '/pdev/health';

    let currentVersion = null;
    let versionCheckInterval = null;

    async function checkVersion() {
        try {
            const response = await fetch(HEALTH_ENDPOINT, {
                method: 'GET',
                cache: 'no-store',
                headers: {
                    'Cache-Control': 'no-cache'
                }
            });

            if (!response.ok) {
                console.warn('[Version Check] Health endpoint returned', response.status);
                return;
            }

            const data = await response.json();
            const serverVersion = data.version || '1.0.0';

            if (currentVersion === null) {
                // First check - store version
                currentVersion = serverVersion;
                console.log('[Version Check] Current version:', currentVersion);
            } else if (serverVersion !== currentVersion) {
                // Version changed - server was updated
                console.log('[Version Check] Version changed:', currentVersion, '→', serverVersion);

                clearInterval(versionCheckInterval);

                showUpdateNotification(currentVersion, serverVersion);
            }
        } catch (err) {
            console.error('[Version Check] Failed:', err.message);
        }
    }

    function showUpdateNotification(oldVersion, newVersion) {
        // Create notification overlay
        const overlay = document.createElement('div');
        overlay.style.cssText = `
            position: fixed;
            top: 0;
            left: 0;
            right: 0;
            bottom: 0;
            background: rgba(0, 0, 0, 0.8);
            display: flex;
            align-items: center;
            justify-content: center;
            z-index: 10000;
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
        `;

        const dialog = document.createElement('div');
        dialog.style.cssText = `
            background: #1a1a2e;
            color: #ffffff;
            padding: 2rem;
            border-radius: 8px;
            max-width: 400px;
            text-align: center;
            box-shadow: 0 4px 20px rgba(0, 0, 0, 0.5);
        `;

        dialog.innerHTML = `
            <div style="font-size: 48px; margin-bottom: 1rem;">🔄</div>
            <h2 style="margin: 0 0 1rem 0; color: #8aa77b;">Update Available</h2>
            <p style="margin: 0 0 0.5rem 0; color: #b0b0b0;">
                PDev-Live has been updated
            </p>
            <p style="margin: 0 0 1.5rem 0; font-size: 0.85rem; color: #808080;">
                ${oldVersion} → ${newVersion}
            </p>
            <button id="reloadBtn" style="
                background: #8aa77b;
                color: #ffffff;
                border: none;
                padding: 0.75rem 2rem;
                border-radius: 4px;
                font-size: 1rem;
                cursor: pointer;
                font-weight: 600;
            ">
                Reload Page
            </button>
            <button id="dismissBtn" style="
                background: transparent;
                color: #808080;
                border: 1px solid #404040;
                padding: 0.75rem 2rem;
                border-radius: 4px;
                font-size: 1rem;
                cursor: pointer;
                margin-left: 0.5rem;
            ">
                Later
            </button>
        `;

        overlay.appendChild(dialog);
        document.body.appendChild(overlay);

        // Reload button handler
        document.getElementById('reloadBtn').addEventListener('click', () => {
            window.location.reload(true);
        });

        // Dismiss button handler
        document.getElementById('dismissBtn').addEventListener('click', () => {
            overlay.remove();
            // Resume checking every 5 minutes after dismiss
            versionCheckInterval = setInterval(checkVersion, 300000);
        });
    }

    // Start version checking after page load
    window.addEventListener('load', () => {
        // Initial check after 5 seconds
        setTimeout(checkVersion, 5000);

        // Then check every 60 seconds
        versionCheckInterval = setInterval(checkVersion, 60000);
    });

    // Stop checking when page unloads
    window.addEventListener('beforeunload', () => {
        if (versionCheckInterval) {
            clearInterval(versionCheckInterval);
        }
    });
})();
