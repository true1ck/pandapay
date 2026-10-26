/**
 * Gemini queue worker.
 *
 * The worker is deliberately stateless: it leases one durable job, sends a
 * redacted payload to Gemini, and posts the validated fact set back with the
 * lease token. A provider failure releases the same job with a bounded delay;
 * it never creates a second job or writes a second transaction.
 */

const path = require('path');
require('dotenv').config();
if (!process.env.GEMINI_API_KEY) {
  require('dotenv').config({ path: path.resolve(__dirname, '../../.env') });
}

const crypto = require('crypto');
const DEFAULT_MODEL = process.env.GEMINI_MODEL || 'gemini-3.5-flash-lite';
const DEFAULT_FALLBACK_MODEL = process.env.GEMINI_FALLBACK_MODEL || 'gemini-flash-lite-latest';
const DEFAULT_INTERVAL_MS = Number(process.env.AI_WORKER_INTERVAL_MS || 2000);
const DEFAULT_API_BASE_URL = process.env.AI_WORKER_API_BASE_URL || `http://127.0.0.1:${process.env.PORT || 4000}`;
const PROVIDER_TIMEOUT_MS = Math.max(1000, Number(process.env.AI_PROVIDER_TIMEOUT_MS || 20000));
const DEFAULT_BATCH_MAX = Math.min(4, Math.max(1, Number(process.env.AI_WORKER_BATCH_MAX || 4)));
const DEFAULT_BATCH_WINDOW_MS = Math.min(500, Math.max(0, Number(process.env.AI_WORKER_BATCH_WINDOW_MS || 300)));
const MAX_OUTPUT_TOKENS = 2048;

const SPEND_CATEGORIES = [
  'groceries', 'fuel', 'dining', 'online', 'travel', 'bills', 'rent',
  'insurance', 'education', 'government', 'wallet', 'entertainment',
  'health', 'emi', 'other',
];

const DECISION_TOPICS = [
  'card_spend', 'card_refund', 'upi_debit', 'upi_credit',
  'atm_withdrawal', 'bank_transfer', 'bill_due_notice',
  'bill_payment_success', 'mandate_autopay', 'investment_purchase',
  'salary_or_income', 'telecom_carrier_deduction', 'loan_upsell_or_offer',
  'credit_card_limit_upsell', 'otp_or_security_code',
  'generic_promotional_spam', 'informational_balance_notice', 'other_non_financial',
];

const REJECTION_REASONS = [
  'none', 'telecom_carrier_deduction', 'loan_upsell',
  'promotional_spam', 'security_otp', 'credit_limit_upsell', 'non_financial',
];

const DECISION_SCHEMA = {
  type: 'OBJECT',
  properties: {
    topic: { type: 'STRING', enum: DECISION_TOPICS },
    summary: { type: 'STRING' },
    shouldConsider: { type: 'BOOLEAN' },
    rejectionReason: { type: 'STRING', enum: REJECTION_REASONS },
  },
  required: ['topic', 'summary', 'shouldConsider', 'rejectionReason'],
};

const UNIVERSAL_SYSTEM_INSTRUCTION = [
  "You are PandaPay's Cognitive Financial SMS Intelligence & Extraction Engine.",
  'Your mission is to evaluate redacted Indian SMS messages, make an intent-based tracking decision, and extract strictly typed financial facts.',
  '',
  'TWO-STAGE COGNITIVE EVALUATION:',
  'STAGE 1: INTENT & TRACKING DECISION (decision object)',
  '- What is this SMS about? Assign the most specific topic from DECISION_TOPICS and write a concise 1-sentence summary.',
  '- Should PandaPay track this? (shouldConsider: boolean):',
  '  * SET shouldConsider=true ONLY for completed or scheduled money movements, bill obligations, salary/income, investments, or active mandates.',
  '  * SET shouldConsider=false for telecom carrier deductions (Jio/Airtel/Vi retention fees, talktime/validity debits), personal loan/pay-later offers (Axio, KreditBee), credit limit upsells, bank OTPs, gambling/promotional spam, or general service alerts.',
  '- Rejection Reason: If shouldConsider=false, choose the matching reason from REJECTION_REASONS. If shouldConsider=true, set rejectionReason="none".',
  '',
  'STAGE 2: FACT EXTRACTION (facts array)',
  '- When shouldConsider=false, facts MUST be an empty array []. Do NOT extract balance snapshots, service alerts, or partial movements for rejected messages.',
  '- When shouldConsider=true, extract strictly typed facts following these rules:',
  '  1. ZERO HALLUCINATION: Never invent or extrapolate missing digits, dates, or merchants. The message has already been redacted.',
  '  2. DISTINGUISH MONEY MOVED FROM MONEY MENTIONED:',
  "   - A debit, card swipe, or purchase is 'posted_movement' with amountRole='posted' and entryKind='spend'.",
  "   - A salary credit or dividend is 'posted_movement' with amountRole='posted' and entryKind='income'.",
  "   - A broker funds payout (e.g., Kotak Neo, Zerodha quarterly settlement) or own-account transfer is 'posted_movement' with amountRole='posted' and entryKind='transfer'.",
  "   - A mutual fund SIP debit or stock purchase is 'posted_movement' with amountRole='posted' and entryKind='investment'.",
  "   - A utility bill, credit card statement, or due notification is 'bill_obligation' with amountRole='due_total' (and 'due_minimum' if present). It is NEVER a posted movement.",
  "   - An AutoPay registration or standing instruction is 'mandate_lifecycle' with amountRole='ceiling' and limitInr. It is NEVER a spend.",
  "   - An ATM withdrawal is 'posted_movement' with instrument='cash' and entryKind='transfer'.",
  '  3. CATEGORIZATION:',
  "   For every spend transaction, extract a clean merchant name (stripping noise words such as 'INFO/', 'VPA', 'IMPS-', 'POS', 'ECOM') and assign exactly ONE of the 15 canonical categories:",
  "   ['groceries', 'fuel', 'dining', 'online', 'travel', 'bills', 'rent', 'insurance', 'education', 'government', 'wallet', 'entertainment', 'health', 'emi', 'other'].",
  '  4. SCORING & COMPLETENESS:',
  "   - Set 'isComplete': true when the message has all necessary fields (for spend: amount, instrument, merchant, category; for bill: amountDue, dueDate, billerName).",
  "   - Set 'confidence': a float from 0.0 to 1.0 reflecting your extraction certainty.",
].join('\n');

