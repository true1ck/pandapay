'use strict';

const crypto = require('node:crypto');
const fx = require('./foreign_exchange');
const UUID = /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i;
const HASH = /^[a-f0-9]{64}$/;
const STATUSES = new Set(['awaiting_amount', 'awaiting_rate', 'estimated', 'confirmed', 'ignored']);
const EDITABLE = ['original_currency','original_amount','occurred_at','merchant_name','card_last4','account_last4','user_card_id','category_id','user_category_id','category_name','direction','reference','refund_of_id','instrument'];
const COLUMNS = [...EDITABLE, 'valuation_status','estimated_inr','billed_inr','rate','rate_date','rate_source','transaction_id','confirmation_source','user_modified'];
class ForeignPaymentError extends Error {
  constructor(status, code) { super(code); this.status = status; this.code = code; }
}
function object(value) { return value && typeof value === 'object' && !Array.isArray(value); }
function fail(code, status = 400) { throw new ForeignPaymentError(status, code); }
function timestamp(value) {
  if (value instanceof Date) return Number.isFinite(value.getTime());
  return typeof value === 'string' && /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?(?:Z|[+-]\d{2}:\d{2})$/.test(value)
    && Number.isFinite(Date.parse(value)) && fx.calendarDay(value.slice(0, 10));
}
function validateInput(body, { partial = false } = {}) {
  if (!object(body)) return 'foreign_payment_object_required';
  if (!partial && !HASH.test(body.source_key || '')) return 'invalid_source_key';
  if (!partial && !timestamp(body.occurred_at)) return 'invalid_occurred_at';
  if (body.occurred_at !== undefined && !timestamp(body.occurred_at)) return 'invalid_occurred_at';
  if (body.original_currency != null && (!fx.CURRENCIES.has(body.original_currency) || body.original_currency === 'INR')) return 'invalid_original_currency';
  if (body.original_amount != null && !fx.originalAmount(body.original_amount, body.original_currency || null)) return 'invalid_original_amount';
  for (const key of ['user_card_id','category_id','user_category_id','transaction_id','refund_of_id']) {
    if (body[key] != null && !UUID.test(body[key])) return `invalid_${key}`;
  }
  for (const key of ['card_last4','account_last4']) if (body[key] != null && !/^\d{4}$/.test(body[key])) return `invalid_${key}`;
  for (const [key, max] of [['merchant_name',200],['category_name',100]]) {
    if (body[key] != null && (typeof body[key] !== 'string' || !body[key].trim() || body[key].length > max)) return `invalid_${key}`;
  }
  if (body.reference != null && (typeof body.reference !== 'string' || !/^[A-Za-z0-9-]{6,40}$/.test(body.reference))) return 'invalid_reference';
  if (body.direction !== undefined && !['spend','refund'].includes(body.direction)) return 'invalid_direction';
  if (body.instrument != null && !['credit_card','debit_card','upi_bank','wallet','cash','other'].includes(body.instrument)) return 'invalid_instrument';
  if (body.valuation_status !== undefined && !['ignored','awaiting_amount'].includes(body.valuation_status)) return 'status_is_server_managed';
  if (body.expected_revision !== undefined && (!Number.isSafeInteger(body.expected_revision) || body.expected_revision < 1)) return 'invalid_expected_revision';
  if (body.billed_inr != null && !fx.inrAmount(body.billed_inr)) return 'invalid_billed_inr';
  if (body.confirmation_source != null && !['user','sms','statement'].includes(body.confirmation_source)) return 'invalid_confirmation_source';
  // Raw financial messages remain device-local, including in rejected requests.
  if (['body','sms_body','raw_sms','sender','raw_body'].some((key) => key in body)) return 'raw_sms_not_accepted';
  return null;
}
function serializePayment(row) {
  if (!row) return null;
  const result = {};
  for (const key of ['id','source_key',...COLUMNS,'revision','created_at','updated_at']) result[key] = row[key] ?? null;
  for (const key of ['original_amount','rate']) if (result[key] != null) result[key] = fx.canonicalDecimal(result[key]);
  for (const key of ['estimated_inr','billed_inr']) if (result[key] != null) result[key] = fx.inrAmount(result[key]);
  if (result.rate_date instanceof Date) result.rate_date = result.rate_date.toISOString().slice(0, 10);
  return result;
}
function valuationFor(record, referenceRate) {
  if (!record.original_currency || !record.original_amount) return { valuation_status: 'awaiting_amount', estimated_inr: null, rate: null, rate_date: null, rate_source: null };
  if (!referenceRate) return { valuation_status: 'awaiting_rate', estimated_inr: null, rate: null, rate_date: null, rate_source: null };
  const estimated = fx.convertToInr(record.original_amount, referenceRate.rate);
  return estimated ? { valuation_status: 'estimated', estimated_inr: estimated, ...referenceRate }
    : { valuation_status: 'awaiting_rate', estimated_inr: null, rate: null, rate_date: null, rate_source: null };
}
async function lockProfile(client, userId) {
  // Share the canonical ingest lock, so a statement and confirmation cannot
  // race to create two different ledger purchases.
  await client.query('SELECT pg_advisory_xact_lock(hashtextextended($1::text, 0))', [`transaction-ingest:${userId}`]);
}
async function validateOwnedFields(client, userId, record) {
  if (record.user_card_id) {
    const card = await client.query('SELECT id,last4 FROM user_cards WHERE profile_id=$1 AND id=$2', [userId,record.user_card_id]);
    if (!card.rows[0]) fail('user_card_not_found',404);
    if (record.card_last4 && card.rows[0].last4 && record.card_last4 !== String(card.rows[0].last4).trim()) fail('card_evidence_conflict',409);
  }
  if (record.category_id) {
    const category = await client.query('SELECT id,name FROM spend_categories WHERE id=$1', [record.category_id]);
    if (!category.rows[0]) fail('category_not_found',404);
    record.category_name=category.rows[0].name;
  }
  if (record.user_category_id) {
    const category = await client.query('SELECT id,name FROM user_categories WHERE profile_id=$1 AND id=$2 AND archived_at IS NULL', [userId,record.user_category_id]);
    if (!category.rows[0]) fail('user_category_not_found',404);
    record.category_name=category.rows[0].name;
  }
  if (record.refund_of_id) {
    if (record.direction !== 'refund' || record.refund_of_id === record.id) fail('invalid_refund_link');
    const parent = await client.query('SELECT id FROM foreign_payments WHERE profile_id=$1 AND id=$2 AND direction=\'spend\'', [userId,record.refund_of_id]);
    if (!parent.rows[0]) fail('original_foreign_payment_not_found',404);
  }
}
async function loadPayment(client,userId,id,{forUpdate=true}={}) {
  const result = await client.query(`SELECT * FROM foreign_payments WHERE profile_id=$1 AND id=$2${forUpdate ? ' FOR UPDATE' : ''}`, [userId,id]);
  return result.rows[0] || null;
}
async function sourcePayment(client,userId,key) {
  const result = await client.query(
    `SELECT p.* FROM foreign_payments p WHERE p.profile_id=$1 AND p.id=COALESCE(
       (SELECT foreign_payment_id FROM foreign_payment_sources WHERE profile_id=$1 AND source_key=$2),
       (SELECT id FROM foreign_payments WHERE profile_id=$1 AND source_key=$2)) FOR UPDATE`, [userId,key]);
  return result.rows[0] || null;
}
async function addSourceAlias(client,userId,id,key) {
  if (!HASH.test(key || '')) return;
  await client.query('INSERT INTO foreign_payment_sources(profile_id,source_key,foreign_payment_id) VALUES($1,$2,$3) ON CONFLICT(profile_id,source_key) DO UPDATE SET foreign_payment_id=EXCLUDED.foreign_payment_id', [userId,key,id]);
}
async function writeEvent(client,userId,kind,before,after) {
  await client.query('INSERT INTO foreign_payment_events(profile_id,foreign_payment_id,event_kind,previous_state,next_state) VALUES($1,$2,$3,$4::jsonb,$5::jsonb)',
    [userId,after.id,kind,before ? JSON.stringify(serializePayment(before)) : null,JSON.stringify(serializePayment(after))]);
}
async function updatePayment(client,userId,before,patch,kind) {
  const keys = Object.keys(patch).filter((key) => COLUMNS.includes(key));
  const result = await client.query(
    `UPDATE foreign_payments SET ${keys.map((key,index)=>`${key}=$${index+3}`).join(',')},revision=revision+1,updated_at=now()
     WHERE profile_id=$1 AND id=$2 RETURNING *`, [userId,before.id,...keys.map((key)=>patch[key])]);
  const row = result.rows[0];
  await writeEvent(client,userId,kind,before,row);
  return row;
}
function normalizeInput(body) {
  const result = {};
  for (const key of EDITABLE) if (body[key] !== undefined) result[key] = typeof body[key] === 'string' ? body[key].trim() : body[key];
  if (result.occurred_at instanceof Date) result.occurred_at=result.occurred_at.toISOString();
  if (result.original_amount != null) result.original_amount = fx.originalAmount(result.original_amount, result.original_currency || null);
  if (result.reference) result.reference = result.reference.toUpperCase();
  return result;
}
async function transactionCandidates(client,userId,record) {
  const sources = await client.query('SELECT source_key FROM foreign_payment_sources WHERE profile_id=$1 AND foreign_payment_id=$2', [userId,record.id]);
  const sourceKeys = [...new Set([record.source_key,...sources.rows.map((r)=>r.source_key)])];
  const result = await client.query(
    `SELECT t.*,uc.last4 AS card_last4,
       ARRAY(SELECT DISTINCT o.source_key FROM transaction_observations o WHERE o.profile_id=t.profile_id AND o.transaction_id=t.id AND o.source_key IS NOT NULL) AS source_keys,
       ARRAY(SELECT DISTINCT upper(replace(COALESCE(o.external_ref,o.metadata->>'bankReference'),'-','')) FROM transaction_observations o WHERE o.profile_id=t.profile_id AND o.transaction_id=t.id AND COALESCE(o.external_ref,o.metadata->>'bankReference') IS NOT NULL) AS bank_references
     FROM transactions t LEFT JOIN user_cards uc ON uc.id=t.user_card_id AND uc.profile_id=t.profile_id
     WHERE t.profile_id=$1 AND t.status='active'
       AND (t.source_key=ANY($2::text[]) OR EXISTS(SELECT 1 FROM transaction_observations o WHERE o.profile_id=$1 AND o.transaction_id=t.id AND o.source_key=ANY($2::text[]))
         OR ($3::text IS NOT NULL AND EXISTS(SELECT 1 FROM transaction_observations o WHERE o.profile_id=$1 AND o.transaction_id=t.id AND upper(replace(COALESCE(o.external_ref,o.metadata->>'bankReference'),'-',''))=$3)))
     ORDER BY t.occurred_at DESC LIMIT 20`, [userId,sourceKeys,record.reference?.replace(/-/g,'') || null]);
  return result.rows.filter((row)=>safeAutomaticMatch(record,row,sourceKeys));
}
function safeAutomaticMatch(payment,transaction,sourceKeys=[payment.source_key]) {
  if (transaction.status !== 'active' || !fx.inrAmount(transaction.amount_inr)) return false;
  if (payment.direction === 'refund' ? transaction.entry_kind !== 'transfer' : transaction.entry_kind !== 'spend') return false;
  if (payment.user_card_id && transaction.user_card_id && payment.user_card_id !== transaction.user_card_id) return false;
  if (payment.card_last4 && transaction.card_last4 && payment.card_last4 !== String(transaction.card_last4).trim()) return false;
  if (payment.account_last4 && transaction.source_account_last4 && payment.account_last4 !== transaction.source_account_last4) return false;
  if (payment.billed_inr && fx.inrAmount(payment.billed_inr) !== fx.inrAmount(transaction.amount_inr)) return false;
  const exactSource = sourceKeys.includes(transaction.source_key) || (transaction.source_keys || []).some((key)=>sourceKeys.includes(key));
  // A legacy parser may already have saved the INR credit limit under this
  // exact SMS key. Source identity alone does not prove its amount.
  if (exactSource && payment.billed_inr) return true;
  const ref = payment.reference?.replace(/-/g,'').toUpperCase();
  const exactReference = ref && (transaction.bank_references || []).includes(ref);
  // Four digits and a merchant/date are not a globally unique bank identity.
  return Boolean(exactReference && payment.user_card_id && payment.user_card_id === transaction.user_card_id
    && Math.abs(Date.parse(payment.occurred_at)-Date.parse(transaction.occurred_at)) <= 7*86400000);
}
async function attachTransaction(client,userId,payment,transaction,source,{userModified=false}={}) {
  if (payment.transaction_id) {
    if (payment.transaction_id !== transaction.id || fx.inrAmount(payment.billed_inr) !== fx.inrAmount(transaction.amount_inr)) fail('confirmation_conflict',409);
    return payment;
  }
  const linked = await client.query('SELECT * FROM foreign_payments WHERE profile_id=$1 AND transaction_id=$2 FOR UPDATE',[userId,transaction.id]);
  if (linked.rows[0] && linked.rows[0].id !== payment.id) {
    // Preserve the reviewed/confirmed row. Suppress the second pending
    // observation and retain its source alias on the single purchase.
    const existing=linked.rows[0];
    await addSourceAlias(client,userId,existing.id,payment.source_key);
    await updatePayment(client,userId,payment,{valuation_status:'ignored'},'reconciled');
    return existing;
  }
  return updatePayment(client,userId,payment,{valuation_status:'confirmed',billed_inr:fx.inrAmount(transaction.amount_inr),transaction_id:transaction.id,confirmation_source:source,user_modified:payment.user_modified || userModified},'confirmed');
}
async function reconcilePayment(client,userId,payment) {
  if (['ignored','confirmed'].includes(payment.valuation_status)) return { payment, reconciliation_status: payment.valuation_status };
  const candidates = await transactionCandidates(client,userId,payment);
  if (candidates.length !== 1) return { payment,reconciliation_status:candidates.length ? 'ambiguous' : 'no_match',candidate_count:candidates.length };
  const transaction = candidates[0];
  const source = transaction.source === 'statement' ? 'statement' : 'sms';
  return { payment:await attachTransaction(client,userId,payment,transaction,source),reconciliation_status:'matched' };
}
async function upsertForeignPayment(client,userId,body,{referenceRate=null}={}) {
  const error=validateInput(body);if(error)fail(error);
  await lockProfile(client,userId);
  let existing=await sourcePayment(client,userId,body.source_key);
  if (existing) {
    // Device backfills/replays cannot overwrite a user's correction, dismissal,
    // frozen estimate or settlement. Explicit PATCH is the correction path.
    if (!existing.user_modified && !['ignored','confirmed'].includes(existing.valuation_status)
        && body.confirmation_source==='sms' && body.billed_inr && !existing.billed_inr) {
      existing=await updatePayment(client,userId,existing,{billed_inr:fx.inrAmount(body.billed_inr)},'edited');
    }
    if (existing.user_modified || ['ignored','confirmed','estimated'].includes(existing.valuation_status)) return (await reconcilePayment(client,userId,existing)).payment;
    const merged={...existing,...Object.fromEntries(Object.entries(normalizeInput(body)).filter(([,v])=>v!=null))};
    await validateOwnedFields(client,userId,merged);
    existing=await updatePayment(client,userId,existing,{...normalizeInput(merged),...valuationFor(merged,referenceRate)},'edited');
  } else {
    const record={...normalizeInput(body),source_key:body.source_key,direction:body.direction || 'spend',
      ...(body.billed_inr && body.confirmation_source === 'sms'
        ? { billed_inr: fx.inrAmount(body.billed_inr) } : {})};
    await validateOwnedFields(client,userId,record);
    const values={...record,...valuationFor(record,referenceRate),user_modified:false};
    const keys=['profile_id','source_key',...COLUMNS.filter((key)=>values[key]!==undefined)];
    const result=await client.query(`INSERT INTO foreign_payments(${keys.join(',')}) VALUES(${keys.map((_,i)=>`$${i+1}`).join(',')}) RETURNING *`,[userId,body.source_key,...keys.slice(2).map((key)=>values[key])]);
    existing=result.rows[0];
    await addSourceAlias(client,userId,existing.id,body.source_key);
    await writeEvent(client,userId,'created',null,existing);
  }
  return (await reconcilePayment(client,userId,existing)).payment;
}
async function patchForeignPayment(client,userId,id,body,{referenceRate=null}={}) {
  const error=validateInput(body,{partial:true});if(error)fail(error);
  await lockProfile(client,userId);
  const before=await loadPayment(client,userId,id);if(!before)fail('foreign_payment_not_found',404);
  if (body.expected_revision!==undefined && body.expected_revision!==before.revision) fail('revision_conflict',409);
  if (before.valuation_status==='confirmed') fail('edit_confirmed_transaction_in_ledger',409);
  const merged={...before,...normalizeInput(body)};
  const finalError=validateInput({...merged,valuation_status:undefined});if(finalError)fail(finalError);
  await validateOwnedFields(client,userId,merged);
  const originalsChanged=['original_currency','original_amount','occurred_at'].some((key)=>body[key]!==undefined && String(body[key])!==String(before[key]));
  const valuation=body.valuation_status==='ignored' ? {valuation_status:'ignored'}
    : originalsChanged || before.valuation_status==='ignored' ? valuationFor(merged,referenceRate)
      : before.valuation_status==='awaiting_rate' && referenceRate ? valuationFor(merged,referenceRate) : {};
  return updatePayment(client,userId,before,{...normalizeInput(body),
    ...((body.category_id!==undefined || body.user_category_id!==undefined) ? {category_name:merged.category_name||null} : {}),
    ...valuation,user_modified:true},body.valuation_status==='ignored'?'ignored':before.valuation_status==='ignored'?'restored':'edited');
}
async function confirmForeignPayment(client,userId,id,body,{insertTransactionAndUpdateState}={}) {
  if(!object(body)||!fx.inrAmount(body.billed_inr))fail('invalid_billed_inr');
  if (body.transaction_id!=null&&!UUID.test(body.transaction_id))fail('invalid_transaction_id');
  if (body.user_card_id!=null&&!UUID.test(body.user_card_id))fail('invalid_user_card_id');
  const source=body.confirmation_source||'user';
  if(!['user','sms','statement'].includes(source))fail('invalid_confirmation_source');
  await lockProfile(client,userId);
  let record=await loadPayment(client,userId,id);if(!record)fail('foreign_payment_not_found',404);
  const billed=fx.inrAmount(body.billed_inr);
  if(record.valuation_status==='confirmed') {
    if(fx.inrAmount(record.billed_inr)!==billed || (body.transaction_id&&body.transaction_id!==record.transaction_id))fail('confirmation_conflict',409);
    return record;
  }
  if(record.valuation_status==='ignored')fail('restore_payment_before_confirming',409);
  if (body.user_card_id && record.user_card_id && body.user_card_id!==record.user_card_id) fail('card_evidence_conflict',409);
  record={...record,user_card_id:body.user_card_id||record.user_card_id,billed_inr:billed};
  await validateOwnedFields(client,userId,record);
  let transaction;
  if(body.transaction_id) {
    const result=await client.query('SELECT t.*,uc.last4 AS card_last4 FROM transactions t LEFT JOIN user_cards uc ON uc.id=t.user_card_id AND uc.profile_id=t.profile_id WHERE t.profile_id=$1 AND t.id=$2 FOR UPDATE OF t',[userId,body.transaction_id]);
    transaction=result.rows[0];
    if(!transaction||transaction.status!=='active')fail('transaction_not_found',404);
    if(fx.inrAmount(transaction.amount_inr)!==billed)fail('billed_amount_conflict',409);
    if(record.direction==='refund' ? transaction.entry_kind!=='transfer' : transaction.entry_kind!=='spend')fail('transaction_direction_conflict',409);
    if(record.user_card_id && transaction.user_card_id && record.user_card_id!==transaction.user_card_id)fail('card_evidence_conflict',409);
    if(source!=='user') {
      const candidates=await transactionCandidates(client,userId,record);
      if(!candidates.some((row)=>row.id===transaction.id))fail('settlement_evidence_required',409);
    }
  } else {
    const candidates=await transactionCandidates(client,userId,record);
    if(candidates.length>1)fail('ambiguous_settlement',409);
    transaction=candidates[0];
    if(!transaction) {
      // Automatic confirmation cannot invent bank evidence. A typed SMS must
      // first materialize its evidenced INR posting through the normal writer.
      if(source!=='user')fail('settlement_evidence_required',409);
      if(typeof insertTransactionAndUpdateState!=='function')throw new Error('canonical_transaction_writer_required');
      let instrument=record.instrument || (record.account_last4?'upi_bank':'other');
      if(record.user_card_id) {
        const selected=await client.query('SELECT cp.card_type FROM user_cards uc JOIN card_products cp ON cp.id=uc.card_product_id WHERE uc.profile_id=$1 AND uc.id=$2',[userId,record.user_card_id]);
        instrument=selected.rows[0]?.card_type==='credit'?'credit_card':selected.rows[0]?.card_type==='debit'?'debit_card':instrument;
      }
      const outcome=await insertTransactionAndUpdateState(client,userId,{
        userCardId:record.user_card_id||null,amount:Number(billed),occurred:new Date(record.occurred_at),
        categoryId:record.category_id||null,userCategoryId:record.user_category_id||null,
        instrument,
        entryKind:record.direction==='refund'?'transfer':'spend',rail:'unknown',merchantName:record.merchant_name||null,
        source:'manual',sourceKey:crypto.createHash('sha256').update(`${userId}:foreign-billed:${record.id}`).digest('hex'),
        backfill:Date.now()-Date.parse(record.occurred_at)>86400000,accountLast4:record.account_last4||null,
        observationMetadata:{foreignPaymentId:record.id,originalCurrency:record.original_currency,originalAmount:record.original_amount,direction:record.direction,refundOfId:record.refund_of_id||null,bankReference:record.reference||null,billedInrSource:'user'},
      });
      if(![200,201].includes(outcome?.status)||!outcome.transaction||outcome.transaction.status!=='active')fail('settlement_requires_duplicate_review',409);
      if(fx.inrAmount(outcome.transaction.amount_inr)!==billed)fail('billed_amount_conflict',409);
      transaction=outcome.transaction;
    }
  }
  // Persist an optional selected card in the same transaction as confirmation.
  const current=await loadPayment(client,userId,id);
  if(record.user_card_id!==current.user_card_id) record=await updatePayment(client,userId,current,{user_card_id:record.user_card_id,user_modified:true},'edited');
  else record=current;
  return attachTransaction(client,userId,record,transaction,source,{userModified:source==='user'});
}

