/**
 * PDev Live Management Interface
 * SECURITY: No admin keys in frontend - uses session-based proxy auth
 */
(function() {
  'use strict';

  var API_BASE = '/pdev';
  var SESSIONS_PATH = '/sessions';

  // Secure toast notification
  function toast(message, isError) {
    var t = document.createElement('div');
    t.textContent = message;
    t.className = 'toast ' + (isError ? 'toast-error' : 'toast-success');
    document.body.appendChild(t);
    setTimeout(function() { t.remove(); }, 3000);
  }

  // Escape HTML to prevent XSS
  function escapeHtml(str) {
    if (!str) return '';
    var div = document.createElement('div');
    div.textContent = str;
    return div.innerHTML;
  }

  // End session (no admin key needed - just marks complete)
  window.endItem = function(id) {
    if (!confirm('End this session?')) return;
    fetch(API_BASE + SESSIONS_PATH + '/' + encodeURIComponent(id) + '/complete', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ status: 'completed' })
    })
    .then(function(res) {
      if (res.ok) { toast('Session ended'); loadItems(); }
      else { toast('Failed: ' + res.status, true); }
    })
    .catch(function() { toast('Network error', true); });
  };

  // Delete session - requires admin auth (prompt for key)
  window.delItem = function(id) {
    if (!confirm('Delete this session permanently?')) return;
    var adminKey = sessionStorage.getItem('pdev_admin_key');
    if (!adminKey) {
      adminKey = prompt('Enter admin key:');
      if (!adminKey) return;
      sessionStorage.setItem('pdev_admin_key', adminKey);
    }
    fetch(API_BASE + SESSIONS_PATH + '/' + encodeURIComponent(id), {
      method: 'DELETE',
      headers: { 'X-Admin-Key': adminKey }
    })
    .then(function(res) {
      if (res.ok) { toast('Deleted'); loadItems(); }
      else if (res.status === 401) {
        sessionStorage.removeItem('pdev_admin_key');
        toast('Invalid admin key', true);
      }
      else { toast('Failed: ' + res.status, true); }
    })
    .catch(function() { toast('Network error', true); });
  };

  // Batch end sessions
  window.endItems = function(ids) {
    if (!ids || !ids.length) return;
    if (!confirm('End ' + ids.length + ' session(s)?')) return;
    var completed = 0;
    ids.forEach(function(id) {
      fetch(API_BASE + SESSIONS_PATH + '/' + encodeURIComponent(id) + '/complete', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ status: 'completed' })
      })
      .then(function() {
        completed++;
        if (completed === ids.length) { toast('Ended ' + ids.length + ' sessions'); loadItems(); }
      });
    });
  };

  // Batch delete sessions - requires admin auth
  window.delItems = function(ids) {
    if (!ids || !ids.length) return;
    if (!confirm('Delete ' + ids.length + ' session(s) permanently?')) return;
    var adminKey = sessionStorage.getItem('pdev_admin_key');
    if (!adminKey) {
      adminKey = prompt('Enter admin key:');
      if (!adminKey) return;
      sessionStorage.setItem('pdev_admin_key', adminKey);
    }
    var completed = 0;
    var failed = 0;
    ids.forEach(function(id) {
      fetch(API_BASE + SESSIONS_PATH + '/' + encodeURIComponent(id), {
        method: 'DELETE',
        headers: { 'X-Admin-Key': adminKey }
      })
      .then(function(res) {
        if (res.ok) completed++;
        else failed++;
        if (completed + failed === ids.length) {
          if (failed > 0) {
            sessionStorage.removeItem('pdev_admin_key');
            toast('Deleted ' + completed + ', failed ' + failed, true);
          } else {
            toast('Deleted ' + completed + ' sessions');
          }
          loadItems();
        }
      });
    });
  };

  // Clear all - requires admin auth with double confirmation
  window.clearAll = function() {
    if (!confirm('Delete ALL sessions? This cannot be undone.')) return;
    if (!confirm('Are you absolutely sure?')) return;
    var adminKey = sessionStorage.getItem('pdev_admin_key');
    if (!adminKey) {
      adminKey = prompt('Enter admin key:');
      if (!adminKey) return;
      sessionStorage.setItem('pdev_admin_key', adminKey);
    }
    fetch(API_BASE + SESSIONS_PATH, {
      method: 'DELETE',
      headers: { 'X-Admin-Key': adminKey }
    })
    .then(function(res) {
      if (res.ok) { toast('All sessions cleared'); loadItems(); }
      else if (res.status === 401) {
        sessionStorage.removeItem('pdev_admin_key');
        toast('Invalid admin key', true);
      }
      else { toast('Failed: ' + res.status, true); }
    })
    .catch(function() { toast('Network error', true); });
  };

  // Load active sessions
  window.loadItems = function() {
    fetch(API_BASE + SESSIONS_PATH + '/active')
    .then(function(res) { return res.json(); })
    .then(function(items) { renderCards(items); })
    .catch(function() { toast('Failed to load sessions', true); });
  };

  // Render project cards with XSS protection
  function renderCards(items) {
    var grid = document.getElementById('cardGrid');
    if (!grid) return;

    if (!items || !items.length) {
      grid.innerHTML = '<div class="empty-state"><div class="icon">📭</div><p>No active projects</p></div>';
      return;
    }

    // Group by project
    var projects = {};
    items.forEach(function(item) {
      var key = (item.project_name || 'unknown') + '|' + (item.server_origin || '');
      if (!projects[key]) {
        projects[key] = {
          name: item.project_name || 'unknown',
          server: item.server_origin || '',
          sessions: [],
          totalSteps: 0
        };
      }
      projects[key].sessions.push(item);
      projects[key].totalSteps += (item.total_steps || 0);
    });

    // Clear and rebuild grid using DOM methods (XSS safe)
    grid.innerHTML = '';
    Object.values(projects).forEach(function(p) {
      var cmds = p.sessions
        .map(function(s) { return '/' + (s.command_type || '?'); })
        .filter(function(v, i, a) { return a.indexOf(v) === i; })
        .join(' ');
      var ids = p.sessions.map(function(s) { return s.id; });

      var card = document.createElement('div');
      card.className = 'scard';
      card.onclick = function() {
        location.href = 'project.html?project=' + encodeURIComponent(p.name) + '&server=' + encodeURIComponent(p.server);
      };

      var head = document.createElement('div');
      head.className = 'shead';

      var projName = document.createElement('span');
      projName.className = 'sproj';
      projName.textContent = p.name;

      var cmdSpan = document.createElement('span');
      cmdSpan.className = 'scmd';
      cmdSpan.textContent = cmds;

      head.appendChild(projName);
      head.appendChild(cmdSpan);

      var meta = document.createElement('div');
      meta.className = 'smeta';
      meta.textContent = p.server + ' - ' + p.totalSteps + ' steps';

      var btns = document.createElement('div');
      btns.className = 'sbtns';

      var endBtn = document.createElement('button');
      endBtn.className = 'sbtn sw';
      endBtn.textContent = 'End';
      endBtn.onclick = function(e) { e.stopPropagation(); endItems(ids); };

      var delBtn = document.createElement('button');
      delBtn.className = 'sbtn sd';
      delBtn.textContent = 'Del';
      delBtn.onclick = function(e) { e.stopPropagation(); delItems(ids); };

      btns.appendChild(endBtn);
      btns.appendChild(delBtn);

      card.appendChild(head);
      card.appendChild(meta);
      card.appendChild(btns);
      grid.appendChild(card);
    });
  }

  // Inject styles
  var styles = document.createElement('style');
  styles.textContent = [
    '.scard{background:var(--card);border:1px solid var(--border);border-radius:8px;padding:1rem;cursor:pointer;transition:border-color 0.2s}',
    '.scard:hover{border-color:var(--accent)}',
    '.scard:focus-visible{outline:2px solid var(--accent);outline-offset:2px}',
    '.shead{display:flex;justify-content:space-between;margin-bottom:.5rem}',
    '.sproj{font-weight:600}',
    '.scmd{color:var(--accent);font-family:monospace}',
    '.smeta{color:var(--muted);font-size:.85rem;margin-bottom:.75rem}',
    '.sbtns{display:flex;gap:.5rem}',
    '.sbtn{padding:.25rem .5rem;font-size:.75rem;border:none;border-radius:4px;cursor:pointer;min-height:44px;min-width:44px}',
    '.sbtn:focus-visible{outline:2px solid var(--accent);outline-offset:2px}',
    '.sbtn:active{transform:scale(0.95)}',
    '.sw{background:var(--warn);color:#000}',
    '.sd{background:var(--error,#ef4444);color:#fff}',
    '.clrBtn{background:#dc2626;color:white;padding:.5rem 1rem;border:none;border-radius:4px;cursor:pointer;margin-left:auto}',
    '.clrBtn:focus-visible{outline:2px solid var(--accent);outline-offset:2px}',
    '#cardGrid{display:grid;grid-template-columns:repeat(auto-fill,minmax(280px,1fr));gap:1rem;padding:1rem}',
    '.toast{position:fixed;bottom:20px;right:20px;padding:12px 24px;border-radius:6px;z-index:9999;color:white;animation:fadeIn 0.2s}',
    '.toast-success{background:var(--success,#22c55e)}',
    '.toast-error{background:var(--error,#ef4444)}',
    '@keyframes fadeIn{from{opacity:0;transform:translateY(10px)}to{opacity:1;transform:translateY(0)}}'
  ].join('');
  document.head.appendChild(styles);

  // Initialize on DOM ready
  document.addEventListener('DOMContentLoaded', function() {
    var header = document.querySelector('header');
    if (header) {
      var clearBtn = document.createElement('button');
      clearBtn.className = 'clrBtn';
      clearBtn.textContent = 'Clear All';
      clearBtn.onclick = clearAll;
      header.appendChild(clearBtn);
    }

    var outputPanel = document.querySelector('.output-panel');
    if (outputPanel) {
      outputPanel.innerHTML = '<div class="output-header"><span>Active Sessions</span><button class="btn btn-outline" onclick="loadItems()">Refresh</button></div><div id="cardGrid"></div>';
    }

    loadItems();
    setInterval(loadItems, 30000);
  });
})();
