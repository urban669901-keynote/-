// 協定測試：對執行中的 URBAN LIVE App 實際連線（不是模擬伺服器）。
//   node protocol-test.mjs --base http://127.0.0.1:8765 --token ABCD2345 [--aliases]
// --aliases：使用 127.0.0.2 起的本機別名，模擬多支不同 IP 的手機（CI 會先建立別名）。
import http from 'node:http';
import { Checklist, Phone, parseArgs, sleep } from './lib.mjs';

const args = parseArgs({ base: 'http://127.0.0.1:8765' });
if (!args.token) { console.error('需要 --token'); process.exit(2); }
const list = new Checklist();
let aliasIndex = 10;
const nextAddress = () => (args.aliases ? `127.0.0.${aliasIndex++}` : undefined);

function request(method, path, body, localAddress) {
  return new Promise((resolve, reject) => {
    const url = new URL(path, args.base);
    const req = http.request({ method, hostname: url.hostname, port: url.port, path: url.pathname + url.search, localAddress,
      headers: body ? { 'Content-Type': 'application/json' } : {} }, (res) => {
      let data = '';
      res.on('data', (chunk) => { data += chunk; });
      res.on('end', () => resolve({ status: res.statusCode, body: data }));
    });
    req.on('error', reject);
    if (body) req.write(JSON.stringify(body));
    req.end();
  });
}

// ---------- HTTP ----------
const page = await request('GET', `/j/${args.token}`);
list.check(page.status === 200 && page.body.includes('早會即時彈幕'), '手機網頁可以打開', `HTTP ${page.status}`);
const status = await request('GET', `/api/status?s=${args.token}`);
list.check(status.status === 200 && JSON.parse(status.body).state === 'live', '狀態查詢回報 live', status.body);
const wrongStatus = await request('GET', '/api/status?s=WRONGTOK');
list.check(JSON.parse(wrongStatus.body).state === 'ended', '錯誤的場次識別碼不會被視為進行中');
list.check((await request('GET', '/nope')).status === 404, '不存在的路徑回 404');
list.check((await request('GET', '/api/send')).status === 405, '錯誤的方法回 405');

// ---------- WebSocket：場次驗證 ----------
const stranger = new Phone({ base: args.base, token: 'WRONG234' });
await stranger.connect();
const bye = await stranger.waitFor((m) => m.t === 'bye').catch(() => null);
list.check(bye && bye.code === 'invalid_session', '錯誤的場次連結會被拒絕並提示重新掃描', JSON.stringify(bye));

try {
  const evil = new Phone({ base: args.base, token: args.token, origin: 'http://evil.example' });
  await evil.connect();
  list.fail('其他網站發起的 WebSocket 應被拒絕');
} catch (error) {
  list.check(String(error.message).includes('403'), '其他網站發起的 WebSocket 被拒絕（403）', String(error.message));
}

// ---------- 正常發送流程 ----------
const kevin = new Phone({ base: args.base, token: args.token, localAddress: nextAddress(), nickname: 'Kevin',
  avatar: { kind: 'emoji', value: '🦁', color: '#2563EB' } });
await kevin.connect();
const welcome = await kevin.hello();
list.check(welcome.t === 'welcome' && welcome.state === 'live', '連線後收到 welcome，狀態 live', JSON.stringify(welcome));
list.check(welcome.maxLength === 25 && welcome.cooldown === 5, '預設限制：25 字、每 5 秒 1 則', `${welcome.maxLength} / ${welcome.cooldown}`);
list.check(welcome.nickname === 'Kevin', '暱稱被接受', String(welcome.nickname));

const first = await kevin.send('URBAN 今天衝三件 🔥');
list.check(first.ack && first.ack.ok === true, `送出彈幕收到成功回條（${first.ack ? first.ack.latency.toFixed(1) : '-'} ms）`, JSON.stringify(first.ack));
const shown = await kevin.waitFor((m) => m.t === 'shown' && m.id === first.id, 15000).catch(() => null);
list.check(Boolean(shown), `Mac 回報彈幕已顯示（送出後 ${shown ? (shown.receivedAt - first.sentAt).toFixed(1) : '-'} ms）`);

