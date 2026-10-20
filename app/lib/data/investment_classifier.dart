/// Returns true when a statement/SMS description represents money moving into
/// an investment or broker account rather than consumption.
///
/// This intentionally requires both movement language and investment intent so
/// a broker name by itself (for example, a brokerage fee) is not enough.
bool isInvestmentMovementDescription(String value) {
  final text = value.trim();
  if (text.isEmpty) return false;

  final provider = RegExp(
    r'\b(?:zerodha|groww|upstox|angel\s+one|dhan|paytm\s+money|indmoney|5paisa|motilal\s+oswal|icici\s+direct|hdfc\s+securities|demat|trading|broker(?:age|ing)?|portfolio)\b',
    caseSensitive: false,
  ).hasMatch(text);
  final explicitIntent = RegExp(
    r'\b(?:sip|systematic\s+investment|mutual\s+fund|investment|invested|investment\s+account|add(?:ing|ed)?\s+(?:money|funds?)|funds?\s+(?:added|credited|transferred|deposited)|top[- ]?up|fund(?:ed|ing)|buy|bought|purchase(?:d)?|units?|stocks?|shares?|equity)\b',
    caseSensitive: false,
  ).hasMatch(text);
  final movement = RegExp(
    r'\b(?:debit(?:ed)?|paid|sent|transferred|withdrawn|invested|purchased|bought|credited|received|deposited|add(?:ing|ed)?|funded|top[- ]?up)\b',
    caseSensitive: false,
  ).hasMatch(text);
  if (!movement) return false;

  final brokerFunding = provider && RegExp(
    r'\b(?:add(?:ing|ed)?|fund(?:s|ed|ing)?|top[- ]?up|debit(?:ed)?|paid|sent|transferred|credited|deposited)\b',
    caseSensitive: false,
  ).hasMatch(text);
  if (!explicitIntent && !brokerFunding) return false;

  final feeOnly = RegExp(
    r'\b(?:fee|fees|charge|charges|commission|brokerage\s+fee|annual\s+maintenance)\b',
    caseSensitive: false,
  ).hasMatch(text);
  if (feeOnly && !RegExp(
    r'\b(?:sip|mutual\s+fund|investment|invested|add(?:ing|ed)?\s+(?:money|funds?))\b',
    caseSensitive: false,
  ).hasMatch(text)) {
    return false;
  }
  return true;
}
