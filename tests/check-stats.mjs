// 檢查 App 寫入的統計檔（statistics.json）：進行中的場次（或最後一場）的人數、票數、換名次數。
//   node check-stats.mjs --file statistics.json --speaker 測試講師 --min-votes 3 --min-participants 5 --nickname-changes 2
import fs from 'node:fs';
import { Checklist, parseArgs } from './lib.mjs';

const args = parseArgs({});
const list = new Checklist();
let archive;
try {
  archive = JSON.parse(fs.readFileSync(args.file, 'utf8'));
} catch (error) {
  list.fail(`讀不到統計檔：${error.message}`);
  list.finish();
}
const session = archive.active ?? archive.sessions[archive.sessions.length - 1];
const participants = session.participants.length ?? session.participants;
const turn = (session.turns || []).find((t) => t.speaker === args.speaker);
console.log(`統計檔：參與 ${participants} 人、最高同時在線 ${session.peakOnline} 人、上螢幕 ${session.messagesShown} 則、` +
  `換名 ${session.nicknameChanges} 次、禮物 ${JSON.stringify(session.giftTotals || session.gifts || {})}；講師 ${(session.turns || []).map((t) => `${t.speaker} ${t.votes} 票（在場 ${t.audience} 人）`).join('、') || '無'}`);

if (args.speaker) list.check(Boolean(turn), `統計檔記錄了講師「${args.speaker}」`);
if (turn && args['min-votes']) list.check(turn.votes >= Number(args['min-votes']), `講師票數 ${turn.votes} ≥ ${args['min-votes']}`);
if (turn && args.votes) list.check(turn.votes === Number(args.votes), `講師票數 = ${args.votes}`, String(turn.votes));
if (args['min-participants']) list.check(participants >= Number(args['min-participants']), `參與人數 ${participants} ≥ ${args['min-participants']}`);
if (args.participants) list.check(participants === Number(args.participants), `參與人數 = ${args.participants}`, String(participants));
const gifts = session.giftTotals || session.gifts || {};
if (args.rockets) list.check((gifts.rocket || 0) === Number(args.rockets), `火箭 = ${args.rockets}`, JSON.stringify(gifts));
if (args['min-poppers']) list.check((gifts.popper || 0) >= Number(args['min-poppers']), `拉炮 ${gifts.popper || 0} ≥ ${args['min-poppers']}`);
if (args['nickname-changes']) {
  list.check(session.nicknameChanges === Number(args['nickname-changes']), `換名次數 = ${args['nickname-changes']}`, String(session.nicknameChanges));
}
const text = JSON.stringify(archive);
list.check(!/\b127\.0\.0\.\d+\b|\b192\.168\.\d+\.\d+\b/.test(text), '統計檔裡沒有 IP 位址');
list.finish();
