// 手機端網頁（同仁掃 QR Code 後打開的頁面）。
// 全部內嵌：不依賴 CDN，在沒有對外網路的會議室 Wi-Fi 也能用。
enum MobilePage {
    static let html = #"""
<!doctype html>
<html lang="zh-Hant">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="theme-color" content="#0B3D91">
<meta name="apple-mobile-web-app-capable" content="yes">
<title>URBAN 即時彈幕</title>
<style>
:root {
  --blue: #0B3D91;
  --glass-top: rgba(30, 82, 178, .80);
  --glass-bottom: rgba(7, 33, 92, .84);
}
* { box-sizing: border-box; -webkit-tap-highlight-color: transparent; }
html, body { margin: 0; min-height: 100%; }
body {
  font-family: -apple-system, BlinkMacSystemFont, "PingFang TC", "Noto Sans TC", "Microsoft JhengHei", sans-serif;
  background: radial-gradient(130% 90% at 50% 0%, #1E5BC6 0%, #0B3D91 45%, #061A42 100%) fixed;
  color: #fff;
  -webkit-text-size-adjust: 100%;
}
main {
  max-width: 520px;
  margin: 0 auto;
  padding: calc(env(safe-area-inset-top) + 22px) 18px calc(env(safe-area-inset-bottom) + 28px);
}
header { text-align: center; margin-bottom: 18px; }
.brand { font-weight: 900; font-size: 30px; letter-spacing: .34em; margin-left: .34em; }
.subtitle { font-weight: 700; font-size: 15px; letter-spacing: .2em; opacity: .85; margin-top: 2px; }
.status {
  display: inline-flex; align-items: center; gap: 8px;
  margin-top: 14px; padding: 6px 14px; border-radius: 999px;
  background: rgba(255, 255, 255, .12); font-size: 13px; font-weight: 700;
}
.dot { width: 8px; height: 8px; border-radius: 50%; background: #3DDC84; box-shadow: 0 0 0 3px rgba(61, 220, 132, .25); }
.status.paused .dot { background: #FFC93C; box-shadow: 0 0 0 3px rgba(255, 201, 60, .25); }
.status.off .dot, .status.offline .dot { background: #FF6B6B; box-shadow: 0 0 0 3px rgba(255, 107, 107, .25); }
.card {
  background: rgba(255, 255, 255, .08);
  border: 1px solid rgba(255, 255, 255, .18);
  border-radius: 22px;
  padding: 16px;
  -webkit-backdrop-filter: blur(12px);
  backdrop-filter: blur(12px);
}
.preview { height: 76px; display: flex; align-items: center; justify-content: center; margin-bottom: 8px; }
.capsule {
  display: inline-block; max-width: 100%;
  white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
  padding: 9px 20px; border-radius: 999px;
  font-size: 21px; font-weight: 800; color: #fff;
  background: linear-gradient(180deg, rgba(255,255,255,.22) 0%, rgba(255,255,255,0) 50%), linear-gradient(180deg, var(--glass-top), var(--glass-bottom));
  border: 1.5px solid rgba(255, 255, 255, .38);
  box-shadow: 0 6px 16px rgba(0, 0, 0, .35);
  text-shadow: 0 1px 2px rgba(0, 0, 0, .35);
}
.capsule.placeholder { opacity: .5; }
form { display: flex; gap: 10px; }
input {
  flex: 1; min-width: 0;
  font: inherit; font-size: 17px; font-weight: 600;
  padding: 14px 16px; border: 0; border-radius: 14px; outline: none;
  color: #0A1B3D; background: #fff;
}
input::placeholder { color: #8A94A6; font-weight: 500; }
button { font: inherit; touch-action: manipulation; cursor: pointer; }
.send {
  padding: 0 20px; border: 0; border-radius: 14px;
  font-size: 17px; font-weight: 800; color: var(--blue); background: #fff;
}
.send:disabled { opacity: .55; }
.counter { text-align: right; font-size: 12px; opacity: .7; margin-top: 6px; }
.counter.over { color: #FFC93C; opacity: 1; font-weight: 700; }
.section-title { margin: 18px 4px 10px; font-size: 14px; font-weight: 700; opacity: .85; }
.emoji-grid { display: grid; grid-template-columns: repeat(4, 1fr); gap: 10px; }
.emoji-grid button {
  font-size: 30px; line-height: 1; padding: 13px 0; color: #fff;
  border-radius: 16px; border: 1px solid rgba(255, 255, 255, .18);
  background: rgba(255, 255, 255, .10);
  transition: transform .08s, background .08s;
}
.emoji-grid button:active { transform: scale(.93); background: rgba(255, 255, 255, .24); }
.toast {
  position: fixed; left: 50%; bottom: calc(env(safe-area-inset-bottom) + 24px);
  transform: translate(-50%, 20px); opacity: 0; pointer-events: none;
  transition: opacity .2s, transform .2s;
  width: max-content; max-width: 88vw; padding: 12px 20px; border-radius: 999px;
  background: #fff; color: var(--blue); font-weight: 800; text-align: center;
  box-shadow: 0 10px 30px rgba(0, 0, 0, .3);
}
.toast.show { opacity: 1; transform: translate(-50%, 0); }
.toast.error { color: #B42318; }
footer { text-align: center; font-size: 12px; opacity: .6; margin-top: 22px; line-height: 1.6; }
</style>
</head>
<body>
<main>
  <header>
    <div class="brand">URBAN</div>
    <div class="subtitle">即時彈幕</div>
    <div id="status" class="status"><span class="dot"></span><span id="statusText">連線中…</span></div>
  </header>

  <section class="card">
    <div class="preview"><span id="preview" class="capsule placeholder">你的彈幕會長這樣</span></div>
    <form id="form" autocomplete="off">
      <input id="text" type="text" enterkeyhint="send" placeholder="輸入文字或 Emoji" aria-label="彈幕內容">
      <button id="send" class="send" type="submit">送出</button>
    </form>
    <div id="counter" class="counter"><span id="count">0</span> / <span id="max">40</span></div>

    <div class="section-title">點一下直接送出</div>
    <div id="emojis" class="emoji-grid"></div>
  </section>

  <footer>請友善發言 · 主持人可以隨時暫停或清空彈幕</footer>
</main>
<div id="toast" class="toast" role="status" aria-live="polite"></div>

<script>
(function () {
  var EMOJIS = ['👍', '👏', '🎉', '❤️', '😂', '🔥', '💪', '🙌', '😮', '💯', '☕️', '🚀'];
  var maxLength = 40;
  var busy = false;
  var toastTimer = null;

  function $(id) { return document.getElementById(id); }
  var input = $('text'), sendButton = $('send'), preview = $('preview');
  var segmenter = (window.Intl && Intl.Segmenter) ? new Intl.Segmenter('zh-Hant', { granularity: 'grapheme' }) : null;

  function graphemes(text) {
    if (segmenter) { return Array.from(segmenter.segment(text), function (s) { return s.segment; }); }
    return Array.from(text);
  }
  function clean(text) { return text.replace(/\s+/g, ' ').trim(); }

  function updatePreview() {
    var parts = graphemes(clean(input.value));
    $('count').textContent = parts.length;
    $('counter').classList.toggle('over', parts.length > maxLength);
    if (parts.length === 0) {
      preview.textContent = '你的彈幕會長這樣';
      preview.classList.add('placeholder');
    } else {
      preview.textContent = parts.slice(0, maxLength).join('');
      preview.classList.remove('placeholder');
    }
  }

  function showToast(message, isError) {
    var toast = $('toast');
    toast.textContent = message;
    toast.classList.toggle('error', !!isError);
    toast.classList.add('show');
    clearTimeout(toastTimer);
    toastTimer = setTimeout(function () { toast.classList.remove('show'); }, isError ? 2600 : 1400);
  }

  function setStatus(state, message) {
    $('status').className = 'status ' + state;
    $('statusText').textContent = message;
  }

  function refreshStatus() {
    fetch('/api/status', { cache: 'no-store' })
      .then(function (res) { return res.json(); })
      .then(function (data) {
        maxLength = data.maxLength || maxLength;
        $('max').textContent = maxLength;
        setStatus(data.state, data.message);
        updatePreview();
      })
      .catch(function () { setStatus('offline', '連不到電腦，請確認在同一個 Wi-Fi'); });
  }

  function send(raw) {
    var text = graphemes(clean(raw)).slice(0, maxLength).join('');
    if (!text) { showToast('請輸入文字或 Emoji', true); return Promise.resolve(false); }
    if (busy) { return Promise.resolve(false); }
    busy = true;
    sendButton.disabled = true;
    return fetch('/api/danmaku', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ text: text }),
      cache: 'no-store'
    })
      .then(function (res) {
        return res.json().catch(function () { return {}; }).then(function (data) {
          if (res.ok && data.ok) {
            showToast('已送出 ✓');
            if (navigator.vibrate) { navigator.vibrate(15); }
            return true;
          }
          showToast(data.message || '送出失敗，請再試一次', true);
          if (data.code === 'paused' || data.code === 'off') { setStatus(data.code, data.message); }
          return false;
        });
      })
      .catch(function () {
        showToast('連不到電腦，請確認在同一個 Wi-Fi', true);
        setStatus('offline', '連線中斷');
        return false;
      })
      .then(function (ok) {
        busy = false;
        setTimeout(function () { sendButton.disabled = false; }, 500);
        return ok;
      });
  }

  EMOJIS.forEach(function (emoji) {
    var button = document.createElement('button');
    button.type = 'button';
    button.textContent = emoji;
    button.setAttribute('aria-label', '送出 ' + emoji);
    button.addEventListener('click', function () { send(emoji); });
    $('emojis').appendChild(button);
  });

  input.addEventListener('input', updatePreview);
  // 注音 / 拼音選字時按 Enter 不要送出
  input.addEventListener('keydown', function (event) {
    if (event.key === 'Enter' && (event.isComposing || event.keyCode === 229)) { event.preventDefault(); }
  });
  $('form').addEventListener('submit', function (event) {
    event.preventDefault();
    send(input.value).then(function (ok) {
      if (ok) { input.value = ''; updatePreview(); }
    });
  });
  document.addEventListener('visibilitychange', function () {
    if (!document.hidden) { refreshStatus(); }
  });

  refreshStatus();
  setInterval(refreshStatus, 10000);
})();
</script>
</body>
</html>
"""#
}
