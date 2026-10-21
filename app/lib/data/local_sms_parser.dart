import 'package:pandapay_domain/pandapay_domain.dart';

import 'investment_classifier.dart';
import 'user_cards_repository.dart';
import 'local/sms_intake_repository.dart';
import 'local/sms_rule_bundle.dart';

enum LocalSmsEventType {
  transaction,
  bill,
  autopay,
  promotion,
  balance,
  failed,
  security,
  unknown,
}

enum LocalSmsDisposition { sync, localObservation, localIgnore, review }

extension LocalSmsEventTypeWire on LocalSmsEventType {
  String get wireValue => switch (this) {
    LocalSmsEventType.transaction => 'transaction',
    LocalSmsEventType.bill => 'bill',
    LocalSmsEventType.autopay => 'autopay',
    LocalSmsEventType.promotion => 'promotion',
    LocalSmsEventType.balance => 'balance',
    LocalSmsEventType.failed => 'failed',
    LocalSmsEventType.security => 'security',
    LocalSmsEventType.unknown => 'unknown',
  };
}

extension LocalSmsDispositionWire on LocalSmsDisposition {
  String get wireValue => switch (this) {
    LocalSmsDisposition.sync => 'sync',
    LocalSmsDisposition.localObservation => 'local_observation',
    LocalSmsDisposition.localIgnore => 'local_ignore',
    LocalSmsDisposition.review => 'review',
  };
}

class LocalSmsObservation {
  final TransactionEntry? transaction;
  final String? cardLast4, accountLast4;
  final String? billerName;
  final String? cadenceHint;
  final DateTime? dueDate;
  final DateTime? statementDate;
  final bool statementDateExplicit;
  final Money? availableBalance, amountDue, minimumDue, autopayLimit;
  final LocalSmsEventType eventType;
  final LocalSmsDisposition disposition;
  final List<String> reasonCodes;
  final double confidence;
  const LocalSmsObservation({
    this.transaction,
    this.cardLast4,
    this.accountLast4,
    this.billerName,
    this.cadenceHint,
    this.dueDate,
    this.statementDate,
    this.statementDateExplicit = false,
    this.availableBalance,
    this.amountDue,
    this.minimumDue,
    this.autopayLimit,
    this.eventType = LocalSmsEventType.unknown,
    this.disposition = LocalSmsDisposition.review,
    this.reasonCodes = const [],
    this.confidence = 0,
  });
}

/// Best-effort values for the manual review sheet. These are suggestions only:
/// the user must confirm them before anything is written as a transaction.
class LocalSmsReviewDraft {
  final Money? amount;
  final String? merchantName;
  final DateTime occurredAt;
  final String? cardLast4;
  final TxnInstrument instrument;
  final TxnEntryKind entryKind;

  const LocalSmsReviewDraft({
    required this.amount,
    required this.merchantName,
    required this.occurredAt,
    required this.cardLast4,
    required this.instrument,
    required this.entryKind,
  });
}

/// Versioned conservative built-in grammar. Unsupported/admin-configured
/// formats remain durable intake for server parsing; they never become guessed
/// spending. Values are local observations until server reconciliation.
class LocalSmsParser {
  // 8: the server can now resolve a card bill notice whose suffix is printed
  // straight after the instrument ("Credit Card 8708 bill"), so the open
  // review queue is re-examined once more and a card's due day can finally be
  // learned from its own AutoPay message.
  static const version = 8;

  /// Messages with a quoted price or a card name are not necessarily a
  /// payment. Apply this before either upload or manual review, including to
  /// rows captured by an older app version.
  static bool isNonTransactionNoise(String sender, String body) {
    final text = body.replaceAll(RegExp(r'\s+'), ' ');
    // A real amount due or statement remains useful even when the issuer
    // appends an offer. Let the bill parser handle it.
    if (_re(
      r'\b(?:payment|amount|minimum|total)\s+due\b|\bdue\s+date\b|\b(?:statement|bill|premium)\b[\s\S]{0,80}\b(?:generated|ready|available|due)\b',
    ).hasMatch(text)) {
      return false;
    }
    // Past aggregate spend is often quoted solely to sell an EMI conversion.
    // It is not a new debit alert.
    if (_re(
          r'\b(?:eligible\s+for\s+conversion|convert(?:ion)?\s+(?:to|into)\s+(?:flexipay\s+)?emi|flexipay\s+emis?)\b',
        ).hasMatch(text) &&
        !_re(r'\b(?:your\s+)?(?:txn|transaction)\s+of\b').hasMatch(text)) {
      return true;
    }
    final completed = _re(
      r'\b(?:your\s+(?:txn|transaction)\s+of|txn\s+(?:of|for)|(?:has\s+been|was|is)\s+(?:debited|credited|charged|paid)|(?:debited|credited|spent|paid|charged|transferred|withdrawn|received)\s*(?:₹|rs\.?|inr)|(?:recharge|payment|transaction|purchase)\b[\s\S]{0,45}\b(?:successful|completed))',
    ).hasMatch(text);
    if (completed ||
        (_re(r'\b(?:cashback|refund)\b').hasMatch(text) &&
            _re(r'\b(?:credited|received|deposited)\b').hasMatch(text))) {
      return false;
    }
    if (_re(r'\bautopay\s+(?:alert|reminder)\b').hasMatch(text)) {
      return false;
    }
    final offer = _re(
      r'\b(?:offer|sale|discount|cashback|voucher|coupon|rewarding|shop\s+at|grab|buy\s+now|apply\s+now|prices?\s+slashed|treat\s+yourself|festive\s+shopping|eligible\s+for\s+conversion|convert\s+(?:to|into)\s+emi|international\s+roaming\s+pack)\b|\b(?:get|earn|save)\b[\s\S]{0,45}\b(?:reward|cashback|off|free|voucher)\b',
    ).hasMatch(text);
    final serviceNotice = _re(
      r'\b(?:services?\s+(?:is|are|has\s+been)\s+(?:blocked|suspended)|visit\s+(?:your\s+)?nearest\s+branch|suspicious\s+(?:txns?|transactions?)\s+in\s+your\s+account|call\s+forwarding\s+is\s+(?:now\s+)?active|calls?\s+are\s+being\s+forwarded|to\s+deactivate\s+(?:this\s+)?service)\b',
    ).hasMatch(text);
    final promotionalSender = _re(r'-p\s*$').hasMatch(sender);
    return offer ||
        serviceNotice ||
        (promotionalSender &&
            !_re(
              r'\b(?:txn|transaction|debited|credited|spent|paid|charged|received|refund|statement|bill\s+due)\b',
            ).hasMatch(text));
  }