const FACT_TYPE_ENUM = [
  'posted_movement',
  'pending_or_failed_attempt',
  'balance_snapshot',
  'bill_obligation',
  'bill_payment',
  'mandate_lifecycle',
  'card_identity_hint',
  'security_or_service_alert',
  'promotion',
];

const UNIVERSAL_RESPONSE_SCHEMA = {
  type: 'OBJECT',
  properties: {
    decision: DECISION_SCHEMA,
    facts: {
      type: 'ARRAY',
      items: {
        type: 'OBJECT',
        properties: {
          factType: { type: 'STRING', enum: FACT_TYPE_ENUM },
          payload: {
            type: 'OBJECT',
            properties: {
              amountRole: {
                type: 'STRING',
                enum: ['posted', 'due_total', 'due_minimum', 'outstanding', 'ceiling', 'proposed'],
              },
              entryKind: { type: 'STRING', enum: ['spend', 'income', 'transfer', 'investment'] },
              amountInr: { type: 'NUMBER' },
              amountDueInr: { type: 'NUMBER' },
              minimumDueInr: { type: 'NUMBER' },
              outstandingInr: { type: 'NUMBER' },
              limitInr: { type: 'NUMBER' },
              proposedAmountInr: { type: 'NUMBER' },
              availableBalanceInr: { type: 'NUMBER' },
              occurredAt: { type: 'STRING' },
              dueDate: { type: 'STRING' },
              statementDate: { type: 'STRING' },
              proposedAt: { type: 'STRING' },
              asOfAt: { type: 'STRING' },
              instrument: {
                type: 'STRING',
                enum: ['upi_bank', 'credit_card', 'debit_card', 'cash', 'wallet', 'other'],
              },
              last4: { type: 'STRING' },
              accountLast4: { type: 'STRING' },
              merchant: { type: 'STRING' },
              billerName: { type: 'STRING' },
              serviceName: { type: 'STRING' },
              transferParty: { type: 'STRING' },
              issuerName: { type: 'STRING' },
              category: { type: 'STRING', enum: SPEND_CATEGORIES },
              reference: { type: 'STRING' },
              mandateStatus: {
                type: 'STRING',
                enum: ['registered', 'scheduled', 'paused', 'cancelled', 'failed'],
              },
              targetKind: {
                type: 'STRING',
                enum: ['card_bill', 'utility_or_other_bill', 'service_merchant', 'unknown'],
              },
              isComplete: { type: 'BOOLEAN' },
              confidence: { type: 'NUMBER' },
            },
            // amountRole is required only for money-bearing fact types; the
            // prompt states that per type. A blanket schema requirement would
            // force balance snapshots to carry a role whose matching amount
            // field the payload validator then demands.
          },
        },
        required: ['factType', 'payload'],
      },
    },
  },
  required: ['decision', 'facts'],
};

const UNIVERSAL_BATCH_RESPONSE_SCHEMA = {
  type: 'OBJECT',
  properties: {
    items: {
      type: 'ARRAY',
      items: {
        type: 'OBJECT',
        properties: {
          id: { type: 'STRING' },
          decision: DECISION_SCHEMA,
          facts: UNIVERSAL_RESPONSE_SCHEMA.properties.facts,
        },
        required: ['id', 'decision', 'facts'],
      },
    },
  },
  required: ['items'],
};

