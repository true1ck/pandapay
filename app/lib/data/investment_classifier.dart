/// Returns true when a statement/SMS description represents money moving into
/// an investment or broker account rather than consumption.
///
/// This intentionally requires both movement language and investment intent so
/// a broker name by itself (for example, a brokerage fee) is not enough.
bool isInvestmentMovementDescription(String value) {
  final text = value.trim();
  if (text.isEmpty) return false;
  if (isInvestmentFolioAllotment(text)) return false;

  final provider = RegExp(
    r'\b(?:zerodha|groww|upstox|angel\s+one|dhan|paytm\s+money|indmoney|5paisa|motilal\s+oswal|icici\s+direct|hdfc\s+securities|demat|trading|broker(?:age|ing)?|portfolio)\b',
    caseSensitive: false,
  ).hasMatch(text);
  final explicitIntent = RegExp(
    r'\b(?:sip|systematic\s+investment|mutual\s+fund|investment|invested|investment\s+account|asba|ipo|add(?:ing|ed)?\s+(?:money|funds?)|funds?\s+(?:added|credited|transferred|deposited)|top[- ]?up|fund(?:ed|ing)|buy|bought|purchase(?:d)?|units?|stocks?|shares?|equity)\b',
    caseSensitive: false,
  ).hasMatch(text);
  final movement = RegExp(
    r'\b(?:debit(?:ed)?|paid|sent|transferred|withdrawn|invested|purchased|bought|credited|received|deposited|add(?:ing|ed)?|funded|top[- ]?up|blocked|lien|accepted)\b',
    caseSensitive: false,
  ).hasMatch(text);
  if (!movement) return false;

  final brokerFunding = provider && RegExp(
    r'\b(?:add(?:ing|ed)?|fund(?:s|ed|ing)?|top[- ]?up|debit(?:ed)?|paid|sent|transferred|credited|deposited)\b',
    caseSensitive: false,
  ).hasMatch(text);
  if (!explicitIntent && !brokerFunding) return false;
  // A broker settlement payout is money vacating the investment account
  // toward the bank, not funding. It must never register as a contribution.
  if (isBrokerSettlementMessage(text)) return false;

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

/// True when a broker (Dhan, Zerodha, Groww, etc.) reports a settlement
/// payout of trading balance into the user's own bank account. Money leaves
/// the investment account and lands in the bank: an investment-proceeds
/// movement — never earned income, never spending, never new funding. The
/// phrase "add funds back to your [broker] account" is an instruction about
/// the user's next step, not this transaction.
bool isBrokerSettlementMessage(String value) {
  final text = value.trim();
  if (text.isEmpty) return false;
  return RegExp(
    r'\b(?:dhan|zerodha|groww|upstox|angel\s+one|5paisa|sharekhan|motilal\s+oswal|hdfc\s+securities|icici\s+direct|kotak\s+securities|paytm\s+money|iifl)\b',
    caseSensitive: false,
  ).hasMatch(text) &&
      RegExp(
    r'\b(?:running\s+account\s+settlement|quarterly\s+settlement|account\s+settlement|settlement\s+(?:payout|credit|dated)|payout|pay-?out|funds?\s+released)\b',
    caseSensitive: false,
  ).hasMatch(text);
}

/// Returns true when a message confirms allotment of units in a mutual fund folio
/// rather than a cash movement from a bank or broker account.
bool isInvestmentFolioAllotment(String body) {
  final text = body.toLowerCase();
  final hasAllotment = RegExp(
    r'\b(?:units?\s+allotted|allotted\s+at\s+nav|units?\s*:\s*[\d.]+\s*,\s*nav|nav\s*:\s*[\d.]+|units?\s+(?:credited|allotted)\s+under\s+folio|allotted\s+for\s+your\s+investment)\b',
    caseSensitive: false,
  ).hasMatch(text);
  final hasFolioOrFund = RegExp(
    r'\b(?:folio|fund|mutual\s+fund|amc)\b',
    caseSensitive: false,
  ).hasMatch(text);
  return hasAllotment && hasFolioOrFund;
}