  /// True only for a deposit/current/savings-bank alert. Account-shaped
  /// suffixes from insurance, demat, brokerage, investment, and card alerts
  /// must not create rows in Home's bank-account snapshot.
  static bool isBankAccountMessage(String body, [String sender = '']) {
    final text = body.toLowerCase();
    if (text.trim().isEmpty ||
        RegExp(r'\b(?:credit|debit)\s+card\b').hasMatch(text)) {
      return false;
    }
    if (RegExp(
      r'\b(?:lic|life\s+insurance|policy|premium|demat|trading|broker(?:age|ing)?|portfolio|holdings?|folio|dp\s*id|client\s*id|nav|units?|shares?|stocks?|equity|sip|mutual\s+fund|investment|zerodha|groww|upstox|angel\s+one|dhan|paytm\s+money)\b',
    ).hasMatch(text)) {
      return false;
    }
    final accountMarker = RegExp(
      r'\b(?:bank|a\/?c\.?|account|savings|current|upi|imps|neft|rtgs|atm)\b',
    ).hasMatch(text);
    final bankIdentityMarker =
        RegExp(
          r'\b(?:bank|a\/?c\.?|savings|current|upi|imps|neft|rtgs|atm)\b',
        ).hasMatch(text) ||
        RegExp(
          r'(?:bank|bnk|bk|upi|sbi|uco|axis|canara|canbnk|canbk|hdfc|kotak|union|equitas|pnb|icici|idbi|indus|yes|rbl|bob|boi|pytm|paytm|federal|aubank|citi|hsbc|dbs|scb)',
        ).hasMatch(sender.toLowerCase());
    final balanceMarker = RegExp(
      r'\b(?:available|avail|avl|current|closing|clr|new)\s*(?:balance|bal)\b',
    ).hasMatch(text);
    final movementMarker = RegExp(
      r'\b(?:debited|debit|credited|credit|paid|spent|sent|transferred|withdrawn|received|deposited)\b',
    ).hasMatch(text);
    // A balance phrase alone is not enough: policy and investment alerts can
    // also contain balance wording. Require explicit account/bank language
    // alongside the balance or completed movement.
    return accountMarker &&
        bankIdentityMarker &&
        (balanceMarker || movementMarker);
  }

  static bool _ownAccountTransfer(String body) => _re(
    r'\b(?:self[ -]?transfer|own\s+(?:bank\s+)?account|between\s+(?:my|your)\s+(?:bank\s+)?accounts)\b|\bfrom\s+your\b[\s\S]{0,100}\bto\s+your\b[\s\S]{0,80}\b(?:a\/?c\.?|account)\b',
  ).hasMatch(body);

  static bool _accountToAccountTransfer(String body) => _re(
    r'\bfrom\b[\s\S]{0,100}\b(?:a\/?c\.?|account)\s*[*xX-]*\s*\d{4}[\s\S]{0,100}\b(?:to|towards?)\b[\s\S]{0,100}\b(?:a\/?c\.?|account)\s*[*xX-]*\s*\d{4}\b|\b(?:a\/?c\.?|account)\s*[*xX-]*\s*\d{4}[\s\S]{0,35}\b(?:debited|sent|transferred|paid)\b[\s\S]{0,100}\b(?:to|towards?)\b[\s\S]{0,100}\b(?:a\/?c\.?|account)\s*[*xX-]*\s*\d{4}\b',
  ).hasMatch(body);

  static bool _walletLoad(String body) => _re(
    // Require a wallet-ish noun within a short window after the load verb. A
    // bare "add funds" cannot win: broker alerts say "add funds back to your
    // Dhan account" as an instruction for the next action, which is not this
    // transaction. Named-wallet branches below carry the common real shapes.
    r'\b(?:wallet\s+load|load(?:ed|ing)?\s+(?:the\s+)?(?:paytm|phonepe|amazon\s*pay|mobikwik|wallet)|money\s+added\s+to\s+(?:the\s+)?wallet|add\s+(?:money|funds?)|top[ -]?up|money\s+added)\b[\s\S]{0,40}\b(?:paytm|phonepe|amazon\s*pay|mobikwik|wallet)\b|\b(?:paytm|phonepe|amazon\s*pay|mobikwik)\b[\s\S]{0,40}\b(?:add\s+(?:money|funds?)|top[ -]?up|wallet\s+load|added)\b|\b(?:added|loaded|credited)\s+to\s+(?:the\s+)?(?:paytm|phonepe|amazon\s*pay|mobikwik)\s+wallet\b|\b(?:paytm|phonepe|amazon\s*pay|mobikwik)\s+wallet\b[\s\S]{0,30}\b(?:added|loaded|credited)\b',
  ).hasMatch(body);

  static bool _brokerSettlement(String body) => isBrokerSettlementMessage(body);

  static const _ownNameNoise = {'mr', 'mrs', 'ms', 'shri', 'smt', 'dr', 'prof'};

  static List<String> _personNameTokens(String value) => RegExp(r"[a-z][a-z']+")
      .allMatches(value.toLowerCase())
      .map((m) => m.group(0)!)
      .where((t) => t.length >= 3 && !_ownNameNoise.contains(t))
      .toList();

  /// UPI/QR transfers frequently address a person by name instead of an
  /// account suffix. When that name is the account owner's profile name the
  /// movement is a self transfer even though the SMS never says so. Deliberately
  /// strict: at least two profile-name tokens must appear, so a namesake
  /// store ("Sujay Enterprises") or a relative sharing one name cannot count.
  /// Ceiling: one-token profile names never match; add initial handling only
  /// if real profiles need it.
  static bool _isOwnPersonName(String candidate, String? ownUserName) {
    final nameTokens = _personNameTokens(ownUserName ?? '');
    if (nameTokens.length < 2) return false;
    final recipientTokens = _personNameTokens(candidate);
    if (recipientTokens.isEmpty) return false;
    var matched = 0;
    for (final nameToken in nameTokens) {
      if (recipientTokens.any(
        (token) =>
            token == nameToken ||
            (token.length >= 2 && nameToken.startsWith(token)) ||
            (nameToken.length >= 2 && token.startsWith(nameToken)),
      )) {
        matched += 1;
      }
    }
    return matched >= 2;
  }

  /// Credit rows say "credited to your A/C *9080 from NAME", so the shared
  /// merchant capture grabs the account clause instead of the person. This
  /// reads the person out of the from-clause directly for own-name matching.
  static bool _ownNameInFromClause(String body, String? ownUserName) {
    if (ownUserName == null) return false;
    final match = _re(
      r"\bfrom\s+([A-Za-z][A-Za-z0-9 .&'@_/-]{1,80}?)(?=\s+(?:on|for|ref(?:erence)?|txn|utr|a\/?c\.?|account|bal(?:ance)?|avl|available)\b|[.,;]|$)",
    ).firstMatch(body);
    return match != null &&
        _isOwnPersonName(match.group(1)!.trim(), ownUserName);
  }

  static bool _incomingBankTransferCandidate(String body) =>
      !_re(r'\b(?:salary|cashback|refund(?:ed)?)\b').hasMatch(body) &&
      _re(r'\bfrom\b[\s\S]{0,80}\b(?:bank|a\/?c\.?|account)\b').hasMatch(body);

  static bool _earnedIncomeCredit(String body) =>
      !_re(
        r'\b(?:refund(?:ed)?|chargeback|reversal|reversed|cashback|reward|rewards|points?|miles?|loan|personal\s+loan|credit\s+line|investment|mutual\s+fund|shares?|stocks?|demat|portfolio|cash\s+deposit|gift|reimburse(?:ment|d)?|expense\s+claim)\b',
      ).hasMatch(body) &&
      !_re(r'\bsalary\s+advance\b').hasMatch(body) &&
      _re(
        r'\b(?:salary|wages?|payroll|pension|interest|dividend|rent|commission|consulting|business\s+(?:receipt|income)|invoice\s+paid)\b',
      ).hasMatch(body);

  static bool _loanRepayment(String body) =>
      !_feeCharge(body) &&
      _re(
        r'\b(?:loan|personal\s+loan|home\s+loan|car\s+loan|education\s+loan|emi|equated\s+monthly\s+installment|instalment)\b[\s\S]{0,90}\b(?:paid|payment|debited|repaid|repayment|deducted|transferred)\b',
      ).hasMatch(body);

  static bool _feeCharge(String body) => _re(
    r'\b(?:bank\s+charge|service\s+charge|processing\s+fee|convenience\s+fee|late\s+fee|annual\s+fee|maintenance\s+fee|finance\s+charge|interest\s+charge|interest\s+(?:on\s+)?(?:loan|emi)|(?:loan|emi)\s+interest|commission|brokerage\s+fee|gst\s+on\s+(?:fee|charge))\b',
  ).hasMatch(body);