/** Spec §5.3: twelve Indian financial scenarios, compact JSON outputs. */
const FEW_SHOT_EXAMPLES = [
  {
    label: 'UPI food delivery debit (Swiggy)',
    sms: 'Sent Rs.420.00 from HDFC Bank A/C **1797 to SWIGGY UPI on 24-10-26. UPI Ref 429812345678. Avail Bal: Rs.45,120.50',
    output: {
      decision: {
        topic: 'upi_debit',
        summary: 'Paid Rs. 420 to Swiggy via HDFC Bank UPI',
        shouldConsider: true,
        rejectionReason: 'none',
      },
      facts: [
        {
          factType: 'posted_movement',
          payload: {
            amountRole: 'posted', entryKind: 'spend', amountInr: 420.0,
            occurredAt: '2026-10-24T00:00:00.000Z', instrument: 'upi_bank',
            accountLast4: '1797', issuerName: 'HDFC Bank', merchant: 'Swiggy',
            category: 'dining', reference: '429812345678', isComplete: true, confidence: 0.98,
          },
        },
        {
          factType: 'balance_snapshot',
          payload: {
            availableBalanceInr: 45120.5,
            asOfAt: '2026-10-24T00:00:00.000Z', instrument: 'upi_bank', accountLast4: '1797',
          },
        },
      ],
    },
  },
  {
    label: 'Credit card purchase (Flipkart)',
    sms: 'Alert: INR 2,499.00 spent on ICICI Bank Credit Card ending XX4002 at FLIPKART on 25-Oct-26. Available limit: INR 1,45,000.00.',
    output: {
      decision: {
        topic: 'card_spend',
        summary: 'Spent Rs. 2,499 on Flipkart with ICICI Bank Credit Card ending 4002',
        shouldConsider: true,
        rejectionReason: 'none',
      },
      facts: [
        {
          factType: 'posted_movement',
          payload: {
            amountRole: 'posted', entryKind: 'spend', amountInr: 2499.0,
            occurredAt: '2026-10-25T00:00:00.000Z', instrument: 'credit_card',
            last4: '4002', issuerName: 'ICICI Bank', merchant: 'Flipkart',
            category: 'online', isComplete: true, confidence: 0.99,
          },
        },
        {
          factType: 'balance_snapshot',
          payload: {
            availableBalanceInr: 145000.0,
            asOfAt: '2026-10-25T00:00:00.000Z', instrument: 'credit_card', last4: '4002',
          },
        },
      ],
    },
  },
  {
    label: 'Credit card monthly statement bill (Axis)',
    sms: 'Your Axis Bank Credit Card XX8891 statement generated. Total Due: Rs 14,850.00, Min Due: Rs 750.00, Due Date: 12-Nov-2026.',
    output: {
      decision: {
        topic: 'bill_due_notice',
        summary: 'Axis Bank Credit Card XX8891 bill due of Rs. 14,850 on 12-Nov-2026',
        shouldConsider: true,
        rejectionReason: 'none',
      },
      facts: [
        {
          factType: 'bill_obligation',
          payload: {
            amountRole: 'due_total', amountDueInr: 14850.0,
            dueDate: '2026-11-12T00:00:00.000Z', instrument: 'credit_card',
            last4: '8891', issuerName: 'Axis Bank', billerName: 'Axis Bank Credit Card',
            targetKind: 'card_bill', isComplete: true, confidence: 0.99,
          },
        },
        {
          factType: 'bill_obligation',
          payload: {
            amountRole: 'due_minimum', minimumDueInr: 750.0,
            dueDate: '2026-11-12T00:00:00.000Z', instrument: 'credit_card',
            last4: '8891', issuerName: 'Axis Bank', billerName: 'Axis Bank Credit Card',
            targetKind: 'card_bill', isComplete: true, confidence: 0.99,
          },
        },
      ],
    },
  },
  {
    label: 'Utility bill (BESCOM electricity)',
    sms: 'Dear Consumer, Electricity bill for CA 102938475 is Rs 1,840.00. Due date is 05-Nov-2026. Pay via BESCOM portal to avoid disconnect.',
    output: {
      decision: {
        topic: 'bill_due_notice',
        summary: 'BESCOM electricity bill of Rs. 1,840 due on 05-Nov-2026',
        shouldConsider: true,
        rejectionReason: 'none',
      },
      facts: [
        {
          factType: 'bill_obligation',
          payload: {
            amountRole: 'due_total', amountDueInr: 1840.0,
            dueDate: '2026-11-05T00:00:00.000Z', billerName: 'BESCOM',
            category: 'bills', targetKind: 'utility_or_other_bill',
            isComplete: true, confidence: 0.96,
          },
        },
      ],
    },
  },
  {
    label: 'Bill payment receipt (credit card bill paid)',
    sms: 'Thank you! Payment of Rs.14,850.00 received towards your Axis Bank Credit Card XX8891 on 25-Oct-26 via CRED.',
    output: {
      decision: {
        topic: 'bill_payment_success',
        summary: 'Paid Rs. 14,850 towards Axis Bank Credit Card XX8891 via CRED',
        shouldConsider: true,
        rejectionReason: 'none',
      },
      facts: [
        {
          factType: 'bill_payment',
          payload: {
            amountRole: 'posted', entryKind: 'transfer', amountInr: 14850.0,
            occurredAt: '2026-10-25T00:00:00.000Z', instrument: 'credit_card',
            last4: '8891', billerName: 'Axis Bank Credit Card', issuerName: 'Axis Bank',
            targetKind: 'card_bill', isComplete: true, confidence: 0.98,
          },
        },
      ],
    },
  },
  {
    label: 'Broker settlement payout (Kotak Neo / Zerodha return to bank)',
    sms: 'Dear Investor, payout of Rs 1,944.38 has been processed towards your Bank A/c XX1797 on 24-Oct-26 on account of quarterly settlement of funds. - Kotak Neo',
    output: {
      decision: {
        topic: 'bank_transfer',
        summary: 'Kotak Neo quarterly funds settlement payout of Rs. 1,944.38 to Bank A/c XX1797',
        shouldConsider: true,
        rejectionReason: 'none',
      },
      facts: [
        {
          factType: 'posted_movement',
          payload: {
            amountRole: 'posted', entryKind: 'transfer', amountInr: 1944.38,
            occurredAt: '2026-10-24T00:00:00.000Z', instrument: 'upi_bank',
            accountLast4: '1797', merchant: 'Kotak Neo',
            transferParty: 'Kotak Neo Settlement', category: 'other',
            isComplete: true, confidence: 0.97,
          },
        },
      ],
    },
  },
  {
    label: 'Broker funding top-up (Zerodha funds added)',
    sms: 'Rs. 25,000.00 debited from HDFC Bank A/c XX1797 on 23-Oct-26 towards ZERODHA BROKING LTD via NetBanking. Ref 429712398.',
    output: {
      decision: {
        topic: 'investment_purchase',
        summary: 'Transferred Rs. 25,000 from HDFC Bank to Zerodha for investment',
        shouldConsider: true,
        rejectionReason: 'none',
      },
      facts: [
        {
          factType: 'posted_movement',
          payload: {
            amountRole: 'posted', entryKind: 'transfer', amountInr: 25000.0,
            occurredAt: '2026-10-23T00:00:00.000Z', instrument: 'upi_bank',
            accountLast4: '1797', merchant: 'Zerodha', reference: '429712398',
            category: 'other', isComplete: true, confidence: 0.98,
          },
        },
      ],
    },
  },
  {
    label: 'Earned income (monthly salary credit)',
    sms: 'Your Salary of Rs. 1,25,000.00 has been credited to your HDFC Bank A/c XX1797 on 30-Oct-2026 by ACME TECH CORP PVT LTD.',
    output: {
      decision: {
        topic: 'salary_or_income',
        summary: 'Salary credit of Rs. 1,25,000 from ACME TECH CORP to HDFC Bank A/c XX1797',
        shouldConsider: true,
        rejectionReason: 'none',
      },
      facts: [
        {
          factType: 'posted_movement',
          payload: {
            amountRole: 'posted', entryKind: 'income', amountInr: 125000.0,
            occurredAt: '2026-10-30T00:00:00.000Z', instrument: 'upi_bank',
            accountLast4: '1797', merchant: 'ACME TECH CORP PVT LTD',
            transferParty: 'Salary Credit', isComplete: true, confidence: 0.99,
          },
        },
      ],
    },
  },
  {
    label: 'Loan EMI debit (home loan auto-debit)',
    sms: 'EMI Rs 32,450.00 for Home Loan A/c HL-998822 debited from SBI Bank A/c XX4321 on 10-Oct-2026.',
    output: {
      decision: {
        topic: 'bank_transfer',
        summary: 'Home loan EMI debit of Rs. 32,450 from SBI Bank A/c XX4321',
        shouldConsider: true,
        rejectionReason: 'none',
      },
      facts: [
        {
          factType: 'posted_movement',
          payload: {
            amountRole: 'posted', entryKind: 'spend', amountInr: 32450.0,
            occurredAt: '2026-10-10T00:00:00.000Z', instrument: 'upi_bank',
            accountLast4: '4321', merchant: 'SBI Home Loan', category: 'emi',
            reference: 'HL-998822', isComplete: true, confidence: 0.97,
          },
        },
      ],
    },
  },
  {
    label: 'AutoPay e-mandate registration (Netflix)',
    sms: 'AutoPay e-mandate successfully registered for NETFLIX Entertainment with max limit INR 1,500.00 on HDFC Bank Card ending 1234. UMN: HDFC998877.',
    output: {
      decision: {
        topic: 'mandate_autopay',
        summary: 'Netflix AutoPay e-mandate registered on HDFC Card ending 1234 up to Rs. 1,500',
        shouldConsider: true,
        rejectionReason: 'none',
      },
      facts: [
        {
          factType: 'mandate_lifecycle',
          payload: {
            amountRole: 'ceiling', limitInr: 1500.0,
            asOfAt: '2026-10-25T00:00:00.000Z', mandateStatus: 'registered',
            targetKind: 'service_merchant', serviceName: 'Netflix', merchant: 'Netflix',
            instrument: 'credit_card', last4: '1234', reference: 'HDFC998877',
            isComplete: true, confidence: 0.99,
          },
        },
      ],
    },
  },
  {
    label: 'ATM cash withdrawal',
    sms: 'Rs 5,000.00 withdrawn from ATM using Debit Card XX9912 on 24-Oct-26 at SBI ATM KORAMANGALA BLR.',
    output: {
      decision: {
        topic: 'atm_withdrawal',
        summary: 'ATM cash withdrawal of Rs. 5,000 using Debit Card XX9912',
        shouldConsider: true,
        rejectionReason: 'none',
      },
      facts: [
        {
          factType: 'posted_movement',
          payload: {
            amountRole: 'posted', entryKind: 'transfer', amountInr: 5000.0,
            occurredAt: '2026-10-24T00:00:00.000Z', instrument: 'cash',
            last4: '9912', merchant: 'ATM Cash Withdrawal', isComplete: true, confidence: 0.98,
          },
        },
      ],
    },
  },
  {
    label: 'Partial / ambiguous spend (needs review)',
    sms: 'A/c XX1797 debited for INR 750.00 on 24-10-26. Info: POS-AMAZON PAY BLR. Avail Bal: 21,400.00.',
    output: {
      decision: {
        topic: 'upi_debit',
        summary: 'Partial debit of Rs. 750 at Amazon Pay from A/c XX1797',
        shouldConsider: true,
        rejectionReason: 'none',
      },
      facts: [
        {
          factType: 'posted_movement',
          payload: {
            amountRole: 'posted', entryKind: 'spend', amountInr: 750.0,
            occurredAt: '2026-10-24T00:00:00.000Z', instrument: 'upi_bank',
            accountLast4: '1797', merchant: 'Amazon Pay', category: 'online',
            isComplete: false, confidence: 0.65,
          },
        },
      ],
    },
  },
  {
    label: 'Telecom carrier retention deduction (Jio ₹9.88 noise)',
    sms: 'Paid Rs. 9.88 for Jio number retention charges via UPI on 20-Oct-2026. Avail Bal: Rs 12.00',
    output: {
      decision: {
        topic: 'telecom_carrier_deduction',
        summary: 'Jio number retention airtime deduction of Rs 9.88',
        shouldConsider: false,
        rejectionReason: 'telecom_carrier_deduction',
      },
      facts: [],
    },
  },
  {
    label: 'Personal loan promotional upsell (Axio / KreditBee noise)',
    sms: 'Congratulations! You are pre-approved for an instant personal loan of up to Rs 2,50,000 from Axio with zero paperwork. Apply now at https://axio.in/loan',
    output: {
      decision: {
        topic: 'loan_upsell_or_offer',
        summary: 'Pre-approved personal loan marketing offer from Axio',
        shouldConsider: false,
        rejectionReason: 'loan_upsell',
      },
      facts: [],
    },
  },
  {
    label: 'Bank security OTP verification',
    sms: '482910 is your OTP for NetBanking login at HDFC Bank. Valid for 10 mins. Do not share OTP with anyone.',
    output: {
      decision: {
        topic: 'otp_or_security_code',
        summary: 'HDFC Bank NetBanking login verification OTP',
        shouldConsider: false,
        rejectionReason: 'security_otp',
      },
      facts: [],
    },
  },
  {
    label: 'Gambling / spam marketing offer',
    sms: 'Deposit Rs 500 & get Rs 1000 free bonus instantly on gbets.win! Play and win real cash now.',
    output: {
      decision: {
        topic: 'generic_promotional_spam',
        summary: 'Gbets gambling deposit bonus promotional spam',
        shouldConsider: false,
        rejectionReason: 'promotional_spam',
      },
      facts: [],
    },
  },
];

