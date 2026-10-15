// 手機端網頁（觀眾掃 QR Code 後打開）。全部內嵌：不依賴 CDN，沒有對外網路的會議室也能用。
// 不需要下載 App、註冊或登入。
enum MobilePage {
    static let html = #"""
<!doctype html>
<html lang="zh-Hant">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="theme-color" content="#123B8A">
<meta name="format-detection" content="telephone=no">
<title>URBAN LIVE｜早會即時彈幕</title>
<style>
:root {
  --royal: #123B8A; --electric: #2563EB; --glacier: #F5FAFF; --deep: #102A5B; --gold: #F3C969;
  --text: #0B1530; --muted: #64748B; --line: #DCE6F5; --danger: #C62828; --ok: #15803D;
}
* { box-sizing: border-box; -webkit-tap-highlight-color: transparent; }
html, body { margin: 0; }
body {
  min-height: 100vh; background: var(--glacier); color: var(--text);
  font-family: -apple-system, BlinkMacSystemFont, "PingFang TC", "Noto Sans TC", "Microsoft JhengHei", sans-serif;
  -webkit-text-size-adjust: 100%;
}
main { max-width: 520px; margin: 0 auto; padding: calc(env(safe-area-inset-top) + 18px) 16px calc(env(safe-area-inset-bottom) + 28px); }
button, input { font: inherit; }
button { cursor: pointer; touch-action: manipulation; }

header { display: flex; align-items: center; justify-content: space-between; margin-bottom: 14px; }
.logo { display: flex; align-items: center; gap: 8px; font-weight: 900; font-size: 22px; letter-spacing: .08em; color: var(--royal); }
.live { display: inline-flex; align-items: center; gap: 6px; padding: 4px 10px 4px 9px; border-radius: 999px; background: var(--electric); color: #fff; font-size: 13px; letter-spacing: .12em; }
.live i { width: 7px; height: 7px; border-radius: 50%; background: var(--gold); animation: pulse 1.6s infinite; }
@keyframes pulse { 0%, 100% { opacity: 1 } 50% { opacity: .35 } }
.status { display: inline-flex; align-items: center; gap: 6px; font-size: 12.5px; font-weight: 700; color: var(--muted); padding: 5px 10px; border-radius: 999px; background: #fff; border: 1px solid var(--line); }
.status b { width: 8px; height: 8px; border-radius: 50%; background: #94A3B8; }
.status.live b { background: #22C55E; }
.status.paused b, .status.hidden b, .status.reconnecting b { background: #F59E0B; }
.status.ended b, .status.offline b, .status.invalid b, .status.blocked b { background: #EF4444; }

h1 { margin: 0 0 4px; font-size: 26px; font-weight: 900; color: var(--deep); letter-spacing: .02em; }
.lead { margin: 0 0 16px; color: var(--muted); font-size: 14px; }

.card { background: #fff; border-radius: 20px; border: 1px solid var(--line); box-shadow: 0 6px 24px rgba(18, 59, 138, .08); padding: 16px; margin-bottom: 14px; }

.profile { display: flex; align-items: center; gap: 12px; width: 100%; border: 0; background: none; padding: 0; text-align: left; color: inherit; }
.avatar { flex: none; width: 46px; height: 46px; border-radius: 50%; display: grid; place-items: center; font-size: 26px; color: #fff; font-weight: 800; background: var(--electric); overflow: hidden; }
.avatar img { width: 100%; height: 100%; object-fit: cover; }
.avatar.none { background: #E2E8F0; color: #94A3B8; font-size: 22px; }
.profile .who { flex: 1; min-width: 0; }
.profile .name { font-weight: 800; font-size: 16px; }
.profile .hint { color: var(--muted); font-size: 13px; }
.profile .edit { color: var(--electric); font-weight: 700; font-size: 14px; }

.preview { display: flex; justify-content: center; margin: 0 0 12px; padding: 6px 0 12px; min-height: 64px; align-items: center; }
.capsule { display: inline-flex; align-items: center; gap: 8px; max-width: 100%; padding: 6px 16px 6px 6px; border-radius: 999px;
  background: linear-gradient(180deg, rgba(255,255,255,.18), rgba(255,255,255,0) 50%), linear-gradient(180deg, rgba(18,59,138,.92), rgba(16,42,91,.95));
  border: 1px solid rgba(255,255,255,.3); box-shadow: 0 6px 16px rgba(16,42,91,.35); color: #fff; font-weight: 800; font-size: 17px; white-space: nowrap; }
.capsule.noavatar { padding-left: 16px; }
.capsule .avatar { width: 32px; height: 32px; font-size: 18px; border: 1.5px solid rgba(255,255,255,.6); }
.capsule .nick { color: var(--gold); font-size: 13px; font-weight: 700; }
.capsule .msg { overflow: hidden; text-overflow: ellipsis; }
.capsule.placeholder .msg { opacity: .6; }

.composer { display: flex; gap: 10px; }
.composer input { flex: 1; min-width: 0; font-size: 17px; padding: 14px 16px; border-radius: 14px; border: 1.5px solid var(--line); outline: none; background: #fff; color: var(--text); }
.composer input:focus { border-color: var(--electric); box-shadow: 0 0 0 3px rgba(37, 99, 235, .15); }
.send { flex: none; min-width: 84px; padding: 0 18px; border: 0; border-radius: 14px; background: var(--royal); color: #fff; font-size: 17px; font-weight: 800; }
.send:disabled { background: #94A3B8; }
.meta { display: flex; justify-content: space-between; font-size: 12.5px; color: var(--muted); margin-top: 8px; }
.meta .over { color: var(--danger); font-weight: 700; }

.emojis { display: grid; grid-template-columns: repeat(6, 1fr); gap: 8px; margin-top: 14px; }
.emojis button { font-size: 26px; padding: 8px 0; border-radius: 12px; border: 1px solid var(--line); background: var(--glacier); }
.emojis button:active { transform: scale(.92); }

.history { list-style: none; margin: 0; padding: 0; }
.history li { display: flex; align-items: center; justify-content: space-between; gap: 10px; padding: 10px 0; border-bottom: 1px solid var(--line); font-size: 14px; }
.history li:last-child { border-bottom: 0; }
.history .text { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.chip { flex: none; font-size: 12px; font-weight: 700; padding: 4px 9px; border-radius: 999px; background: #EEF2F7; color: var(--muted); }
.chip.ok { background: #DCFCE7; color: var(--ok); }
.chip.wait { background: #DBEAFE; color: var(--electric); }
.chip.bad { background: #FEE2E2; color: var(--danger); }
.section-title { font-size: 13px; font-weight: 800; color: var(--muted); margin: 0 0 6px; letter-spacing: .04em; }

.notice { display: none; text-align: center; padding: 24px 16px; }
.notice h2 { margin: 6px 0; font-size: 20px; color: var(--deep); }
.notice p { margin: 0 0 14px; color: var(--muted); }
.notice .big { font-size: 44px; }
.btn { display: inline-block; border: 0; border-radius: 12px; padding: 12px 18px; background: var(--royal); color: #fff; font-weight: 800; }
.btn.ghost { background: #EEF2F7; color: var(--royal); }

.toast { position: fixed; left: 50%; bottom: calc(env(safe-area-inset-bottom) + 22px); transform: translate(-50%, 16px); opacity: 0; pointer-events: none;
  transition: opacity .2s, transform .2s; width: max-content; max-width: 90vw; padding: 12px 18px; border-radius: 999px;
  background: var(--deep); color: #fff; font-weight: 800; box-shadow: 0 10px 30px rgba(16,42,91,.3); text-align: center; }
.toast.show { opacity: 1; transform: translate(-50%, 0); }
.toast.error { background: var(--danger); }

.sheet-backdrop { position: fixed; inset: 0; background: rgba(11,21,48,.45); display: none; align-items: flex-end; justify-content: center; z-index: 10; }
.sheet-backdrop.open { display: flex; }
.sheet { width: 100%; max-width: 520px; background: #fff; border-radius: 22px 22px 0 0; padding: 18px 16px calc(env(safe-area-inset-bottom) + 18px); max-height: 92vh; overflow: auto; }
.sheet h3 { margin: 0 0 12px; font-size: 18px; }
.sheet label { display: block; font-size: 13px; font-weight: 800; color: var(--muted); margin: 14px 0 6px; }
.sheet input[type=text] { width: 100%; font-size: 17px; padding: 12px 14px; border-radius: 12px; border: 1.5px solid var(--line); outline: none; }
.choices { display: grid; grid-template-columns: repeat(6, 1fr); gap: 8px; }
.choices button { aspect-ratio: 1; border-radius: 50%; border: 3px solid transparent; font-size: 24px; display: grid; place-items: center; padding: 0; color: #fff; }
.choices button.selected { border-color: var(--gold); box-shadow: 0 0 0 2px var(--royal); }
.row { display: flex; gap: 10px; margin-top: 18px; }
.row .btn { flex: 1; text-align: center; }
.small { font-size: 12px; color: var(--muted); margin-top: 6px; }
footer { text-align: center; font-size: 12px; color: var(--muted); margin-top: 18px; line-height: 1.7; }
</style>
</head>
<body>
<main>
  <header>
    <div class="logo">URBAN <span class="live"><i></i>LIVE</span></div>
    <div id="status" class="status"><b></b><span id="statusText">連線中…</span></div>
  </header>
  <h1>早會即時彈幕</h1>
  <p class="lead" id="lead">輸入文字或 Emoji，就會出現在大螢幕上</p>

  <section id="app">
    <div class="card">
      <button class="profile" id="openProfile" type="button">
        <div class="avatar none" id="myAvatar">👤</div>
        <div class="who">
          <div class="name" id="myName">匿名觀眾</div>
          <div class="hint">設定暱稱與大頭貼（選填）</div>
        </div>
        <div class="edit">編輯 ›</div>
      </button>
    </div>

    <div class="card">
      <div class="preview"><div class="capsule placeholder" id="preview"><span class="msg">你的彈幕會長這樣</span></div></div>
      <form class="composer" id="form" autocomplete="off">
        <input id="text" type="text" enterkeyhint="send" placeholder="輸入文字或 Emoji" aria-label="彈幕內容">
        <button id="send" class="send" type="submit">發送</button>
      </form>
      <div class="meta"><span id="cooldown"></span><span id="counter"><span id="count">0</span> / <span id="max">25</span> 字</span></div>
      <div class="emojis" id="emojis"></div>
    </div>

    <div class="card" id="historyCard" style="display:none">
      <p class="section-title">我送出的訊息</p>
      <ul class="history" id="history"></ul>
    </div>
  </section>

  <section class="card notice" id="notice">
    <div class="big" id="noticeIcon">📷</div>
    <h2 id="noticeTitle">請掃描大螢幕上的 QR Code</h2>
    <p id="noticeText">掃描後就能發送彈幕，不需要下載 App 或登入。</p>
    <button class="btn" id="retry" type="button" style="display:none">重新連線</button>
  </section>

  <footer>URBAN LIVE · 請友善發言<br>主持人可以隨時暫停、清空或封鎖不當訊息</footer>
</main>

<div class="sheet-backdrop" id="sheet">
  <div class="sheet" role="dialog" aria-modal="true" aria-labelledby="sheetTitle">
    <h3 id="sheetTitle">我的暱稱與大頭貼</h3>
    <label for="nickname">暱稱（最多 10 個字，可留空）</label>
    <input id="nickname" type="text" maxlength="30" placeholder="例如：Kevin、小美">
    <label>大頭貼</label>
    <div class="choices" id="choices"></div>
    <div class="row" style="margin-top:12px">
      <button class="btn ghost" id="uploadBtn" type="button">📷 上傳照片</button>
      <button class="btn ghost" id="noAvatar" type="button">不使用大頭貼</button>
    </div>
    <input id="file" type="file" accept="image/*" style="display:none">
    <p class="small" id="photoNote">照片只會縮小成小圓形大頭貼，傳送到現場的 Mac 顯示，不會上傳到其他地方。</p>
    <div class="row">
      <button class="btn ghost" id="cancelProfile" type="button">取消</button>
      <button class="btn" id="saveProfile" type="button">儲存</button>
    </div>
  </div>
</div>

<div id="toast" class="toast" role="status" aria-live="polite"></div>

<script>
(function () {
  'use strict';
  var EMOJIS = ['🔥', '👍', '👏', '🎉', '💪', '❤️', '😂', '🙌', '💯', '🚀', '☕️', '💙'];
  var ANIMALS = ['🦁', '🐯', '🐼', '🐨', '🦊', '🐻', '🐰', '🐶', '🐱', '🦅', '🐳', '🦄'];
  var COLORS = ['#2563EB', '#123B8A', '#0EA5E9', '#7C3AED', '#DB2777', '#EA580C', '#16A34A', '#102A5B', '#2563EB', '#123B8A', '#0EA5E9', '#7C3AED'];
  var STORE = 'urbanlive.';

  function $(id) { return document.getElementById(id); }
  function load(key, fallback) { try { var v = localStorage.getItem(STORE + key); return v ? JSON.parse(v) : fallback; } catch (e) { return fallback; } }
  function save(key, value) { try { localStorage.setItem(STORE + key, JSON.stringify(value)); } catch (e) {} }
  function randomId(prefix) {
    var chars = 'abcdefghijklmnopqrstuvwxyz0123456789', out = prefix;
    var bytes = (window.crypto && crypto.getRandomValues) ? crypto.getRandomValues(new Uint8Array(16)) : null;
    for (var i = 0; i < 16; i++) { out += chars[(bytes ? bytes[i] : Math.floor(Math.random() * 256)) % chars.length]; }
    return out;
  }
  var segmenter = (window.Intl && Intl.Segmenter) ? new Intl.Segmenter('zh-Hant', { granularity: 'grapheme' }) : null;
  function graphemes(text) { return segmenter ? Array.from(segmenter.segment(text), function (s) { return s.segment; }) : Array.from(text); }
  function clean(text) { return text.replace(/\s+/g, ' ').trim(); }

  var match = location.pathname.match(/^\/j\/([A-Za-z0-9]{4,16})/);
  var token = match ? match[1].toUpperCase() : null;
  var clientId = load('clientId', null);
  if (!clientId) { clientId = randomId('c_'); save('clientId', clientId); }
  var profile = load('profile', { nickname: '', avatar: { kind: 'none' } });

  var state = { ws: null, connected: false, attempts: 0, fallback: false, stopped: false, live: false,
                maxLength: 25, cooldown: 5, cooldownUntil: 0, allowPhoto: true, pending: {}, counter: 0 };
  var input = $('text'), sendButton = $('send');

  // ---------- 畫面 ----------
  var toastTimer = null;
  function toast(message, isError) {
    var el = $('toast');
    el.textContent = message;
    el.className = 'toast show' + (isError ? ' error' : '');
    clearTimeout(toastTimer);
    toastTimer = setTimeout(function () { el.className = 'toast'; }, isError ? 3200 : 1800);
  }
  function setStatus(kind, text) { $('status').className = 'status ' + kind; $('statusText').textContent = text; }
  function showNotice(icon, title, text, canRetry) {
    $('app').style.display = 'none';
    $('notice').style.display = 'block';
    $('noticeIcon').textContent = icon; $('noticeTitle').textContent = title; $('noticeText').textContent = text;
    $('retry').style.display = canRetry ? 'inline-block' : 'none';
  }
  function hideNotice() { $('app').style.display = 'block'; $('notice').style.display = 'none'; }

  function avatarHTML(avatar, nickname, cls) {
    var el = document.createElement('div');
    el.className = 'avatar ' + (cls || '');
    if (avatar && avatar.kind === 'emoji') { el.textContent = avatar.value; el.style.background = avatar.color; }
    else if (avatar && avatar.kind === 'photo') { var img = document.createElement('img'); img.src = avatar.data; img.alt = ''; el.appendChild(img); }
    else if (nickname) { el.textContent = graphemes(nickname)[0].toUpperCase(); el.style.background = '#2563EB'; }
    else { el.textContent = '👤'; el.className += ' none'; }
    return el;
  }
  function renderProfile() {
    var current = $('myAvatar');
    var fresh = avatarHTML(profile.avatar, profile.nickname);
    fresh.id = 'myAvatar';
    current.parentNode.replaceChild(fresh, current);
    $('myName').textContent = profile.nickname || '匿名觀眾';
    renderPreview();
  }
  function renderPreview() {
    var preview = $('preview');
    var text = graphemes(clean(input.value)).slice(0, state.maxLength).join('');
    preview.innerHTML = '';
    var hasAvatar = profile.avatar && profile.avatar.kind !== 'none' || profile.nickname;
    preview.className = 'capsule' + (text ? '' : ' placeholder') + (hasAvatar ? '' : ' noavatar');
    if (hasAvatar) { preview.appendChild(avatarHTML(profile.avatar, profile.nickname)); }
    if (profile.nickname) { var nick = document.createElement('span'); nick.className = 'nick'; nick.textContent = profile.nickname; preview.appendChild(nick); }
    var msg = document.createElement('span'); msg.className = 'msg'; msg.textContent = text || '你的彈幕會長這樣'; preview.appendChild(msg);
  }
  function updateCounter() {
    var count = graphemes(clean(input.value)).length;
    $('count').textContent = count;
    $('max').textContent = state.maxLength;
    $('counter').className = count > state.maxLength ? 'over' : '';
    renderPreview();
  }
  function updateSendButton() {
    var remaining = Math.ceil((state.cooldownUntil - Date.now()) / 1000);
    var waiting = remaining > 0;
    var sending = Object.keys(state.pending).length > 0;
    sendButton.disabled = sending || waiting || !state.live || (!state.connected && !state.fallback);
    sendButton.textContent = sending ? '傳送中' : (waiting ? remaining + ' 秒' : '發送');
    $('cooldown').textContent = waiting ? '每 ' + state.cooldown + ' 秒可以發送一則' : '';
  }
  setInterval(updateSendButton, 250);

  // ---------- 送出紀錄（顯示真實狀態） ----------
  var history = [];
  function addHistory(id, text) {
    history.unshift({ id: id, text: text, status: 'sending', label: '傳送中…' });
    history = history.slice(0, 5);
    renderHistory();
  }
  function updateHistory(id, status, label) {
    for (var i = 0; i < history.length; i++) { if (history[i].id === id) { history[i].status = status; history[i].label = label; } }
    renderHistory();
  }
  function renderHistory() {
    $('historyCard').style.display = history.length ? 'block' : 'none';
    var list = $('history'); list.innerHTML = '';
    history.forEach(function (item) {
      var li = document.createElement('li');
      var text = document.createElement('span'); text.className = 'text'; text.textContent = item.text;
      var chip = document.createElement('span');
      chip.className = 'chip ' + ({ shown: 'ok', queued: 'wait', sending: '', failed: 'bad', dropped: 'bad' }[item.status] || '');
      chip.textContent = item.label;
      li.appendChild(text); li.appendChild(chip); list.appendChild(li);
    });
  }

  // ---------- 連線 ----------
  function applyState(kind, message) {
    state.live = kind === 'live';
    var label = { live: '已連線', paused: '主持人暫停中', hidden: '彈幕暫時隱藏', ended: '場次已結束' }[kind] || message;
    setStatus(kind, label);
    $('lead').textContent = message || '';
    updateSendButton();
  }

  function connect() {
    if (!token || state.stopped) { return; }
    var url = (location.protocol === 'https:' ? 'wss://' : 'ws://') + location.host + '/ws?s=' + encodeURIComponent(token);
    var ws;
    try { ws = new WebSocket(url); } catch (e) { scheduleReconnect(); return; }
    state.ws = ws;
    var opened = false;
    ws.onopen = function () {
      opened = true;
      state.connected = true; state.attempts = 0; state.fallback = false;
      ws.send(JSON.stringify({ t: 'hello', clientId: clientId, profile: profile }));
    };
    ws.onmessage = function (event) {
      var data; try { data = JSON.parse(event.data); } catch (e) { return; }
      handle(data);
    };
    ws.onclose = function () {
      state.connected = false;
      failPending('連線中斷，這則可能沒有送達，請再送一次');
      if (!opened) { state.attempts++; }
      if (!state.stopped) { scheduleReconnect(); }
      updateSendButton();
    };
    ws.onerror = function () {};
  }

  function scheduleReconnect() {
    if (state.stopped) { return; }
    var attempt = Math.max(state.attempts, 1);
    if (state.attempts >= 4 && !state.fallback) {
      // WebSocket 一直連不上（少數網路會擋），改用一般 HTTP 發送
      state.fallback = true;
      pollStatus();
    }
    setStatus('reconnecting', state.fallback ? '備援模式' : '重新連線中…');
    var delay = Math.min(10000, 800 * Math.pow(2, attempt - 1));
    setTimeout(connect, delay);
  }

  function pollStatus() {
    fetch('/api/status?s=' + encodeURIComponent(token), { cache: 'no-store' })
      .then(function (r) { return r.json(); })
      .then(function (data) {
        if (!state.connected) {
          state.maxLength = data.maxLength || state.maxLength; state.cooldown = data.cooldown || state.cooldown;
          applyState(data.state, data.message);
          if (data.state === 'ended') { setStatus('ended', '場次已結束或連結失效'); }
        }
      })
      .catch(function () { if (!state.connected) { setStatus('offline', '連不到電腦'); } });
  }
  setInterval(function () { if (state.fallback && !state.connected) { pollStatus(); } }, 8000);

  function handle(data) {
    switch (data.t) {
      case 'welcome':
        state.maxLength = data.maxLength || 25;
        state.cooldown = data.cooldown || 5;
        state.allowPhoto = data.allowPhoto !== false;
        hideNotice();
        applyState(data.state, data.message);
        updateCounter();
        break;
      case 'state':
        applyState(data.state, data.message);
        break;
      case 'ack':
        var pending = state.pending[data.id];
        delete state.pending[data.id];
        if (pending) { clearTimeout(pending.timer); }
        if (data.ok) {
          updateHistory(data.id, 'queued', data.queue > 1 ? '排隊中' : '已送出');
          toast(data.message || '已送出');
          if (pending && input.value === pending.raw) { input.value = ''; updateCounter(); }
          state.cooldownUntil = Date.now() + state.cooldown * 1000;
        } else {
          updateHistory(data.id, 'failed', '未送出');
          toast(data.message || '送出失敗', true);
          if (data.retryAfter) { state.cooldownUntil = Date.now() + data.retryAfter * 1000; }
        }
        break;
      case 'shown':
        updateHistory(data.id, 'shown', '已上大螢幕 ✓');
        break;
      case 'dropped':
        updateHistory(data.id, 'dropped', '未顯示');
        toast(data.message || '這則沒有顯示', true);
        break;
      case 'profile':
        if (data.ok === false) { toast(data.message || '暱稱無法使用', true); }
        break;
      case 'bye':
        state.stopped = true;
        state.connected = false;
        if (data.code === 'blocked') { showNotice('⛔️', '你已被主持人暫停發言', data.message || '', false); setStatus('blocked', '已暫停發言'); }
        else if (data.code === 'ended') { showNotice('👋', '場次已結束', data.message || '謝謝參與！', true); setStatus('ended', '場次已結束'); }
        else { showNotice('📷', '請重新掃描 QR Code', data.message || '這個連結已失效', true); setStatus('invalid', '連結已失效'); }
        break;
    }
  }

  function failPending(message) {
    Object.keys(state.pending).forEach(function (id) {
      clearTimeout(state.pending[id].timer);
      updateHistory(id, 'failed', '未送達');
    });
    if (Object.keys(state.pending).length) { toast(message, true); }
    state.pending = {};
  }

  // ---------- 發送 ----------
  function send() {
    var raw = input.value;
    var text = graphemes(clean(raw)).slice(0, state.maxLength).join('');
    if (!text) { toast('請輸入文字或 Emoji', true); return; }
    if (Date.now() < state.cooldownUntil) { toast('請稍等，每 ' + state.cooldown + ' 秒可以發送一則', true); return; }
    state.counter++;
    var id = 'm' + Date.now().toString(36) + state.counter;
    addHistory(id, text);

    if (state.connected && state.ws && state.ws.readyState === 1) {
      var timer = setTimeout(function () {
        if (state.pending[id]) { delete state.pending[id]; updateHistory(id, 'failed', '未確認送達'); toast('沒有收到電腦回應，請再試一次', true); }
      }, 6000);
      state.pending[id] = { raw: raw, timer: timer };
      state.ws.send(JSON.stringify({ t: 'send', id: id, text: text }));
      return;
    }
    // 備援：HTTP（回應成功才算送達）
    fetch('/api/send', {
      method: 'POST', headers: { 'Content-Type': 'application/json' }, cache: 'no-store',
      body: JSON.stringify({ session: token, clientId: clientId, text: text, nickname: profile.nickname || null })
    }).then(function (r) { return r.json().catch(function () { return {}; }); })
      .then(function (data) {
        if (data.ok) {
          updateHistory(id, 'queued', '已送出'); toast(data.message || '已送出');
          input.value = ''; updateCounter(); state.cooldownUntil = Date.now() + state.cooldown * 1000;
        } else {
          updateHistory(id, 'failed', '未送出'); toast(data.message || '送出失敗，請再試一次', true);
        }
      })
      .catch(function () { updateHistory(id, 'failed', '未送達'); toast('連不到電腦，請確認和現場在同一個 Wi-Fi', true); });
  }

  $('form').addEventListener('submit', function (event) { event.preventDefault(); send(); });
  input.addEventListener('input', updateCounter);
  input.addEventListener('keydown', function (event) {
    // 注音、拼音選字時按 Enter 不要送出
    if (event.key === 'Enter' && (event.isComposing || event.keyCode === 229)) { event.preventDefault(); }
  });
  EMOJIS.forEach(function (emoji) {
    var button = document.createElement('button');
    button.type = 'button'; button.textContent = emoji; button.setAttribute('aria-label', '加入 ' + emoji);
    button.addEventListener('click', function () { input.value += emoji; updateCounter(); });
    $('emojis').appendChild(button);
  });

  // ---------- 暱稱與大頭貼 ----------
  var draft = null;
  function renderChoices() {
    var box = $('choices'); box.innerHTML = '';
    ANIMALS.forEach(function (emoji, index) {
      var button = document.createElement('button');
      button.type = 'button'; button.textContent = emoji; button.style.background = COLORS[index];
      if (draft.avatar.kind === 'emoji' && draft.avatar.value === emoji) { button.className = 'selected'; }
      button.addEventListener('click', function () { draft.avatar = { kind: 'emoji', value: emoji, color: COLORS[index] }; renderChoices(); });
      box.appendChild(button);
    });
    $('uploadBtn').style.display = state.allowPhoto ? 'block' : 'none';
    $('uploadBtn').textContent = draft.avatar.kind === 'photo' ? '✅ 已選照片（重選）' : '📷 上傳照片';
    $('photoNote').textContent = state.allowPhoto ? '照片只會縮小成小圓形大頭貼，傳送到現場的 Mac 顯示，不會上傳到其他地方。' : '主持人目前只開放 Emoji 大頭貼。';
  }
  $('openProfile').addEventListener('click', function () {
    draft = JSON.parse(JSON.stringify(profile));
    $('nickname').value = draft.nickname || '';
    renderChoices();
    $('sheet').className = 'sheet-backdrop open';
  });
  $('cancelProfile').addEventListener('click', function () { $('sheet').className = 'sheet-backdrop'; });
  $('noAvatar').addEventListener('click', function () { draft.avatar = { kind: 'none' }; renderChoices(); });
  $('uploadBtn').addEventListener('click', function () { $('file').click(); });
  $('file').addEventListener('change', function (event) {
    var file = event.target.files && event.target.files[0];
    if (!file) { return; }
    var reader = new FileReader();
    reader.onload = function () {
      var img = new Image();
      img.onload = function () {
        var side = Math.min(img.width, img.height), canvas = document.createElement('canvas');
        canvas.width = 160; canvas.height = 160;
        canvas.getContext('2d').drawImage(img, (img.width - side) / 2, (img.height - side) / 2, side, side, 0, 0, 160, 160);
        var data = canvas.toDataURL('image/jpeg', 0.82);
        if (data.length > 120000) { toast('照片太大，請換一張', true); return; }
        draft.avatar = { kind: 'photo', data: data };
        renderChoices();
      };
      img.onerror = function () { toast('無法讀取這張照片', true); };
      img.src = reader.result;
    };
    reader.readAsDataURL(file);
    event.target.value = '';
  });
  $('saveProfile').addEventListener('click', function () {
    draft.nickname = graphemes(clean($('nickname').value)).slice(0, 10).join('');
    profile = draft;
    save('profile', profile);
    renderProfile();
    $('sheet').className = 'sheet-backdrop';
    if (state.connected && state.ws) { state.ws.send(JSON.stringify({ t: 'profile', profile: profile })); toast('已更新暱稱與大頭貼'); }
  });

  $('retry').addEventListener('click', function () { location.reload(); });
  document.addEventListener('visibilitychange', function () {
    // 手機從背景回來時立即重連（iOS 鎖屏會中斷連線）
    if (!document.hidden && !state.connected && !state.stopped) { state.attempts = 0; connect(); }
  });

  renderProfile();
  updateCounter();
  if (!token) {
    showNotice('📷', '請掃描大螢幕上的 QR Code', '掃描後就能發送彈幕，不需要下載 App 或登入。', false);
    setStatus('ended', '尚未加入');
  } else {
    connect();
  }
})();
</script>
</body>
</html>
"""#
}