  static bool _investmentProceeds(String body) =>
      (_re(
        r'\b(?:redeemed?|redemption|sold|sale\s+proceeds?|withdrawn?)\b',
      ).hasMatch(body) &&
      _re(
        r'\b(?:mutual\s+fund|sip|investment|shares?|stocks?|equity|zerodha|groww|upstox|angel\s+one|dhan|demat|portfolio)\b',
      ).hasMatch(body));

  static bool _cardCredit(String body) {
    if (!_re(r'\b(?:credit|debit)\s+card\b|\bcard\b').hasMatch(body)) {
      return false;
    }
    if (_re(
      r'\b(?:payment|amount|minimum)\s+due\b|\bdue\s+on\b',
    ).hasMatch(body)) {
      return false;
    }
    if (_re(
          r'\b(?:declined|failed|pending|processing|initiated|cancelled|canceled)\b',
        ).hasMatch(body) &&
        !_re(r'\b(?:reversed|refunded|credited)\b').hasMatch(body)) {
      return false;
    }
    return _re(
          r'\b(?:credited|received|refunded|refund|cashback|reward|statement\s+credit|balance\s+adjustment)\b',
        ).hasMatch(body) ||
        (_re(r'\b(?:reversed|reversal)\b').hasMatch(body) &&
            _re(r'\b(?:posted|applied|credited)\b').hasMatch(body));
  }

  static bool sensitive(String body) => RegExp(
    r"\b(?:otp|one[-\s]?time password|verification code|security code|cvv|pin)\b|\b(?:do not|don't|never)\s+share\b|\b\d{4,8}\b[\s\S]{0,40}\bvalid\s+(?:for|till|until)\s+\d+\s*(?:minutes?|mins?|seconds?|secs?)\b",
    caseSensitive: false,
  ).hasMatch(body);
  static RegExp _re(String s) => RegExp(s, caseSensitive: false);

  /// Extracts a display-safe biller name without retaining the raw SMS.
  /// Bank sender IDs are transport identifiers (for example, TNBPAY), not
  /// the provider name a person should see in a commitment list.
  static String? extractBillerName(String body) {
    final text = body.replaceAll(RegExp(r'\s+'), ' ').trim();
    final patterns = [
      _re(
        r'\b(?:your|the)\s+([A-Za-z][A-Za-z0-9 .&\x27/-]{2,80}?)\s+(?:bill|invoice|premium)\b',
      ),
      _re(
        r'\b(?:bill|invoice|premium)\s+(?:from|of)\s+([A-Za-z][A-Za-z0-9 .&\x27/-]{2,80}?)(?=\s+(?:of|is|due|pay|dated|for)\b|[,.;]|$)',
      ),
    ];
    for (final pattern in patterns) {
      final match = pattern.firstMatch(text);
      final candidate = match?.group(1)?.trim();
      if (candidate == null || candidate.length < 3) continue;
      if (_re(
        r'^(?:credit card|card|account|bank|payment|electricity|water|gas|utility|internet|mobile|phone|broadband|insurance|premium)$',
      ).hasMatch(candidate)) {
        continue;
      }
      return candidate.replaceAll(RegExp(r'\s+'), ' ');
    }
    return null;
  }

  static const dateToken =
      r'(?:\d{4}[./-]\d{1,2}[./-]\d{1,2}|\d{1,2}[./-]\d{1,2}[./-]\d{2,4}|\d{1,2}(?:st|nd|rd|th)?[\s./-]+[A-Za-z]{3,9}[,\s./-]+\d{2,4}|[A-Za-z]{3,9}[\s./-]+\d{1,2}(?:st|nd|rd|th)?[,]?[\s./-]+\d{2,4})';

  static DateTime? parseDate(String raw) {
    final text = raw
        .replaceAllMapped(_re(r'(\d)(?:st|nd|rd|th)\b'), (m) => m[1]!)
        .trim();
    final parts = text.split(RegExp(r'[\s,./-]+'));
    if (parts.length != 3) return null;
    const months = [
      'jan',
      'feb',
      'mar',
      'apr',
      'may',
      'jun',
      'jul',
      'aug',
      'sep',
      'oct',
      'nov',
      'dec',
    ];
    int? month(String s) =>
        int.tryParse(s) ??
        (s.length >= 3 && months.contains(s.substring(0, 3).toLowerCase())
            ? months.indexOf(s.substring(0, 3).toLowerCase()) + 1
            : null);
    int? year, day, mon;
    if (parts[0].length == 4 && int.tryParse(parts[0]) != null) {
      year = int.tryParse(parts[0]);
      mon = month(parts[1]);
      day = int.tryParse(parts[2]);
    } else if (int.tryParse(parts[0]) != null) {
      day = int.tryParse(parts[0]);
      mon = month(parts[1]);
      year = int.tryParse(parts[2]);
    } else {
      mon = month(parts[0]);
      day = int.tryParse(parts[1]);
      year = int.tryParse(parts[2]);
    }
    if (year == null ||
        mon == null ||
        day == null ||
        mon < 1 ||
        mon > 12 ||
        day < 1) {
      return null;
    }
    if (year < 100) year += 2000;
    final date = DateTime(year, mon, day);
    return date.year == year && date.month == mon && date.day == day
        ? date
        : null;
  }