function renderFewShots() {
  return [
    'Few-shot examples (redacted SMS -> expected facts JSON):',
    ...FEW_SHOT_EXAMPLES.map(
      (example, index) => `Example ${index + 1} (${example.label}):\nSMS: ${example.sms}\nOutput: ${JSON.stringify(example.output)}`,
    ),
  ].join('\n');
}

class GeminiProviderError extends Error {
  constructor(message, { retryable = false, retryAfterMs = undefined, status = undefined } = {}) {
    super(message);
    this.name = 'GeminiProviderError';
    this.retryable = retryable;
    this.retryAfterMs = retryAfterMs;
    this.status = status;
  }
}

function retryAfterMsFromHeaders(headers, errorBody = null) {
  const value = headers?.get?.('retry-after');
  if (value) {
    const seconds = Number(value);
    if (Number.isFinite(seconds)) return Math.max(0, seconds * 1000);
    const date = Date.parse(value);
    if (Number.isFinite(date)) return Math.max(0, date - Date.now());
  }
  if (errorBody) {
    try {
      const data = typeof errorBody === 'string' ? JSON.parse(errorBody) : errorBody;
      const details = data?.error?.details || [];
      for (const d of details) {
        if (typeof d?.retryDelay === 'string') {
          const match = /^([0-9.]+)s$/i.exec(d.retryDelay);
          if (match) {
            const s = parseFloat(match[1]);
            if (Number.isFinite(s)) return Math.max(0, s * 1000);
          }
        }
      }
    } catch (_) {}
  }
  return undefined;
}

