'use strict';
const v=require('./validation');
const {allocateExpense}=require('./domain');
const UUID=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

// Bill metadata is reviewed with the whole immutable revision. It never changes
// the shared financial snapshot or claims that a bank payment was verified.
function validateBill(bill,snapshot) {
  v.record(bill,['currency','totalMinor','contributions','allocation'],'payload.bill');
  v.currency(bill.currency);
  const total=v.amount(bill.totalMinor,'payload.bill.totalMinor',{positive:true});
  if(total<BigInt(snapshot.totalMinor))v.fail('BILL_TOTAL_MISMATCH','payload.bill.totalMinor');
  v.count(bill.contributions,8,'INVALID_PAYER_COUNT','payload.bill.contributions');
  const full=new Map();let sum=0n;
  for(const [index,row] of bill.contributions.entries()) {
    const field=`payload.bill.contributions[${index}]`;
    v.record(row,['memberId','amountMinor'],field);
    if(!v.matches(UUID,row.memberId))v.fail('INVALID_MEMBER_ID',`${field}.memberId`);
    if(full.has(row.memberId))v.fail('DUPLICATE_MEMBER',`${field}.memberId`);
    const amount=v.amount(row.amountMinor,`${field}.amountMinor`,{positive:true});
    full.set(row.memberId,amount);sum+=amount;
  }
  if(sum!==total)v.fail('BILL_TOTAL_MISMATCH','payload.bill.contributions');
  for(const row of snapshot.contributions) {
    if((full.get(row.memberId)??0n)<BigInt(row.amountMinor))v.fail('BILL_CONTRIBUTION_MISMATCH','payload.bill.contributions');
  }
  v.record(bill.allocation,['mode','participants','tieOrder'],'payload.bill.allocation');
  const result=allocateExpense({currency:'INR',totalMinor:snapshot.totalMinor,...bill.allocation});
  const actual=new Map(snapshot.shares.map(row=>[row.memberId,row.amountMinor]));
  if(result.allocations.length!==actual.size||result.allocations.some(row=>actual.get(row.memberId)!==row.amountMinor))v.fail('BILL_ALLOCATION_MISMATCH','payload.bill.allocation');
  return bill;
}
module.exports={validateBill};
