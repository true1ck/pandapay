/// Coarse message family, used only to slice golden metrics. A port of the
/// family list in `docs/sms-pipeline-v2/seed/real_sms_tools/analyze.py`; the
/// first matching family wins.
const List<(String, String)> _families = [
  ('otp_security', r'\botp\b|one.time password|verification code|do not share|never share your'),
  ('ipo_asba_hold', r'\basba\b|\bipo\b|\bunblock|\bblocked\b.*(?:application|mandate|amount)|\blien\b'),
  ('mandate_autopay', r'mandate|autopay|auto.pay|e-?nach|\bumrn\b|standing instruction|\bsi\b'),
  ('card_payment', r'payment.{0,40}(?:received|credited).{0,40}card|card.{0,40}payment.{0,20}(?:received|credited)|towards.{0,30}credit card|\bbbps\b|\bcred\b|billpay'),
  ('bill_statement', r'statement|total (?:amt|amount) due|min(?:imum)?\.? (?:amt |amount )?due|due date|bill (?:generated|is due|due)'),
  ('limit', r'credit limit|limit.{0,30}(?:enhanc|increas|revis)'),
  ('reward_points', r'reward points?|\bpoints\b|cashback'),
  ('wallet', r'wallet|amazon pay|zomato money|mobikwik|freecharge|paytm balance|pay balance'),
  ('refund_reversal', r'refund|revers'),
  ('salary_income', r'salary|\bsal\b'),
  ('investment', r'mutual fund|\bsip\b|folio|\bnav\b|\bunits\b|groww|zerodha|upstox|demat|allot|redemption'),
  ('loan_emi', r'\bemi\b|\bloan\b'),
  ('insurance', r'premium|policy'),
  ('failed_declined', r'failed|declined|unsuccessful|insufficient|could not be processed'),
  ('card_spend', r'\bspent\b|purchase|card.{0,30}(?:used|txn|transaction)|txn.{0,30}card'),
  ('debit', r'debited|\bsent\b|\bpaid\b|transferred|withdrawn|withdrawal'),
  ('credit', r'credited|received|deposited'),
  ('balance', r'avl\.? bal|available balance|a/c bal|balance (?:is|in)'),
  ('promotion', r'\boffer|apply now|pre-?approved|eligible|limited period|\bwin\b|exclusive|upgrade|click|% off|discount'),
  ('delivery_service', r'deliver|dispatch|shipped|order|out for delivery|recharge|data pack|validity'),
];

final List<(String, RegExp)> _familyRx = [
  for (final (name, pattern) in _families)
    (name, RegExp(pattern, caseSensitive: false)),
];

String guessFamily(String body) {
  for (final (name, rx) in _familyRx) {
    if (rx.hasMatch(body)) return name;
  }
  return 'other';
}
