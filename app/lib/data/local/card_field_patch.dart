/// How a queued card edit (`card_fields_patch` command, the card's own PATCH
/// route) looks on the stored card row.
///
/// One mapping, used twice: the store lays pending edits over every read (so a
/// wallet refresh that brings back the server's older copy cannot flip the card
/// back before the edit is delivered), and the delivered edit is written into
/// the stored copy so it stays after the command is gone.
///
/// A null value means "leave as it is" (the PATCH route skips nulls), except
/// `last4`, where '' really clears the digits.
Map<String, dynamic> cardStorePatchFromCommand(Map<String, Object?> payload) {
  final patch = <String, dynamic>{};
  void copy(String from, String to) {
    final value = payload[from];
    if (value != null) patch[to] = value;
  }

  copy('nickname', 'nickname');
  copy('creditLimitInr', 'credit_limit_inr');
  copy('statementDay', 'statement_day');
  copy('dueDay', 'due_day');
  copy('autopayMode', 'autopay_mode');
  if (payload.containsKey('last4') && payload['last4'] != null) {
    final last4 = payload['last4'] as String;
    patch['last4'] = last4.isEmpty ? null : last4;
  }
  if (payload['clearAnnualFeeOverride'] == true) {
    patch['annual_fee_override_inr'] = null;
  } else {
    copy('annualFeeOverrideInr', 'annual_fee_override_inr');
  }
  return patch;
}