  /// Extracts review suggestions without changing the automatic transaction
  /// grammar. This is intentionally allowed to be incomplete because it is
  /// only used to reduce typing in a user-confirmed form.
  static LocalSmsReviewDraft reviewDraft({
    required String namespace,
    required String sender,
    required String body,
    required DateTime receivedAt,
    List<UserCard> cards = const [],
    String? ownUserName,
  }) {
    final parsed = parse(
      namespace: namespace,
      sender: sender,
      body: body,
      receivedAt: receivedAt,
      cards: cards,
      ownUserName: ownUserName,
    );
    final transaction = parsed?.transaction;
    if (transaction != null) {
      return LocalSmsReviewDraft(
        amount: transaction.amount,
        merchantName: transaction.merchantName,
        occurredAt: transaction.occurredAt,
        cardLast4: transaction.cardLast4,
        instrument: transaction.instrument,
        entryKind: transaction.entryKind,
      );
    }

    // These messages should normally never enter the manual queue because
    // capture handles them locally. Keep the review helper defensive anyway:
    // a hosted-parser response or an older cached queue must not turn a bill,
    // promotion, failure, or security amount into a suggested transaction.
    final localOnly =
        sensitive(body) ||
        (parsed != null && parsed.disposition != LocalSmsDisposition.review);

    Money? money(String? text) {
      if (text == null) return null;
      final match = RegExp(
        r'^(\d+)(?:\.(\d{1,2}))?$',
      ).firstMatch(text.replaceAll(',', ''));
      if (match == null) return null;
      final paise =
          int.parse(match[1]!) * 100 +
          int.parse((match[2] ?? '').padRight(2, '0'));
      final value = Money.fromPaise(paise);
      return value.paise > 0 ? value : null;
    }

    final completedSignal = _re(
      r'\b(?:spent|debit|debited|paid|purchase|purchased|charged|withdrawn|sent|transferred|credited|received|deposited|refunded|reversed|successful|successfully|completed)\b',
    ).hasMatch(body);
    final nonFinalSignal = _re(
      r'\b(?:pending|processing|initiated|declined|failed|failure|cancelled|canceled)\b|\b(?:will|shall|would)\s+be\b|\b(?:not|never)\s+(?:be\s+)?(?:credited|received|deposited|refunded|reversed)\b',
    ).hasMatch(body);
    final amount = !localOnly && completedSignal && !nonFinalSignal
        ? money(
            _re(
              r'(?:₹|rs\.?|inr)\s*[:.]?\s*([\d,]+(?:\.\d{1,2})?)',
            ).firstMatch(body)?.group(1),
          )
        : null;
    final cardLast4 =
        parsed?.cardLast4 ??
        _re(
          r'\b(?:credit|debit)\s+card\b[\s\S]{0,45}?\b(?:ending|last\s*4|no\.?)\D{0,8}(\d{4})\b',
        ).firstMatch(body)?.group(1);
    final dateMatch = _re(dateToken).firstMatch(body);
    final parsedDate = dateMatch == null
        ? null
        : parseDate(dateMatch.group(0)!);
    final occurredAt =
        !localOnly &&
            parsedDate != null &&
            !parsedDate.isAfter(receivedAt.add(const Duration(days: 1)))
        ? parsedDate
        : receivedAt;
    final merchant = localOnly
        ? null
        : _re(
            r'\b(?:at|to|for|from|by)\s+([A-Za-z_][A-Za-z0-9 ._&@*\x27/-]{1,80}?)(?=\s+(?:from|on|via|upi|ref(?:erence)?|txn|transaction|bal(?:ance)?|avl|available|if\s+not|call|sms\s+block)\b|\s*\(|[.,;]|$)',
          ).firstMatch(body)?.group(1)?.trim();
    final accountLike = _re(
      r'\b(?:a/c|account|upi|imps|neft)\b',
    ).hasMatch(body);
    final instrument =
        accountLike && !_re(r'\b(?:credit|debit)\s+card\b').hasMatch(body)
        ? TxnInstrument.upiBank
        : _re(
            r'\bdebit\s+card\b|\b(?:atm|cash\s+withdrawal|withdrawn)\b',
          ).hasMatch(body)
        ? TxnInstrument.debitCard
        : _re(r'\bcredit\s+card\b|\bcard\b').hasMatch(body)
        ? TxnInstrument.creditCard
        : TxnInstrument.other;
    final entryKind =
        _ownAccountTransfer(body) ||
            _accountToAccountTransfer(body) ||
            _brokerSettlement(body) ||
            _walletLoad(body) ||
            _cardCredit(body) ||
            (merchant != null &&
                ownUserName != null &&
                _isOwnPersonName(merchant, ownUserName)) ||
            _ownNameInFromClause(body, ownUserName) ||
            _re(
              r'\b(?:refund(?:ed)?|reversal|reversed|cashback|reward|salary\s+advance|loan\s+disbursement|cash\s+deposit|cash\s+withdrawal)\b',
            ).hasMatch(body)
        ? TxnEntryKind.transfer
        : _re(r'\b(?:credited|received|deposited)\b').hasMatch(body) &&
              _earnedIncomeCredit(body)
        ? TxnEntryKind.income
        : TxnEntryKind.spend;

    return LocalSmsReviewDraft(
      amount: amount,
      merchantName: merchant,
      occurredAt: occurredAt,
      cardLast4: cardLast4,
      instrument: instrument,
      entryKind: entryKind,
    );
  }

