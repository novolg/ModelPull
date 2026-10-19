enum Page {
    // Self-contained page: no external fonts/scripts, works offline.
    static let html = #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>ModelPull</title>
<link rel="icon" type="image/png" href="/icon.png">
<style>
:root{
  --bg:#0a0a0a; --panel:#131313; --field:#1b1b1b; --hover:#222; --stroke:rgba(255,255,255,.07);
  --text:#ededed; --dim:#8c8c8c; --faint:#5c5c5c; --track:#242424;
  color-scheme:dark;
}
*{box-sizing:border-box}
html,body{margin:0;background:var(--bg);color:var(--text);font:13px/1.4 system-ui,-apple-system,"Ubuntu","Segoe UI",sans-serif;-webkit-font-smoothing:antialiased}
.wrap{max-width:660px;margin:0 auto;padding:28px 20px 40px;display:flex;flex-direction:column;gap:18px}
header{display:flex;align-items:center;gap:10px}
h1{font-size:13px;font-weight:600;margin:0;flex:1}
.pill{font-size:9px;letter-spacing:1.4px;text-transform:uppercase;color:var(--dim);border:1px solid var(--stroke);border-radius:99px;padding:3px 8px}
.label{font-size:9px;font-weight:600;letter-spacing:1.6px;text-transform:uppercase;color:var(--dim);margin-bottom:7px}
.field{display:flex;align-items:center;gap:8px;height:34px;padding:0 12px;background:var(--field);border:1px solid var(--stroke);border-radius:8px;color:var(--text)}
.field input{flex:1;min-width:0;background:none;border:0;outline:0;color:var(--text);font:inherit;font-size:12px}
.field input::placeholder{color:var(--faint)}
.field.click{cursor:pointer}.field.click:hover{background:var(--hover)}
.field .path{flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;font-size:12px}
.row{display:flex;align-items:center;gap:8px}
.grow{flex:1;min-width:0}
button{font:inherit}
.btn{height:34px;padding:0 14px;border-radius:8px;border:1px solid var(--stroke);background:var(--field);color:var(--text);font-size:12px;font-weight:500;cursor:pointer;white-space:nowrap}
.btn:hover{background:var(--hover)}
.btn.primary{background:rgba(255,255,255,.92);color:#000;border-color:transparent}
.btn.primary:hover{background:#fff}
.btn.small{height:28px;padding:0 10px;font-size:11px}
.icon{width:26px;height:26px;display:inline-grid;place-items:center;border-radius:6px;border:0;background:none;color:var(--dim);cursor:pointer;padding:0}
.icon:hover{background:var(--hover);color:var(--text)}
.icon svg{width:13px;height:13px}
.msg{font-size:11px;color:var(--dim);margin-top:6px;min-height:0}
.list{display:flex;flex-direction:column;gap:8px}
.card{background:var(--panel);border:1px solid var(--stroke);border-radius:10px;padding:14px;display:flex;flex-direction:column;gap:10px}
.name{font-size:12.5px;font-weight:500;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.tag{font-size:8.5px;font-weight:600;letter-spacing:1.2px;color:var(--dim);border:1px solid var(--stroke);border-radius:99px;padding:3px 7px}
.bar{height:3px;border-radius:3px;background:var(--track);overflow:hidden}
.bar i{display:block;height:100%;width:0;background:rgba(255,255,255,.9);border-radius:3px;transition:width .25s linear}
.mono{font:11px ui-monospace,"Ubuntu Mono",Menlo,monospace;color:var(--dim);font-variant-numeric:tabular-nums}
.status{font-size:11px;color:var(--faint)}
.status.err{color:var(--text)}
.actions{display:flex;gap:2px}
.empty{text-align:center;color:var(--dim);padding:48px 0;display:flex;flex-direction:column;gap:6px;align-items:center}
.empty small{color:var(--faint)}
.overlay{position:fixed;inset:0;background:rgba(0,0,0,.6);display:grid;place-items:center;padding:16px;z-index:10}
.modal{width:min(440px,100%);max-height:90vh;overflow:auto;background:var(--panel);border:1px solid var(--stroke);border-radius:12px;padding:22px;display:flex;flex-direction:column;gap:16px}
.modal h2{font-size:13px;margin:0;font-weight:600}
.hint{font-size:10.5px;color:var(--faint);margin-top:6px}
.radios{display:flex;gap:18px}
.radio{display:flex;align-items:center;gap:8px;cursor:pointer;color:var(--dim);font-size:12px;background:none;border:0;padding:0}
.radio .dot{width:12px;height:12px;border-radius:50%;border:1px solid var(--faint);display:grid;place-items:center}
.radio.on{color:var(--text)}.radio.on .dot{border-color:var(--text)}
.radio.on .dot::after{content:"";width:6px;height:6px;border-radius:50%;background:#fff}
.toggle{display:flex;align-items:center;gap:12px;cursor:pointer;background:none;border:0;padding:0;color:var(--text);font-size:12px}
.track{width:48px;height:22px;border-radius:99px;border:1px solid var(--stroke);background:#171717;display:flex;align-items:center;justify-content:space-between;padding:0 9px;font-size:8px;color:var(--faint)}
.track .k{width:7px;height:7px;border-radius:50%;background:#4a4a4a}
.toggle.on .track{background:#2b2b2b;color:var(--dim)}
.toggle.on .track .k{background:#fff;order:2}
.dirs{border:1px solid var(--stroke);border-radius:8px;max-height:280px;overflow:auto}
.dir{display:flex;gap:8px;align-items:center;padding:8px 12px;cursor:pointer;font-size:12px;color:var(--text);border:0;background:none;width:100%;text-align:left}
.dir:hover{background:var(--hover)}
.dir svg{width:12px;height:12px;color:var(--faint);flex:none}
.right{display:flex;gap:8px;justify-content:flex-end;align-items:center}
.link{background:none;border:0;color:var(--dim);font-size:10.5px;cursor:pointer;padding:0;text-decoration:underline}
.down{position:fixed;left:50%;bottom:20px;transform:translateX(-50%);background:var(--panel);border:1px solid var(--stroke);border-radius:8px;padding:10px 14px;font-size:12px;color:var(--text)}
</style>
</head>
<body>
<div class="wrap">
  <header>
    <img src="/icon.png" width="18" height="18" alt="" style="display:block">
    <h1>ModelPull</h1>
    <span class="pill" id="net" hidden>No network</span>
    <button class="icon" id="settingsBtn" title="Settings"></button>
    <button class="icon" id="quitBtn" title="Quit"></button>
  </header>

  <div>
    <div class="label">Link</div>
    <div class="row">
      <label class="field grow"><input id="link" placeholder="Paste Hugging Face or Civitai link" autocomplete="off" spellcheck="false"><span id="linkIcon" style="color:var(--faint);display:grid"></span></label>
      <button class="btn primary" id="add">Add</button>
    </div>
    <div class="msg" id="addMsg" hidden></div>
  </div>

  <div>
    <div class="label">Save to</div>
    <div class="field click" id="saveTo"><span id="folderIcon" style="color:var(--faint);display:grid"></span><span class="path" id="saveDir">…</span><span id="chev" style="color:var(--dim);display:grid"></span></div>
  </div>

  <div class="row" style="margin-top:4px"><div class="label grow" style="margin:0">Downloads</div><span class="mono" id="count" style="color:var(--faint)">0</span></div>

  <div class="list" id="list"></div>
  <div class="empty" id="empty" hidden>
    <span>No downloads yet</span>
    <small>Downloads survive drops, VPN switches and app restarts.</small>
  </div>
</div>

<div class="down" id="down" hidden>ModelPull is not running. Start it again from the app menu.</div>

<script>
"use strict";
const I = {
  gear:'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.7 1.7 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-1.8-.3 1.7 1.7 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1a1.7 1.7 0 0 0-1.1-1.5 1.7 1.7 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.7 1.7 0 0 0 .3-1.8 1.7 1.7 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1a1.7 1.7 0 0 0 1.5-1.1 1.7 1.7 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.7 1.7 0 0 0 1.8.3H9a1.7 1.7 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.7 1.7 0 0 0 1 1.5 1.7 1.7 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.7 1.7 0 0 0-.3 1.8V9a1.7 1.7 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.7 1.7 0 0 0-1.5 1z"/></svg>',
  power:'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round"><path d="M12 3v9"/><path d="M6.3 7.3a8 8 0 1 0 11.4 0"/></svg>',
  link:'<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><path d="M10 13a5 5 0 0 0 7.5.5l3-3a5 5 0 0 0-7-7l-1.7 1.7"/><path d="M14 11a5 5 0 0 0-7.5-.5l-3 3a5 5 0 0 0 7 7l1.7-1.7"/></svg>',
  folder:'<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round"><path d="M3 6.5A1.5 1.5 0 0 1 4.5 5H9l2 2.5h8.5A1.5 1.5 0 0 1 21 9v9.5a1.5 1.5 0 0 1-1.5 1.5h-15A1.5 1.5 0 0 1 3 18.5z"/></svg>',
  chev:'<svg width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round"><path d="m6 9 6 6 6-6"/></svg>',
  pause:'<svg viewBox="0 0 24 24" fill="currentColor"><rect x="6" y="5" width="4" height="14" rx="1"/><rect x="14" y="5" width="4" height="14" rx="1"/></svg>',
  play:'<svg viewBox="0 0 24 24" fill="currentColor"><path d="M7 5.5v13a1 1 0 0 0 1.5.9l10.5-6.5a1 1 0 0 0 0-1.8L8.5 4.6A1 1 0 0 0 7 5.5z"/></svg>',
  retry:'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M21 12a9 9 0 1 1-2.6-6.4"/><path d="M21 3v6h-6"/></svg>',
  restart:'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M3 12a9 9 0 1 0 2.6-6.4"/><path d="M3 3v6h6"/></svg>',
  x:'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round"><path d="M6 6l12 12M18 6 6 18"/></svg>',
  up:'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="m15 18-6-6 6-6"/></svg>',
};
const $ = s => document.querySelector(s);
const esc = s => String(s).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
$('#settingsBtn').innerHTML = I.gear; $('#quitBtn').innerHTML = I.power;
$('#linkIcon').innerHTML = I.link; $('#folderIcon').innerHTML = I.folder; $('#chev').innerHTML = I.chev;

async function api(path, body) {
  const opt = body === undefined ? {} : {method:'POST', headers:{'Content-Type':'application/json','X-ModelPull':'1'}, body:JSON.stringify(body)};
  const r = await fetch(path, opt);
  const j = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(j.error || r.statusText);
  return j;
}

function bytes(n) {
  if (n == null) return '—';
  const u = ['B','KB','MB','GB','TB']; let i = 0, v = n;
  while (v >= 1000 && i < u.length - 1) { v /= 1000; i++; }
  return (i === 0 ? v : v.toFixed(v < 10 ? 2 : 1)) + ' ' + u[i];
}
function dur(s) {
  if (!isFinite(s) || s <= 0) return '';
  const m = Math.floor(s / 60);
  if (m >= 60) return Math.floor(m / 60) + ' h ' + (m % 60) + ' min';
  return m > 0 ? m + ' min' : Math.floor(s) + ' s';
}

let state = null;
const cards = new Map();
const confirming = new Set();

async function tick() {
  try {
    state = await api('/api/state');
    $('#down').hidden = true;
    render();
  } catch (e) { $('#down').hidden = false; }
}

function render() {
  $('#saveDir').textContent = state.settings.saveDir;
  $('#count').textContent = state.jobs.length;
  $('#net').hidden = state.online;
  $('#empty').hidden = state.jobs.length > 0;
  const list = $('#list');
  const ids = new Set(state.jobs.map(j => j.id));
  for (const [id, el] of cards) if (!ids.has(id)) { el.remove(); cards.delete(id); confirming.delete(id); }
  state.jobs.forEach((j, idx) => {
    let el = cards.get(j.id);
    if (!el) { el = makeCard(j.id); cards.set(j.id, el); }
    if (list.children[idx] !== el) list.insertBefore(el, list.children[idx] || null);
    updateCard(el, j);
  });
}

function makeCard(id) {
  const el = document.createElement('div');
  el.className = 'card';
  el.innerHTML = '<div class="row"><div class="name grow"></div><span class="tag"></span></div>'
    + '<div class="bar"><i></i></div>'
    + '<div class="row"><div class="mono grow stats"></div><div class="actions"></div></div>'
    + '<div class="status"></div><div class="row confirm" hidden></div>';
  el.addEventListener('click', e => { const b = e.target.closest('[data-a]'); if (b) act(id, b.dataset.a); });
  return el;
}

function updateCard(el, j) {
  el.querySelector('.name').textContent = j.name;
  el.querySelector('.name').title = j.url;
  el.querySelector('.tag').textContent = j.kind;
  el.querySelector('.bar i').style.width = (Math.max(0, Math.min(1, j.fraction)) * 100).toFixed(2) + '%';
  let stats = '—';
  if (j.total != null) {
    if (j.phase === 'done') stats = bytes(j.total);
    else {
      const p = [bytes(j.done) + ' / ' + bytes(j.total)];
      if (j.phase === 'downloading' && j.speed > 0) { p.push(bytes(j.speed) + '/s'); const e = dur((j.total - j.done) / j.speed); if (e) p.push(e); }
      stats = p.join('  ·  ');
    }
  }
  el.querySelector('.stats').textContent = stats;
  const st = el.querySelector('.status');
  st.textContent = j.text;
  st.classList.toggle('err', j.phase === 'failed');

  const key = j.phase + '|' + j.status + '|' + confirming.has(j.id);
  if (el.dataset.key === key) return;
  el.dataset.key = key;
  let a = '';
  if (j.phase === 'paused') a += btn('resume', I.play, 'Resume');
  else if (j.phase === 'failed') a += btn('resume', I.retry, 'Retry') + btn('restart', I.restart, 'Restart from zero');
  else if (j.phase !== 'done') a += btn('pause', I.pause, 'Pause');
  a += btn('reveal', I.folder, 'Open folder') + btn('ask', I.x, 'Remove');
  el.querySelector('.actions').innerHTML = a;
  const c = el.querySelector('.confirm');
  c.hidden = !confirming.has(j.id);
  c.innerHTML = '<span class="grow" style="font-size:11px;color:var(--dim)">Remove from list?</span>'
    + '<button class="btn small" data-a="cancel">Cancel</button>'
    + (j.status === 'done'
        ? '<button class="btn small" data-a="remove">Keep file</button><button class="btn small primary" data-a="delete">Delete file</button>'
        : '<button class="btn small primary" data-a="remove">Remove + delete partial</button>');
}
const btn = (a, icon, title) => '<button class="icon" data-a="' + a + '" title="' + title + '">' + icon + '</button>';

async function act(id, a) {
  if (a === 'ask') { confirming.has(id) ? confirming.delete(id) : confirming.add(id); render(); return; }
  if (a === 'cancel') { confirming.delete(id); render(); return; }
  confirming.delete(id);
  try { await api('/api/jobs/' + id + '/' + a, {}); } catch (e) { alertMsg(e.message); }
  tick();
}

function alertMsg(m) { const el = $('#addMsg'); el.textContent = m; el.hidden = !m; }

async function add() {
  const v = $('#link').value.trim();
  if (!v) return;
  try { await api('/api/add', {url: v}); $('#link').value = ''; alertMsg(''); tick(); }
  catch (e) { alertMsg(e.message); }
}
$('#add').onclick = add;
$('#link').addEventListener('keydown', e => { if (e.key === 'Enter') add(); });
document.addEventListener('dragover', e => e.preventDefault());
document.addEventListener('drop', e => {
  e.preventDefault();
  const t = e.dataTransfer.getData('text/uri-list') || e.dataTransfer.getData('text/plain');
  if (t) { $('#link').value = t.split('\n')[0].trim(); add(); }
});

// ---- modals
function modal(html) {
  const o = document.createElement('div');
  o.className = 'overlay';
  o.innerHTML = '<div class="modal">' + html + '</div>';
  o.addEventListener('mousedown', e => { if (e.target === o) o.remove(); });
  document.body.appendChild(o);
  return o;
}
document.addEventListener('keydown', e => { if (e.key === 'Escape') document.querySelectorAll('.overlay').forEach(o => o.remove()); });

function radios(name, opts, val) {
  return '<div class="radios" data-r="' + name + '">' + opts.map(o =>
    '<button type="button" class="radio' + (o === val ? ' on' : '') + '" data-v="' + o + '"><span class="dot"></span>' + o + '</button>').join('') + '</div>';
}
function toggle(name, label, on) {
  return '<button type="button" class="toggle' + (on ? ' on' : '') + '" data-t="' + name + '"><span class="track"><span>' + (on ? 'on' : 'off') + '</span><span class="k"></span></span>' + label + '</button>';
}

$('#settingsBtn').onclick = () => {
  if (!state) return;
  const s = state.settings, t = state.tokens;
  const tok = (id, label, has, ph, hint) =>
    '<div><div class="row"><div class="label grow">' + label + '</div>' + (has ? '<button class="link" data-clear="' + id + '">remove</button>' : '') + '</div>'
    + '<label class="field"><input type="password" id="' + id + '" placeholder="' + (has ? 'Saved · leave empty to keep' : ph) + '" autocomplete="off"></label>'
    + '<div class="hint">' + hint + '</div></div>';
  const o = modal('<h2>Settings</h2>'
    + tok('hf', 'Hugging Face token', t.huggingface, 'hf_…', 'For gated or private models. huggingface.co/settings/tokens')
    + tok('cv', 'Civitai API key', t.civitai, 'API key', 'For models that need login. civitai.com/user/account')
    + '<div><div class="label">Connections per file</div>' + radios('connections', [2, 4, 8], s.connections) + '</div>'
    + '<div><div class="label">Downloads at once</div>' + radios('maxActive', [1, 2, 3], s.maxActive) + '</div>'
    + '<div style="display:flex;flex-direction:column;gap:10px">' + toggle('verifySHA', 'Check SHA256 after download', s.verifySHA)
    + toggle('keepAwake', 'Keep computer awake while downloading', s.keepAwake) + '</div>'
    + '<div class="msg" id="setMsg" hidden></div>'
    + '<div class="right"><span class="hint grow" style="margin:0">Tokens are stored in ~/.config/modelpull (mode 600).</span>'
    + '<button class="btn" data-x="cancel">Cancel</button><button class="btn primary" data-x="save">Save</button></div>');
  const next = {...s};
  const clear = {};
  o.addEventListener('click', async e => {
    const r = e.target.closest('.radio');
    if (r) { const g = r.parentElement; g.querySelectorAll('.radio').forEach(x => x.classList.toggle('on', x === r)); next[g.dataset.r] = +r.dataset.v; return; }
    const tg = e.target.closest('.toggle');
    if (tg) { const on = !tg.classList.contains('on'); tg.classList.toggle('on', on); tg.querySelector('.track span').textContent = on ? 'on' : 'off'; next[tg.dataset.t] = on; return; }
    const c = e.target.closest('[data-clear]');
    if (c) { clear[c.dataset.clear] = true; o.querySelector('#' + c.dataset.clear).placeholder = 'Will be removed on Save'; c.remove(); return; }
    const x = e.target.closest('[data-x]');
    if (!x) return;
    if (x.dataset.x === 'cancel') { o.remove(); return; }
    const body = {};
    const hf = o.querySelector('#hf').value.trim(), cv = o.querySelector('#cv').value.trim();
    if (hf || clear.hf) body.huggingface = hf;
    if (cv || clear.cv) body.civitai = cv;
    try {
      await api('/api/settings', next);
      if (Object.keys(body).length) await api('/api/tokens', body);
      o.remove(); tick();
    } catch (err) { const m = o.querySelector('#setMsg'); m.textContent = err.message; m.hidden = false; }
  });
};

$('#saveTo').onclick = () => {
  if (!state) return;
  const o = modal('<h2>Save to</h2><div class="mono" id="dpath" style="color:var(--text);word-break:break-all"></div>'
    + '<div class="dirs" id="dlist"></div><div class="msg" id="dmsg" hidden></div>'
    + '<div class="right"><button class="btn" data-x="cancel">Cancel</button><button class="btn primary" data-x="use">Use this folder</button></div>');
  let cur = state.settings.saveDir;
  async function load(p) {
    try {
      const d = await api('/api/dirs?path=' + encodeURIComponent(p));
      cur = d.path;
      o.querySelector('#dpath').textContent = d.path;
      o.querySelector('#dlist').innerHTML = (d.parent ? '<button class="dir" data-p="' + esc(d.parent) + '">' + I.up + '..</button>' : '')
        + d.dirs.map(n => '<button class="dir" data-p="' + esc((d.path === '/' ? '' : d.path) + '/' + n) + '">' + I.folder + esc(n) + '</button>').join('')
        + (d.dirs.length ? '' : '<div class="dir" style="color:var(--faint);cursor:default">No subfolders</div>');
    } catch (e) { const m = o.querySelector('#dmsg'); m.textContent = e.message; m.hidden = false; }
  }
  o.addEventListener('click', async e => {
    const d = e.target.closest('[data-p]');
    if (d) { load(d.dataset.p); return; }
    const x = e.target.closest('[data-x]');
    if (!x) return;
    if (x.dataset.x === 'cancel') { o.remove(); return; }
    try { await api('/api/settings', {...state.settings, saveDir: cur}); o.remove(); tick(); }
    catch (err) { const m = o.querySelector('#dmsg'); m.textContent = err.message; m.hidden = false; }
  });
  load(cur);
};

$('#quitBtn').onclick = () => {
  const o = modal('<h2>Quit ModelPull?</h2><div style="color:var(--dim);font-size:12px">Downloads stop now and continue from the same byte when you start ModelPull again.</div>'
    + '<div class="right"><button class="btn" data-x="cancel">Cancel</button><button class="btn primary" data-x="quit">Quit</button></div>');
  o.addEventListener('click', async e => {
    const x = e.target.closest('[data-x]');
    if (!x) return;
    if (x.dataset.x === 'quit') { try { await api('/api/quit', {}); } catch (_) {} }
    o.remove();
  });
};

tick();
setInterval(tick, 1000);
</script>
</body>
</html>
"""#
}
