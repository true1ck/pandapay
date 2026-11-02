const test = require('node:test');
const assert = require('node:assert/strict');
const fx = require('../src/foreign_exchange');

test('ISO accounting precision is independent of display and cash rounding', () => {
  for (const [code, amount] of [['USD','20.12'],['PKR','20.12'],['HUF','20.12'],['IDR','20.12'],['IQD','20.123'],['KWD','20.123'],['CLF','20.1234'],['JPY','20']]) {
    assert.equal(fx.originalAmount(amount,code), amount);
  }
  for (const [code,amount] of [['JPY','20.1'],['USD','20.123'],['IQD','20.1234'],['XYZ','20']]) assert.equal(fx.originalAmount(amount,code),null);
  assert.equal(fx.originalAmount('20.000','JPY'),'20');
  for (const value of ['.00','0','-20','NaN','1e2',{},null]) assert.equal(fx.originalAmount(value,'USD'),null);
});
test('conversion uses integer decimal arithmetic and rounds once to paise', () => {
  assert.equal(fx.convertToInr('20','85.12345'),'1702.47');
  assert.equal(fx.convertToInr('0.1','0.05'),'0.01');
  assert.equal(fx.convertToInr('1.234','25.123456789'),'31.00');
  assert.equal(fx.convertToInr('9999999999999999','85'),null);
  assert.equal(fx.convertToInr('0','85'),null);
  assert.equal(fx.inrAmount('1.001'),null);
  assert.equal(fx.inrAmount('12.30'),'12.30');
});
test('a historical estimate accepts prior observation dates, never future or unrelated rates', () => {
  const valid={base:'USD',quote:'INR',date:'2026-03-27',rate:85};
  assert.equal(fx.validateRate(valid,'USD','2026-03-29').rate_date,'2026-03-27');
  for (const invalid of [{...valid,date:'2026-03-30'},{...valid,date:'2026-01-01'},{...valid,rate:0},{...valid,quote:'EUR'},{...valid,base:'GBP'}]) assert.equal(fx.validateRate(invalid,'USD','2026-03-29'),null);
  assert.equal(fx.calendarDay('2026-02-30'),false);
  assert.equal(fx.accountingDay('2026-03-01T20:00:00Z'),'2026-03-02');
});
test('rate retrieval sends currency/date only, caches snapshots, and coalesces requests', async () => {
  const stored=new Map();let requests=0,seen;
  const withUserClient=async (owner,fn)=>fn({query:async(sql,args)=>{
    if(sql.startsWith('SELECT'))return {rows:stored.has(args.join(':'))?[stored.get(args.join(':'))]:[]};
    const row={rate:args[3],rate_date:args[2],rate_source:args[4]};stored.set(args.slice(0,2).join(':'),row);return {rows:[row]};
  }});
  const exchange=fx.createForeignExchangeService({withUserClient,now:()=>new Date('2026-11-02T00:00:00Z'),fetchImpl:async(url,options)=>{
    requests++;seen={url,options};await new Promise(resolve=>setTimeout(resolve,5));
    return new Response(JSON.stringify({base:'USD',quote:'INR',date:'2026-03-27',rate:85}));
  }});
  const values=await Promise.all([exchange.getRate('private-owner','USD','2026-03-29'),exchange.getRate('another-owner','USD','2026-03-29')]);
  assert.equal(requests,1);assert.equal(values[0].rate,'85');
  await exchange.getRate('private-owner','USD','2026-03-29');assert.equal(requests,1);
  assert.equal(seen.url,'https://api.frankfurter.dev/v2/rate/usd/inr?date=2026-03-29');
  assert.equal(seen.options.redirect,'error');assert.ok(seen.options.signal);
  assert.doesNotMatch(JSON.stringify(seen),/private-owner|another-owner|Authorization|sms/i);
});
test('rate outages remain unresolved with bounded retry and no invented price', async () => {
  let requests=0;
  const exchange=fx.createForeignExchangeService({withUserClient:async(_,fn)=>fn({query:async()=>({rows:[]})}),now:()=>new Date('2026-11-02T00:00:00Z'),fetchImpl:async()=>{requests++;throw Error('offline');}});
  assert.equal(await exchange.getRate('owner','USD','2026-03-29'),null);
  assert.equal(await exchange.getRate('owner','USD','2026-03-29'),null);assert.equal(requests,1);
  assert.equal(await exchange.getRate('owner','USD','2026-12-01'),null);
});
