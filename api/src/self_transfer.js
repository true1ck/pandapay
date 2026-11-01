// Personal, explicitly confirmed relationships. Never a shared parser rule.
function senderFamily(sender) {
  const family = String(sender || '').trim().toLowerCase()
    .replace(/^[a-z0-9]{2}-/, '').replace(/-[a-z]$/, '');
  return ({ hdfcbk: 'hdfc', canbnk: 'canara', canbk: 'canara', kotakb: 'kotak',
    icicib: 'icici', unionb: 'union', axisbnk: 'axis', axisb: 'axis',
    sbibnk: 'sbi', sbibk: 'sbi', idbibk: 'idbi', yesbnk: 'yes',
    yesbank: 'yes', ucob: 'uco', eqt: 'equitas', pytm: 'paytm' })[family] || family;
}

function transferIdentity(sender, fields) {
  if (!fields || fields.instrument !== 'upi_bank' || fields.entryKind !== 'spend'
      || !/^\d{4}$/.test(fields.accountLast4 || '') || !fields.transferParty) return null;
  return {
    sourceSender: senderFamily(sender),
    sourceAccountLast4: fields.accountLast4,
    party: fields.transferParty.trim().replace(/\s+/g, ' ').toLowerCase(),
  };
}

function selfTransferLabel(destination) {
  const bank = ({ slcbnk: 'Slice', hdfc: 'HDFC Bank', canara: 'Canara Bank',
    kotak: 'Kotak Bank', union: 'Union Bank', axis: 'Axis Bank', icici: 'ICICI Bank',
    sbi: 'SBI', idbi: 'IDBI Bank', yes: 'Yes Bank', equitas: 'Equitas Bank',
    paytm: 'Paytm Bank' })[destination.bank] || destination.bank.toUpperCase();
  return `Self-transfer to ${bank} •${destination.accountLast4}`;
}

function applySelfTransferRule(parsed, sender, rules) {
  const identity = parsed.ok && transferIdentity(sender, parsed.fields);
  if (!identity) return parsed;
  const matching = rules.filter(rule => rule.sourceSender === identity.sourceSender
    && rule.sourceAccountLast4 === identity.sourceAccountLast4 && rule.party === identity.party);
  const destinations = new Set(matching.map(rule => JSON.stringify(rule.destination)));
  if (destinations.size !== 1) return parsed; // conflicting confirmations require review
  const destination = matching[0].destination;
  if (!destination || !/^\d{4}$/.test(destination.accountLast4 || '')
      || !/^[a-z0-9]{2,30}$/.test(destination.bank || '')) return parsed;
  if (parsed.fields.destinationAccountLast4
      && parsed.fields.destinationAccountLast4 !== destination.accountLast4) return parsed;
  return { ...parsed, fields: { ...parsed.fields, entryKind: 'transfer',
    transferKind: 'account_to_account', destinationAccountLast4: destination.accountLast4,
    transferSubtype: 'self_transfer',
    selfTransferRule: { ...identity, destination },
    merchant: selfTransferLabel(destination) } };
}

async function confirmedSelfTransferRules(client, userId) {
  // Checking the catalog first keeps a missing migration from aborting the
  // caller's PostgreSQL transaction. Catching undefined_table cannot do that.
  const available = await client.query("SELECT to_regclass('public.self_transfer_rules') AS relation");
  if (!available.rows[0]?.relation) return [];
    const result = await client.query(
      `SELECT source_sender AS "sourceSender",
              source_account_last4 AS "sourceAccountLast4",
              transfer_party AS party,
              jsonb_build_object('bank', destination_bank,
                                 'accountLast4', destination_account_last4) AS destination
         FROM self_transfer_rules
        WHERE profile_id=$1 AND is_active=true`, [userId]);
    // Once the table exists it is the authoritative lifecycle store. An empty
    // result is meaningful: a user may have explicitly disabled a relationship.
    return result.rows;
}

async function saveSelfTransferRule(client, userId, rule) {
  const identity = rule;
  const destination = rule && rule.destination;
  if (!identity?.sourceSender || !identity.sourceAccountLast4 || !identity.party || !destination) {
    throw new Error('Invalid self-transfer relationship');
  }
  await client.query(
    `INSERT INTO self_transfer_rules
       (profile_id, source_sender, source_account_last4, transfer_party,
        destination_bank, destination_account_last4, is_active, version)
     VALUES ($1,$2,$3,$4,$5,$6,true,1)
     ON CONFLICT (profile_id, source_sender, source_account_last4,
                  transfer_party, destination_bank, destination_account_last4)
     DO UPDATE SET is_active=true, version=self_transfer_rules.version+1,
                   updated_at=now()`,
    [userId, identity.sourceSender, identity.sourceAccountLast4, identity.party,
      destination.bank, destination.accountLast4]);
}

