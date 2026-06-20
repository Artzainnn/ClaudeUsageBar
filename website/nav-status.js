// Shared script: keeps every nav + footer status indicator on the site
// in sync with status.claude.com. Pings every 60s; per-tab localStorage
// cache so navigating between pages doesn't refetch.
(function() {
  'use strict';
  const SUMMARY_URL    = 'https://status.claude.com/api/v2/summary.json';
  const TRACKED_KEY    = 'cub_tracked_components';
  const CACHE_KEY      = 'cub_status_cache';
  const CACHE_TTL_MS   = 60 * 1000;
  const STATES = ['operational', 'minor', 'major', 'critical', 'loading'];
  // Same severity model as the status-page card (effectiveIndicator), so the
  // pill colour always matches the card for every state, not just green.
  const SEVERITY = {
    operational: 0, under_maintenance: 1, degraded_performance: 1,
    partial_outage: 2, major_outage: 3
  };
  const INDICATOR = ['operational', 'minor', 'major', 'critical'];

  async function fetchStatus() {
    try {
      const cached = JSON.parse(localStorage.getItem(CACHE_KEY));
      if (cached && Date.now() - cached.ts < CACHE_TTL_MS) return cached;
    } catch (e) {}

    const sumRes = await fetch(SUMMARY_URL, { cache: 'no-store' });
    const sum = await sumRes.json();
    const data = {
      ts: Date.now(),
      components: (sum.components || []).map(c => ({
        id: c.id, name: c.name, status: c.status
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
    // Worst severity among the components the user actually tracks — identical
    // to the status-page card's effectiveIndicator(). Same data + same logic +
    // same colours => pill and card always agree.
    const max = data.components
      .filter(c => selected.has(c.id))
      .reduce((m, c) => Math.max(m, SEVERITY[c.status] ?? 0), 0);
    return INDICATOR[max] || 'operational';
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
