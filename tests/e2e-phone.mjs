// 端對端測試：用真的瀏覽器（Google Chrome，模擬 iPhone）打開 QR Code 網址，
// 設定暱稱與大頭貼、輸入「URBAN 今天衝三件 🔥」並發送，等待 Mac 回報「已上大螢幕」。
//   node e2e-phone.mjs --url http://192.168.1.23:8765/j/ABCD2345 --shot phone.png
import { chromium, devices } from 'playwright-core';
import { Checklist, parseArgs } from './lib.mjs';

const args = parseArgs({ shot: 'phone.png', channel: 'chrome' });
if (!args.url) { console.error('需要 --url'); process.exit(2); }
const list = new Checklist();

// 預設使用電腦上已安裝的 Google Chrome；--channel bundled 改用 Playwright 內建的 Chromium
const browser = await chromium.launch(args.channel === 'bundled' ? { headless: true } : { channel: args.channel, headless: true });
const context = await browser.newContext({ ...devices['iPhone 13'] });
const page = await context.newPage();
const errors = [];
page.on('pageerror', (error) => errors.push(String(error)));

await page.goto(args.url);
await page.waitForFunction(() => document.getElementById('statusText').textContent === '已連線', null, { timeout: 10000 });
list.pass('手機網頁開啟並連線');

// 用瀏覽器畫一張直式「人像照片」（600×800），經由上傳流程設為大頭貼
const portrait = await page.evaluate(() => {
  const canvas = document.createElement('canvas');
  canvas.width = 600; canvas.height = 800;
  const g = canvas.getContext('2d');
  const sky = g.createLinearGradient(0, 0, 0, 800);
  sky.addColorStop(0, '#8EC5FF'); sky.addColorStop(1, '#EAF4FF');
  g.fillStyle = sky; g.fillRect(0, 0, 600, 800);
  g.fillStyle = '#123B8A'; g.beginPath(); g.ellipse(300, 860, 300, 260, 0, 0, Math.PI * 2); g.fill();   // 西裝
  g.fillStyle = '#F5FAFF'; g.beginPath(); g.moveTo(250, 600); g.lineTo(350, 600); g.lineTo(300, 700); g.fill(); // 襯衫
  g.fillStyle = '#E9B48F'; g.fillRect(262, 470, 76, 130);                                                  // 脖子
  g.beginPath(); g.ellipse(300, 350, 135, 165, 0, 0, Math.PI * 2); g.fill();                              // 臉
  g.fillStyle = '#2B1D14'; g.beginPath(); g.ellipse(300, 250, 150, 95, 0, Math.PI, 0); g.fill();          // 頭髮
  g.fillRect(150, 250, 300, 30);
  g.fillStyle = '#2B1D14'; g.beginPath(); g.arc(250, 345, 13, 0, Math.PI * 2); g.arc(350, 345, 13, 0, Math.PI * 2); g.fill(); // 眼睛
  g.strokeStyle = '#B5523B'; g.lineWidth = 9; g.beginPath(); g.arc(300, 405, 48, 0.15 * Math.PI, 0.85 * Math.PI); g.stroke(); // 微笑
  return canvas.toDataURL('image/jpeg', 0.9);
});
await page.click('#openProfile');
await page.fill('#nickname', '小明');
await page.setInputFiles('#file', { name: 'portrait.jpg', mimeType: 'image/jpeg', buffer: Buffer.from(portrait.split(',')[1], 'base64') });
await page.waitForFunction(() => document.getElementById('uploadBtn').textContent.includes('已選照片'), null, { timeout: 5000 });
const uploaded = await page.evaluate(() => {
  const img = document.querySelector('#sheetAvatar img');
  return img ? img.src.length : 0;
});
list.check(uploaded > 1000 && uploaded <= 125000, `照片裁切壓縮後上傳（${Math.round(uploaded / 1024)} KB）`);
await page.click('#saveProfile');
list.check((await page.textContent('#myName')) === '小明' && (await page.$('#myAvatar img')) !== null, '設定暱稱與照片大頭貼');
list.check((await page.$('#preview.profile .lines .nick')) !== null, '預覽為「大頭貼放大、暱稱在上」的兩行樣式');

await page.fill('#text', 'URBAN 今天衝三件 🔥');
const started = Date.now();
await page.click('#send');
await page.waitForFunction(() => document.getElementById('history').textContent.includes('已送出') ||
  document.getElementById('history').textContent.includes('排隊中') || document.getElementById('history').textContent.includes('已上大螢幕'), null, { timeout: 5000 });
const acked = Date.now() - started;
list.check((await page.inputValue('#text')) === '', `收到 Mac 回條後清空輸入框（${acked} ms）`);
await page.waitForFunction(() => document.getElementById('history').textContent.includes('已上大螢幕'), null, { timeout: 15000 });
const shown = Date.now() - started;
list.pass(`Mac 回報「已上大螢幕」（按下發送後 ${shown} ms）`);
console.log(`E2E_SHOWN_MS=${shown}`);

await page.fill('#text', '馬上再送一則');
await page.evaluate(() => document.getElementById('form').requestSubmit());
await page.waitForTimeout(500);
list.check((await page.textContent('#toast')).includes('秒'), '冷卻時間內再送會提示要等幾秒', await page.textContent('#toast'));

await page.screenshot({ path: args.shot });
list.check(errors.length === 0, '頁面沒有 JavaScript 錯誤', errors.join('; '));
await browser.close();
list.finish();
