const SOURCES = new Set(['statement', 'screenshot', 'csv', 'xlsx', 'json']);
const RAILS = new Set(['upi_qr', 'swipe', 'online', 'contactless', 'atm', 'emi', 'unknown']);
const ENTRY_KINDS = new Set(['spend', 'income', 'investment', 'transfer']);
const INSTRUMENTS = new Set(['credit_card', 'debit_card', 'cash', 'upi_bank', 'wallet', 'other']);
function maskAccount(value) { return value?.replace(/\d{6,}/g, (digits) => `****${digits.slice(-4)}`) || null; }
const HASH = /^[a-f0-9]{64}$/i;
const UUID = /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i;
const { importTagNames } = require('./transaction_tags');

/**
 * Statement rows do not always carry a trustworthy type column. Apply the
 * same conservative movement rules used by SMS imports to the narration,
 * while preserving an explicit user/source classification when supplied.
 */
function inferStatementEntryKind(transaction) {
  if (ENTRY_KINDS.has(transaction?.entryKind)) return transaction.entryKind;
  const text = String(transaction?.merchantName || transaction?.description || '').toLowerCase();
  if (/\b(?:investment|mutual\s+fund|sip|stocks?|shares?|equity|redemption|sold\s+units?)\b/.test(text)) {
    return /\b(?:redemption|sold\s+units?|proceeds?)\b/.test(text) ? 'transfer' : 'investment';
  }
  if (/\b(?:interest\s+(?:charge|fee|on\s+(?:loan|emi))|(?:loan|emi)\s+interest|(?:processing|service|late|annual|maintenance|brokerage)\s+fee|bank\s+charge|finance\s+charge)\b/.test(text)) {
    return 'spend';
  }
  const nonIncomeMovement = /\b(?:refund(?:ed)?|chargeback|revers(?:al|ed)|cashback|reward|statement\s+credit|balance\s+adjustment|card\s+adjustment|gift|reimburse(?:ment|d)?|loan\s+(?:disbursement|credited)|salary\s+advance|cash\s+deposit|cash\s+withdrawal|wallet\s+(?:load|top[ -]?up)|top[ -]?up|self\s+transfer|own\s+account|transfer|credit\s+card\s+(?:bill\s+)?(?:payment|pmt)|card\s+bill\s+pay|loan\s+(?:payment|repayment)|emi)\b/.test(text);
  if (!nonIncomeMovement
      && /\b(?:salary|wages?|payroll|pension|interest\s+earned|dividend|rent\s+received|invoice\s+paid|business\s+(?:receipt|income))\b/.test(text)) {
    return 'income';
  }
  if (nonIncomeMovement) {
    return 'transfer';
  }
  return 'spend';
}

function calendarDate(value) {
  if (typeof value !== 'string') return false;
  const match = /^(\d{4})-(\d{2})-(\d{2})(?:$|T)/.exec(value);
  if (!match) return false;
  const [year, month, day] = match.slice(1).map(Number);
  if (year < 1900 || year > 2100 || month < 1 || month > 12 || day < 1) return false;
  return new Date(Date.UTC(year, month - 1, day)).getUTCDate() === day;
}

function timestamp(value) {
  if (!calendarDate(value)) return false;
  const time = /^\d{4}-\d{2}-\d{2}T(\d{2}):(\d{2}):(\d{2})(?:\.\d{1,6})?(?:Z|[+-]\d{2}:\d{2})$/.exec(value);
  return Boolean(time && Number(time[1]) < 24 && Number(time[2]) < 60 && Number(time[3]) < 60 && Number.isFinite(Date.parse(value)));
}

function money(value, { signed = false } = {}) {
  return typeof value === 'number' && Number.isFinite(value) && (signed || value >= 0)
    && Math.abs(value) <= 9999999999.99
    && /^-?\d+(?:\.\d{1,2})?$/.test(String(value));
}