  static LocalSmsObservation? parse({
    required String namespace,
    required String sender,
    required String body,
    required DateTime receivedAt,
    List<UserCard> cards = const [],
    String? ownUserName,
    SmsRuleBundle? downloadedRules,
  }) {
    if (body.length > 20000 || sensitive(body)) return null;

    // Safety gate: built-in non-transaction noise checks MUST run before any
    // downloaded rule. A downloaded rule can never turn marketing/promotional
    // offers, EMI solicitations or service notices into financial events.
    if (isNonTransactionNoise(sender, body)) {
      return const LocalSmsObservation(
        eventType: LocalSmsEventType.promotion,
        disposition: LocalSmsDisposition.localIgnore,
        reasonCodes: ['non_transaction_message'],
      );
    }

    if (downloadedRules != null && downloadedRules.rules.isNotEmpty) {
      for (final rule in downloadedRules.rules) {
        if (!rule.matchesSender(sender)) continue;
        final match = rule.regExp.firstMatch(body);
        if (match == null) continue;

        final obs = _applyDownloadedRule(
          namespace: namespace,
          rule: rule,
          match: match,
          sender: sender,
          body: body,
          receivedAt: receivedAt,
          cards: cards,
        );
        if (obs != null) return obs;
      }
    }
    final cardLast4 =
        _re(
          r'\b(?:credit\s+|debit\s+)?card\b[\s\S]{0,45}?(?:ending(?:\s+with)?\s*|x{1,4}|\*{1,4}|\.{3,}|last\s*4\s*|no\.?\s*)\D{0,5}(\d{4})\b',
        ).firstMatch(body)?.group(1) ??
        _re(
          r'\b(?:credit|debit)\s+card\s+(\d{4})\b',
        ).firstMatch(body)?.group(1);
    // Credit-card account references identify a card ledger, not a bank account.
    final destinationAccountLast4 = _re(
      r'\bto\s+your\b[\s\S]{0,70}\b(?:a\/?c\.?|account)\s*(?:no\.?|number)?\s*[*xX-]*\s*(\d{4})\b',
    ).firstMatch(body)?.group(1);
    final accountLast4 = _re(r'\bcredit\s+card\b').hasMatch(body)
        ? null
        : _ownAccountTransfer(body) &&
              _re(r'\b(?:credited|received|deposited)\b').hasMatch(body) &&
              destinationAccountLast4 != null
        ? destinationAccountLast4
        : _re(
            r'\b(?:a\/?c\.?|account)\s*(?:no\.?|number)?\s*(?:(?:ending(?:\s+with)?|last\s*4)\s*)?[*xX-]*\s*(\d{4})\b',
          ).firstMatch(body)?.group(1);
    final isInsuranceReminder = _re(
      r'\b(?:lic|life insurance|policy|premium)\b',
    ).hasMatch('$sender $body');
    final policyLast4 = isInsuranceReminder
        ? _re(
            r'\b(?:policy|pol\.?)(?:\s*(?:no\.?|number|#))?\s*[:#-]?\s*(?:x{2,}|\*{2,})?(\d{4,})\b',
          ).firstMatch(body)?.group(1)
        : null;
    DateTime? due;
    for (final phrase in [
      r'\bdue\s*(?:date\s*)?(?:is|on|by)?\s*[:\-]?\s*',
      r'\bpay\s+by\s*[:\-]?\s*',
      r'\b(?:payment|bill|amount)\s+due\s+date\b[\s\S]{0,120}?\b(?:is|on|by)\s*[:\-]?\s*',
      r'\b(?:renew(?:s|al|ing)?|expires?)\s*(?:date\s*)?(?:is|on|by)?\s*[:\-]?\s*',
      r'\b(?:will|shall|to)?\s*(?:be\s+)?(?:auto[- ]?)?(?:deducted|debited)\b[\s\S]{0,70}?\bon\s*[:\-]?\s*',
      r'\b(?:auto[- ]?deducted|auto[- ]?debited)\s+on\s*[:\-]?\s*',
      if (isInsuranceReminder)
        r'\b(?:premium|policy)\b[\s\S]{0,90}?\b(?:due|payable|debit(?:ed)?|scheduled)\s*(?:date\s*)?(?:is|on|by)?\s*[:\-]?\s*',
      if (isInsuranceReminder)
        r'\b(?:premium|policy)\b[\s\S]{0,90}?\b(?:on|by)\s*',
      if (isInsuranceReminder)
        r'\b(?:maintain|keep)\s+(?:sufficient|adequate)\s+(?:funds|balance)\b[\s\S]{0,100}?\b(?:on|by|before)\s*',
    ]) {
      final token = _re('$phrase($dateToken)').firstMatch(body)?.group(1);
      if (token != null) {
        due = parseDate(token);
        if (due != null) break;
      }
    }
    DateTime? statementDate;
    var statementDateExplicit = false;
    final statementAlert =
        _re(
          r'\b(?:credit\s+card|card\b[\s\S]{0,45}\b(?:ending|last\s*4|no\.?|number|xx|x{2,}|\*{2,})\s*[:#.-]?\s*\d{4})\b',
        ).hasMatch(body) &&
        (_re(
              r'\b(?:e[- ]?statement|statement|bill)\b[\s\S]{0,70}\b(?:generated|ready|available|issued|created|raised|prepared)\b',
            ).hasMatch(body) ||
            // A printed billing period is bill context on its own, even when
            // the "ready" clause falls outside the window above. Its END date
            // is the billing day.
            _re(
              r'\b(?:period|cycle)\b[\s\S]{0,25}?(' +
                  dateToken +
                  r')[\s\S]{0,15}?\b(?:to|till|until)\s*[:\-]?\s*(' +
                  dateToken +
                  r')',
            ).hasMatch(body));
    if (statementAlert) {
      // The period pattern closes with the cycle-end date in group 2 (that
      // printed date is the billing day); every other pattern captures the
      // printed date in group 1.
      final explicitPatterns = <(RegExp, int)>[
        (
          _re(
            r'\b(?:period|cycle)\b[\s\S]{0,25}?(' +
                dateToken +
                r')[\s\S]{0,15}?\b(?:to|till|until)\s*[:\-]?\s*(' +
                dateToken +
                r')',
          ),
          2,
        ),
        (
          _re(
            r'\b(?:statement|e[- ]?statement|bill)\b[\s\S]{0,45}?\b(?:generated|issued|created|raised|prepared|dated)\b\s*(?:on|is|:|-)?\s*(' +
                dateToken +
                r')',
          ),
          1,
        ),
        (
          _re(
            r'\b(?:generated|issued|created|raised|prepared|dated)\s*(?:date\s+)?(?:on|is|:|-)?\s*(' +
                dateToken +
                r')',
          ),
          1,
        ),
        (
          _re(
            r'\b(?:statement|e[- ]?statement|bill)\s+date\s*(?:is|on|:|-)?\s*(' +
                dateToken +
                r')',
          ),
          1,
        ),
      ];
      final dueClause = _re(r'\b(?:due|payable|pay\s+by)\b');
      for (final (pattern, group) in explicitPatterns) {
        final match = pattern.firstMatch(body);
        if (match == null) continue;
        // A due/payable clause inside the matched phrase means the captured
        // date is the PAYMENT date printed in the same bill SMS, not the
        // billing day.
        if (dueClause.hasMatch(match.group(0)!)) continue;
        statementDate = parseDate(match.group(group)!);
        if (statementDate != null) {
          statementDateExplicit = true;
          break;
        }
      }
      // Most issuers omit the generated date from the body. The SMS receive
      // date is then the best available statement-day observation.
      statementDate ??= receivedAt;
    }
    final balanceText = _re(
      r'\b(?:available|avail|avl|current|closing|clr|new)\s*(?:balance|bal)\s*(?:is|:|-)?\s*(?: ₹|rs\.?|inr)?\s*:?\s*([\d,]+(?:\.\d{1,2})?)',
    ).firstMatch(body)?.group(1);
    Money? money(String? text) {
      if (text == null) return null;
      final match = RegExp(
        r'^(\d+)(?:\.(\d{1,2}))?$',
      ).firstMatch(text.replaceAll(',', ''));
      if (match == null) return null;
      final paise =
          int.parse(match[1]!) * 100 +
          int.parse((match[2] ?? '').padRight(2, '0'));
      return Money.fromPaise(paise);
    }

    final balance = money(balanceText);
    final billerName = extractBillerName(body);
    final cadenceHint = _re(r'\bmonthly\b').hasMatch(body)
        ? 'monthly'
        : _re(r'\bquarterly\b').hasMatch(body)
        ? 'quarterly'
        : _re(r'\b(?:half[- ]yearly|half[- ]annual)\b').hasMatch(body)
        ? 'halfYearly'
        : _re(r'\b(?:annual|yearly)\b').hasMatch(body)
        ? 'annual'
        : null;
    final amountDue = money(
      _re(
        r'\b(?:total|full|statement|amount)\s*(?:amount\s*)?due\b\s*(?:is|:|-)?\s*(?:₹|rs\.?|inr)?\s*(?:dr\.?|cr\.?)?\s*:?[\s]*([\d,]+(?:\.\d{1,2})?)',
      ).firstMatch(body)?.group(1) ??
          _re(
            r'\btotal\s+(?:amt|amount)\s*[:\-]?\s*(?:₹|rs\.?|inr)?\s*(?:dr\.?|cr\.?)?\s*:?[\s]*([\d,]+(?:\.\d{1,2})?)',
          ).firstMatch(body)?.group(1),
    );
    final billAmount = money(
      _re(
        r'\b(?:bill|invoice|premium)\s+(?:of|amount(?:\s+is)?)\s*(?:₹|rs\.?|inr)?\s*(?:dr\.?|cr\.?)?\s*[:.]?\s*([\d,]+(?:\.\d{1,2})?)',
      ).firstMatch(body)?.group(1) ??
          _re(
            r'\bautopay\s+(?:alert|reminder)\s*[:\-]?\s*(?:₹|rs\.?|inr)?\s*(?:dr\.?|cr\.?)?\s*[:.]?\s*([\d,]+(?:\.\d{1,2})?)',
          ).firstMatch(body)?.group(1),
    );
    final minimumDue = money(
      _re(
        r'\b(?:minimum|min)\s*(?:amt|amount\s*)?due\b\s*(?:is|:|-)?\s*(?:₹|rs\.?|inr)?\s*(?:dr\.?|cr\.?)?\s*:?[\s]*([\d,]+(?:\.\d{1,2})?)',
      ).firstMatch(body)?.group(1),
    );
    final autopayLimit = money(
      _re(
        r'\b(?:max(?:imum)?|mandate)\s*(?:limit|amount)?\s*(?:[:\-]|\s+(?:of|is|for))?\s*(?:₹|rs\.?|inr)?\s*:?[\s]*([\d,]+(?:\.\d{1,2})?)',
      ).firstMatch(body)?.group(1),
    );
    final hasAutopay = _re(
      r'\b(?:auto[- ]?pay|autopay|mandate|e[- ]?mandate)\b',
    ).hasMatch(body);
    final autopaySetup =
        hasAutopay &&
        _re(
          r'\b(?:activation|activated|enabled|registered|created|set\s+up|maximum|max\s+limit|e[- ]?mandate)\b',
        ).hasMatch(body) &&
        !_re(
          r'\b(?:spent|debited|debit|paid|purchase|purchased|charged|withdrawn|sent|transferred)\b',
        ).hasMatch(body);
    final promotion = _re(
      r'\b(?:offer|promotion|promotional|campaign|eligible|cashback|reward|voucher)\b[\s\S]{0,80}\b(?:spend|card)\b|\bspend\s*(?:₹|rs\.?|inr)[\s\S]{0,50}\b(?:get|earn|cashback|reward|voucher)\b|\bbuy\s+\d+\s+get\s+\d+\b|\bget\s+(?:free|additional)\b|\brecharge\b[\s\S]{0,80}\b(?:free|offer|bonus|additional)\b',
    ).hasMatch(body);
    final failed = _re(
      r'\b(?:declined|failed|failure|cancelled|canceled|pending|processing)\b',
    ).hasMatch(body);
    final balanceOnly = _re(
      r'\b(?:available|avail|avl|current|closing|clr|new)\s*(?:balance|bal)\b|\bcredit\s+limit\b',
    ).hasMatch(body);
    final hasBillMarker =
        due != null ||
        _re(
          r'\b(?:payment|amount|minimum|total|premium)\s+due\b|\b(?:statement|bill|invoice)\b[\s\S]{0,80}\b(?:generated|ready|available|due)\b|\b(?:subscription|membership)\b[\s\S]{0,50}\b(?:renew|renewal|due|expires?)\b|\bautopay\s+(?:alert|reminder)\b|\b(?:auto[- ]?debited|auto[- ]?deducted)\b[\s\S]{0,60}?\b(?:dues?|bill)\b',
        ).hasMatch(body);
    // "No money was debited" makes the debit word a negation, not evidence
    // of movement — failure notices from banks print exactly this sentence.
    final hasCompletedMovement =
        !_re(r'\b(?:no\s+money\s+(?:was|is)?\s*(?:debited|deducted)|not\s+(?:debited|deducted|charged))\b')
                .hasMatch(body) &&
        (_re(
              r'\b(?:spent|debited|debit|paid|charged|withdrawn|sent|transferred|credited|received|deposited|refunded|reversed)\b',
            ).hasMatch(body) ||
            (!failed && _re(r'\b(?:purchase|purchased)\b').hasMatch(body)) ||
            _re(
              r'\b(?:recharge|payment|transaction|purchase|debit|spent|paid|charged|withdrawn|sent|transferred)\b[\s\S]{0,40}\b(?:successful|successfully|completed)\b',
            ).hasMatch(body));
    LocalSmsObservation observation([
      TransactionEntry? row,
      LocalSmsEventType? type,
      LocalSmsDisposition? disposition,
      List<String> reasons = const [],
    ]) => LocalSmsObservation(
      transaction: row,
      cardLast4: cardLast4,
      accountLast4: isInsuranceReminder
          ? policyLast4?.substring(policyLast4.length - 4)
          : accountLast4,
      billerName: billerName,
      cadenceHint: cadenceHint,
      dueDate: due,
      statementDate: statementDate,
      statementDateExplicit: statementDateExplicit,
      availableBalance: balance,
      amountDue: amountDue ?? billAmount,
      minimumDue: minimumDue,
      autopayLimit: autopayLimit,
      eventType:
          type ??
          (row == null
              ? LocalSmsEventType.unknown
              : LocalSmsEventType.transaction),
      disposition:
          disposition ??
          (row == null ? LocalSmsDisposition.review : LocalSmsDisposition.sync),
      reasonCodes: reasons,
      confidence: type == LocalSmsEventType.bill
          ? (0.55 +
                    (billerName == null ? 0 : 0.2) +
                    (due == null ? 0 : 0.2) +
                    (statementDate == null ? 0 : 0.05) +
                    ((amountDue ?? billAmount) == null ? 0 : 0.1) +
                    (accountLast4 == null ? 0 : 0.05))
                .clamp(0, 0.95)
                .toDouble()
          : 1,
    );
    // Reminders and offers are observations, never purchases.
    final futureDebit =
        _re(
          r'\b(?:will|shall|to|scheduled to)\s+be\s+(?:auto[- ]?)?(?:debited|deducted|charged)\b',
        ).hasMatch(body);
    if (isNonTransactionNoise(sender, body)) {
      return observation(
        null,
        LocalSmsEventType.promotion,
        LocalSmsDisposition.localIgnore,
        ['non_transaction_message'],
      );
    }
    if (hasBillMarker &&
        !autopaySetup &&
        (!hasCompletedMovement || futureDebit)) {
      return observation(
        null,
        LocalSmsEventType.bill,
        LocalSmsDisposition.localObservation,
        [if (due != null) 'due_date_detected'],
      );
    }
    if (autopaySetup) {
      return observation(
        null,
        LocalSmsEventType.autopay,
        LocalSmsDisposition.localIgnore,
        ['autopay_setup'],
      );
    }
    if (promotion &&
        !hasCompletedMovement &&
        !_re(r'\b(?:credited|received|deposited|refunded)\b').hasMatch(body)) {
      return observation(
        null,
        LocalSmsEventType.promotion,
        LocalSmsDisposition.localIgnore,
        ['promotional_message'],
      );
    }
    // A failure/decline notice is non-spending only when it contains no
    // evidence that money actually moved. Some issuers send both messages
    // together (for example, "payment failed but account debited"); keep
    // those cases reviewable instead of acknowledging them as noise.
    if (failed && !hasCompletedMovement) {
      return observation(
        null,
        LocalSmsEventType.failed,
        LocalSmsDisposition.localIgnore,
        ['unsuccessful_transaction'],
      );
    }
    if (balanceOnly && !hasCompletedMovement) {
      return observation(
        null,
        LocalSmsEventType.balance,
        LocalSmsDisposition.localIgnore,
        ['balance_or_limit_notice'],
      );
    }
    if (_re(
          r'\b(?:declined|failed|failure|cancelled|canceled|pending|processing|initiated)\b',
        ).hasMatch(body) &&
        !hasCompletedMovement) {
      return observation();
    }
    if (futureDebit) return observation();
    final amount = money(
      _re(
        r'(?:₹|rs\.?|inr)\s*[:.]?\s*([\d,]+(?:\.\d{1,2})?)',
      ).firstMatch(body)?.group(1),
    );
    if (amount == null || amount.paise <= 0) return observation();
    final accountShaped = _re(r'\b(?:a\/?c\.?|account)\b').hasMatch(body);
    final credit =
        !_re(r'\b(?:credit|debit)\s+card\b').hasMatch(body) &&
        !_re(
          r'\b(?:will|shall|would|to)\s+be\s+(?:credited|received|deposited|refunded|reversed)\b|\b(?:not|never)\s+(?:been\s+)?(?:credited|received|deposited|refunded|reversed)\b',
        ).hasMatch(body) &&
        _re(
          r'\b(?:credited|received|deposited|refunded|reversed)\b',
        ).hasMatch(body) &&
        (_re(r'\b(?:a\/?c\.?|account|savings|bank|wallet)\b').hasMatch(body) ||
            _re(
              r'\b(?:money|amount|payment|funds?)\b[\s\S]{0,40}\b(?:received|credited|deposited)\b',
            ).hasMatch(body));
    final billPaymentCandidate = _re(
      r'\b(?:payment|paid|debited|debit|amount)\b[\s\S]{0,90}\btowards?\b[\s\S]{0,50}\b(?:your\s+)?credit\s+card\b|\bcredit\s+card\s+(?:bill|payment)\b[\s\S]{0,90}\b(?:received|credited|debited|paid|successful|completed)\b|\b(?:paid|payment|debited)\b[\s\S]{0,90}\b(?:to|for)\s+(?:(?:your|the|axis|hdfc|icici|sbi|bank|flipkart)\s+){0,5}credit\s+card(?:\s+bill)?\b|\bbill\b[\s\S]{0,60}\b(?:for|on|of)\s+(?:(?:your|the|axis|hdfc|icici|sbi|bank|flipkart)\s+){0,5}credit\s+card\b[\s\S]{0,90}\b(?:paid|received|successful|completed)\b|\b(?:card\s+bill\s*(?:payment|pmt)|cc\s*(?:bill\s*)?(?:payment|pmt)|card\s+bill\s+pay)\b[\s\S]{0,90}\b(?:paid|received|debited|successful|completed|credited)\b|\b(?:payment|paid|debited|debit|transferred)\b[\s\S]{0,90}\b(?:towards?|for|to)\s+(?:your\s+)?(?:card|cc)\b|\b(?:imps|neft|upi)\b[\s\S]{0,80}\b(?:cc|credit\s+card)\s*(?:bill\s*)?(?:pmt|payment)\b',
    ).hasMatch(body);
    final billPayment =
        billPaymentCandidate &&
        (!_re(
              r'\b(?:payment|amount|minimum)\s+due\b|\bdue\s+on\b',
            ).hasMatch(body) ||
            _re(
              r'\b(?:paid|payment)\s+(?:successfully|completed)\b|\bpayment\s+received\b',
            ).hasMatch(body));
    final cashWithdrawal = _re(
      r'\b(?:cash\s+withdrawal|withdrawn\s+from\b[\s\S]{0,50}\bcard|withdrawn\s+(?:from|at)\s+(?:an?\s+)?atm|atm\b[\s\S]{0,60}\bwithdrawn)\b',
    ).hasMatch(body);
    final loanRepayment = !cashWithdrawal && _loanRepayment(body);
    final feeCharge = !cashWithdrawal && !loanRepayment && _feeCharge(body);
    final brokerSettlement = _brokerSettlement(body);
    final investmentDebit =
        !cashWithdrawal &&
        !loanRepayment &&
        !feeCharge &&
        !brokerSettlement &&
        isInvestmentMovementDescription(body);
    final walletLoad = _walletLoad(body) && !brokerSettlement;
    final refundCredit = _re(
      r'\b(?:refund(?:ed)?|chargeback)\b',
    ).hasMatch(body);
    final reversalCredit = _re(r'\b(?:reversal|reversed)\b').hasMatch(body);
    final rewardCredit = _re(
      r'\b(?:cashback|reward|rewards|points?|miles?)\b',
    ).hasMatch(body);
    final loanDisbursement = _re(
      r'\b(?:loan|personal\s+loan|salary\s+advance|credit\s+line)\b[\s\S]{0,70}\b(?:credited|received|disbursed|disbursement)\b',
    ).hasMatch(body);
    final investmentProceeds = _investmentProceeds(body);
    final cashDeposit = _re(r'\bcash\s+(?:deposit|deposited)\b').hasMatch(body);
    final giftCredit = _re(r'\b(?:gift|gifted|present)\b').hasMatch(body);
    final reimbursementCredit = _re(
      r'\b(?:reimburse(?:ment|d)?|expense\s+claim)\b',
    ).hasMatch(body);
    final cardCredit = _cardCredit(body);
    if (!credit &&
        !cardCredit &&
        !billPayment &&
        !walletLoad &&
        !loanRepayment &&
        !feeCharge &&
        !_re(
          r'\b(?:spent|debited|debit|paid|purchase|purchased|charged|withdrawn|sent|transferred)\b',
        ).hasMatch(body)) {
      return observation();
    }
    if (!credit &&
        !cardCredit &&
        !billPayment &&
        _re(
          r'\b(?:credited|refund(?:ed)?|reversed|reversal)\b',
        ).hasMatch(body)) {
      return observation();
    }
    final bankDebit =
        accountShaped && !_re(r'\b(?:credit|debit)\s+card\b').hasMatch(body);
    final instrument = billPayment
        ? (bankDebit ? TxnInstrument.upiBank : TxnInstrument.other)
        : cardCredit
        ? TxnInstrument.creditCard
        : credit && _re(r'\bwallet\b').hasMatch(body)
        ? TxnInstrument.wallet
        : bankDebit || credit
        ? TxnInstrument.upiBank
        : _re(
            r'\bdebit\s+card\b|\b(?:atm|withdrawn|cash\s+withdrawal|block\s+dc)\b',
          ).hasMatch(body)
        ? TxnInstrument.debitCard
        : cardLast4 != null
        ? TxnInstrument.creditCard
        : null;
    if (instrument == null) return observation();
    var transfer =
        billPayment ||
        cardCredit ||
        cashWithdrawal ||
        walletLoad ||
        brokerSettlement ||
        loanRepayment ||
        investmentProceeds ||
        _accountToAccountTransfer(body);
    var kind = transfer
        ? TxnEntryKind.transfer
        : feeCharge
        ? TxnEntryKind.spend
        : investmentDebit
        ? TxnEntryKind.investment
        : credit && !_earnedIncomeCredit(body)
        ? TxnEntryKind.transfer
        : credit
        ? TxnEntryKind.income
        : TxnEntryKind.spend;
    var merchant = _re(
      r'\b(?:at|to|for|from|by)\s+([A-Za-z_][A-Za-z0-9 ._&@*\x27/-]{1,80}?)(?=\s+(?:from|on|via|upi|ref(?:erence)?|txn|transaction|bal(?:ance)?|avl|available|if\s+not|call|sms\s+block)\b|\s*\(|[.,;]|$)',
    ).firstMatch(body)?.group(1)?.trim();
    // "by Mob Bk" describes the banking channel, not the recipient.
    if (merchant != null &&
        _re(
          r'^(?:mob(?:ile)?\s*(?:bk|banking)|net\s*(?:bk|banking)|internet\s*banking)$',
        ).hasMatch(merchant)) {
      merchant = null;
    }
    final ownNameTransfer =
        merchant != null &&
        ownUserName != null &&
        _isOwnPersonName(merchant, ownUserName);
    if (bankDebit &&
        !credit &&
        !transfer &&
        !investmentDebit &&
        merchant == null) {
      return observation(
        null,
        LocalSmsEventType.unknown,
        LocalSmsDisposition.review,
        ['ambiguous_account_debit'],
      );
    }
    if (billPayment) {
      merchant = 'Credit card bill payment';
    } else if (ownNameTransfer) {
      merchant = 'Transfer between own accounts';
    } else if (brokerSettlement) {
      merchant = 'Investment proceeds';
    } else if (cardCredit) {
      merchant =
          _re(
            r'\b(?:refund(?:ed)?|reversed?|reversal|chargeback)\b',
          ).hasMatch(body)
          ? 'Refund'
          : _re(
              r'\b(?:cashback|reward|rewards|points?|miles?)\b',
            ).hasMatch(body)
          ? 'Reward or cashback'
          : _re(r'\breversed?|reversal\b').hasMatch(body)
          ? 'Reversal'
          : 'Card statement adjustment';
    } else if (walletLoad) {
      merchant = 'Wallet load';
    } else if (cashWithdrawal) {
      merchant = 'Cash withdrawal';
    } else if (loanRepayment) {
      merchant = 'Loan or EMI repayment';
    } else if (investmentProceeds) {
      merchant = 'Investment proceeds';
    } else if (feeCharge) {
      merchant = 'Bank or service fee';
    } else if (investmentDebit) {
      merchant = 'Investment contribution';
    } else if (credit && refundCredit) {
      merchant = 'Refund';
    } else if (credit && reversalCredit) {
      merchant = 'Reversal';
    } else if (credit && rewardCredit) {
      merchant = 'Reward or cashback';
    } else if (credit && loanDisbursement) {
      merchant = 'Loan disbursement';
    } else if (credit && investmentProceeds) {
      merchant = 'Investment proceeds';
    } else if (credit && cashDeposit) {
      merchant = 'Cash deposit';
    } else if (credit && giftCredit) {
      merchant = 'Gift received';
    } else if (credit && reimbursementCredit) {
      merchant = 'Reimbursement';
    } else if (credit && _incomingBankTransferCandidate(body)) {
      merchant = 'Bank transfer';
    } else if (credit && _re(r'\bsalary\b').hasMatch(body)) {
      merchant = 'Salary';
    } else if (credit) {
      merchant ??= 'Money received';
    } else {
      merchant ??= bankDebit ? 'Bank transfer' : null;
    }
    final ownNameCredit = credit && _ownNameInFromClause(body, ownUserName);
    if (ownNameCredit) merchant = 'Transfer between own accounts';
    if (ownNameTransfer || ownNameCredit) {
      transfer = true;
      kind = TxnEntryKind.transfer;
    }
    final matching = cards
        .where(
          (c) =>
              !c.isArchived &&
              c.last4 == cardLast4 &&
              ((instrument == TxnInstrument.debitCard &&
                      c.cardType == 'debit') ||
                  (instrument == TxnInstrument.creditCard &&
                      c.cardType != 'debit')),
        )
        .toList();
    final card = matching.length == 1 ? matching.single : null;
    final dateMatch = _re(dateToken).firstMatch(body);
    final parsedDate = dateMatch == null
        ? null
        : parseDate(dateMatch.group(0)!);
    final date =
        parsedDate != null &&
            !parsedDate.isAfter(receivedAt.add(const Duration(days: 1)))
        ? parsedDate
        : receivedAt;
    final key = smsSourceKey(namespace, sender, body);
    return observation(
      TransactionEntry(
        id: 'local-sms:$key',
        sourceKey: key,
        amount: amount,
        occurredAt: date,
        merchantName: merchant,
        userCardId: card?.id,
        cardDisplayName: card?.cardName,
        cardLast4: cardLast4,
        accountLast4: accountLast4,
        instrument: instrument,
        entryKind: kind,
        source: 'sms',
        status: 'active',
        rewardState: 'estimated',
      ),
    );
  }

