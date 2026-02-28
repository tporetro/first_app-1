/* Shared utilities for all pages */

const API = '/api';

async function apiFetch(path, opts = {}) {
  const res = await fetch(API + path, opts);
  const data = await res.json();
  if (!res.ok) throw new Error(data.error || res.statusText);
  return data;
}

function setActive(href) {
  document.querySelectorAll('.nav-item').forEach(el => {
    el.classList.toggle('active', el.getAttribute('href') === href);
  });
}

function showAlert(container, msg, type = 'error') {
  container.innerHTML = `<div class="alert alert-${type}">${escHtml(msg)}</div>`;
}

function escHtml(str) {
  return String(str)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

function formatNum(n) {
  return Number(n).toLocaleString();
}

// Community color palette (cycles)
const COMMUNITY_COLORS = [
  '#38bdf8','#f97316','#22c55e','#a78bfa','#ec4899',
  '#fbbf24','#34d399','#60a5fa','#f43f5e','#2dd4bf',
];
function communityColor(id) {
  return COMMUNITY_COLORS[id % COMMUNITY_COLORS.length];
}

// Node type → vis-network style
const NODE_STYLE = {
  Person: {
    color: { background: '#1d4ed8', border: '#3b82f6', highlight: { background: '#2563eb', border: '#60a5fa' } },
    shape: 'dot', size: 16,
  },
  Building: {
    color: { background: '#c2410c', border: '#f97316', highlight: { background: '#ea580c', border: '#fb923c' } },
    shape: 'square', size: 14,
  },
  Company: {
    color: { background: '#15803d', border: '#22c55e', highlight: { background: '#16a34a', border: '#4ade80' } },
    shape: 'diamond', size: 14,
  },
};

// Relationship → vis-network edge style
const EDGE_STYLE = {
  OWNS:      { color: { color: '#f97316', highlight: '#fb923c' }, dashes: false, width: 2 },
  WORKS_AT:  { color: { color: '#22c55e', highlight: '#4ade80' }, dashes: false, width: 1.5 },
  KNOWS:     { color: { color: '#38bdf8', highlight: '#7dd3fc' }, dashes: false, width: 1 },
  FAMILY_OF: { color: { color: '#ec4899', highlight: '#f9a8d4' }, dashes: false, width: 1.5 },
  FOLLOWS:   { color: { color: '#a78bfa', highlight: '#c4b5fd' }, dashes: true,  width: 1 },
};
const DEFAULT_EDGE_STYLE = { color: { color: '#475569' }, dashes: false, width: 1 };
