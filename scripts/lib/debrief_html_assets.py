#!/usr/bin/env python3
"""Offline CSS and vanilla JS assets for the /debrief v2 interactive HTML report."""

REPORT_CSS = """
* { box-sizing: border-box; margin: 0; padding: 0; }
body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; background: #f8fafc; color: #334155; line-height: 1.65; padding: 40px 20px 64px; }
.container { max-width: 980px; margin: 0 auto; }
h1 { font-size: 30px; font-weight: 700; color: #0f172a; margin-bottom: 6px; letter-spacing: -0.02em; }
h2 { font-size: 20px; font-weight: 600; color: #0f172a; margin-top: 44px; margin-bottom: 14px; }
.subtitle { color: #64748b; font-size: 14px; margin-bottom: 24px; }
.nav-toc { display: flex; flex-wrap: wrap; gap: 8px; margin: 20px 0 28px; padding: 14px; background: #fff; border-radius: 8px; border: 1px solid #e2e8f0; }
.nav-toc a { font-size: 12px; color: #475569; text-decoration: none; padding: 5px 11px; border-radius: 6px; background: #f1f5f9; }
.nav-toc a:hover { background: #e2e8f0; color: #0f172a; }
.stats-row { display: flex; gap: 22px; margin-bottom: 32px; padding: 18px 0; border-top: 1px solid #e2e8f0; border-bottom: 1px solid #e2e8f0; flex-wrap: wrap; }
.stat { text-align: center; min-width: 96px; }
.stat-value { font-size: 22px; font-weight: 700; color: #0f172a; font-variant-numeric: tabular-nums; }
.stat-label { font-size: 11px; color: #64748b; text-transform: uppercase; letter-spacing: 0.03em; }
.at-a-glance { background: linear-gradient(135deg, #fef3c7 0%, #fde68a 100%); border: 1px solid #f59e0b; border-radius: 12px; padding: 20px 24px; margin-bottom: 28px; }
.glance-title { font-size: 16px; font-weight: 700; color: #92400e; margin-bottom: 14px; }
.glance-sections { display: flex; flex-direction: column; gap: 10px; }
.glance-section { font-size: 14px; color: #78350f; line-height: 1.6; }
.glance-section strong { color: #92400e; }
.see-more { color: #b45309; text-decoration: none; font-size: 13px; white-space: nowrap; font-weight: 500; }
.see-more:hover { text-decoration: underline; }
.project-areas, .big-wins, .friction-categories, .features-section, .patterns-section, .horizon-section { display: flex; flex-direction: column; gap: 12px; margin-bottom: 24px; }
.project-area, .narrative, .chart-card { background: #fff; border: 1px solid #e2e8f0; border-radius: 8px; padding: 16px 18px; }
.area-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 6px; gap: 8px; }
.area-name { font-weight: 600; font-size: 15px; color: #0f172a; }
.area-count { font-size: 12px; color: #475569; background: #f1f5f9; padding: 2px 8px; border-radius: 4px; white-space: nowrap; }
.area-desc { font-size: 14px; color: #475569; line-height: 1.55; }
.narrative p { margin-bottom: 12px; font-size: 14px; color: #475569; line-height: 1.7; }
.key-insight { background: #f0fdf4; border: 1px solid #bbf7d0; border-radius: 8px; padding: 12px 16px; margin-top: 10px; font-size: 14px; color: #166534; }
.section-intro { font-size: 14px; color: #64748b; margin-bottom: 14px; }
.big-win { background: #f0fdf4; border: 1px solid #bbf7d0; border-radius: 8px; padding: 16px; }
.big-win-title { font-weight: 600; font-size: 15px; color: #166534; margin-bottom: 6px; }
.big-win-desc { font-size: 14px; color: #15803d; line-height: 1.55; }
.friction-category { background: #fef2f2; border: 1px solid #fca5a5; border-radius: 8px; padding: 16px; }
.friction-title { font-weight: 600; font-size: 15px; color: #991b1b; margin-bottom: 6px; }
.friction-desc { font-size: 13px; color: #7f1d1d; margin-bottom: 8px; }
.friction-examples { margin: 0 0 0 20px; font-size: 13px; color: #334155; }
.friction-examples li { margin-bottom: 4px; }
.friction-fix { margin-top: 10px; padding: 9px 12px; background: #fff; border-left: 3px solid #16a34a; border-radius: 4px; font-size: 13px; color: #1e293b; }
.friction-fix strong { color: #166534; }
.col-guide { margin-top: 12px; padding: 10px 14px; background: #f8fafc; border: 1px solid #e2e8f0; border-radius: 6px; font-size: 12px; color: #475569; }
.col-guide summary { cursor: pointer; font-weight: 600; color: #334155; }
.col-guide ul { margin: 8px 0 0 18px; line-height: 1.55; }
.col-guide li { margin-bottom: 3px; }
.action-pill { display: inline-block; padding: 2px 8px; border-radius: 4px; font-size: 11px; font-weight: 700; letter-spacing: 0.03em; }
.act-create { background: #dcfce7; color: #166534; }
.act-modify { background: #fef3c7; color: #92400e; }
.act-remove { background: #fee2e2; color: #991b1b; }
.coach-item { padding: 10px 12px; border-radius: 6px; margin-bottom: 10px; font-size: 13px; }
.coach-item:last-child { margin-bottom: 0; }
.coach-user { background: #eff6ff; border-left: 3px solid #2563eb; }
.coach-agent { background: #f0fdf4; border-left: 3px solid #16a34a; }
.coach-title { font-weight: 600; color: #0f172a; margin-bottom: 3px; }
.coach-ev { color: #475569; margin-bottom: 4px; font-size: 12px; }
.coach-act { color: #1e293b; }
.rules-section { background: #eff6ff; border: 1px solid #bfdbfe; border-radius: 8px; padding: 16px; margin-bottom: 20px; }
.rules-section h3 { font-size: 14px; font-weight: 600; color: #1e40af; margin-bottom: 10px; }
.rules-actions { margin-bottom: 12px; padding-bottom: 10px; border-bottom: 1px solid #dbeafe; }
.copy-all-btn { background: #2563eb; color: #fff; border: none; border-radius: 4px; padding: 6px 12px; font-size: 12px; cursor: pointer; font-weight: 500; }
.copy-all-btn:hover { background: #1d4ed8; }
.copy-all-btn.copied { background: #16a34a; }
.rule-item { display: flex; flex-wrap: wrap; align-items: flex-start; gap: 8px; padding: 10px 0; border-bottom: 1px solid #dbeafe; }
.rule-item:last-child { border-bottom: none; }
.cmd-checkbox { margin-top: 4px; }
.cmd-code { background: #fff; padding: 8px 12px; border-radius: 4px; font-size: 12px; color: #1e40af; border: 1px solid #bfdbfe; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; display: block; white-space: pre-wrap; word-break: break-word; flex: 1; }
.cmd-why { font-size: 12px; color: #475569; width: 100%; padding-left: 24px; margin-top: 4px; }
.feature-card { background: #f0fdf4; border: 1px solid #86efac; border-radius: 8px; padding: 16px; }
.pattern-card { background: #f0f9ff; border: 1px solid #7dd3fc; border-radius: 8px; padding: 16px; }
.horizon-card { background: linear-gradient(135deg, #faf5ff 0%, #f5f3ff 100%); border: 1px solid #c4b5fd; border-radius: 8px; padding: 16px; }
.feature-title, .pattern-title { font-weight: 600; font-size: 15px; color: #0f172a; margin-bottom: 6px; }
.horizon-title { font-weight: 600; font-size: 15px; color: #5b21b6; margin-bottom: 6px; }
.feature-oneliner, .pattern-summary { font-size: 14px; color: #475569; margin-bottom: 6px; }
.feature-why, .pattern-detail, .horizon-possible { font-size: 13px; color: #334155; line-height: 1.55; margin-bottom: 8px; }
.horizon-tip { font-size: 13px; color: #6b21a8; background: rgba(255,255,255,0.65); padding: 8px 12px; border-radius: 4px; margin-bottom: 10px; }
.copyable-prompt-row { display: flex; align-items: flex-start; gap: 8px; margin-top: 6px; }
.copyable-prompt { flex: 1; background: #f8fafc; padding: 10px 12px; border-radius: 4px; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 12px; color: #1e293b; border: 1px solid #e2e8f0; white-space: pre-wrap; line-height: 1.45; }
.prompt-label { font-size: 11px; font-weight: 600; text-transform: uppercase; color: #64748b; margin-top: 8px; }
.copy-btn { background: #e2e8f0; border: none; border-radius: 4px; padding: 5px 9px; font-size: 11px; cursor: pointer; color: #334155; flex-shrink: 0; font-weight: 500; }
.copy-btn:hover { background: #cbd5e1; }
.charts-row { display: grid; grid-template-columns: 1fr 1fr; gap: 18px; margin: 20px 0; }
.chart-title { font-size: 12px; font-weight: 600; color: #64748b; text-transform: uppercase; margin-bottom: 12px; letter-spacing: 0.03em; }
.bar-head { display: flex; justify-content: space-between; font-size: 10px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.03em; color: #94a3b8; padding-bottom: 5px; margin-bottom: 7px; border-bottom: 1px solid #f1f5f9; }
.bar-row { display: flex; align-items: center; margin-bottom: 6px; }
.bar-label { width: 148px; font-size: 11px; color: #475569; flex-shrink: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.bar-track { flex: 1; height: 7px; background: #f1f5f9; border-radius: 4px; margin: 0 8px; overflow: hidden; }
.bar-fill { height: 100%; border-radius: 4px; }
.bar-value { width: 54px; font-size: 11px; font-weight: 600; color: #475569; text-align: right; font-variant-numeric: tabular-nums; }
.overlap-stats { display: flex; gap: 28px; margin: 10px 0; flex-wrap: wrap; }
.overlap-num { font-size: 22px; font-weight: 700; color: #7c3aed; }
table { width: 100%; border-collapse: collapse; font-size: 13px; margin-top: 6px; }
th, td { text-align: left; padding: 6px 8px; border-bottom: 1px solid #e2e8f0; }
th { font-size: 11px; text-transform: uppercase; color: #64748b; background: #f8fafc; }
td.num, th.num { text-align: right; font-variant-numeric: tabular-nums; }
code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 0.88em; background: #f1f5f9; padding: 1px 4px; border-radius: 4px; }
.caveats { background: #fff; border: 1px solid #e2e8f0; border-radius: 8px; padding: 14px 18px; margin-top: 32px; font-size: 12px; color: #64748b; }
.caveats ul { margin: 6px 0 0 18px; }
.caveats li { margin-bottom: 4px; }
@media (max-width: 680px) { .charts-row { grid-template-columns: 1fr; } }
"""

