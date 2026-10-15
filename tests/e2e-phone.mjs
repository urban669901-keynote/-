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

await page.click('#openProfile');
await page.fill('#nickname', '小明');
await page.click('#choices button:nth-child(1)');
await page.click('#saveProfile');
list.check((await page.textContent('#myName')) === '小明', '設定暱稱與大頭貼');

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