function validateStatementImport(body) {
  if (!body || typeof body !== 'object' || Array.isArray(body)) return 'An import object is required';
  if (body.userCardId != null && (typeof body.userCardId !== 'string' || !UUID.test(body.userCardId))) return 'userCardId must be a card id or null';
  if (body.instrument != null && !INSTRUMENTS.has(body.instrument)) return 'instrument is invalid';
  if (!calendarDate(body.statementFrom) || !/^\d{4}-\d{2}-\d{2}$/.test(body.statementFrom)
      || !calendarDate(body.statementTo) || !/^\d{4}-\d{2}-\d{2}$/.test(body.statementTo)
      || body.statementFrom > body.statementTo) return 'Choose a valid statement date range';
  if (!SOURCES.has(body.importSource ?? 'statement')) return 'Unsupported import source';
  if (body.closingBalanceInr != null && !money(body.closingBalanceInr, { signed: true })) return 'closingBalanceInr is invalid';
  if (body.pointsPosted != null && (typeof body.pointsPosted !== 'number' || !Number.isFinite(body.pointsPosted))) return 'pointsPosted is invalid';
  if (body.issuerFormatId != null && (typeof body.issuerFormatId !== 'string' || body.issuerFormatId.length > 100)) return 'issuerFormatId is invalid';
  if (body.transactions === undefined) {
    if (!body.userCardId) return 'A card is required for a legacy summary-only import';
    for (const name of ['txnCount', 'reconciledCount']) {
      if (body[name] != null && (!Number.isInteger(body[name]) || body[name] < 0)) return `${name} must be a nonnegative integer`;
    }
    return null;
  }
  if (!Array.isArray(body.transactions) || body.transactions.length < 1 || body.transactions.length > 5000) return 'Choose between 1 and 5000 transactions per batch';
  if (typeof body.importKey !== 'string' || !HASH.test(body.importKey)) return 'A SHA-256 importKey is required';
  const keys = new Set();
  for (const [index, row] of body.transactions.entries()) {
    const prefix = `transactions[${index}]`;
    if (!row || typeof row !== 'object' || Array.isArray(row)) return `${prefix} must be an object`;
    if (row.tagNames != null && (!Array.isArray(row.tagNames) || row.tagNames.length > 30 || row.tagNames.some((name) => typeof name !== 'string' || !name.trim() || name.trim().length > 60))) return `${prefix}.tagNames is invalid`;
    if (row.entryKind != null && !ENTRY_KINDS.has(row.entryKind)) return `${prefix}.entryKind is invalid`;
    if (row.instrument != null && !INSTRUMENTS.has(row.instrument)) return `${prefix}.instrument is invalid`;
    if (!money(row.amountInr) || row.amountInr <= 0) return `${prefix}.amountInr must be positive INR with at most two decimals`;
    if (!timestamp(row.occurredAt)) return `${prefix}.occurredAt must be a valid ISO timestamp with timezone`;
    // The app's date range is in the device's accounting timezone. Allow the
    // full UTC-offset envelope rather than shifting date-only purchases a day.
    const time = Date.parse(row.occurredAt);
    if (time < Date.parse(body.statementFrom) - 14 * 3600000 || time >= Date.parse(body.statementTo) + 38 * 3600000) return `${prefix} falls outside the statement period`;
    if (row.merchantName != null && (typeof row.merchantName !== 'string' || !row.merchantName.trim() || row.merchantName.length > 500)) return `${prefix}.merchantName is invalid`;
    for (const field of ['categoryHint', 'subcategoryHint']) {
      if (row[field] != null && (typeof row[field] !== 'string' || row[field].length > 120)) return `${prefix}.${field} is invalid`;
    }
    for (const field of ['categoryId', 'userCategoryId']) {
      if (row[field] != null && (typeof row[field] !== 'string' || !UUID.test(row[field]))) return `${prefix}.${field} is invalid`;
    }
    if (row.note != null && (typeof row.note !== 'string' || row.note.length > 500)) return `${prefix}.note is invalid`;
    if (row.bankReference != null && (typeof row.bankReference !== 'string' || !/^[a-z0-9-]{6,40}$/i.test(row.bankReference))) return `${prefix}.bankReference is invalid`;
    if (row.sourceAccount != null && (typeof row.sourceAccount !== 'string' || row.sourceAccount.length > 200)) return `${prefix}.sourceAccount is invalid`;
    if (row.rail != null && !RAILS.has(row.rail)) return `${prefix}.rail is invalid`;
    if (row.importRowKey !== undefined) {
      if (typeof row.importRowKey !== 'string' || !HASH.test(row.importRowKey)) return `${prefix}.importRowKey must be a SHA-256 digest`;
      if (keys.has(row.importRowKey)) return 'A source row is repeated inside this batch';
      keys.add(row.importRowKey);
    }
  }
  return null;
}

