// Usage: node run_server.js <apiDir> <messages.jsonl> <out.jsonl>
const fs = require('fs'); const path = require('path'); const readline = require('readline');
const [apiDir, src, outPath] = process.argv.slice(2);
const { parseSmsAgainstPatterns } = require(path.join(apiDir, 'src/sms_parser'));
const out = fs.openSync(outPath, 'w', 0o600);
const rl = readline.createInterface({ input: fs.createReadStream(src) });
let n = 0;
rl.on('line', (line) => {
  const m = JSON.parse(line); let r;
  try { r = parseSmsAgainstPatterns([], { sender: m.sender, body: m.body }); } catch (e) { r = { ok: false, reason: 'THROW' }; }
  const f = r.fields || {};
  fs.writeSync(out, JSON.stringify({ id: m.id, ok: !!r.ok, reason: r.reason || null, kind: f.entryKind || null,
    amount: f.amountInr ?? null, instrument: f.instrument || null, card: f.cardLast4 || f.last4 || null, acct: f.accountLast4 || null }) + '\n');
  n++;
});
rl.on('close', () => { fs.closeSync(out); console.log('server parsed', n); });
