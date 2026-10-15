// 壓力測試：模擬 N 支手機（每支不同 IP）同時連線、同時發送、持續發送。
//   node loadtest.mjs --base http://127.0.0.1:8765 --token ABCD2345 --clients 200 --duration 60 --out result.json
// --photos <資料夾>：每支手機用資料夾裡不同的 JPEG 當照片大頭貼（模擬每個人都上傳自己的照片）
// 需要 lo0 別名 127.0.0.2 ～ 127.0.0.(N+1)：
//   for i in $(seq 2 201); do sudo ifconfig lo0 alias 127.0.0.$i up; done
import fs from 'node:fs';
import path from 'node:path';
import { Phone, parseArgs, percentile, sleep } from './lib.mjs';

const args = parseArgs({ base: 'http://127.0.0.1:8765', clients: '200', duration: '60', normal: '45', out: '', photos: '' });
if (!args.token) { console.error('需要 --token'); process.exit(2); }
const clientCount = Number(args.clients);
const duration = Number(args.duration) * 1000;
const texts = ['URBAN 今天衝三件 🔥', '早安 ☀️', '加油 💪', '👏👏👏', '這個數字太強了', '收到！', '+1 👍', '🎉', '衝衝衝 🚀', '辛苦了 ☕️'];

const summary = { clients: clientCount, durationSeconds: duration / 1000 };

// 照片大頭貼：與手機網頁上傳的格式相同（data URL）
const photos = args.photos
  ? fs.readdirSync(args.photos).filter((name) => name.endsWith('.jpg')).sort()
    .map((name) => `data:image/jpeg;base64,${fs.readFileSync(path.join(args.photos, name)).toString('base64')}`)
  : [];
if (args.photos && photos.length === 0) { console.error(`${args.photos} 裡沒有 JPEG`); process.exit(2); }
const emojis = ['🦁', '🐯', '🐼', '🐰'];
const avatarFor = (i) => (photos.length
  ? { kind: 'photo', data: photos[i % photos.length] }
  : { kind: 'emoji', value: emojis[i % emojis.length], color: '#2563EB' });
if (photos.length) {
  const used = Array.from({ length: clientCount }, (_, i) => photos[i % photos.length]);
  const bytes = used.reduce((sum, url) => sum + url.length, 0);
  summary.photoAvatars = { distinct: Math.min(photos.length, clientCount), averageUploadKB: Math.round(bytes / used.length / 1024 * 10) / 10 };
  console.log(`▶ 照片大頭貼：${summary.photoAvatars.distinct} 張不同照片，每人上傳平均 ${summary.photoAvatars.averageUploadKB} KB（base64）`);
}
const stats = (values) => ({ count: values.length, p50: percentile(values, 50), p95: percentile(values, 95), p99: percentile(values, 99), max: values.length ? Math.round(Math.max(...values) * 10) / 10 : null });
const tally = (results) => results.reduce((acc, r) => {
  const key = r.ack ? (r.ack.ok ? 'accepted' : r.ack.code) : 'no_ack';
  acc[key] = (acc[key] || 0) + 1;
  return acc;
}, {});

// ---------- 1. 同時連線 ----------
console.log(`▶ ${clientCount} 支手機同時連線…`);
const phones = Array.from({ length: clientCount }, (_, i) => new Phone({
  base: args.base, token: args.token, localAddress: `127.0.0.${2 + i}`,
  nickname: `測試員${i + 1}`, avatar: avatarFor(i),
}));
const connectStart = performance.now();
const connectResults = await Promise.allSettled(phones.map(async (phone) => {
  const started = performance.now();
  await phone.connect(10000);
  const welcome = await phone.hello();
  if (welcome.t !== 'welcome') throw new Error(`收到 ${welcome.t}`);
  return performance.now() - started;
}));
const connected = connectResults.filter((r) => r.status === 'fulfilled');
summary.connect = {
  succeeded: connected.length,
  failed: connectResults.length - connected.length,
  allConnectedInMs: Math.round(performance.now() - connectStart),
  latencyMs: stats(connected.map((r) => r.value)),
  errors: [...new Set(connectResults.filter((r) => r.status === 'rejected').map((r) => String(r.reason && r.reason.message)))].slice(0, 5),
};
console.log(`  成功 ${summary.connect.succeeded}、失敗 ${summary.connect.failed}，全部完成 ${summary.connect.allConnectedInMs} ms`);
const live = phones.filter((_, i) => connectResults[i].status === 'fulfilled');

// ---------- 2. 一般互動：200 人在線，全場平均每 3 秒有人送一則 ----------
const normalSeconds = Number(args.normal);
console.log(`▶ 一般互動 ${normalSeconds} 秒：${live.length} 人在線，全場平均每 3 秒有人送一則…`);
const normal = [];
const normalPending = [];
const normalDeadline = performance.now() + normalSeconds * 1000;
for (let k = 0; performance.now() < normalDeadline; k += 1) {
  const phone = live[(k * 37) % live.length];
  normalPending.push(phone.send(texts[k % texts.length]).then((result) => { result.phone = phone; normal.push(result); }));
  await sleep(2000 + Math.random() * 2000);
}
await Promise.all(normalPending);
await sleep(15000); // 等最後幾則上螢幕
const normalShown = normal
  .filter((r) => r.ack && r.ack.ok)
  .map((r) => { const at = r.phone.shownAt(r.id); return at ? at - r.sentAt : null; })
  .filter((v) => v !== null);
