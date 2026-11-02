'use strict';

const payments = require('./foreign_payments');
const fx = require('./foreign_exchange');
const { safeErrorCode } = require('./safeErrorCode');
const MAX_LIMIT=200;
function periodValue(value) {
  if(value===undefined)return null;
  if(typeof value!=='string')return undefined;
  if(fx.calendarDay(value))return `${value}T00:00:00+05:30`;
  return /^\d{4}-\d{2}-\d{2}T/.test(value)&&Number.isFinite(Date.parse(value))?new Date(value).toISOString():undefined;
}
function parseListQuery(query={}) {
  const limit=query.limit===undefined?100:Number(query.limit);
  if(!Number.isInteger(limit)||limit<1||limit>MAX_LIMIT)return null;
  const from=periodValue(query.from),to=periodValue(query.to);
  if(from===undefined||to===undefined||(from&&to&&Date.parse(from)>=Date.parse(to)))return null;
  let cursor=null;
  if(query.cursor!==undefined) {
    if(typeof query.cursor!=='string'||query.cursor.length>160)return null;
    try {
      cursor=JSON.parse(Buffer.from(query.cursor,'base64url').toString('utf8'));
      if(!Array.isArray(cursor)||cursor.length!==2||!Number.isFinite(Date.parse(cursor[0]))||!payments.UUID.test(cursor[1]))return null;
    }catch(_){return null;}
  }
  return {limit,from,to,cursor,includeIgnored:query.include_ignored==='true'};
}
function cursorFor(row) {return Buffer.from(JSON.stringify([new Date(row.occurred_at).toISOString(),row.id])).toString('base64url');}
function summarize(rows) {
  let estimated=0n,estimatedRefund=0n,confirmed=0n,confirmedRefund=0n;
  let pending=0,unknown=0,awaitingRate=0,estimatedCount=0;
  for(const row of rows) {
    if(row.valuation_status==='ignored')continue;
    const refund=row.direction==='refund';
    if(row.valuation_status==='confirmed') {
      if(refund)confirmedRefund+=fx.inrMinor(row.billed_inr)||0n;else confirmed+=fx.inrMinor(row.billed_inr)||0n;
    } else {
      pending++;
      if(row.valuation_status==='awaiting_amount')unknown++;
      if(row.valuation_status==='awaiting_rate')awaitingRate++;
      if(row.valuation_status==='estimated') {
        estimatedCount++;
        if(refund)estimatedRefund+=fx.inrMinor(row.estimated_inr)||0n;else estimated+=fx.inrMinor(row.estimated_inr)||0n;
      }
    }
  }
  return {pending_count:pending,unknown_amount_count:unknown,awaiting_rate_count:awaitingRate,estimated_count:estimatedCount,
    estimated_inr:fx.minorToInr(estimated),estimated_refund_inr:fx.minorToInr(estimatedRefund),estimated_net_inr:fx.minorToInr(estimated-estimatedRefund),
    confirmed_inr:fx.minorToInr(confirmed),confirmed_refund_inr:fx.minorToInr(confirmedRefund),confirmed_net_inr:fx.minorToInr(confirmed-confirmedRefund)};
}
function summaryFromAggregate(row={}) {
  return {pending_count:Number(row.pending_count||0),unknown_amount_count:Number(row.unknown_amount_count||0),awaiting_rate_count:Number(row.awaiting_rate_count||0),estimated_count:Number(row.estimated_count||0),
    estimated_inr:String(row.estimated_inr||'0.00'),estimated_refund_inr:String(row.estimated_refund_inr||'0.00'),estimated_net_inr:String(row.estimated_net_inr||'0.00'),
    confirmed_inr:String(row.confirmed_inr||'0.00'),confirmed_refund_inr:String(row.confirmed_refund_inr||'0.00'),confirmed_net_inr:String(row.confirmed_net_inr||'0.00')};
}
function registerForeignPaymentRoutes(app,{requireAuth,withUserClient,insertTransactionAndUpdateState,exchangeService,logger=console}) {
  const exchange=exchangeService||fx.createForeignExchangeService({withUserClient});
  const errorResponse=(res,error)=>{
    if(error instanceof payments.ForeignPaymentError)return res.status(error.status).json({error:error.code});
    logger.error('foreign payment operation failed',safeErrorCode(error));
    return res.status(error?.code==='42P01'?503:500).json({error:error?.code==='42P01'?'foreign_payments_temporarily_unavailable':'foreign_payment_operation_failed'});
  };
  const referenceRate=async(userId,record)=>record?.original_currency&&record?.original_amount
    ? exchange.getRate(userId,record.original_currency,fx.accountingDay(record.occurred_at)):null;
  app.get('/foreign-payments',requireAuth,async(req,res)=>{
    const query=parseListQuery(req.query);if(!query)return res.status(400).json({error:'invalid_foreign_payment_query'});
    try {
      const result=await withUserClient(req.userId,async(client)=>{
        const rows=await client.query(
          `SELECT * FROM foreign_payments WHERE profile_id=$1 AND ($2::timestamptz IS NULL OR occurred_at >= $2)
           AND ($3::timestamptz IS NULL OR occurred_at < $3) AND ($4::boolean OR valuation_status<>'ignored')
           AND ($5::timestamptz IS NULL OR (occurred_at,id)<($5::timestamptz,$6::uuid)) ORDER BY occurred_at DESC,id DESC LIMIT $7`,
          [req.userId,query.from,query.to,query.includeIgnored,query.cursor?.[0]||null,query.cursor?.[1]||null,query.limit+1]);
        // The aggregate deliberately ignores pagination and is computed across
        // the requested accounting period, rather than only the current page.
        const aggregate=await client.query(
          `SELECT count(*) FILTER(WHERE valuation_status NOT IN ('confirmed','ignored')) AS pending_count,
           count(*) FILTER(WHERE valuation_status='awaiting_amount') AS unknown_amount_count,
           count(*) FILTER(WHERE valuation_status='awaiting_rate') AS awaiting_rate_count,
           count(*) FILTER(WHERE valuation_status='estimated') AS estimated_count,
           COALESCE(sum(estimated_inr) FILTER(WHERE valuation_status='estimated' AND direction='spend'),0)::text AS estimated_inr,
           COALESCE(sum(estimated_inr) FILTER(WHERE valuation_status='estimated' AND direction='refund'),0)::text AS estimated_refund_inr,
           COALESCE(sum(CASE WHEN direction='refund' THEN -estimated_inr ELSE estimated_inr END) FILTER(WHERE valuation_status='estimated'),0)::text AS estimated_net_inr,
           COALESCE(sum(billed_inr) FILTER(WHERE valuation_status='confirmed' AND direction='spend'),0)::text AS confirmed_inr,
           COALESCE(sum(billed_inr) FILTER(WHERE valuation_status='confirmed' AND direction='refund'),0)::text AS confirmed_refund_inr,
           COALESCE(sum(CASE WHEN direction='refund' THEN -billed_inr ELSE billed_inr END) FILTER(WHERE valuation_status='confirmed'),0)::text AS confirmed_net_inr
           FROM foreign_payments WHERE profile_id=$1 AND ($2::timestamptz IS NULL OR occurred_at >= $2) AND ($3::timestamptz IS NULL OR occurred_at < $3)`,
          [req.userId,query.from,query.to]);
        const page=rows.rows.slice(0,query.limit);
        return {items:page.map(payments.serializePayment),summary:summaryFromAggregate(aggregate.rows[0]),next_cursor:rows.rows.length>query.limit?cursorFor(page[page.length-1]):null};
      });
      res.set?.('Cache-Control','no-store');return res.json(result);
    }catch(error){return errorResponse(res,error);}
  });
  app.post('/foreign-payments',requireAuth,async(req,res)=>{
    const error=payments.validateInput(req.body);if(error)return res.status(400).json({error});
    try {
      const rate=await referenceRate(req.userId,req.body);
      const payment=await withUserClient(req.userId,async(client)=>{
        let record=await payments.upsertForeignPayment(client,req.userId,req.body,{referenceRate:rate});
        if(req.body.billed_inr && record.valuation_status!=='ignored' && req.body.confirmation_source==='user') {
          record=await payments.confirmForeignPayment(client,req.userId,record.id,req.body,{insertTransactionAndUpdateState});
        }
        return record;
      });
      return res.json({item:payments.serializePayment(payment)});
    }catch(error){return errorResponse(res,error);}
  });
  app.patch('/foreign-payments/:id',requireAuth,async(req,res)=>{
    if(!payments.UUID.test(req.params.id))return res.status(400).json({error:'invalid_foreign_payment_id'});
    const error=payments.validateInput(req.body,{partial:true});if(error)return res.status(400).json({error});
    try {
      const existing=await withUserClient(req.userId,(client)=>payments.loadPayment(client,req.userId,req.params.id,{forUpdate:false}));
      if(!existing)return res.status(404).json({error:'foreign_payment_not_found'});
      const merged={...existing,...req.body};
      const rate=req.body.valuation_status==='ignored'?null:await referenceRate(req.userId,merged);
      const payment=await withUserClient(req.userId,(client)=>payments.patchForeignPayment(client,req.userId,req.params.id,req.body,{referenceRate:rate}));
      return res.json({item:payments.serializePayment(payment)});
    }catch(error){return errorResponse(res,error);}
  });
  app.post('/foreign-payments/:id/confirm',requireAuth,async(req,res)=>{
    if(!payments.UUID.test(req.params.id))return res.status(400).json({error:'invalid_foreign_payment_id'});
    try {
      const payment=await withUserClient(req.userId,(client)=>payments.confirmForeignPayment(client,req.userId,req.params.id,req.body,{insertTransactionAndUpdateState}));
      return res.json({item:payments.serializePayment(payment)});
    }catch(error){return errorResponse(res,error);}
  });
  app.post('/foreign-payments/:id/reconcile',requireAuth,async(req,res)=>{
    if(!payments.UUID.test(req.params.id))return res.status(400).json({error:'invalid_foreign_payment_id'});
    try {
      const result=await withUserClient(req.userId,async(client)=>{
        await payments.lockProfile(client,req.userId);
        const payment=await payments.loadPayment(client,req.userId,req.params.id);
        if(!payment)throw new payments.ForeignPaymentError(404,'foreign_payment_not_found');
        return payments.reconcilePayment(client,req.userId,payment);
      });
      return res.json({...result,item:payments.serializePayment(result.payment),payment:undefined});
    }catch(error){return errorResponse(res,error);}
  });
  app.post('/foreign-payments/refresh',requireAuth,async(req,res)=>{
    try {
      const records=await withUserClient(req.userId,async(client)=>(await client.query("SELECT * FROM foreign_payments WHERE profile_id=$1 AND valuation_status IN ('awaiting_amount','awaiting_rate','estimated') ORDER BY last_refreshed_at ASC NULLS FIRST,updated_at ASC LIMIT 20",[req.userId])).rows);
      const items=[];
      const deadline=Date.now()+10000;
      for(const record of records) {
        if(Date.now()>=deadline)break;
        const rate=record.valuation_status==='estimated'?null:await referenceRate(req.userId,record);
        const updated=await withUserClient(req.userId,async(client)=>{
          await payments.lockProfile(client,req.userId);
          let current=await payments.loadPayment(client,req.userId,record.id);
          if(!current||['confirmed','ignored'].includes(current.valuation_status))return current;
          await client.query('UPDATE foreign_payments SET last_refreshed_at=now() WHERE profile_id=$1 AND id=$2',[req.userId,record.id]);
          if(current.valuation_status==='awaiting_rate'&&rate)current=await payments.updatePayment(client,req.userId,current,payments.valuationFor(current,rate),'estimated');
          return (await payments.reconcilePayment(client,req.userId,current)).payment;
        });
        if(updated)items.push(payments.serializePayment(updated));
      }
      return res.json({items});
    }catch(error){return errorResponse(res,error);}
  });
}
module.exports={MAX_LIMIT,parseListQuery,cursorFor,summarize,summaryFromAggregate,registerForeignPaymentRoutes};