function nextAdaptiveBatchSize(current, maximum, outcome) {
  const cap = Math.max(1, Math.min(4, Number(maximum) || 1));
  const size = Math.max(1, Math.min(cap, Number(current) || 1));
  if (outcome?.retried || outcome?.failed) return Math.max(1, Math.floor(size / 2));
  if (outcome?.completed) return Math.min(cap, size + 1);
  return size;
}

function parseModelJson(text) {
  const cleaned = String(text || '')
    .trim()
    .replace(/^```(?:json)?\s*/i, '')
    .replace(/\s*```$/i, '')
    .trim();
  try {
    return JSON.parse(cleaned);
  } catch (error) {
    throw new GeminiProviderError('Gemini returned invalid JSON', { retryable: false });
  }
}

function buildGeminiPrompt(job, { batch = false, includeExamples = true } = {}) {
  const payload = job?.payload || {};
  return [
    'Evaluate this Indian SMS for a personal finance app. First make a cognitive tracking decision, then extract facts if trackable.',
    'The message has already been redacted. Never infer or invent missing digits.',
    batch
      ? 'Supply this item\'s decision and facts array in the batch items envelope. If shouldConsider=false, set facts: [].'
      : 'Return JSON only in the form {"decision":{...},"facts":[...]}. If shouldConsider=false, set facts: [].',
    'Each fact must use the app contract: factType, payload, provenance.',
    'Allowed factType values: posted_movement, pending_or_failed_attempt, balance_snapshot, bill_obligation, bill_payment, mandate_lifecycle, card_identity_hint, security_or_service_alert, promotion.',
    'Allowed entryKind values for posted_movement: spend, income, transfer, investment (use "spend" for debited/purchases).',
    'Allowed instruments if present: upi_bank, credit_card, debit_card, cash, wallet, other.',
    `Allowed category values for spend facts: ${SPEND_CATEGORIES.join(', ')}.`,
    'Amounts must use the correct role: posted, due_total, due_minimum, outstanding, ceiling, or proposed.',
    'Required payload fields: posted_movement = amountRole, entryKind, occurredAt; pending_or_failed_attempt = attemptStatus, occurredAt; balance_snapshot = availableBalanceInr, asOfAt; bill_obligation = amountRole, dueDate and its evidenced amount/date fields; bill_payment = amountRole, occurredAt and its evidenced amount field; mandate_lifecycle = mandateStatus, asOfAt; card_identity_hint = asOfAt; security_or_service_alert = alertKind, occurredAt; promotion may be empty.',
    'For amountRole, include its matching amount and date: posted=amountInr/occurredAt, due_total=amountDueInr/dueDate, due_minimum=minimumDueInr/dueDate, outstanding=outstandingInr/asOfAt, ceiling=limitInr/asOfAt, proposed=proposedAmountInr/proposedAt.',
    'A posted spend also requires merchant. A mandate limit is valid only for registered status. Never omit required fields or invent values; if any required value is absent or uncertain, leave this SMS\'s facts array empty.',
    'Set isComplete=true only when every essential attribute for the fact type is present, and confidence to your extraction certainty from 0.0 to 1.0.',
    'Do not treat a bill total, credit limit, or mandate ceiling as a posted movement.',
    ...(includeExamples ? [renderFewShots()] : []),
    `Sender: ${String(payload.sender || '')}`,
    `Occurred at: ${String(payload.occurredAt || '')}`,
    `SMS: ${String(payload.body || '')}`,
  ].join('\n');
}

function buildGeminiBatchPrompt(jobs) {
  return [
    'Classify each SMS independently. Return JSON only: {"items":[{"id":"<id>","decision":{...},"facts":[...]}]}.',
    'Return exactly one item per supplied id, even when its facts array is empty.',
    'Never mix an amount, account or date from one item into another item.',
    renderFewShots(),
    ...jobs.map((job) => `ITEM ${job.id}\n${buildGeminiPrompt(job, { batch: true, includeExamples: false })}`),
  ].join('\n\n');
}

function estimateProviderTokens(jobs) {
  const promptChars = buildGeminiBatchPrompt(jobs).length;
  // Include room for the structured response and fixed prompt overhead. The
  // estimate intentionally errs high; the database reservation is a safety
  // gate, not a billing meter.
  return Math.min(20000, Math.max(1, Math.ceil(promptChars / 3) + jobs.length * 512));
}

async function reserveProviderCapacity({ jobs, apiBaseUrl, workerToken, fetchImpl, waitImpl, heartbeat }) {
  const estimatedTokens = estimateProviderTokens(jobs);
  for (;;) {
    const permit = await jsonRequest(fetchImpl, `${apiBaseUrl}/ai/provider/reserve`, workerToken, { estimatedTokens });
    if (permit.allowed === true) return permit;
    if (permit.dailyLimitReached === true) {
      throw new GeminiProviderError('Gemini daily Free-tier request limit reached', {
        retryable: true,
        retryAfterMs: Math.max(1000, Number(permit.retryAfterMs) || 60000),
      });
    }
    if (permit.permanentlyBlocked === true) {
      throw new GeminiProviderError('Provider token window is smaller than this request', { retryable: false });
    }
    const waitMs = Math.max(100, Math.min(60000, Number(permit.waitMs) || 1000));
    if (typeof heartbeat === 'function') await heartbeat(jobs);
    await waitImpl(waitMs);
  }
}

