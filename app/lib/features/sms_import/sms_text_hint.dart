/// UA-5.3 (Chunk 31): pure-Dart, on-device half of SMS auto-import — no
/// platform channel, no `telephony` plugin, in this file. Kept separate
/// from the listener wiring (`sms_listener_service.dart`) for the same
/// reason UA-4 (Chunk 30) split `card_text_matcher.dart` out from
/// `card_scanner.dart`: this half is unit-testable without a device.
///
/// The actual amount/merchant/date parsing is done server-side by
/// `api/src/sms_parser.js` against the admin-managed `parser_patterns`
/// table (that's the part with real regex catalogue + telemetry). This
/// file does NOT duplicate that. What it does is a much narrower,
/// deliberately dumb job: pull a plausible last-4-digit "card ending in
/// ____" hint out of raw SMS text purely so the on-device UI can show the
/// user something ("this SMS looks like it's for a card ending 4321 — pick
/// which of your cards that is") when asking them to confirm which
/// `userCardId` a parsed SMS should be attributed to. `user_cards` has no
/// last4 column in this schema (checked db/supabase/migrations/0004 and
/// 0006), so this can never be an automatic match — it's a display hint
/// only, and callers must not treat it as a resolved card id.
library;

/// Returns a bare 4-digit string if [smsBody] contains a "ending NNNN" /
/// "XXNNNN" / "card NNNN" style last-4 mention, else null. Deliberately
/// conservative: multiple distinct 4-digit candidates (e.g. an OTP or a
/// reference number sitting next to the real card suffix) means "not
/// confident enough" — returns null rather than guessing which one.
String? extractLast4Hint(String smsBody) {
  final matches = RegExp(
    r'(?:ending|card(?:\s+no\.?)?|xx|XX)\s*[:\-]?\s*(\d{4})\b',
    caseSensitive: false,
  ).allMatches(smsBody).map((m) => m.group(1)!).toSet();

  if (matches.length != 1) return null;
  return matches.first;
}

/// Rough client-side pre-filter for "does this look like a bank
/// transaction SMS at all" — used only to decide whether it's worth
/// forwarding to POST /transactions/from-sms in the first place (avoids
/// spamming the server/parser_failures table with every unrelated SMS a
/// device receives, e.g. OTPs, delivery notifications, spam). This is
/// intentionally loose/high-recall: the real accept/reject decision is the
/// server-side regex match, not this. A false positive here just costs one
/// extra API call; a false negative here means a real transaction is
/// silently never even attempted.
bool looksLikeTransactionSms(String smsBody) {
  final lower = smsBody.toLowerCase();
  const keywords = ['spent', 'debited', 'credited', 'txn', 'transaction', 'purchase of', 'paid'];
  return keywords.any(lower.contains);
}
