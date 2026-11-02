// A cached pattern derived from ignored transactions is not ongoing charge
// evidence. Explicit subscriptions, mandates and user corrections survive.
function filterCurrentRecurringRows(rows, detected) {
  const keys=new Set(detected.map((row)=>row.merchantKey));
  return rows.filter((row)=>row.detection_source!=='observed' || row.user_edited || keys.has(row.merchant_key));
}
module.exports={filterCurrentRecurringRows};