function parseConfiguredApiKeys(primary, fallback) {
  const keys = [
    primary,
    fallback,
    ...(process.env.GEMINI_API_KEYS ? process.env.GEMINI_API_KEYS.split(',') : []),
  ];
  return [...new Set(keys.map((k) => String(k || '').trim()).filter(Boolean))];
}

class GeminiProvider {
  constructor({
    apiKey,
    fallbackApiKey,
    apiKeys = null,
    model = DEFAULT_MODEL,
    fallbackModel = DEFAULT_FALLBACK_MODEL,
    fetchImpl = globalThis.fetch,
    endpointBase = 'https://generativelanguage.googleapis.com/v1beta/models',
  } = {}) {
    if (typeof fetchImpl !== 'function') throw new Error('global fetch is required');
    const primaryKey = apiKey !== undefined ? apiKey : process.env.GEMINI_API_KEY;
    const fallbackKey = fallbackApiKey !== undefined ? fallbackApiKey : (apiKey === '' ? '' : process.env.GEMINI_FALLBACK_API_KEY);
    const keys = Array.isArray(apiKeys) && apiKeys.length > 0
      ? apiKeys.map((k) => String(k || '').trim()).filter(Boolean)
      : (apiKey === '' && !fallbackApiKey ? [] : parseConfiguredApiKeys(primaryKey, fallbackKey));
    this.apiKeys = keys;
    this.currentKeyIndex = 0;
    this.apiKey = this.apiKeys[0] || (primaryKey ? String(primaryKey).trim() : null);
    this.model = model;
    this.fallbackModel = fallbackModel && fallbackModel !== model ? fallbackModel : null;
    this.fetchImpl = fetchImpl;
    this.endpointBase = endpointBase.replace(/\/$/, '');
  }

  async classify(job) {
    if (!this.apiKey && (!this.apiKeys || this.apiKeys.length === 0)) {
      throw new GeminiProviderError('GEMINI_API_KEY is not configured', { retryable: false });
    }
    const maxAttempts = Math.max(1, this.apiKeys.length);
    for (let attempt = 0; attempt < maxAttempts; attempt++) {
      const activeKey = this.apiKeys[this.currentKeyIndex] || this.apiKey;
      let response;
      try {
        response = await this.fetchImpl(
          `${this.endpointBase}/${encodeURIComponent(this.model)}:generateContent`,
          {
            method: 'POST',
            signal: AbortSignal.timeout(PROVIDER_TIMEOUT_MS),
            headers: { 'content-type': 'application/json', 'x-goog-api-key': activeKey },
            body: JSON.stringify({
              systemInstruction: {
                parts: [{ text: UNIVERSAL_SYSTEM_INSTRUCTION }],
              },
              contents: [{ role: 'user', parts: [{ text: buildGeminiPrompt(job) }] }],
              generationConfig: {
                responseMimeType: 'application/json',
                responseSchema: UNIVERSAL_RESPONSE_SCHEMA,
                maxOutputTokens: MAX_OUTPUT_TOKENS,
              },
            }),
          },
        );
      } catch (_) {
        throw new GeminiProviderError('Gemini request failed or timed out', { retryable: true });
      }
      if (!response.ok) {
        let providerError = '';
        try { providerError = JSON.stringify(await response.json()); } catch (_) { /* no body */ }
        const quotaError = (response.status === 403 || response.status === 429) &&
          /quota|resource[_ -]?exhausted|rate.?limit/i.test(providerError);
        const is429 = response.status === 429 || quotaError;

        if (response.status === 404 && this.fallbackModel && this.model !== this.fallbackModel) {
          console.warn(`[GeminiProvider] Model ${this.model} hit HTTP 404, switching to fallback model ${this.fallbackModel}`);
          this.model = this.fallbackModel;
          this.fallbackModel = null;
          attempt--;
          continue;
        }

        if ((is429 || response.status === 403) && this.apiKeys.length > 1 && attempt < maxAttempts - 1) {
          const nextIndex = (this.currentKeyIndex + 1) % this.apiKeys.length;
          console.warn(`[GeminiProvider] Key index ${this.currentKeyIndex} hit HTTP ${response.status}, rotating to fallback key index ${nextIndex}`);
          this.currentKeyIndex = nextIndex;
          this.apiKey = this.apiKeys[nextIndex];
          continue;
        }

        const retryable = response.status === 408 || response.status === 409 || is429 || response.status >= 500;
        const parsedDelay = retryAfterMsFromHeaders(response.headers, providerError);
        const retryAfterMs = parsedDelay ?? (is429 ? (30000 + Math.floor(Math.random() * 5000)) : undefined);
        throw new GeminiProviderError(`Gemini HTTP ${response.status}`, {
          retryable,
          retryAfterMs,
          status: response.status,
        });
      }
      const data = await response.json();
      const text = data?.candidates?.[0]?.content?.parts?.map((part) => part.text || '').join('');
      const parsed = parseModelJson(text);
      if (!parsed || !Array.isArray(parsed.facts)) {
        throw new GeminiProviderError('Gemini response has no facts array', { retryable: false });
      }
      if (attempt === 0 && this.apiKeys.length > 1) {
        this.currentKeyIndex = (this.currentKeyIndex + 1) % this.apiKeys.length;
        this.apiKey = this.apiKeys[this.currentKeyIndex];
      }
      return {
        decision: parsed.decision || {
          topic: parsed.facts.length > 0 ? 'card_spend' : 'other_non_financial',
          summary: parsed.facts.length > 0 ? 'Financial transaction detected' : 'Non-financial or unrecognized message',
          shouldConsider: parsed.facts.length > 0,
          rejectionReason: parsed.facts.length > 0 ? 'none' : 'non_financial',
        },
        facts: parsed.facts,
      };
    }
  }

