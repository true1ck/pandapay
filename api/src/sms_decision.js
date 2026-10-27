const DECISION_TOPICS = [
  'card_spend', 'card_refund', 'upi_debit', 'upi_credit',
  'atm_withdrawal', 'bank_transfer', 'bill_due_notice',
  'bill_payment_success', 'mandate_autopay', 'investment_purchase',
  'salary_or_income', 'telecom_carrier_deduction', 'loan_upsell_or_offer',
  'credit_card_limit_upsell', 'otp_or_security_code',
  'generic_promotional_spam', 'informational_balance_notice',
  'pay_later_due_notice', 'pay_later_drawdown', 'other_non_financial',
];

const REJECTION_REASONS = [
  'none', 'telecom_carrier_deduction', 'loan_upsell',
  'promotional_spam', 'security_otp', 'credit_limit_upsell', 'non_financial',
];

const DECISION_FIELDS = ['topic', 'shouldConsider', 'rejectionReason'];

/**
 * Validate the small, safety-critical classification envelope independently
 * from Gemini's response schema. Invalid decisions are kept for manual review;
 * they must never be treated as an instruction to dismiss an SMS.
 */
function validateDecision(decision, facts = []) {
  const errors = [];
  if (!decision || typeof decision !== 'object' || Array.isArray(decision)) {
    return { valid: false, errors: ['decision must be an object'] };
  }
  if (Object.keys(decision).some((key) => !DECISION_FIELDS.includes(key))) {
    errors.push('decision contains unsupported fields');
  }
  if (!DECISION_TOPICS.includes(decision.topic)) errors.push('decision.topic is unsupported');
  if (typeof decision.shouldConsider !== 'boolean') {
    errors.push('decision.shouldConsider must be a boolean');
  }
  if (!REJECTION_REASONS.includes(decision.rejectionReason)) {
    errors.push('decision.rejectionReason is unsupported');
  }
  if (decision.shouldConsider === true && decision.rejectionReason !== 'none') {
    errors.push('trackable decisions must use rejectionReason=none');
  }
  if (decision.shouldConsider === false && decision.rejectionReason === 'none') {
    errors.push('dismiss decisions require an explicit rejection reason');
  }
  if (decision.shouldConsider === false && (!Array.isArray(facts) || facts.length !== 0)) {
    errors.push('dismiss decisions must not contain facts');
  }
  return { valid: errors.length === 0, errors };
}

module.exports = { DECISION_TOPICS, REJECTION_REASONS, validateDecision };