summary.normal = {
  sent: normal.length,
  outcomes: tally(normal),
  ackLatencyMs: stats(normal.filter((r) => r.ack).map((r) => r.ack.latency)),
  shown: normalShown.length,
  sendToShownMs: stats(normalShown),
};
console.log(`  送出 ${summary.normal.sent} 則：${JSON.stringify(summary.normal.outcomes)}`);
console.log(`  回條延遲 p50 ${summary.normal.ackLatencyMs.p50} ms、p95 ${summary.normal.ackLatencyMs.p95} ms、最大 ${summary.normal.ackLatencyMs.max} ms`);
console.log(`  已顯示 ${summary.normal.shown} 則；送出到上螢幕 p50 ${summary.normal.sendToShownMs.p50} ms、p95 ${summary.normal.sendToShownMs.p95} ms、最大 ${summary.normal.sendToShownMs.max} ms`);

// ---------- 3. 同一瞬間全部發送 ----------
console.log(`▶ ${live.length} 支手機在同一瞬間發送…`);
const burst = await Promise.all(live.map((phone, i) => phone.send(texts[i % texts.length])));
summary.burst = {
  outcomes: tally(burst),
  ackLatencyMs: stats(burst.filter((r) => r.ack).map((r) => r.ack.latency)),
};
console.log(`  結果：${JSON.stringify(summary.burst.outcomes)}；回條延遲 p50 ${summary.burst.ackLatencyMs.p50} ms、p95 ${summary.burst.ackLatencyMs.p95} ms、最大 ${summary.burst.ackLatencyMs.max} ms`);

// ---------- 4. 極端情況：每個人都持續發送 ----------
console.log(`▶ 持續 ${duration / 1000} 秒：每支手機每 6～20 秒發送一則…`);
await sleep(5500); // 讓同時發送的冷卻時間過去
const sustained = [];
const deadline = performance.now() + duration;
await Promise.all(live.map(async (phone, i) => {
  await sleep(Math.random() * 6000);
  while (performance.now() < deadline) {
    const result = await phone.send(`${texts[(i + sustained.length) % texts.length]} #${sustained.length + 1}`);
    result.phone = phone;
    sustained.push(result);
    await sleep(6000 + Math.random() * 14000);
  }
}));
await sleep(3000);
const shownLatencies = sustained
  .filter((r) => r.ack && r.ack.ok)
  .map((r) => { const at = r.phone.shownAt(r.id); return at ? at - r.sentAt : null; })
  .filter((v) => v !== null);
const droppedCount = sustained.filter((r) => r.phone.messages.some((m) => m.t === 'dropped' && m.id === r.id)).length;
summary.sustained = {
  sent: sustained.length,
  offeredPerSecond: Math.round((sustained.length / (duration / 1000)) * 10) / 10,
  outcomes: tally(sustained),
  ackLatencyMs: stats(sustained.filter((r) => r.ack).map((r) => r.ack.latency)),
  shown: shownLatencies.length,
  sendToShownMs: stats(shownLatencies),
  droppedAfterAccept: droppedCount,
};
console.log(`  共送出 ${summary.sustained.sent} 則（約 ${summary.sustained.offeredPerSecond} 則/秒）：${JSON.stringify(summary.sustained.outcomes)}`);
console.log(`  回條延遲 p50 ${summary.sustained.ackLatencyMs.p50} ms、p95 ${summary.sustained.ackLatencyMs.p95} ms、最大 ${summary.sustained.ackLatencyMs.max} ms`);
console.log(`  已顯示 ${summary.sustained.shown} 則；送出到上螢幕 p50 ${summary.sustained.sendToShownMs.p50} ms、p95 ${summary.sustained.sendToShownMs.p95} ms`);

// ---------- 5. 連線穩定度 ----------
summary.stillConnected = live.filter((phone) => phone.closed === null).length;
console.log(`▶ 測試結束時仍連線：${summary.stillConnected} / ${live.length}`);
live.forEach((phone) => phone.close());

if (args.out) fs.writeFileSync(args.out, JSON.stringify(summary, null, 2));

// ---------- 判定 ----------
const problems = [];
if (summary.connect.failed > 0) problems.push(`${summary.connect.failed} 支手機連線失敗`);
const noAck = (summary.normal.outcomes.no_ack || 0) + (summary.burst.outcomes.no_ack || 0) + (summary.sustained.outcomes.no_ack || 0);
if ((summary.normal.ackLatencyMs.p95 ?? 0) > 1000) problems.push(`一般互動回條 p95 超過 1 秒`);
if (summary.normal.shown < (summary.normal.outcomes.accepted || 0)) problems.push(`一般互動有 ${(summary.normal.outcomes.accepted || 0) - summary.normal.shown} 則被接受卻沒有顯示`);
if (noAck > 0) problems.push(`${noAck} 則沒有收到回條`);
if ((summary.burst.ackLatencyMs.p95 ?? 0) > 1000) problems.push(`同時發送回條 p95 超過 1 秒`);
if ((summary.sustained.ackLatencyMs.p95 ?? 0) > 1000) problems.push(`持續發送回條 p95 超過 1 秒`);
if (summary.stillConnected < live.length) problems.push(`${live.length - summary.stillConnected} 支手機中途斷線`);
if (problems.length) { console.log(`❌ ${problems.join('；')}`); process.exit(1); }
console.log('✅ 壓力測試通過');