  async classifyBatch(jobs) {
    if (jobs.length === 1) return new Map([[jobs[0].id, await this.classify(jobs[0])]]);
    if (!this.apiKey && (!this.apiKeys || this.apiKeys.length === 0)) {
      throw new GeminiProviderError('GEMINI_API_KEY is not configured');
    }
    const maxAttempts = Math.max(1, this.apiKeys.length);
    for (let attempt = 0; attempt < maxAttempts; attempt++) {
      const activeKey = this.apiKeys[this.currentKeyIndex] || this.apiKey;
      let response;
      try {
        response = await this.fetchImpl(
          `${this.endpointBase}/${encodeURIComponent(this.model)}:generateContent`,
          {
            method: 'POST',
            signal: AbortSignal.timeout(PROVIDER_TIMEOUT_MS),
            headers: { 'content-type': 'application/json', 'x-goog-api-key': activeKey },
            body: JSON.stringify({
              systemInstruction: {
                parts: [{ text: UNIVERSAL_SYSTEM_INSTRUCTION }],
              },
              contents: [{ role: 'user', parts: [{ text: buildGeminiBatchPrompt(jobs) }] }],
              generationConfig: {
                responseMimeType: 'application/json',
                responseSchema: UNIVERSAL_BATCH_RESPONSE_SCHEMA,
                maxOutputTokens: MAX_OUTPUT_TOKENS,
              },
            }),
          },
        );
      } catch (_) {
        throw new GeminiProviderError('Gemini batch request failed or timed out', { retryable: true });
      }
      if (!response.ok) {
        let providerError = '';
        try { providerError = JSON.stringify(await response.json()); } catch (_) { /* no body */ }
        const quotaError = (response.status === 403 || response.status === 429) &&
          /quota|resource[_ -]?exhausted|rate.?limit/i.test(providerError);
        const is429 = response.status === 429 || quotaError;

        if (response.status === 404 && this.fallbackModel && this.model !== this.fallbackModel) {
          console.warn(`[GeminiProvider] Model ${this.model} hit HTTP 404, switching to fallback model ${this.fallbackModel}`);
          this.model = this.fallbackModel;
          this.fallbackModel = null;
          attempt--;
          continue;
        }

        if ((is429 || response.status === 403) && this.apiKeys.length > 1 && attempt < maxAttempts - 1) {
          const nextIndex = (this.currentKeyIndex + 1) % this.apiKeys.length;
          console.warn(`[GeminiProvider] Key index ${this.currentKeyIndex} hit HTTP ${response.status}, rotating to fallback key index ${nextIndex}`);
          this.currentKeyIndex = nextIndex;
          this.apiKey = this.apiKeys[nextIndex];
          continue;
        }

        const parsedDelay = retryAfterMsFromHeaders(response.headers, providerError);
        const retryAfterMs = parsedDelay ?? (is429 ? (30000 + Math.floor(Math.random() * 5000)) : undefined);
        throw new GeminiProviderError(`Gemini HTTP ${response.status}`, {
          retryable: response.status === 408 || response.status === 409 || is429 || response.status >= 500,
          retryAfterMs,
          status: response.status,
        });
      }
      const data = await response.json();
      const parsed = parseModelJson(data?.candidates?.[0]?.content?.parts?.map((part) => part.text || '').join(''));
      if (!Array.isArray(parsed?.items)) throw new GeminiProviderError('Gemini batch has no items array');
      const expected = new Set(jobs.map((job) => job.id));
      const output = new Map();
      for (const item of parsed.items) {
        if (!expected.has(item?.id) || output.has(item.id) || !Array.isArray(item.facts)) {
          throw new GeminiProviderError('Gemini batch has an invalid item');
        }
        output.set(item.id, {
          decision: item.decision || {
            topic: item.facts.length > 0 ? 'card_spend' : 'other_non_financial',
            summary: item.facts.length > 0 ? 'Financial transaction detected' : 'Non-financial or unrecognized message',
            shouldConsider: item.facts.length > 0,
            rejectionReason: item.facts.length > 0 ? 'none' : 'non_financial',
          },
          facts: item.facts,
        });
      }
      if (attempt === 0 && this.apiKeys.length > 1) {
        this.currentKeyIndex = (this.currentKeyIndex + 1) % this.apiKeys.length;
        this.apiKey = this.apiKeys[this.currentKeyIndex];
      }
      return output;
    }
  }
}

async function jsonRequest(fetchImpl, url, token, body) {
  const response = await fetchImpl(url, {
    method: 'POST',
    headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
    body: JSON.stringify(body || {}),
  });
  let data = {};
  try { data = await response.json(); } catch (_) { /* empty body */ }
  if (!response.ok) {
    const error = new Error(data.error || `worker endpoint HTTP ${response.status}`);
    error.status = response.status;
    error.retryAfterMs = retryAfterMsFromHeaders(response.headers);
    throw error;
  }
  return data;
}

