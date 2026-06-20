// Shared script: keeps every nav + footer status indicator on the site
// in sync with status.claude.com. Pings every 60s; per-tab localStorage
// cache so navigating between pages doesn't refetch.
(function() {
  'use strict';
  const SUMMARY_URL    = 'https://status.claude.com/api/v2/summary.json';
  const INCIDENTS_URL  = 'https://status.claude.com/api/v2/incidents.json';
  const TRACKED_KEY    = 'cub_tracked_components';
  const CACHE_KEY      = 'cub_status_cache';
  const CACHE_TTL_MS   = 60 * 1000;
  const STATES = ['operational', 'investigating', 'identified', 'monitoring', 'loading'];

  async function fetchStatus() {
    try {
      const cached = JSON.parse(localStorage.getItem(CACHE_KEY));
      if (cached && Date.now() - cached.ts < CACHE_TTL_MS) return cached;
    } catch (e) {}

    const [sumRes, incRes] = await Promise.all([
      fetch(SUMMARY_URL,   { cache: 'no-store' }),
      fetch(INCIDENTS_URL, { cache: 'no-store' })
    ]);
    const sum = await sumRes.json();
    const inc = await incRes.json();
    const data = {
      ts: Date.now(),
      components: (sum.components || []).map(c => ({
        id: c.id, name: c.name, status: c.status
      })),
      incidents: (inc.incidents || [])
        .filter(i => i.status !== 'resolved' && i.status !== 'postmortem')
        .map(i => ({
          id: i.id,
          status: i.status,
          componentIds: (i.components || []).map(c => c.id)
        }))
    };
    try { localStorage.setItem(CACHE_KEY, JSON.stringify(data)); } catch (e) {}
    return data;
  }

  function getSelectedIds(components) {
    try {
      const raw = localStorage.getItem(TRACKED_KEY);
      if (raw) return new Set(JSON.parse(raw));
    } catch (e) {}
    return new Set(components.filter(c => !/government/i.test(c.name)).map(c => c.id));
  }

  function chooseState(data) {
    const selected = getSelectedIds(data.components);
    // Mirror the status-page card: only show a non-green state when a TRACKED
    // component is actually degraded. An incident lingering in "monitoring"
    // while its components are already back to operational must NOT grey the
    // pill (that mismatch is exactly what made the dot look grey while the card
    // showed all-green).
    const degraded = new Set(
      data.components
        .filter(c => selected.has(c.id) && c.status !== 'operational')
        .map(c => c.id)
    );
    if (!degraded.size) return 'operational';
    // Pick the incident lifecycle state, but only from incidents that hit a
    // currently-degraded tracked component.
    const relevant = data.incidents.filter(i =>
      i.componentIds.some(id => degraded.has(id))
    );
    if (relevant.some(i => i.status === 'investigating')) return 'investigating';
    if (relevant.some(i => i.status === 'identified'))    return 'identified';
    if (relevant.some(i => i.status === 'monitoring'))    return 'monitoring';
    // A tracked component is degraded but no matching incident state — still
    // not green; surface it as monitoring rather than hiding the problem.
    return 'monitoring';
  }

  function applyState(state) {
    document.querySelectorAll('[data-nav-status]').forEach(el => {
      STATES.forEach(s => el.classList.remove(s));
      el.classList.add(state);
    });
  }

  async function update() {
    try {
      const data = await fetchStatus();
      applyState(chooseState(data));
    } catch (e) {
      console.warn('[nav-status] fetch failed', e);
    }
  }

  // Run as soon as DOM elements exist
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', update);
  } else {
    update();
  }
  setInterval(update, 60 * 1000);
})();