  static LocalSmsObservation? _applyDownloadedRule({
    required String namespace,
    required RestrictedSmsRule rule,
    required Match match,
    required String sender,
    required String body,
    required DateTime receivedAt,
    required List<UserCard> cards,
  }) {
    if (rule.family == SmsRuleFamily.ignoreNoise) {
      // Safety safeguard: an ignore rule cannot silence an SMS containing real
      // completed movement verbs, due dates or balance markers.
      final hasFinancialWords = RegExp(
        r'\b(?:debited|credited|spent|paid|charged|transferred|withdrawn|received|due date|amount due|balance|avail bal)\b',
        caseSensitive: false,
      ).hasMatch(body);
      if (hasFinancialWords) return null;

      return LocalSmsObservation(
        eventType: LocalSmsEventType.promotion,
        disposition: LocalSmsDisposition.localIgnore,
        reasonCodes: ['downloaded_rule_noise_match', rule.id],
        confidence: rule.confidence,
      );
    }

    String? getGroup(String field) {
      final idx = rule.fieldMap[field];
      if (idx == null || idx < 1 || idx > match.groupCount) return null;
      return match.group(idx)?.trim();
    }

    Money? parseMoney(String? text) {
      if (text == null) return null;
      final cleaned = text.replaceAll(RegExp(r'[, ]'), '');
      final val = double.tryParse(cleaned);
      if (val == null || val <= 0 || !val.isFinite) return null;
      return Money.fromRupees(val);
    }

    if (rule.family == SmsRuleFamily.postedMovement) {
      // Safety check: must contain completed payment wording
      final hasCompletedWording = RegExp(
        r'\b(?:debited|credited|spent|paid|charged|transferred|withdrawn|received|successful|completed)\b',
        caseSensitive: false,
      ).hasMatch(body);
      if (!hasCompletedWording) return null;

      final amount = parseMoney(getGroup('amount') ?? getGroup('amountInr'));
      if (amount == null) return null;
      final merchant = getGroup('merchant') ?? 'Unknown Merchant';
      final last4 = getGroup('last4') ?? getGroup('cardLast4') ?? getGroup('accountLast4');

      var instrument = TxnInstrument.upiBank;
      final rawInst = (rule.defaultFields['instrument'] ?? getGroup('instrument'))?.toString().toLowerCase();
      if (rawInst == 'creditcard' || rawInst == 'credit_card') {
        instrument = TxnInstrument.creditCard;
      } else if (rawInst == 'debitcard' || rawInst == 'debit_card') {
        instrument = TxnInstrument.debitCard;
      } else if (rawInst == 'wallet') {
        instrument = TxnInstrument.wallet;
      }

      var entryKind = TxnEntryKind.spend;
      final rawKind = (rule.defaultFields['entryKind'] ?? getGroup('entryKind'))?.toString().toLowerCase();
      if (rawKind == 'income' || rawKind == 'credit') {
        entryKind = TxnEntryKind.income;
      }

      String? matchedCardId;
      if (last4 != null) {
        for (final c in cards) {
          if (c.last4 == last4) {
            matchedCardId = c.id;
            break;
          }
        }
      }

      // Instrument safety: if card is claimed but last4 is missing/invalid, default away from card
      if ((instrument == TxnInstrument.creditCard || instrument == TxnInstrument.debitCard) &&
          (last4 == null || last4.length != 4)) {
        instrument = TxnInstrument.other;
      }

      // Calibrate confidence: an unassigned card cannot be auto-accepted at ultra-high confidence
      var calibratedConfidence = rule.confidence;
      if (instrument == TxnInstrument.creditCard && matchedCardId == null) {
        calibratedConfidence = calibratedConfidence.clamp(0.5, 0.90);
      }

      final key = smsSourceKey(namespace, sender, body);
      final txn = TransactionEntry(
        id: 'local-sms:$key',
        sourceKey: key,
        userCardId: matchedCardId,
        amount: amount,
        merchantName: merchant,
        occurredAt: receivedAt,
        instrument: instrument,
        entryKind: entryKind,
        cardLast4: last4,
        source: 'sms',
        status: 'active',
        rewardState: 'estimated',
      );

      return LocalSmsObservation(
        transaction: txn,
        cardLast4: last4,
        confidence: calibratedConfidence,
        disposition: LocalSmsDisposition.sync,
        reasonCodes: ['downloaded_rule_match', rule.id],
      );
    }

    if (rule.family == SmsRuleFamily.balanceSnapshot) {
      final bal = parseMoney(getGroup('availableBalance') ?? getGroup('availableBalanceInr'));
      final acct = getGroup('accountLast4') ?? getGroup('last4');
      if (bal == null && acct == null) return null;
      return LocalSmsObservation(
        eventType: LocalSmsEventType.balance,
        disposition: LocalSmsDisposition.localObservation,
        availableBalance: bal,
        accountLast4: acct,
        confidence: rule.confidence,
        reasonCodes: ['downloaded_rule_balance', rule.id],
      );
    }

    if (rule.family == SmsRuleFamily.billObligation) {
      final amt = parseMoney(getGroup('amountDue') ?? getGroup('amountDueInr') ?? getGroup('minimumDue'));
      final dueRaw = getGroup('dueDate');
      final due = dueRaw != null ? parseDate(dueRaw) : null;
      final biller = getGroup('billerName') ?? sender;
      final last4 = getGroup('last4') ?? getGroup('cardLast4');
      if (amt == null && due == null) return null;
      return LocalSmsObservation(
        eventType: LocalSmsEventType.bill,
        disposition: LocalSmsDisposition.localObservation,
        amountDue: amt,
        dueDate: due,
        billerName: biller,
        cardLast4: last4,
        confidence: rule.confidence,
        reasonCodes: ['downloaded_rule_bill', rule.id],
      );
    }

    if (rule.family == SmsRuleFamily.mandateLifecycle) {
      final lim = parseMoney(getGroup('autopayLimit') ?? getGroup('limitInr'));
      final biller = getGroup('billerName') ?? getGroup('merchant') ?? sender;
      final last4 = getGroup('last4') ?? getGroup('cardLast4');
      return LocalSmsObservation(
        eventType: LocalSmsEventType.autopay,
        disposition: LocalSmsDisposition.localObservation,
        autopayLimit: lim,
        billerName: biller,
        cardLast4: last4,
        confidence: rule.confidence,
        reasonCodes: ['downloaded_rule_mandate', rule.id],
      );
    }

    return null;
  }

}