REPORT_JS = """
function copyText(btn) {
  const code = btn.previousElementSibling;
  if (!code || !navigator.clipboard) return;
  navigator.clipboard.writeText(code.textContent).then(() => {
    btn.textContent = 'Copied!';
    setTimeout(() => { btn.textContent = 'Copy'; }, 1800);
  });
}
function copyRuleItem(idx) {
  const cb = document.getElementById('rule-' + idx);
  if (!cb || !navigator.clipboard) return;
  navigator.clipboard.writeText(cb.dataset.text || '').then(() => {
    const btn = cb.parentElement.querySelector('.copy-btn');
    if (btn) { btn.textContent = 'Copied!'; setTimeout(() => { btn.textContent = 'Copy'; }, 1800); }
  });
}
function copyAllCheckedRules() {
  const cbs = document.querySelectorAll('.cmd-checkbox:checked');
  const texts = [];
  cbs.forEach(cb => { if (cb.dataset.text) texts.push(cb.dataset.text); });
  if (!texts.length || !navigator.clipboard) return;
  navigator.clipboard.writeText(texts.join('\\n\\n')).then(() => {
    const btn = document.querySelector('.copy-all-btn');
    if (btn) {
      btn.textContent = 'Copied ' + texts.length + ' items!';
      btn.classList.add('copied');
      setTimeout(() => { btn.textContent = 'Copy All Checked'; btn.classList.remove('copied'); }, 1800);
    }
  });
}
function updateHourHistogram(offsetHours) {
  const periods = [
    { label: 'Morning (6-12)', range: [6,7,8,9,10,11] },
    { label: 'Afternoon (12-18)', range: [12,13,14,15,16,17] },
    { label: 'Evening (18-24)', range: [18,19,20,21,22,23] },
    { label: 'Night (0-6)', range: [0,1,2,3,4,5] }
  ];
  const adj = {};
  for (const [hr, cnt] of Object.entries(rawUtcHours)) {
    const nh = (parseInt(hr, 10) + offsetHours + 24) % 24;
    adj[nh] = (adj[nh] || 0) + cnt;
  }
  const rows = periods.map(p => ({ label: p.label, count: p.range.reduce((s, h) => s + (adj[h] || 0), 0) }));
  const maxC = Math.max(...rows.map(r => r.count), 1);
  const el = document.getElementById('hour-histogram');
  if (!el) return;
  el.textContent = '';
  rows.forEach(r => {
    const row = document.createElement('div'); row.className = 'bar-row';
    const lbl = document.createElement('div'); lbl.className = 'bar-label'; lbl.textContent = r.label;
    const trk = document.createElement('div'); trk.className = 'bar-track';
    const fil = document.createElement('div'); fil.className = 'bar-fill';
    fil.style.width = ((r.count / maxC) * 100) + '%'; fil.style.background = '#8b5cf6';
    trk.appendChild(fil);
    const val = document.createElement('div'); val.className = 'bar-value'; val.textContent = r.count;
    row.appendChild(lbl); row.appendChild(trk); row.appendChild(val);
    el.appendChild(row);
  });
}
document.addEventListener('DOMContentLoaded', () => {
  const sel = document.getElementById('timezone-select');
  if (sel) {
    sel.addEventListener('change', () => {
      const off = parseInt(sel.value, 10);
      updateHourHistogram(Number.isNaN(off) ? 0 : off);
    });
    const initOff = parseInt(sel.value, 10);
    updateHourHistogram(Number.isNaN(initOff) ? -5 : initOff);
  }
});
"""
