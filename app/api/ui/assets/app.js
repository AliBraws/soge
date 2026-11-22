'use strict';
// Session token: short-lived (5 min), silently renewed at 80% of its lifetime.
// Network failures on execution are retried with the SAME Idempotency-Key, so a
// retry can never create a duplicate deal.
const PAIRS = ['EURUSD', 'EURGBP', 'EURJPY', 'EURCHF'];
const $ = (id) => document.getElementById(id);
let token = null, renewTimer = null, locked = null, lockTimer = null;

async function session() {
  try {
    // Renewal: present the current token so the issuer keeps the same subject.
    const r = await fetch('/x/s', { method: 'POST', headers: token ? { Authorization: 'Bearer ' + token } : {} });
    if (!r.ok) throw new Error(r.status);
    const s = await r.json();
    token = s.token;
    const ttl = (s.expires_in || 300) * 1000;
    clearTimeout(renewTimer);
    renewTimer = setTimeout(session, ttl * 0.8);
    $('sess').textContent = 'session: renews in ' + Math.round(ttl * 0.8 / 1000) + 's';
    $('sess').className = 'chip ok';
  } catch (e) {
    $('sess').textContent = 'session: retrying';
    $('sess').className = 'chip warn';
    setTimeout(session, 2000 + Math.random() * 2000);
  }
}

async function api(path, opts = {}, attempt = 0) {
  const headers = Object.assign({ Authorization: 'Bearer ' + token }, opts.headers || {});
  const r = await fetch(path, Object.assign({}, opts, { headers }));
  if (r.status === 401 && attempt === 0) { await session(); return api(path, opts, 1); }
  return r;
}

function tile(pair) {
  const el = document.createElement('div');
  el.className = 'tile';
  el.innerHTML = '<h3></h3><div class="px"><button class="sell"><small>SELL</small><span>-</span></button>' +
    '<button class="buy"><small>BUY</small><span>-</span></button></div>';
  el.querySelector('h3').textContent = pair.slice(0, 3) + '/' + pair.slice(3);
  el.querySelector('.sell').onclick = () => lock(pair, 'SELL');
  el.querySelector('.buy').onclick = () => lock(pair, 'BUY');
  $('board').appendChild(el);
  return el;
}
const tiles = Object.fromEntries(PAIRS.map((p) => [p, null]));
const last = {};

async function poll() {
  if (token) {
    await Promise.all(PAIRS.map(async (p) => {
      try {
        const r = await api('/x/q?p=' + p);
        if (!r.ok) return;
        const q = await r.json();
        last[p] = q;
        tiles[p] = tiles[p] || tile(p);
        tiles[p].querySelector('.sell span').textContent = q.bid.toFixed(p.endsWith('JPY') ? 3 : 5);
        tiles[p].querySelector('.buy span').textContent = q.ask.toFixed(p.endsWith('JPY') ? 3 : 5);
        const fresh = q.source.startsWith('ecb');
        $('src').textContent = 'rates: ' + q.source;
        $('src').className = 'chip ' + (fresh ? 'ok' : 'warn');
      } catch (_) { /* transient, next tick */ }
    }));
  }
  setTimeout(poll, 1500);
}

function lock(pair, side) {
  const q = last[pair];
  if (!q) return;
  locked = { q, side, idem: crypto.randomUUID() };
  $('exec').disabled = false;
  clearInterval(lockTimer);
  const tick = () => {
    const left = q.exp - Math.floor(Date.now() / 1000);
    if (left <= 0) { $('locked').textContent = 'Quote expired, pick a new price.'; $('exec').disabled = true; clearInterval(lockTimer); return; }
    $('locked').textContent = side + ' ' + pair + ' @ ' + (side === 'BUY' ? q.ask : q.bid) + ' - ' + left + 's';
  };
  tick();
  lockTimer = setInterval(tick, 250);
}

async function execute() {
  if (!locked) return;
  $('exec').disabled = true;
  const body = JSON.stringify({ quote: locked.q.token, side: locked.side, notional: Number($('notional').value) });
  for (let attempt = 0; attempt < 4; attempt++) {
    try {
      const r = await api('/x/d', { method: 'POST', headers: { 'Content-Type': 'application/json', 'Idempotency-Key': locked.idem }, body });
      const d = await r.json();
      if (r.status === 201 || r.status === 200) { $('msg').textContent = 'Done ' + d.id.slice(0, 8); prepend(d); locked = null; clearInterval(lockTimer); return; }
      if (r.status !== 503) { $('msg').textContent = d.error || ('Error ' + r.status); return; }
    } catch (_) { /* network error: retry with the same key */ }
    await new Promise((res) => setTimeout(res, 300 * 2 ** attempt + Math.random() * 200));
  }
  $('msg').textContent = 'Not confirmed - retry is safe.';
  $('exec').disabled = false;
}

function prepend(d) {
  const tr = document.createElement('tr');
  [new Date(d.created_at).toLocaleTimeString(), d.pair, d.side, d.notional.toLocaleString(), d.price].forEach((v) => {
    const td = document.createElement('td'); td.textContent = v; tr.appendChild(td);
  });
  $('blotter').prepend(tr);
}

async function blotter() {
  const r = await api('/x/d');
  if (!r.ok) return;
  const { deals } = await r.json();
  $('blotter').textContent = '';
  deals.reverse().forEach(prepend);
}

$('exec').onclick = execute;
session().then(() => { poll(); blotter(); });
