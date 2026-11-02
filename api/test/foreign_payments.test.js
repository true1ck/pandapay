const test = require('node:test');
const assert = require('node:assert/strict');
const p = require('../src/foreign_payments');
const { parseListQuery,summarize,registerForeignPaymentRoutes } = require('../src/foreign_payments_route');
const input={source_key:'a'.repeat(64),original_currency:'USD',original_amount:'20',occurred_at:'2026-03-05T00:00:00Z'};

test('foreign record validation retains genuinely missing fields but rejects invalid currency, precision and raw SMS',()=>{
  assert.equal(p.validateInput(input),null);
  assert.equal(p.validateInput({...input,original_amount:null}),null);
  for(const extra of [{original_currency:'INR'},{original_currency:'XYZ'},{original_amount:'.00'},{original_amount:'20.123'},{body:'private SMS'},{user_card_id:'other'},{valuation_status:'confirmed'},{reference:'a'.repeat(41)}]) assert.ok(p.validateInput({...input,...extra}));
});
test('valuation states never promote a reference estimate to a ledger amount',()=>{
  assert.equal(p.valuationFor({...input,original_amount:null},null).valuation_status,'awaiting_amount');
  assert.equal(p.valuationFor(input,null).valuation_status,'awaiting_rate');
  const estimated=p.valuationFor(input,{rate:'85',rate_date:'2026-03-05',rate_source:'Reference'});
  assert.equal(estimated.valuation_status,'estimated');assert.equal(estimated.estimated_inr,'1700.00');assert.equal(estimated.billed_inr,undefined);
});
test('an exact old SMS key alone cannot confirm a legacy credit-limit expense',()=>{
  const payment={...input,direction:'spend'};
  const legacy={status:'active',entry_kind:'spend',amount_inr:'286388.46',source_key:input.source_key};
  assert.equal(p.safeAutomaticMatch(payment,legacy),false);
  assert.equal(p.safeAutomaticMatch({...payment,billed_inr:'1742'},legacy),false);
  assert.equal(p.safeAutomaticMatch({...payment,billed_inr:'1742'},{...legacy,amount_inr:'1742'}),true);
});
test('automatic settlement matching requires exact references and same saved account identity',()=>{
  const payment={...input,direction:'spend',reference:'ABC123',user_card_id:'card-one'};
  const transaction={status:'active',entry_kind:'spend',amount_inr:'1742',bank_references:['ABC123'],user_card_id:'card-one',occurred_at:'2026-03-06T00:00:00Z'};
  assert.equal(p.safeAutomaticMatch(payment,transaction),true);
  for(const extra of [{bank_references:[]},{user_card_id:'card-two'},{occurred_at:'2026-06-01T00:00:00Z'},{status:'ignored'},{entry_kind:'income'}]) assert.equal(p.safeAutomaticMatch(payment,{...transaction,...extra}),false);
  assert.equal(p.safeAutomaticMatch({...payment,user_card_id:null},transaction),false);
});
test('summary excludes ignored rows, separates pending and confirmed refunds, and counts unknown prices',()=>{
  const summary=summarize([{valuation_status:'estimated',estimated_inr:'1700',direction:'spend'},{valuation_status:'awaiting_amount'},{valuation_status:'confirmed',billed_inr:'1742',direction:'spend'},{valuation_status:'confirmed',billed_inr:'100',direction:'refund'},{valuation_status:'ignored',estimated_inr:'286388.46'}]);
  assert.equal(summary.pending_count,2);assert.equal(summary.unknown_amount_count,1);
  assert.equal(summary.estimated_inr,'1700.00');assert.equal(summary.confirmed_net_inr,'1642.00');assert.equal(summary.confirmed_refund_inr,'100.00');
});
test('bounded accounting-period pagination rejects malformed cursors before database access',()=>{
  assert.ok(parseListQuery({from:'2026-03-01',to:'2026-04-01',limit:'200'}));
  for(const query of [{limit:'201'},{limit:'-1'},{cursor:'private'},{from:'2026-04-01',to:'2026-03-01'}]) assert.equal(parseListQuery(query),null);
});
test('invalid creates and item identifiers never acquire a database connection or fetch a rate',async()=>{
  const routes=new Map();registerForeignPaymentRoutes({get(path,auth,handler){routes.set('GET '+path,handler);},post(path,auth,handler){routes.set('POST '+path,handler);},patch(path,auth,handler){routes.set('PATCH '+path,handler);}},{requireAuth(){},withUserClient(){throw Error('database must not run');},exchangeService:{getRate(){throw Error('rate must not run');}}});
  const response=()=>({statusCode:200,status(code){this.statusCode=code;return this;},json(body){this.body=body;return this;}});
  let res=response();await routes.get('POST /foreign-payments')({body:{...input,body:'raw private message'}},res);assert.equal(res.statusCode,400);
  res=response();await routes.get('POST /foreign-payments/:id/confirm')({params:{id:'bad'},body:{}},res);assert.equal(res.statusCode,400);
});