async function runWorkerOnce({
  apiBaseUrl = DEFAULT_API_BASE_URL,
  workerToken = process.env.AI_WORKER_TOKEN,
  fetchImpl = globalThis.fetch,
  provider = new GeminiProvider(),
  maxBatch = DEFAULT_BATCH_MAX,
  batchWindowMs = DEFAULT_BATCH_WINDOW_MS,
  waitImpl = (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
  reserveCapacity = null,
} = {}) {
  if (!workerToken) throw new Error('AI_WORKER_TOKEN is not configured');
  if (provider instanceof GeminiProvider && !provider.apiKey) {
    throw new Error('GEMINI_API_KEY is not configured');
  }
  const base = apiBaseUrl.replace(/\/$/, '');
  const lease = await jsonRequest(fetchImpl, `${base}/ai/jobs/lease`, workerToken);
  if (!lease.leased) return { leased: false, ...(lease.abandoned ? { abandoned: lease.abandoned } : {}) };

  const jobs = [lease.job];
  if (typeof provider.classifyBatch === 'function' && maxBatch > 1) {
    if (batchWindowMs > 0) await new Promise((resolve) => setTimeout(resolve, batchWindowMs));
    while (jobs.length < maxBatch) {
      const next = await jsonRequest(fetchImpl, `${base}/ai/jobs/lease`, workerToken);
      if (!next.leased || jobs.some((job) => job.id === next.job.id)) break;
      jobs.push(next.job);
    }
  }
  const batchId = crypto.randomUUID();
  const settleFailure = async (job, error) => {
    // Only the API's 422 has already failed/purged the job. A provider 422
    // still needs the terminal failure endpoint to release this lease.
    if (error?.status === 422 && !(error instanceof GeminiProviderError)) return { jobId: job.id, failed: true };
    const retryable = error?.retryable === true || error?.status === 408 || error?.status === 409 || error?.status === 429 || error?.status >= 500;
    const route = retryable ? 'retry' : 'fail';
    const outcome = await jsonRequest(fetchImpl, `${base}/ai/jobs/${encodeURIComponent(job.id)}/${route}`, workerToken, {
      profileId: job.profileId,
      leaseToken: job.leaseToken,
      ...(retryable ? {
        reason: 'provider_retry',
        ...(Number.isFinite(error.retryAfterMs) ? { retryAfterMs: error.retryAfterMs } : {}),
      } : { reason: error instanceof GeminiProviderError ? 'invalid_provider_output' : 'invalid_result' }),
    });
    return { jobId: job.id, [retryable ? 'retried' : 'failed']: true, outcome };
  };
  try {
    if (typeof reserveCapacity === 'function') {
      await reserveCapacity({ jobs, estimatedTokens: estimateProviderTokens(jobs) });
    } else {
      await reserveProviderCapacity({
        jobs, apiBaseUrl: base, workerToken, fetchImpl, waitImpl,
        heartbeat: async (leasedJobs) => {
          for (const job of leasedJobs) {
            const renewed = await jsonRequest(
              fetchImpl,
              `${base}/ai/jobs/${encodeURIComponent(job.id)}/heartbeat`,
              workerToken,
              { profileId: job.profileId, leaseToken: job.leaseToken },
            );
            if (renewed.renewed !== true) {
              const error = new Error('worker lease heartbeat was refused');
              error.status = 409;
              throw error;
            }
          }
        },
      });
    }
    const byId = jobs.length > 1
      ? await provider.classifyBatch(jobs)
      : new Map([[jobs[0].id, await provider.classify(jobs[0])]]);
    const outcomes = [];
    for (const job of jobs) {
      if (!byId.has(job.id)) {
        outcomes.push(await settleFailure(job, new GeminiProviderError('Gemini omitted batch item')));
        continue;
      }
      try {
        const itemResult = byId.get(job.id);
        const facts = Array.isArray(itemResult) ? itemResult : (itemResult?.facts || []);
        const decision = Array.isArray(itemResult) ? null : (itemResult?.decision || null);
        const result = await jsonRequest(fetchImpl, `${base}/ai/jobs/${encodeURIComponent(job.id)}/result`, workerToken, {
          decision,
          facts,
          profileId: job.profileId,
          leaseToken: job.leaseToken,
          batchId,
          batchSize: jobs.length,
        });
        outcomes.push({ jobId: job.id, completed: true, result });
      } catch (error) {
        outcomes.push(await settleFailure(job, error));
      }
    }
    return { leased: true, completed: outcomes.every((item) => item.completed),
      retried: outcomes.some((item) => item.retried), failed: outcomes.some((item) => item.failed),
      jobId: jobs[0].id, batchSize: jobs.length, outcomes,
      ...(jobs.length === 1 ? { result: outcomes[0].result } : {}) };
  } catch (error) {
    const outcomes = [];
    for (const job of jobs) outcomes.push(await settleFailure(job, error));
    const backoffMs = error?.retryAfterMs || Math.max(0, ...outcomes.map((o) => o.outcome?.delayMs || 0).filter(Number.isFinite));
    return { leased: true, completed: false, retried: outcomes.some((item) => item.retried),
      failed: outcomes.some((item) => item.failed), jobId: jobs[0].id, batchSize: jobs.length, outcomes,
      ...(backoffMs > 0 ? { backoffMs } : {}) };
  }
}

function startWorker(options = {}) {
  const intervalMs = Math.max(250, Number(options.intervalMs || DEFAULT_INTERVAL_MS));
  const configuredMaxBatch = Math.max(1, Math.min(4, Number(options.maxBatch || DEFAULT_BATCH_MAX)));
  let adaptiveBatchSize = 1;
  let stopped = false;
  let timer = null;
  const tick = async () => {
    if (stopped) return;
    let nextDelay = intervalMs;
    try {
      const outcome = await runWorkerOnce({ ...options, maxBatch: adaptiveBatchSize });
      adaptiveBatchSize = nextAdaptiveBatchSize(adaptiveBatchSize, configuredMaxBatch, outcome);
      if (outcome?.retried && outcome?.backoffMs > 0) {
        nextDelay = Math.max(intervalMs, outcome.backoffMs);
        console.warn(`Gemini worker throttled (429/quota), sleeping for ${Math.round(nextDelay / 1000)}s`);
      }
    } catch (error) {
      console.error('Gemini worker tick failed:', error.message || error);
      if (error?.status === 429 || error?.retryable) {
        nextDelay = Math.max(intervalMs, error?.retryAfterMs || 30000);
        console.warn(`Gemini worker throttled, sleeping for ${Math.round(nextDelay / 1000)}s`);
      }
    } finally {
      if (!stopped) timer = setTimeout(tick, nextDelay);
    }
  };
  timer = setTimeout(tick, 0);
  return () => {
    stopped = true;
    if (timer) clearTimeout(timer);
  };
}

if (require.main === module) {
  if (!process.env.AI_WORKER_TOKEN || !process.env.GEMINI_API_KEY) {
    console.error('Gemini worker requires AI_WORKER_TOKEN and GEMINI_API_KEY');
    process.exitCode = 1;
  } else {
    startWorker();
  }
}

module.exports = {
  GeminiProvider,
  GeminiProviderError,
  DECISION_TOPICS,
  REJECTION_REASONS,
  DECISION_SCHEMA,
  UNIVERSAL_SYSTEM_INSTRUCTION,
  UNIVERSAL_RESPONSE_SCHEMA,
  UNIVERSAL_BATCH_RESPONSE_SCHEMA,
  FEW_SHOT_EXAMPLES,
  SPEND_CATEGORIES,
  buildGeminiPrompt,
  buildGeminiBatchPrompt,
  parseModelJson,
  nextAdaptiveBatchSize,
  estimateProviderTokens,
  reserveProviderCapacity,
  runWorkerOnce,
  startWorker,
};