function createStatementImportHandler({ withUserClient, importResolvers, clientMutationSourceKey, insertTransactionAndUpdateState, logger = console }) {
  return async (req, res) => {
  const {
    userCardId,
    instrument: requestedInstrument = 'other',
    statementFrom,
    statementTo,
    closingBalanceInr,
    pointsPosted,
    txnCount,
    reconciledCount,
    issuerFormatId,
    importSource = 'statement',
    importKey,
    transactions: structuredTransactions,
  } = req.body || {};
  const validationError = validateStatementImport(req.body);
  if (validationError) return res.status(400).json({ error: validationError });

  try {
    const result = await withUserClient(req.userId, async (client) => {
      const transactionSource = importSource === 'statement' ? 'statement' : 'imported';
      let instrument = requestedInstrument;
      if (userCardId) {
        const card = await client.query(
          `SELECT cp.card_type FROM user_cards uc
             JOIN card_products cp ON cp.id = uc.card_product_id
            WHERE uc.id = $1 AND uc.profile_id = $2 AND uc.is_archived = false`,
          [userCardId, req.userId]
        );
        if (!card.rows.length) return { status: 404, error: 'user_card not found' };
        instrument = card.rows[0].card_type === 'credit' ? 'credit_card' : card.rows[0].card_type === 'debit' ? 'debit_card' : 'other';
      }

      // User-selected categories must be valid for this account before we
      // create an import batch. Cache repeated assignments so large files
      // with the same category do not add one lookup per row.
      const explicitAssignments = new Map();
      for (const transaction of structuredTransactions || []) {
        if (!transaction.categoryId && !transaction.userCategoryId) continue;
        const cacheKey = `${transaction.categoryId || ''}:${transaction.userCategoryId || ''}`;
        if (explicitAssignments.has(cacheKey)) continue;
        if (transaction.userCategoryId) {
          const category = await client.query(
            `SELECT id, parent_category_id
               FROM user_categories
              WHERE id = $1 AND profile_id = $2`,
            [transaction.userCategoryId, req.userId]
          );
          const selected = category.rows[0];
          if (!selected || (transaction.categoryId || null) !== (selected.parent_category_id || null)) {
            return { status: 400, error: 'A selected private category is unavailable or does not match its parent.' };
          }
          explicitAssignments.set(cacheKey, {
            categoryId: selected.parent_category_id || null,
            userCategoryId: selected.id,
          });
        } else {
          const category = await client.query(
            'SELECT id FROM spend_categories WHERE id = $1',
            [transaction.categoryId]
          );
          if (!category.rows.length) {
            return { status: 400, error: 'A selected category is unavailable.' };
          }
          explicitAssignments.set(cacheKey, {
            categoryId: category.rows[0].id,
            userCategoryId: null,
          });
        }
      }
      const statementSourceKey = importKey
        ? clientMutationSourceKey(req.userId, 'statement', importKey)
        : null;
      const insertedImport = await client.query(
        `INSERT INTO statement_imports
           (profile_id, user_card_id, statement_from, statement_to, closing_balance_inr,
            points_posted, txn_count, reconciled_count, issuer_format_id, source_key)
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
         ON CONFLICT (profile_id, source_key) WHERE source_key IS NOT NULL DO NOTHING
         RETURNING *`,
        [
          req.userId,
          userCardId,
          statementFrom,
          statementTo,
          closingBalanceInr ?? null,
          pointsPosted ?? null,
          structuredTransactions?.length ?? (txnCount ?? 0),
          structuredTransactions ? 0 : (reconciledCount ?? 0),
          issuerFormatId ?? null,
          statementSourceKey,
        ]
      );

      if (insertedImport.rowCount === 0) {
        const existing = await client.query(
          `SELECT * FROM statement_imports WHERE profile_id = $1 AND source_key = $2`,
          [req.userId, statementSourceKey]
        );
        return {
          status: 200,
          statementImport: existing.rows[0],
          duplicate: true,
          summary: { imported: 0, pendingDuplicates: 0, exactRetries: structuredTransactions?.length ?? 0 },
        };
      }

      const statementImport = insertedImport.rows[0];
      let imported = 0;
      let pendingDuplicates = 0;
      let exactRetries = 0;
      let reconciled = 0;
      for (const [index, transaction] of (structuredTransactions || []).entries()) {
        const occurred = new Date(transaction.occurredAt);
        const merchantName = transaction.merchantName?.trim() || null;
        const merchantVpa = transaction.merchantVpa || transaction.vpa || null;
        const merchantMcc = transaction.mcc || null;
        const explicitKey = `${transaction.categoryId || ''}:${transaction.userCategoryId || ''}`;
        const classification = explicitAssignments.get(explicitKey) || (importResolvers.resolveCategoryAssignmentForImport
          ? await importResolvers.resolveCategoryAssignmentForImport(client, req.userId, {
              merchantName,
              vpa: merchantVpa,
              mcc: merchantMcc,
              categoryHint: transaction.categoryHint,
              subcategoryHint: transaction.subcategoryHint,
              entryKind: inferStatementEntryKind(transaction),
              status: 'active',
            })
          : {
              categoryId: await importResolvers.resolveCategoryForImport(client, req.userId, {
                merchantName,
                vpa: merchantVpa,
                mcc: merchantMcc,
                entryKind: inferStatementEntryKind(transaction),
                status: 'active',
              }),
              userCategoryId: null,
            });
        const sourceKey = clientMutationSourceKey(
          req.userId,
          transactionSource,
          transaction.importRowKey || `${importKey}:${index}`,
        );
        const outcome = await insertTransactionAndUpdateState(client, req.userId, {
          userCardId,
          instrument: userCardId ? instrument : (transaction.instrument || instrument),
          amount: Number(transaction.amountInr),
          entryKind: inferStatementEntryKind(transaction),
          occurred,
          categoryId: classification.categoryId,
          userCategoryId: classification.userCategoryId,
          rail: transaction.rail || 'unknown',
          merchantName,
          merchantVpa,
          mcc: merchantMcc,
          note: transaction.note || null,
          source: transactionSource,
          sourceKey,
          backfill: true,
          accountLast4: /(?:^|\s)(\d{4})$/.exec(transaction.sourceAccount || '')?.[1],
          observationMetadata: { bankReference: transaction.bankReference || null, statementImportId: statementImport.id, line: index, importSource, sourceAccount: maskAccount(transaction.sourceAccount) },
        });
        if (outcome.status !== 200 && outcome.status !== 201) {
          throw new Error(`statement transaction ${index} failed: ${outcome.error || outcome.status}`);
        }
        if (transaction.tagNames?.length) await importTagNames(client, req.userId, outcome.transaction.id, transaction.tagNames);
        if (['exact_retry', 'high_confidence'].includes(outcome.duplicateKind)) {
          exactRetries += 1;
          if (outcome.transaction?.status === 'active') reconciled += 1;
        }
        else {
          if (outcome.duplicatePending) pendingDuplicates += 1;
          else { imported += 1; reconciled += 1; }
          await client.query(
            `UPDATE transactions
                SET statement_import_id = $1,
                    reward_state = CASE WHEN status = 'active' THEN 'confirmed' ELSE reward_state END,
                    reconciled_at = CASE WHEN status = 'active' THEN now() ELSE reconciled_at END
              WHERE id = $2`,
            [statementImport.id, outcome.transaction.id]
          );
        }
      }

      const updatedImport = await client.query(
        `UPDATE statement_imports
            SET txn_count = $1, reconciled_count = $2
          WHERE id = $3
          RETURNING *`,
        [structuredTransactions?.length ?? (txnCount ?? 0), structuredTransactions ? reconciled : (reconciledCount ?? 0), statementImport.id]
      );
      return {
        status: 201,
        statementImport: updatedImport.rows[0],
        summary: { imported, pendingDuplicates, exactRetries },
      };
    });
    res.status(result.status).json(result);
  } catch (err) {
    logger.error('POST /statement-imports error', {
      requestId: req.requestId || null,
      error: err,
    });
    res.status(500).json({
      error: 'internal_error',
      ...(req.requestId ? { requestId: req.requestId } : {}),
    });
  }
  };
}

module.exports = { validateStatementImport, createStatementImportHandler, maskAccount, inferStatementEntryKind };
