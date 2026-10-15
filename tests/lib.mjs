// 共用：模擬一支手機的 WebSocket 連線（與手機網頁使用完全相同的協定）。
import WebSocket from 'ws';

export function parseArgs(defaults) {
  const args = { ...defaults };
  const argv = process.argv.slice(2);
  for (let i = 0; i < argv.length; i += 1) {
    if (!argv[i].startsWith('--')) continue;
    const key = argv[i].slice(2);
    const next = argv[i + 1];
    if (next === undefined || next.startsWith('--')) { args[key] = true; } else { args[key] = next; i += 1; }
  }
  return args;
}

export const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

export function percentile(values, p) {
  if (values.length === 0) return null;
  const sorted = [...values].sort((a, b) => a - b);
  const index = Math.min(sorted.length - 1, Math.ceil((p / 100) * sorted.length) - 1);
  return Math.round(sorted[Math.max(0, index)] * 10) / 10;
}

/** 一支模擬手機。localAddress 用來模擬不同手機的 IP（需要 lo0 別名）。 */
export class Phone {
  constructor({ base, token, localAddress, nickname, avatar, clientId, origin }) {
    this.base = base;
    this.token = token;
    this.localAddress = localAddress;
    this.nickname = nickname;
    this.avatar = avatar ?? { kind: 'none' };
    this.clientId = clientId ?? `c_${Math.random().toString(36).slice(2, 12)}`;
    this.origin = origin;
    this.messages = [];
    this.waiters = [];
    this.counter = 0;
    this.closed = null;
  }

  connect(timeoutMs = 5000) {
    const url = `${this.base.replace(/^http/, 'ws')}/ws?s=${encodeURIComponent(this.token)}`;
    const options = { handshakeTimeout: timeoutMs };
    if (this.localAddress) options.localAddress = this.localAddress;
    if (this.origin) options.origin = this.origin;
    this.ws = new WebSocket(url, options);
    this.ws.on('message', (raw) => {
      let data;
      try { data = JSON.parse(raw.toString()); } catch { return; }
      data.receivedAt = performance.now();
      this.messages.push(data);
      this.waiters = this.waiters.filter((waiter) => {
        if (!waiter.match(data)) return true;
        clearTimeout(waiter.timer);
        waiter.resolve(data);
        return false;
      });
    });
    this.ws.on('close', (code) => { this.closed = code; });
    return new Promise((resolve, reject) => {
      this.ws.once('open', () => resolve(this));
      this.ws.once('error', reject);
      this.ws.once('unexpected-response', (_req, res) => reject(new Error(`HTTP ${res.statusCode}`)));
    });
  }

  /** 等待第一則符合條件的訊息（包含已收到的）。 */
  waitFor(match, timeoutMs = 5000) {
    const existing = this.messages.find(match);
    if (existing) return Promise.resolve(existing);
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.waiters = this.waiters.filter((waiter) => waiter.timer !== timer);
        reject(new Error('timeout'));
      }, timeoutMs);
      this.waiters.push({ match, resolve, timer });
    });
  }

  async hello() {
    const started = performance.now();
    this.ws.send(JSON.stringify({ t: 'hello', clientId: this.clientId, profile: { nickname: this.nickname, avatar: this.avatar } }));
    const welcome = await this.waitFor((m) => m.t === 'welcome' || m.t === 'bye');
    welcome.latency = welcome.receivedAt - started;
    return welcome;
  }

  /** 送出一則彈幕，回傳 { id, sentAt, ack }（ack 為 null 代表逾時沒有回條）。 */
  async send(text, ackTimeoutMs = 5000) {
    this.counter += 1;
    const id = `t${this.counter}_${Math.random().toString(36).slice(2, 7)}`;
    const sentAt = performance.now();
    this.ws.send(JSON.stringify({ t: 'send', id, text }));
    try {
      const ack = await this.waitFor((m) => m.t === 'ack' && m.id === id, ackTimeoutMs);
      ack.latency = ack.receivedAt - sentAt;
      return { id, sentAt, ack };
    } catch {
      return { id, sentAt, ack: null };
    }
  }

  shownAt(id) {
    const shown = this.messages.find((m) => m.t === 'shown' && m.id === id);
    return shown ? shown.receivedAt : null;
  }

  close() {
    try { this.ws.close(); } catch { /* ignore */ }
  }
}

export class Checklist {
  constructor() { this.failures = 0; }
  pass(message) { console.log(`✅ ${message}`); }
  fail(message) { console.log(`❌ ${message}`); this.failures += 1; }
  check(condition, message, detail = '') {
    if (condition) this.pass(message); else this.fail(detail ? `${message}：${detail}` : message);
  }
  finish() {
    if (this.failures > 0) { console.log(`\n❌ 共 ${this.failures} 項失敗`); process.exit(1); }
    console.log('\n✅ 全部通過');
  }
}