async function disableSelfTransferRule(client, userId, rule) {
  if (!rule || !rule.sourceSender || !rule.sourceAccountLast4 || !rule.party
      || !rule.destination) return;
  await client.query(
    `UPDATE self_transfer_rules
        SET is_active=false, version=version+1, updated_at=now()
      WHERE profile_id=$1 AND source_sender=$2 AND source_account_last4=$3
        AND transfer_party=$4 AND destination_bank=$5
        AND destination_account_last4=$6`,
    [userId, rule.sourceSender, rule.sourceAccountLast4, rule.party,
      rule.destination.bank, rule.destination.accountLast4]);
}

async function applySelfTransferRuleHistorically(
  client,
  userId,
  rule,
  excludeTransactionId = null,
  remembered = true,
) {
  const identity = rule;
  const destination = rule && rule.destination;
  if (!identity?.sourceSender || !identity.sourceAccountLast4 || !identity.party || !destination) {
    throw new Error('Invalid self-transfer relationship');
  }
  const result = await client.query(
    `SELECT t.id, o.metadata
       FROM transactions t
       JOIN transaction_observations o
         ON o.transaction_id=t.id AND o.profile_id=t.profile_id
      WHERE t.profile_id=$1
        AND t.entry_kind='spend'
        AND t.instrument='upi_bank'
        AND o.source IN ('sms','sms_bulk')
        AND o.metadata->>'accountLast4'=$2
      ORDER BY t.occurred_at, t.id`,
    [userId, identity.sourceAccountLast4],
  );
  const metadata = JSON.stringify({
    selfTransferRule: identity,
    selfTransferRemembered: remembered,
    transferSubtype: 'self_transfer',
    classificationLocked: true,
    classificationSource: 'remembered_self_transfer',
    classificationEvidenceVersion: 1,
  });
  let applied = 0;
  for (const row of result.rows) {
    if (excludeTransactionId && row.id === excludeTransactionId) continue;
    const evidence = row.metadata || {};
    if (evidence.classificationLocked === true && evidence.transferSubtype !== 'self_transfer') continue;
    const candidateIdentity = transferIdentity(evidence.senderBank, {
      ...evidence, instrument: 'upi_bank', entryKind: 'spend',
    });
    if (!candidateIdentity
        || candidateIdentity.sourceSender !== identity.sourceSender
        || candidateIdentity.sourceAccountLast4 !== identity.sourceAccountLast4
        || candidateIdentity.party !== identity.party
        || (evidence.destinationAccountLast4
            && evidence.destinationAccountLast4 !== destination.accountLast4)) continue;
    const updated = await client.query(
      `UPDATE transactions
          SET entry_kind='transfer', merchant_name=$3
        WHERE id=$1 AND profile_id=$2 AND entry_kind='spend'
        RETURNING id`,
      [row.id, userId, selfTransferLabel(destination)],
    );
    if (updated.rowCount !== 1) continue;
    await client.query(
      `UPDATE transaction_observations
          SET metadata = metadata || $3::jsonb
        WHERE profile_id=$1 AND transaction_id=$2`,
      [userId, row.id, metadata],
    );
    applied += 1;
  }
  return applied;
}

async function confirmSelfTransfer(client, userId, transactionId, destination) {
  if (!destination || typeof destination !== 'object'
      || !/^\d{4}$/.test(destination.accountLast4 || '')
      || !/^[a-z0-9]{2,30}$/.test(destination.bank || '')) {
    throw new Error('Choose a valid destination bank account');
  }
  // All evidence is profile-scoped. No caller-supplied source/beneficiary is trusted.
  const result = await client.query(
    `SELECT transaction_id, metadata FROM transaction_observations
      WHERE profile_id=$1 AND source IN ('sms','sms_bulk')
        AND (transaction_id=$2 OR metadata->>'accountLast4'=$3)
      ORDER BY observed_at DESC`, [userId, transactionId, destination.accountLast4]);
  const source = result.rows.find(row => row.transaction_id === transactionId
    && row.metadata?.isBankAccount === true && row.metadata?.transferParty);
  const dest = result.rows.find(row => row.metadata?.isBankAccount === true
    && row.metadata.accountLast4 === destination.accountLast4
    && senderFamily(row.metadata.senderBank) === destination.bank);
  const identity = source && transferIdentity(source.metadata.senderBank, {
    ...source.metadata, instrument: 'upi_bank', entryKind: 'spend',
  });
  if (!identity) throw new Error('This SMS does not identify a bank-transfer source and recipient');
  if (!dest || (identity.sourceAccountLast4 === destination.accountLast4
      && identity.sourceSender === destination.bank)) {
    throw new Error('Choose a different destination bank account from your accounts');
  }
  return { ...identity, destination: { bank: destination.bank, accountLast4: destination.accountLast4 } };
}

module.exports = {
  senderFamily, transferIdentity, selfTransferLabel, applySelfTransferRule,
  confirmedSelfTransferRules, confirmSelfTransfer, saveSelfTransferRule,
  disableSelfTransferRule, applySelfTransferRuleHistorically,
};