const tooFast = await kevin.send('第二則');
list.check(tooFast.ack && tooFast.ack.ok === false && tooFast.ack.code === 'too_fast' && tooFast.ack.retryAfter > 0,
  '5 秒內第二則被限流，並告知要等幾秒', JSON.stringify(tooFast.ack));

// ---------- 內容審核 ----------
const other = new Phone({ base: args.base, token: args.token, localAddress: nextAddress(), nickname: '智障' });
await other.connect();
const profileError = other.waitFor((m) => m.t === 'profile' && m.ok === false, 3000).catch(() => null);
const otherWelcome = await other.hello();
list.check(Boolean(await profileError) && otherWelcome.nickname === undefined, '不當暱稱被拒絕');

const filtered = await other.send('靠 北');
list.check(filtered.ack && filtered.ack.code === 'filtered', '敏感詞被擋下（含拆字）', JSON.stringify(filtered.ack));
const empty = await other.send('   ');
list.check(empty.ack && empty.ack.code === 'empty', '空白訊息被擋下', JSON.stringify(empty.ack));
if (!args.aliases) await sleep(5200); // 沒有別名時所有連線同一個 IP，共用發言額度
const okAfterReject = await other.send('被擋下的不會消耗額度 👍');
list.check(okAfterReject.ack && okAfterReject.ack.ok === true, '被擋下的訊息不消耗發言額度', JSON.stringify(okAfterReject.ack));

if (args.aliases) {
  const dup = new Phone({ base: args.base, token: args.token, localAddress: nextAddress() });
  await dup.connect();
  await dup.hello();
  const d1 = await dup.send('重複測試 👏');
  await sleep(5300);
  const d2 = await dup.send('重複測試👏');
  list.check(d1.ack && d1.ack.ok && d2.ack && d2.ack.code === 'duplicate', '同一人重複送出相同內容被擋下', JSON.stringify(d2.ack));
  dup.close();

  const fallback = await request('POST', '/api/send', { session: args.token, clientId: 'c_http', text: 'HTTP 備援通道', nickname: '備援' }, nextAddress());
  list.check(fallback.status === 200 && JSON.parse(fallback.body).ok, 'HTTP 備援通道可以送出', fallback.body);
  const wrongSession = await request('POST', '/api/send', { session: 'WRONG234', text: 'x' }, nextAddress());
  list.check(wrongSession.status === 403, 'HTTP 備援也會驗證場次', `HTTP ${wrongSession.status}`);
}

// ---------- 大頭貼與異常輸入 ----------
const tinyJpeg = '/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/wAALCAAQABABAREA/8QAFQABAQAAAAAAAAAAAAAAAAAAAAf/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/9oACAEBAAA/AKp//9k=';
const photo = new Phone({ base: args.base, token: args.token, localAddress: nextAddress(), nickname: '照片',
  avatar: { kind: 'photo', data: `data:image/jpeg;base64,${tinyJpeg}` } });
await photo.connect();
list.check((await photo.hello()).t === 'welcome', '照片大頭貼不影響連線');

const flood = new Phone({ base: args.base, token: args.token, localAddress: nextAddress() });
await flood.connect();
flood.ws.send('x'.repeat(300 * 1024));
await sleep(800);
list.check(flood.closed !== null, `過大的訊息會被斷線（close ${flood.closed}）`);

const garbage = new Phone({ base: args.base, token: args.token, localAddress: nextAddress() });
await garbage.connect();
garbage.ws.send('not json');
garbage.ws.send(JSON.stringify({ t: 'send', id: '<script>', text: 'id 含特殊字元' }));
const garbageAck = await garbage.waitFor((m) => m.t === 'ack', 3000).catch(() => null);
list.check(garbageAck && /^m\d+$/.test(garbageAck.id), '不合法的 JSON 被忽略、不合法的 id 被替換', JSON.stringify(garbageAck));

[kevin, other, photo, flood, garbage, stranger].forEach((phone) => phone.close());
list.finish();