/** Used inside the statement import's existing transaction. Explicit original
 * fields create a foreign sidecar; otherwise only an exact reference/account
 * match may reconcile an existing pending payment. No price-based matching. */
async function reconcileStatementForeignPayment(client,userId,evidence) {
  if(!evidence?.transactionId || !fx.inrAmount(evidence.billedInr))return null;
  await lockProfile(client,userId);
  const transaction={id:evidence.transactionId,amount_inr:evidence.billedInr,status:'active',entry_kind:evidence.entryKind||'spend',user_card_id:evidence.userCardId||null,source:'statement',source_key:evidence.sourceKey,occurred_at:evidence.occurredAt,bank_references:evidence.bankReference?[String(evidence.bankReference).replace(/-/g,'').toUpperCase()]:[]};
  const known=await client.query('SELECT * FROM foreign_payments WHERE profile_id=$1 AND transaction_id=$2 FOR UPDATE',[userId,evidence.transactionId]);
  if(known.rows[0])return known.rows[0];
  let pending=[];
  if(evidence.foreignSourceKey&&HASH.test(evidence.foreignSourceKey)) {
    const direct=await sourcePayment(client,userId,evidence.foreignSourceKey);
    const sameOriginal=direct && evidence.originalCurrency===direct.original_currency
      && fx.originalAmount(evidence.originalAmount,evidence.originalCurrency)===fx.originalAmount(direct.original_amount,direct.original_currency);
    // An import's claimed SMS source commitment is only a proposed link.
    // Require the same saved card, original amount/currency and nearby date.
    if(direct && sameOriginal && evidence.userCardId && evidence.userCardId===direct.user_card_id
       && Math.abs(Date.parse(evidence.occurredAt)-Date.parse(direct.occurred_at))<=7*86400000)pending=[direct];
  }
  if(!pending.length && evidence.bankReference && evidence.userCardId) {
    const found=await client.query("SELECT * FROM foreign_payments WHERE profile_id=$1 AND valuation_status NOT IN ('confirmed','ignored') AND upper(replace(reference,'-',''))=$2 AND user_card_id=$3 FOR UPDATE",[userId,String(evidence.bankReference).replace(/-/g,'').toUpperCase(),evidence.userCardId]);
    pending=found.rows.filter((row)=>safeAutomaticMatch(row,transaction,[row.source_key])
      && (!evidence.originalCurrency || evidence.originalCurrency===row.original_currency)
      && (evidence.originalAmount==null || fx.originalAmount(evidence.originalAmount,evidence.originalCurrency||row.original_currency)===fx.originalAmount(row.original_amount,row.original_currency)));
  }
  if(pending.length===1) {
    if(evidence.sourceKey)await addSourceAlias(client,userId,pending[0].id,evidence.sourceKey);
    return attachTransaction(client,userId,pending[0],transaction,'statement');
  }
  if(pending.length>1)return null;
  if(!evidence.originalCurrency || !fx.originalAmount(evidence.originalAmount,evidence.originalCurrency))return null;
  // A rejected claimed alias must not bypass the strict identity checks by
  // falling through into creation under another payment's SMS commitment.
  const key=evidence.sourceKey;
  if(!HASH.test(key||''))return null;
  let record=await upsertForeignPayment(client,userId,{source_key:key,original_currency:evidence.originalCurrency,original_amount:evidence.originalAmount,occurred_at:new Date(evidence.occurredAt).toISOString(),merchant_name:evidence.merchantName||null,user_card_id:evidence.userCardId||null,card_last4:evidence.cardLast4||null,account_last4:evidence.accountLast4||null,reference:evidence.bankReference||null,direction:evidence.entryKind==='transfer'?'refund':'spend'});
  if(record.valuation_status==='ignored')return record;
  return attachTransaction(client,userId,record,transaction,'statement');
}

module.exports={UUID,HASH,STATUSES,ForeignPaymentError,validateInput,serializePayment,valuationFor,normalizeInput,safeAutomaticMatch,upsertForeignPayment,patchForeignPayment,confirmForeignPayment,reconcilePayment,reconcileStatementForeignPayment,loadPayment,updatePayment,lockProfile};
