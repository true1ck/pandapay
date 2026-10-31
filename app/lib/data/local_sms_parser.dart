import 'package:pandapay_domain/pandapay_domain.dart';

import 'commitments_repository.dart';
import 'investment_classifier.dart';
import 'user_cards_repository.dart';
import 'local/sms_intake_repository.dart';
import 'local/sms_learning_feedback.dart';
import 'local/sms_rule_bundle.dart';
import 'indian_narration_sanitizer.dart';
import 'merchant_identity.dart';
import 'flashtext_merchant_extractor.dart';

enum LocalSmsEventType {
  transaction,
  bill,
  autopay,
  promotion,
  balance,
  failed,
  security,
  investment,
  unknown,
}

enum LocalSmsDisposition {
  sync,
  localObservation,
  localIgnore,
  review,
  localCommitment,
}

extension LocalSmsEventTypeWire on LocalSmsEventType {
  String get wireValue => switch (this) {
    LocalSmsEventType.transaction => 'transaction',
    LocalSmsEventType.bill => 'bill',
    LocalSmsEventType.autopay => 'autopay',
    LocalSmsEventType.promotion => 'promotion',
    LocalSmsEventType.balance => 'balance',
    LocalSmsEventType.failed => 'failed',
    LocalSmsEventType.security => 'security',
    LocalSmsEventType.investment => 'investment',
    LocalSmsEventType.unknown => 'unknown',
  };
}

extension LocalSmsDispositionWire on LocalSmsDisposition {
  String get wireValue => switch (this) {
    LocalSmsDisposition.sync => 'sync',
    LocalSmsDisposition.localObservation => 'local_observation',
    LocalSmsDisposition.localIgnore => 'local_ignore',
    LocalSmsDisposition.review => 'review',
    LocalSmsDisposition.localCommitment => 'local_commitment',
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
  final Money? amount;
  final DateTime? startDate;
  final DateTime? endDate;
  final String? paymentMethod;
  String? get merchantName => billerName;
  final LocalSmsEventType eventType;
  final LocalSmsDisposition disposition;
  final List<String> reasonCodes;
  final double confidence;
  final bool _isAutopay;
  bool get isAutopay =>
      _isAutopay ||
      reasonCodes.contains('autopay_notice') ||
      reasonCodes.contains('mandate_notice') ||
      eventType == LocalSmsEventType.autopay;

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
    this.amount,
    this.startDate,
    this.endDate,
    this.paymentMethod,
    this.eventType = LocalSmsEventType.unknown,
    this.disposition = LocalSmsDisposition.review,
    this.reasonCodes = const [],
    this.confidence = 0,
    bool isAutopay = false,
  }) : _isAutopay = isAutopay;
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
  // 10: preserve uncertain card types, insurance date precision, and explicit
  // due-date labels; re-evaluate older review observations with this grammar.
  // 11: merchant names that follow an Axis transaction date/time are captured
  // from the alert rather than treated as unknown.
  // 12: explicitly zoned IST transaction times are retained for card spends.
  // 9: AutoPay setup and reminder observations no longer invent a monthly
  // cadence, receive-date due date, or due amount from a mandate ceiling.
  // 8: the server can now resolve a card bill notice whose suffix is printed
  // straight after the instrument ("Credit Card 8708 bill"), so the open
  // review queue is re-examined once more and a card's due day can finally be
  // learned from its own AutoPay message.
  // 15: Telecom carrier retention fees (Jio, Airtel airtime deductions) and loan cross-sells.
  // 16: Betting/gambling promotions and digital credit power / loan limit marketing.
  // 17: Bank cautionary advisory warnings ("Never share OTP/PIN/CVV") do not drop valid transactions.
  // 18: Disambiguate investment share vs advisory warnings, support YONO UPI, and dot-masked accounts.
  // 19: Allow scanner reprocessing of historical alerts on parser upgrade without lockout.
  // 21: Named payees for UPI narrations and "towards X for INR" debits, weak-name rejection.
  // 22: Unicode-masked UPI references precede the named recipient.
  // 23: A decline notice that prints its amount ("Txn of Rs 81,467 declined
  // due to insufficient balance") is a failed attempt, not a spend, and a
  // decline reason is never used as the payee name.
  // 24: A decline that states its own reason outranks the movement verbs
  // printed beside it ("Rs 81,467 spent ... was declined", "ECS debit
  // returned due to insufficient funds"), so no branch can mint a spend.
  static const version = 24;

  /// User-learned merchant rules run before FlashText/grammar category
  /// inference. Deterministic and longest-pattern-first so two overlapping
  /// rules cannot produce different categories across captures.
  ///
  /// Public so the AI auto-resolution path can apply the user's latest
  /// correction BEFORE the AI's own category decision (plan C5 precedence).
  static String? userCategoryRuleSlug(
    Map<String, String>? rules,
    String? merchant,
    String sender,
    [String? body]
  ) {
    if (rules == null || rules.isEmpty) return null;
    String normalize(String value) =>
        value.trim().replaceAll(RegExp(r'\s+'), ' ').toUpperCase();
    final merchantText = normalize(merchant ?? '');
    final senderText = normalize(sender);
    final contextualPrefix = 'CTX|$merchantText|';
    final contextualRules = rules.entries.where(
      (entry) => entry.key.startsWith(contextualPrefix),
    );
    if (contextualRules.isNotEmpty) {
      if (body == null || merchantText.isEmpty) return null;
      final exact = SmsLearningFeedback.contextPattern(merchantText, sender, body);
      return rules[exact];
    }
    String? matchedSlug;
    var matchedLength = -1;
    for (final entry in rules.entries) {
      final pattern = normalize(entry.key);
      if (pattern.startsWith('CTX|')) continue;
      if (pattern.isEmpty) continue;
      final matched =
          (merchantText.isNotEmpty && merchantText.contains(pattern)) ||
          (senderText.isNotEmpty && senderText.contains(pattern));
      if (matched && pattern.length > matchedLength) {
        matchedSlug = entry.value;
        matchedLength = pattern.length;
      }
    }
    return matchedSlug;
  }

  static String? _sharedCategoryRuleSlug(
    Map<String, String>? rules,
    String? merchant,
    String sender,
    String body,
  ) {
    if (rules == null || merchant == null || merchant.trim().isEmpty) {
      return null;
    }
    final key = merchant.trim().replaceAll(RegExp(r'\s+'), ' ').toUpperCase();
    final senderKey = sender.trim().toUpperCase();
    if (!RegExp(r'^[A-Z]{2}-[A-Z0-9]{3,10}(?:-[A-Z])?$').hasMatch(senderKey)) {
      return null;
    }
    final contextKey = SmsSharedCategoryRule.contextKeyForBody(
      body,
      merchant: merchant,
    );
    if (contextKey.isEmpty || contextKey.split('|').length > 8) return null;
    return rules[SmsSharedCategoryRule.tupleKey(
      merchantKey: key,
      senderKey: senderKey,
      contextKey: contextKey,
      factFamily: 'posted_movement',
    )];
  }

  static String? categoryDisplayName(String? slug) {
    if (slug == null || slug.isEmpty) return null;
    return switch (slug.toLowerCase()) {
      'groceries' => 'Groceries',
      'dining' => 'Dining',
      'online' => 'Online Shopping',
      'fuel' => 'Fuel',
      'travel' => 'Travel',
      'bills' => 'Bills & Utilities',
      'health' => 'Health',
      'entertainment' => 'Entertainment',
      'rent' => 'Rent',
      'investment' || 'investments' => 'Investments',
      'emi' => 'EMI & Loans',
      'insurance' => 'Insurance',
      'education' => 'Education',
      'income' => 'Income',
      'wallet' => 'Wallet',
      'cash' => 'Cash',
      _ => slug[0].toUpperCase() + slug.substring(1),
    };
  }

  static bool isInvestmentFolioAllotment(String body) {
    final text = body.toLowerCase();
    final hasAllotment = RegExp(
      r'\b(?:units?\s+allotted|allotted\s+at\s+nav|units?\s*:\s*[\d.]+\s*,\s*nav|nav\s*:\s*[\d.]+|units?\s+(?:credited|allotted)\s+under\s+folio|allotted\s+for\s+your\s+investment|processed\s+at\s+(?:the\s+)?nav\s+of\s+[\d.]+|for\s+[\d.]+\s+units)\b',
      caseSensitive: false,
    ).hasMatch(text);
    final hasFolioOrFund = RegExp(
      r'\b(?:folio|fund|mutual\s+fund|amc|etf)\b',
      caseSensitive: false,
    ).hasMatch(text);
    return hasAllotment && hasFolioOrFund;
  }

  static bool isMerchantReceiptOrEbill(String body) {
    final text = body.toLowerCase();
    return RegExp(
      r'\b(?:view\s+(?:the\s+)?(?:payment\s+)?(?:e[- ]?bill|bill|invoice|tax\s+invoice|receipt)|e[- ]?bill\s+of\b|view\s+bill\s+of\b|payment\s+receipt\b|thanks?\s+for\s+(?:your\s+)?payment\s+of\s+(?:rs\.?|inr)|thank\s+you\s+for\s+your\s+purchase\b[\s\S]{0,240}\b(?:download|view)\b[\s\S]{0,80}\b(?:bill|invoice|receipt)\b)',
    ).hasMatch(text) ||
        // Arbitrary named-shop receipts, e.g. "your payment of Rs. 700.0 to
        // Balaji Sports has been recorded". The payee is not hardcoded: only
        // the recorded/received sentence shape identifies a receipt.
        RegExp(
          r'\bpayment\s+of\s+(?:₹|rs\.?|inr)?\s*[\d,]+(?:\.\d{1,2})?\s+(?:to|towards)\s+[^.!?\n]{2,80}?\s+(?:has|have|was|were)\s+(?:been\s+)?(?:recorded|received)\b',
        ).hasMatch(text);
  }

  /// Extracts the payee from a merchant receipt/order confirmation without
  /// relying on a hardcoded shop. Returns null for opaque IDs and boilerplate.
  static String? extractReceiptMerchant(String body) {
    final patterns = <RegExp>[
      _re(
        r'\b(?:made\s+)?payment\s+of\s+(?:₹|rs\.?|inr)?\s*[\d,]+(?:\.\d{1,2})?\s+(?:to|towards)\s+([^.!?\n]{2,80}?)(?=\s+(?:has|have|was|were|is|are)\s+(?:been\s+)?(?:recorded|received|successful|successfully|completed|credited|debited|paid|processed)\b|[.!?\n]|\s+-\s+|$)',
      ),
      _re(
        r'\b(?:paid|payment\s+to)\b[\s\S]{0,25}?(?:₹|rs\.?|inr)?\s*[\d,]+(?:\.\d{1,2})?\s+(?:to|at|towards)\s+([^.!?\n]{2,80}?)(?=[.!?\n]|\s+for\b|\s+(?:has|was|were|is)\b|\s+-\s+|$)',
      ),
      _re(
        r'\bpayment\s+(?:to|towards)\s+([^.!?\n]{2,80}?)(?=\s+(?:has|have|was|were)\s+(?:been\s+)?(?:recorded|received|successful|successfully|completed)\b|[.!?\n]|\s+-\s+|$)',
      ),
      _re(
        r'\b(?:purchase|order)\s*(?:@|at|from|with)\s+([^.!?\n]{2,60}?)(?=[.!?,]|\s+for\b|\s+has\b|$)',
      ),
      _re(
        r'(?:^|\s)@\s*([^.!?\n]{2,60}?)(?=[.!?,]|\s+for\b|\s+has\b|$)',
      ),
      _re(
        r'\breceipt\s+(?:from|for)\s+([^.!?\n]{2,80}?)(?=[.!?\n]|$)',
      ),
      _re(
        r'\b(?:thank\s+you|thanks)\s+for\s+(?:choosing|visiting|shopping\s+(?:at|with))\s+([^.!?\n]{2,80}?)(?=[.!?\n]|\s+(?:view|download)\b|$)',
      ),
    ];
    for (final pattern in patterns) {
      final candidate = pattern.firstMatch(body)?.group(1);
      final cleaned = MerchantIdentity.cleanName(candidate);
      if (cleaned != null) return cleaned;
    }
    return null;
  }

  static Money? extractReceiptAmount(String body) {
    final match = _re(
      r'(?:₹|rs\.?|inr)\s*[:.]?\s*([\d,]+(?:\.\d{1,2})?)',
    ).firstMatch(body);
    if (match == null) return null;
    final digits = match.group(1)?.replaceAll(',', '');
    if (digits == null) return null;
    final numMatch = RegExp(r'^(\d+)(?:\.(\d{1,2}))?$').firstMatch(digits);
    if (numMatch == null) return null;
    final paise =
        int.parse(numMatch[1]!) * 100 +
        int.parse((numMatch[2] ?? '').padRight(2, '0'));
    final value = Money.fromPaise(paise);
    return value.paise > 0 ? value : null;
  }

  /// Some bank alerts print only the number after the movement verb
  /// ("debited by 50.00"). Currencyless amounts are accepted only when they
  /// are tied directly to a completed debit/credit clause, never from a bare
  /// number elsewhere in the SMS.
  static String? _currencylessBankMovementAmountText(String body) {
    final match = _re(
      r'\b(?:debited|credited|deducted|deposited|withdrawn)\s+(?:by|with|for|of)\s*(?:₹|rs\.?|inr)?\s*[:.]?\s*([\d,]+(?:\.\d{1,2})?)\b',
    ).firstMatch(body);
    return match?.group(1);
  }

  /// A merchant receipt is only independent evidence when it names an
  /// instrument that actually moved money. Otherwise the bank alert is the
  /// posted-spend source of truth and the receipt is just enrichment.
  static bool _receiptHasSettlementInstrument(String body) => _re(
    r'\b(?:a\/?c\.?|account|card|wallet)\b[^.!?\n]{0,45}\b(?:debited|deducted|charged|withdrawn)\b'
    r'|\b(?:debited|deducted|charged|withdrawn)\s+(?:from|to|on|using)\s+(?:your\s+)?(?:credit\s+|debit\s+|bank\s+)?(?:a\/?c\.?|account|card|wallet)\b',
  ).hasMatch(body);

  /// Shared by the downloaded-rule safety gate and the built-in future gate.
  /// "would" is included deliberately: it previously slipped through and was
  /// parsed as a completed spend.
  static bool _hasFutureDebitWording(String body) => _re(
    r'\b(?:(?:will|would|shall|to|scheduled\s+to|scheduled\s+for)\s+be\s+(?:auto[- ]?)?(?:debited|deducted|charged)|for\s+(?:auto[- ]?)?debit|scheduled\s+for\s+(?:auto[- ]?)?debit|(?:maintain|keep)\s+sufficient\s+(?:bal|balance)\b[\s\S]{0,50}\b(?:debit|deduction)|(?:auto[- ]?debit|auto[- ]?pay|autopay|standing\s+instruction|si\s+debit|pre[- ]?debit)\b[\s\S]{0,50}?\b(?:will|would|shall)\s+be\b|(?:auto[- ]?debit|auto[- ]?pay|autopay|standing\s+instruction|si\s+debit|pre[- ]?debit)\b[\s\S]{0,50}?\b(?:attempted|scheduled)\b)\b',
  ).hasMatch(body);

  /// True if the message describes an AutoPay, mandate, recurring contribution,
  /// or scheduled payment deduction alert.
  static bool isAutoPayNotice(String body) {
    final text = body.replaceAll(RegExp(r'\s+'), ' ');
    return _re(
          r'\b(?:autopay\s+(?:alert|reminder|scheduled)?|auto[- ]?pay|mandate|e[- ]?mandate|e[- ]?nach|enach|standing\s+instruction|si\s+(?:debit|alert|notification)|pre[- ]?debit(?:\s+notification)?|auto[- ]?debit|recurring\s+subscription)\b',
        ).hasMatch(text) ||
        _re(
          r'\b(?:will|shall|to|scheduled\s+to|scheduled\s+for)\s+(?:be\s+)?(?:auto[- ]?)?(?:deducted|debited|charged)\b',
        ).hasMatch(text) ||
        _re(
          r'\b(?:auto[- ]?deducted|auto[- ]?debited|automatically\s+(?:charged|debited|deducted))\s+(?:on|from|to)\b',
        ).hasMatch(text) ||
        _re(
          r'\b(?:contribution|subscription|installment|instalment)\s+amount\b',
        ).hasMatch(text) ||
        _re(r'\bmaintain\s+(?:sufficient\s+)?bal(?:ance)?\b').hasMatch(text) ||
        (_re(
              r'\b(?:broadband|fiber|telecom|yojana|pension|subscription|insurance|utility)\b',
            ).hasMatch(text) &&
            _re(r'\b(?:due|payable|bill|payment)\b').hasMatch(text) &&
            !_re(r'\b(?:due\s+for\s+renewal|renew\s+now)\b').hasMatch(text)) ||
        _re(
          r'\bpayment\s+of\s*(?:₹|rs\.?|inr)?\s*[\d,]+(?:\.\d{1,2})?\s*is\s+due\b',
        ).hasMatch(text);
  }

  /// A dated insurance expiry/due notice is actionable even if it also says
  /// "renew now". Date-less renewal advertising remains noise.
  static bool isActionableInsuranceRenewal(String body) {
    final hasInsurance = _re(
      r'\b(?:insurance|policy|premium|lic)\b',
    ).hasMatch(body);
    if (!hasInsurance) return false;
    final hasExpiryCue = _re(
      r'\b(?:will\s+expire|expires?\b|expiry\b|premium\s+due|renewal\s+due|due\s+for\s+renewal|next\s+premium)\b',
    ).hasMatch(body);
    if (!hasExpiryCue) return false;
    return _re(dateToken).hasMatch(body) ||
        nextPremiumDueMonth(body) != null ||
        _re(r'\b(?:today|tomorrow|in\s+\d{1,2}\s+days?)\b').hasMatch(body);
  }

  /// True if the message represents an unambiguous completed transaction, bill obligation,
  /// or balance snapshot. Used by Stage 0 sender scrubbing to whitelist real transactional
  /// alerts from promotional routes (-P).
  static bool isCompletedTransactionOrBill(String body) {
    if (isMerchantReceiptOrEbill(body) || isInvestmentFolioAllotment(body)) {
      return true;
    }
    final text = body.replaceAll(RegExp(r'\s+'), ' ');
    if (_re(
      r'\b(?:payment|amount|minimum|total|premium)\s+due\b|\bdue\s+date\b|\b(?:statement|bill|premium)\b[\s\S]{0,80}\b(?:generated|ready|available|due)\b',
    ).hasMatch(text)) {
      return true;
    }
    final orderNotice =
        _re(
          r'\b(?:order\b[\s\S]{0,40}\b(?:out\s+for\s+delivery|delivered|arriving|picked\s+up|is\s+on\s+the\s+way)|we\s+have\s+received\s+your\s+order)\b',
        ).hasMatch(text) &&
        !_re(r'\b(?:debited|credited|charged)\b').hasMatch(text);
    if (orderNotice) return false;

    final completed = _re(
      r'\b(?:your\s+(?:txn|transaction)\s+of|(?:txn|transaction)\s+(?:of\s+)?(?:₹|rs\.?|inr)\s*[*xX]*[\d,.]+|txn\s+(?:of|for)|(?:has\s+been|was|is)\s+(?:debited|credited|charged|paid)|(?:debited|credited|spent|paid|charged|transferred|withdrawn|received)(?:\s+(?:by|with|for|towards|of|amounting\s+to))?\s*(?:₹|rs\.?|inr)|(?:₹|rs\.?|inr)\s*[*xX]*\s*[\d,]+(?:\.\d{1,2})?\s*(?:has\s+been\s+)?(?:debited|credited|spent|paid|charged|transferred|withdrawn|received)|(?:sent|cash\s+withdrawal|withdrawal|auto[-\s]?debit)\s*(?:of|by)?\s*(?:₹|rs\.?|inr)|(?:recharge|payment|transaction|purchase|settlement|payout)\b[\s\S]{0,45}\b(?:successful|completed|initiated|processed))',
    ).hasMatch(text);
    final asbaIpo = _re(
      r'\b(?:asba\s+application|asba\s+(?:req(?:uest)?|bid|block|lien)|towards\s+asba|for\s+asba|asba\b[\s\S]{0,50}\b(?:accepted|blocked|lien|created)|(?:blocked|lien\s+marked)\b[\s\S]{0,50}\b(?:for|towards)?\s*(?:ipo|asba|rights\s+issue)|(?:ipo\s+(?:application|bid|mandate|block|lien)))\b',
    ).hasMatch(text);
    if (completed ||
        asbaIpo ||
        (_re(r'\b(?:cashback|refund)\b').hasMatch(text) &&
            _re(r'\b(?:credited|received|deposited)\b').hasMatch(text)) ||
        _re(r'\b(?:debit|credit)\s+hua\b').hasMatch(text)) {
      return true;
    }
    if (isAutoPayNotice(text)) {
      return true;
    }
    final balance =
        (_re(
              r'\b(?:available|current|closing|avl|avail)\s+bal(?:ance)?\b[\s\S]{0,60}(?:₹|rs\.?|inr)\s?[\d,]+(?:\.\d{1,2})?|\b(?:available|current|closing|avl|avail)\s+bal(?:ance)?\b',
            ).hasMatch(text) ||
            (_re(
                  r'\b(?:available|current|closing|avl|avail)\s+(?:credit\s+limit|limit)\b|\bcredit\s+limit\b[\s\S]{0,30}(?:₹|rs\.?|inr)\s?[\d,]+(?:\.\d{1,2})?',
                ).hasMatch(text) &&
                !_re(
                  r'\b(?:apply\s+now|pre[-\s]?approved|upgrade\s+your|zero\s+joining\s+fee|no\s+annual\s+fee|lifetime\s+free|instant\s+cash\s+loan)\b',
                ).hasMatch(text))) &&
        !_re(
          r'\b(?:eligible\s+for\s+(?:conversion|flexipay|emi)|convert\s+(?:to|into)\s+emi)\b',
        ).hasMatch(text);
    if (balance) {
      return true;
    }
    return false;
  }

  /// Messages with a quoted price or a card name are not necessarily a
  /// payment. Apply this before either upload or manual review, including to
  /// rows captured by an older app version.
  static bool isNonTransactionNoise(String sender, String body) {
    if (isMerchantReceiptOrEbill(body) || isInvestmentFolioAllotment(body)) {
      return false;
    }
    final cleanSender = sender.trim();
    if (cleanSender.isNotEmpty) {
      // 10-digit mobile phone numbers are P2P / smishing fraud
      if (RegExp(r'^(?:\+?91[\-\s]?|0)?[6-9]\d{9}$').hasMatch(cleanSender)) {
        return true;
      }
      // TRAI 140-series telemarketing CLI
      if (RegExp(r'^(?:\+?91[\-\s]?|0)?140\d{7}$').hasMatch(cleanSender)) {
        return true;
      }
      // 6-digit numeric headers where digit 1-8 is bulk promotional SMS (TRAI DLT)
      if (RegExp(
        r'^(?:[A-Za-z]{2}-)?\d{6}(?:-[A-Za-z])?$',
      ).hasMatch(cleanSender)) {
        return true;
      }
    }
    final text = body.replaceAll(RegExp(r'\s+'), ' ');
    // Biller onboarding only enrols a service; it does not report a bill.
    // "Once the bill is generated" is a future promise, so it must be
    // rejected before the bill-ready keep-rule below. Any amount, due date
    // or AutoPay/mandate terms keep the message actionable.
    final billerOnboarding =
        _re(
          r'\b(?:added|registered|enrolled|linked|activated|subscribed|enabled)\b[\s\S]{0,80}\b(?:bill\s*pay|billpay|bill\s*payment(?:\s+service)?|biller|payee|e[- ]?bill|paperless|bill\s+fetch|bill\s+alerts?)\b',
        ).hasMatch(text) ||
        _re(
          r'\b(?:bill\s*pay|billpay|biller|payee|e[- ]?bill|paperless|bill\s+fetch|bill\s+alerts?)\b[\s\S]{0,60}\b(?:added|registered|enrolled|linked|activated|subscribed|enabled|registration)\b',
        ).hasMatch(text) ||
        _re(
          r'\b(?:bill\s+will\s+be\s+generated|bill\s+generation\s+date|we\s+will\s+notify\s+you\b[\s\S]{0,60}\bbill\b|(?:you\s+will\s+(?:receive|get)|we\s+will\s+(?:send|notify|inform))\b[\s\S]{0,50}\bbill\b|\bwill\s+(?:send|notify|inform|share)\b[\s\S]{0,40}\bbill\b|(?:once|when|after)\b[\s\S]{0,30}\bbill\b[\s\S]{0,15}\b(?:is\s+|gets\s+)?generated\b)',
        ).hasMatch(text);
    final hasCurrencyAmount = _re(
      r'(?:₹|\brs\.?|\binr)\s*[\d,]+|\b\d[\d,]*(?:\.\d{1,2})?\s*(?:₹|rs\.?|inr)\b',
    ).hasMatch(text);
    final hasDueDate = _re(
      r'\b(?:payment|amount|total|minimum)\s+due\b|\bdue\s+(?:date|on|by)\b|\bpay(?:ment)?\s+(?:by|before)\b',
    ).hasMatch(text);
    final hasMandate =
        isAutoPayNotice(text) ||
        _re(
          r'\b(?:auto\s*pay|autopay|e[- ]?mandate|mandate|standing\s+instruction|auto[- ]?debit)\b',
        ).hasMatch(text);
    final hasMovement = _re(
      r'\b(?:failed|declined|debited|credited|paid|charged|transferred|withdrawn)\b|\b(?:payment|transaction|txn)\b[\s\S]{0,20}\b(?:successful|completed|failed)\b',
    ).hasMatch(text);
    if (billerOnboarding &&
        !hasCurrencyAmount &&
        !hasDueDate &&
        !hasMandate &&
        !hasMovement) {
      return true;
    }
    final hasMaskedAccount = _re(
      r'\b(?:a\/?c|account|card)\b[\s\S]{0,25}\b(?:xx|\*{2,}|ending(?:\s+(?:with|in))?\s*\d{3,4})\b|\b(?:xx|\*{2,})\d{3,4}\b',
    ).hasMatch(text);

    final telecomCarrierNotice =
        (_re(r'\b(?:number\s+)?retention\s+charges?\b').hasMatch(text) ||
            _re(
              r'\b(?:deducted|debited)\s+from\s+(?:top-?up|talktime|prepaid|main|core)\s+bal(?:ance)?\b',
            ).hasMatch(text) ||
            _re(r'\b(?:from|on)\s+top-?up\s+bal(?:ance)?\b').hasMatch(text) ||
            _re(
              r'\bno\s+usage\s+observed\b[\s\S]{0,40}\b(?:days?|recharge)\b',
            ).hasMatch(text) ||
            _re(
              r'\brecharge\s+your\s+(?:jio|airtel|vi|vodafone|idea|bsnl)?\s*number\b[\s\S]{0,60}\bto\s+avoid\s+(?:these\s+)?charges\b',
            ).hasMatch(text) ||
            (_re(
                  r'\b(?:jio|airtel|vi|vodafone|idea|bsnl)\b',
                  caseSensitive: false,
                ).hasMatch('$cleanSender $text') &&
                _re(r'\b[6-9]\d{9}\b').hasMatch(text) &&
                _re(
                  r'\b(?:recharge\s+now|(?:kindly\s+|please\s+)?recharge\s+your|validity\s+(?:is\s+)?expir|top-?up|talktime|retention)\b',
                ).hasMatch(text) &&
                !_re(
                  r'\b(?:successful|completed|done|received)\b',
                ).hasMatch(text) &&
                !hasMaskedAccount)) &&
        !hasDueDate &&
        !_re(
          r'\b(?:statement|bill)\b[\s\S]{0,80}\b(?:generated|ready|available|due)\b',
        ).hasMatch(text);
    if (telecomCarrierNotice) return true;

    // Repayment acknowledgments and loan eligibility checks that carry no
    // transaction amount or debit evidence are informational cross-sells.
    final repaymentCourtesyOrLoanUpsell =
        _re(
          r'\b(?:we\s+have\s+)?received\s+your\s+(?:timely\s+)?repayment\b[\s\S]{0,60}\btowards?\s+your\s+(?:pay\s*later|credit\s*line|loan)\b|'
          r'\b(?:check\s+your\s+)?(?:updated\s+)?personal\s+loan\s+eligibility\b|'
          r'\bpersonal\s+loan\s+eligibility\s+here\b',
        ).hasMatch(text) &&
        !hasCurrencyAmount;
    if (repaymentCourtesyOrLoanUpsell) return true;

    final loanOrCreditPowerMarketing =
        _re(
          r'\b(?:new\s+credit\s+alert|your\s+loan\s+limit\s+is\s+revised|(?:loan|credit)\s+limit\b[\s\S]{0,30}\b(?:revised|increased|enhanced|updated)|digital\s+credit\s+power\s+is\s+(?:now\s+)?active|updated\s+limit\s+here\b|view\s+your\s+updated\s+limit)\b',
        ).hasMatch(text) &&
        !hasCurrencyAmount;
    if (loanOrCreditPowerMarketing) return true;

    final bettingOrGamblingSpam = _re(
      r'\b(?:betting\s+(?:site|app)|gullybet|casino|slots|aviator|cockfight|fancy\s+bet|teen\s+patti|online\s+gambling|huge\s+bonus\b[\s\S]{0,30}\b(?:bet|casino|slots|win)|gbets\.win)\b',
    ).hasMatch(text);
    if (bettingOrGamblingSpam) return true;

    // A real amount due or statement remains useful even when the issuer
    // appends an offer. Let the bill parser handle it.
    if (_re(
      r'\b(?:payment|amount|minimum|total|premium)\s+due\b|\bdue\s+date\b|\b(?:statement|bill|premium)\b[\s\S]{0,80}\b(?:generated|ready|available|due)\b',
    ).hasMatch(text)) {
      return false;
    }
    // Past aggregate spend is often quoted solely to sell an EMI conversion.
    // It is not a new debit alert.
    if (_re(
          r'\b(?:eligible\s+for\s+(?:[\w\s]{0,20}\s+)?(?:conversion|flexipay|emis?)|convert(?:ed|ing)?\b[\s\S]{0,60}?\b(?:in)?to\b[\s\S]{0,20}?\b(?:smart\s+|flexipay\s+|easy\s+)?emis?|can\s+(?:now\s+)?be\s+converted\s+(?:in)?to\s+emis?|flexipay\s+emis?)\b',
        ).hasMatch(text) &&
        !_re(
          r'\b(?:has\s+been|was|is)\s+(?:debited|credited|charged|paid)\b',
        ).hasMatch(text) &&
        !_re(
          r'\b(?:debited|charged)\s*(?:by|with|for)?\s*(?:₹|rs\.?|inr)',
        ).hasMatch(text)) {
      return true;
    }
    final orderNotice =
        _re(
          r'\b(?:order\b[\s\S]{0,40}\b(?:out\s+for\s+delivery|delivered|arriving|picked\s+up|is\s+on\s+the\s+way)|we\s+have\s+received\s+your\s+order)\b',
        ).hasMatch(text) &&
        !_re(r'\b(?:debited|credited|charged)\b').hasMatch(text);
    if (orderNotice) return true;

    final completed =
        _re(
          r'\b(?:your\s+(?:txn|transaction)\s+of|(?:txn|transaction)\s+(?:of\s+)?(?:₹|rs\.?|inr)?\s*[\d,.]+|txn\s+(?:of|for)|(?:has\s+been|was|is)\s+(?:debited|credited|charged|paid)|(?:debited|credited|spent|paid|charged|transferred|withdrawn|received)(?:\s+(?:by|with|for|towards|of|amounting\s+to))?\s*(?:₹|rs\.?|inr)|(?:₹|rs\.?|inr)\s*[*xX]*\s*[\d,]+(?:\.\d{1,2})?\s*(?:has\s+been\s+)?(?:debited|credited|spent|paid|charged|transferred|withdrawn|received)|(?:sent|cash\s+withdrawal|withdrawal|auto[-\s]?debit)\s*(?:of|by)?\s*(?:₹|rs\.?|inr)|(?:recharge|payment|transaction|purchase|settlement|payout)\b[\s\S]{0,45}\b(?:successful|completed|initiated|processed))',
        ).hasMatch(text) &&
        !(_re(r'\b(?:will|shall)\s+be\b').hasMatch(text) && !hasCurrencyAmount);
    final asbaIpo = _re(
      r'\b(?:asba\s+application|asba\s+(?:req(?:uest)?|bid|block|lien)|towards\s+asba|for\s+asba|asba\b[\s\S]{0,50}\b(?:accepted|blocked|lien|created)|(?:blocked|lien\s+marked)\b[\s\S]{0,50}\b(?:for|towards)?\s*(?:ipo|asba|rights\s+issue)|(?:ipo\s+(?:application|bid|mandate|block|lien)))\b',
    ).hasMatch(text);
    if (completed ||
        asbaIpo ||
        (_re(r'\b(?:cashback|refund)\b').hasMatch(text) &&
            _re(r'\b(?:credited|received|deposited)\b').hasMatch(text)) ||
        _re(r'\b(?:debit|credit)\s+hua\b').hasMatch(text)) {
      return false;
    }
    if (isAutoPayNotice(text)) {
      return false;
    }
    final offer = _re(
      r'\b(?:offer|sale|discount|cashback|voucher|coupon|rewarding|shop\s+at|grab|buy\s+now|apply\s+now|prices?\s+slashed|treat\s+yourself|festive\s+shopping|eligible\s+for\s+conversion|convert\s+(?:to|into)\s+emi|international\s+roaming\s+pack)\b|\b(?:get|earn|save)\b[\s\S]{0,45}\b(?:reward|cashback|off|free|voucher)\b',
    ).hasMatch(text);
    final serviceNotice = _re(
      r'\b(?:services?\s+(?:is|are|has\s+been)\s+(?:blocked|suspended)|visit\s+(?:your\s+)?nearest\s+branch|suspicious\s+(?:txns?|transactions?)\s+in\s+your\s+account|call\s+forwarding\s+is\s+(?:now\s+)?active|calls?\s+are\s+being\s+forwarded|to\s+deactivate\s+(?:this\s+)?service|transaction\s+check\s+alert|confirm\s+(?:the\s+)?(?:following\s+)?txn|sim\s+swap|reported\s+(?:your\s+)?fund\s+bal(?:ance)?|securities\s+bal(?:ance)?|excludes\s+your\s+bank|beware\s+(?:of\s+)?dealing\s+(?:in|on)\s+unsolicited\s+tips|unsolicited\s+tips|due\s+for\s+renewal|renew\s+now\s+with\s+policybazaar|wallet\s+balance\s+is\s+(?:rs\.?|inr)\s*0|add\s+money\s+to\s+wallet|report\s+spam|trai\s+dnd|telecommunications\s+act|sanchar\s+saathi|chakshu|share\s+yours?\s+feedback\b|help\s+us\s+serve\b|rate\s+yours?\s+(?:experience|service|stay|purchase|ride)\b|experience\s+(?:matters\s+to\s+us|and\s+feedback)|csat\s+score|nps\s+survey|net\s+promoter\s+score|take\s+(?:a\s+)?(?:quick\s+)?survey\b|survey\s+(?:link|earn)|online\s+investment\s+scams|traded\s+value\s+for\b|has\s+been\s+dispatched|has\s+been\s+delivered|modification\s+success!?|card\s+usage\s+settings?|card\s+(?:usage\s+)?settings?\s+(?:for|modified|updated)|card\s+controls?\s+(?:modified|updated)|card\s+usage\s+(?:limits?|controls?|preferences?)|usage\s+(?:&|and)\s+transaction\s+limit|transaction\s+limits?\s+options?|limits?\s+(?:have|has)\s+been\s+updated|usage\s+options?\s+(?:have|has)\s+been\s+updated|ckyc\s+record|central\s+kyc\s+registry|out\s+for\s+delivery\s+with\s+cash\s+memo|pls\s+share\s+delivery\s+code|delivery\s+code\s+\d+|talktime\s+bal(?:ance)?|prepaid\s+bal(?:ance)?|low\s+talktime|recharge\s+now\s+to\s+stay\s+connected|data\s+pack\s+expired|data\s+exhausted|\d+%\s+daily\s+data\s+used)\b',
    ).hasMatch(text);
    final balance =
        (_re(
              r'\b(?:available|current|closing|avl|avail)\s+bal(?:ance)?\b[\s\S]{0,60}(?:₹|rs\.?|inr)\s?[\d,]+(?:\.\d{1,2})?|\b(?:available|current|closing|avl|avail)\s+bal(?:ance)?\b',
            ).hasMatch(text) ||
            (_re(
                  r'\b(?:available|current|closing|avl|avail)\s+(?:credit\s+limit|limit)\b|\bcredit\s+limit\b[\s\S]{0,30}(?:₹|rs\.?|inr)\s?[\d,]+(?:\.\d{1,2})?',
                ).hasMatch(text) &&
                !_re(
                  r'\b(?:apply\s+now|pre[-\s]?approved|upgrade\s+your|zero\s+joining\s+fee|no\s+annual\s+fee|lifetime\s+free|instant\s+cash\s+loan)\b',
                ).hasMatch(text))) &&
        !_re(
          r'\b(?:eligible\s+for\s+(?:conversion|flexipay|emi)|convert\s+(?:to|into)\s+emi)\b',
        ).hasMatch(text);
    if (balance) {
      return false;
    }

    final promotionalSender =
        _re(r'-p\s*$').hasMatch(cleanSender) &&
        !isCompletedTransactionOrBill(body);
    final operationalNotice = _re(
      r'\b(?:will\s+remain\s+open\s+and\s+fully\s+operational|available\s+at\s+our\s+branches\s+during\s+normal\s+working\s+hours|submission\s+of\s+positive\s+pay\s+details\s+is\s+mandatory)\b|'
      r'\bdone\s+\d+\s+out\s+of\s+\d+\s+free\s+transactions\s+at\s+[\w\s]+atms\b|'
      r'\b(?:cdsl|nsdl)\s*:\s*(?:debit|credit)\s+in\s+a/c\b[\s\S]{0,40}\b(?:etf|bees|shares?|units?|mf)\b|'
      r'\b(?:cdsl|nsdl)\s*:\s*(?:unpledge|pledge)\b|'
      r'\b(?:updated\s+(?:your\s+)?address\s+(?:under|of)\s+folio|address\s+in\s+folio[^\w\n]*\w+\s+(?:is|has\s+been)\s+updated|based\s+on\s+(?:the\s+)?feed\s+received\s+from\s+kra)\b|'
      r"\b(?:track\s+it\s+using\s+this\s+ticket\s+id|ticket\s+id\s*:\s*\d+\s+on\s+the\s+help\s+section|we're\s+on\s+it\s+and\s+will\s+get\s+back\s+to\s+you\s+in\s+\d+[-–]\d+\s+hours)\b|"
      r'\benable\s+online,\s+international\s+(?:and|&)\s+contactless\s+transactions\b|'
      r'\byour\s+ekyc\s+has\s+been\s+successfully\s+completed\b|'
      r'\bdue\s+to\s+scheduled\s+maintenance\b[\s\S]{0,80}\b(?:paused|unavailable|interrupted)\b|'
      r'\bregistration\s+alert\s*:\s*device\s+name\b|'
      r'\bcoupons?\s+expire\b|'
      r'\b(?:order\b[\s\S]{0,40}\b(?:is\s+)?dispatched\s+through|order\s+(?:is\s+)?dispatched\s+through|we\s+have\s+received\s+your\s+order\s+id)\b|'
      r'\blifetime[- ]free\s+credit\s+card\s+facility\s+has\s+been\s+enabled\b|'
      r'\b(?:two\s+wheeler|car|motor|vehicle)?\s*insurance\s+for\b[\s\S]{0,50}\b(?:has\s+expired|expires\s+today|will\s+expire)\b|'
      r'\b(?:two\s+wheeler|car|motor|vehicle)?\s*insurance\s+expired\b|'
      r'\b(?:bse\s+trade\s+confirmation|welcome\s+to\s+nse,\s+you\s+have\s+been\s+registered\b|registered\s+with\s+[\w\s]+in\s+segment(?:\(s\))?|registered\s+with\s+[\w\s]+in\s+segment\(s\))\b|'
      r'\b(?:puc\s+certificate\s+for\s+vehicle\b|your\s+itr\s+for\s+ay\b[\s\S]{0,30}\bawaits\s+at\s+the\s+e[- ]?filing\s+portal)\b|'
      r'\b(?:(?:last\s+chance\s*:?\s*)?renew\s+(?:your\s+)?expired\b|(?:(?:car|motor|two[ -]?wheeler|vehicle|bike|health)\s+)?insurance\s+will\s+expire\s+on\b|will\s+expire\s+on\b[\s\S]{0,80}\b(?:premium|insurance|renew|policy|visit|starts?\s+(?:just\s+)?(?:at\s+)?(?:rs\.?|inr)|instant\s+renewal)\b|\+\s*taxes\*?)\b|'
      r'\b(?:claim\s+your\s+[\w\s]+(?:insta\s+)?emi\s+card|avail\s+(?:credit\s+)?card\s+with\s+limit|eligible\s+for\s+(?:a\s+)?(?:[\w\s]{0,20}\s+)?loan\b|use\s+card\s+loan\s+limit\s+of\b|complete\s+your\s+[\w\s]+emi\s+card\s+application|pre[-\s]?approved\s+loan)\b|'
      r'\b(?:is\s+still\s+not\s+renewed|renew\s+to\s+avoid\s+unexpected\s+expenses|renew\s+before\s+expiry\s+on|registration\s+for\s+(?:fingerprint|face\s+id|biometric)|your\s+request\s+for\s+renewal\s+has\s+been\s+received\s+&\s+processed)\b',
    ).hasMatch(text);
    // Informational card/account controls carry no money movement, amount,
    // due date, balance or mandate. They are matched last so a completed
    // debit, bill, balance snapshot or limit-with-amount already returned
    // false above and remains useful.
    final sebiSettlementPattern = _re(
      r'\b(?:unused|unutilised)\s+funds\b[\s\S]{0,100}\b(?:transferred|settled|settlement)\b'
      r'|\bas\s+per\s+sebi\b[\s\S]{0,120}\bsettlement\b',
    ).hasMatch(text);

    final hasCompletedSettlement =
        hasCurrencyAmount &&
        (hasMovement ||
            _re(
              r'\b(?:transferred|settled|credited|payout|released)\b',
            ).hasMatch(text)) &&
        !_re(
          r'\b(?:will|shall)\s+be\s+(?:transferred|settled|credited|paid|released)\b',
        ).hasMatch(text);

    final sebiSettlementNoise =
        sebiSettlementPattern && !hasCompletedSettlement;

    final controlNotice =
        sebiSettlementNoise ||
        _re(
          r'\btransaction\s+limits?\b[\s\S]{0,60}\b(?:has|have|is|are)\s+been\s+(?:updated|changed|modified|set)\b'
          r'|\bsecurity\s+tip\b[\s\S]{0,80}\b(?:enable|set|disable|protect|never\s+share|keep\s+your)\b'
          r'|\benable\s+online\s+(?:use|usage|transactions?)\b'
          r'|\bset\s+limit\s+on\b[\s\S]{0,40}\b(?:credit\s+card|card)\b'
          r'|\b(?:credit\s+card|card|account)\b[\s\S]{0,50}\bhas\s+been\s+linked\b'
          r'|\blinked\s+for\s+(?:net\s*banking|internet\s+banking|mobile\s+banking)\b'
          r'|\bday\s+of\s+settlement\b',
        ).hasMatch(text);
    if (isActionableInsuranceRenewal(body)) return false;
    return offer ||
        serviceNotice ||
        operationalNotice ||
        controlNotice ||
        promotionalSender;
  }

  /// True only for a deposit/current/savings-bank alert. Account-shaped
  /// suffixes from insurance, demat, brokerage, investment, and card alerts
  /// must not create rows in Home's bank-account snapshot.
  static bool isBankAccountMessage(String body, [String sender = '']) {
    final cleaned = body.replaceAll(advisoryWarningRe, '');
    final text = cleaned.toLowerCase();
    if (text.trim().isEmpty) return false;
    final senderText = sender.toLowerCase();
    // Axio is a Pay Later / lending account, not a deposit bank. Its sender
    // families use bank-like words such as "a/c", "credit", and "received"
    // in eligibility and repayment promotions, which must never establish
    // ownership of a savings/current account.
    if (senderText.contains('axio') ||
        RegExp(r'\b(?:pay\s+later|credit\s+line)\b').hasMatch(text)) {
      return false;
    }
    final hasExplicitAccount = RegExp(
      r'\b(?:a\/?c\.?|account)\s*(?:no\.?|number)?\s*(?:(?:ending(?:\s+with)?|last\s*4)\s*)?[*xX.\s-]*\d{4}\b',
    ).hasMatch(text);
    if (RegExp(r'\bcredit\s+card\b').hasMatch(text)) {
      return false;
    }
    if (!hasExplicitAccount && RegExp(r'\bdebit\s+card\b').hasMatch(text)) {
      return false;
    }
    if (RegExp(
      r'\b(?:lic|life\s+insurance|policy|premium|demat|trading|broker(?:age|ing)?|portfolio|holdings?|folio|dp\s*id|client\s*id|nav|units?|shares|equity\s+shares?|stocks?|equity|sip|mutual\s+fund|investment|zerodha|groww|upstox|angel\s+one|dhan|paytm\s+money)\b',
    ).hasMatch(text)) {
      return false;
    }
    final accountMarker = RegExp(
      r'\b(?:bank|a\/?c\.?|account|savings|current|upi|imps|neft|rtgs|atm|co-?op(?:erative)?|sahakari|ucb)\b',
    ).hasMatch(text);
    final bankIdentityMarker =
        RegExp(
          r'\b(?:bank|a\/?c\.?|savings|current|upi|imps|neft|rtgs|atm|co-?op(?:erative)?|sahakari|ucb)\b',
        ).hasMatch(text) ||
        RegExp(
          r'(?:bank|bnk|bk|upi|sbi|yono|sbyono|sbiyon|uco|axis|canara|canbnk|canbk|hdfc|kotak|union|equitas|pnb|icici|idbi|indus|yes|rbl|bob|boi|pytm|paytm|federal|aubank|citi|hsbc|dbs|scb|gucb|cosmos|svc|tjsb|nkgsb|kccb|coop|ucb)',
        ).hasMatch(senderText);
    final balanceMarker = RegExp(
      r'\b(?:(?:total\s+)?(?:available|avail|avl|current|closing|clr|new|remaining)\.?\s*(?:balance|bal)\b|bal(?:ance)?\.?\s*(?:is|:|-))',
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
    r'\bfrom\b[\s\S]{0,100}\b(?:a\/?c\.?|account)\s*(?:no\.?|number)?\s*(?:(?:ending(?:\s+(?:with|in))?|last\s*4)\s*)?[*xX.\s-]*\d{4}[\s\S]{0,100}\b(?:to|towards?)\b[\s\S]{0,100}\b(?:a\/?c\.?|account)\s*(?:no\.?|number)?\s*(?:(?:ending(?:\s+(?:with|in))?|last\s*4)\s*)?[*xX.\s-]*\d{4}\b|\b(?:a\/?c\.?|account)\s*(?:no\.?|number)?\s*(?:(?:ending(?:\s+(?:with|in))?|last\s*4)\s*)?[*xX.\s-]*\d{4}[\s\S]{0,35}\b(?:debited|sent|transferred|paid)\b[\s\S]{0,100}\b(?:to|towards?)\b[\s\S]{0,100}\b(?:a\/?c\.?|account)\s*(?:no\.?|number)?\s*(?:(?:ending(?:\s+(?:with|in))?|last\s*4)\s*)?[*xX.\s-]*\d{4}\b',
  ).hasMatch(body);

  static bool _walletLoad(String body) => _re(
    // Require a wallet-ish noun within a short window after the load verb. A
    // bare "add funds" cannot win: broker alerts say "add funds back to your
    // Dhan account" as an instruction for the next action, which is not this
    // transaction. Named-wallet branches below carry the common real shapes.
    r'\b(?:wallet\s+load|load(?:ed|ing)?\s+(?:the\s+)?(?:paytm|phonepe|amazon\s*pay|mobikwik|wallet)|money\s+added\s+to\s+(?:the\s+)?wallet|add\s+(?:money|funds?)|top[ -]?up|money\s+added)\b[\s\S]{0,40}\b(?:paytm|phonepe|amazon\s*pay|mobikwik|wallet)\b|\b(?:paytm|phonepe|amazon\s*pay|mobikwik)\b[\s\S]{0,40}\b(?:add\s+(?:money|funds?)|top[ -]?up|wallet\s+load|added)\b|\b(?:added|loaded|credited)\s+to\s+(?:the\s+)?(?:paytm|phonepe|amazon\s*pay|mobikwik)\s+wallet\b|\b(?:paytm|phonepe|amazon\s*pay|mobikwik)\s+wallet\b[\s\S]{0,30}\b(?:added|loaded|credited)\b',
  ).hasMatch(body);

  static String? _detectBrokerName(String body, [String? sender]) {
    final text = '$sender $body'.toLowerCase();
    if (RegExp(r'\b(?:zerodha)\b').hasMatch(text)) return 'Zerodha';
    if (RegExp(r'\b(?:dhan(?:hq)?)\b').hasMatch(text)) return 'Dhan';
    if (RegExp(r'\b(?:groww)\b').hasMatch(text)) return 'Groww';
    if (RegExp(r'\b(?:upstox)\b').hasMatch(text)) return 'Upstox';
    if (RegExp(r'\b(?:angel\s+one|angel\s+broking|angel)\b').hasMatch(text))
      return 'Angel One';
    if (RegExp(r'\b(?:5paisa)\b').hasMatch(text)) return '5paisa';
    if (RegExp(r'\b(?:kotak\s+neo|kotakn|neo)\b').hasMatch(text))
      return 'Kotak Neo';
    if (RegExp(r'\b(?:kotak\s+securities|kotaks)\b').hasMatch(text))
      return 'Kotak Securities';
    if (RegExp(r'\b(?:hdfc\s+sky|hdfcsky)\b').hasMatch(text)) return 'HDFC Sky';
    if (RegExp(r'\b(?:hdfc\s+securities|hdfcsec)\b').hasMatch(text))
      return 'HDFC Securities';
    if (RegExp(r'\b(?:icici\s+direct|icicid|icicis)\b').hasMatch(text))
      return 'ICICI Direct';
    if (RegExp(r'\b(?:paytm\s+money|pytmmn|paytmm)\b').hasMatch(text))
      return 'Paytm Money';
    if (RegExp(r'\b(?:motilal\s+oswal|moswal|motlal)\b').hasMatch(text))
      return 'Motilal Oswal';
    if (RegExp(r'\b(?:sharekhan|shrkhn)\b').hasMatch(text)) return 'Sharekhan';
    if (RegExp(r'\b(?:espresso|esprso)\b').hasMatch(text)) return 'Espresso';
    if (RegExp(r'\b(?:lemonn)\b').hasMatch(text)) return 'Lemonn';
    if (RegExp(r'\b(?:shoonya|shoony)\b').hasMatch(text)) return 'Shoonya';
    if (RegExp(r'\b(?:finvasia|fnvasia)\b').hasMatch(text)) return 'Finvasia';
    if (RegExp(r'\b(?:blinkx)\b').hasMatch(text)) return 'BlinkX';
    if (RegExp(r'\b(?:jm\s+financial|jmfin)\b').hasMatch(text))
      return 'JM Financial';
    if (RegExp(r'\b(?:geojit)\b').hasMatch(text)) return 'Geojit';
    if (RegExp(r'\b(?:axis\s+direct|axisdir|axisd)').hasMatch(text))
      return 'Axis Direct';
    if (RegExp(r'\b(?:m\.?stock)\b').hasMatch(text)) return 'm.Stock';
    if (RegExp(r'\b(?:mirae\s+asset|miraea|mirae)\b').hasMatch(text))
      return 'Mirae Asset';
    if (RegExp(r'\b(?:iifl\s+securities|iiflsec|iiflsc|iifl)\b').hasMatch(text))
      return 'IIFL Securities';
    if (RegExp(r'\b(?:sbi\s+securities|sbisec|sbicap)\b').hasMatch(text))
      return 'SBI Securities';
    if (RegExp(r'\b(?:fyers)\b').hasMatch(text)) return 'Fyers';
    return null;
  }

  static bool _brokerSettlement(String body, [String? sender]) =>
      isBrokerSettlementMessage(body, sender);

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

  /// UPI debit alerts often put the account clause before the recipient:
  /// "debited from A/c XX1234 to Sujay Enterprises via UPI". The generic
  /// `from ...` merchant pattern otherwise keeps the account text as part of
  /// the merchant name. Require the account-shaped source and UPI rail so this
  /// remains narrow and does not change unrelated card or NEFT narratives.
  static String? _upiAccountRecipient(String body) {
    final match = _re(
      r'\bfrom\s+(?:your\s+)?(?:a\/?c\.?|account)\s*(?:no\.?|number)?\s*[*xX.\s-]*\d{4}[\s\S]{0,50}?\bto\s+([A-Za-z][A-Za-z0-9 .&@_\x27/-]{1,80}?)(?=\s+(?:by\s+upi|via\s+upi|via|on|ref(?:erence)?|refno|avl|available|bal(?:ance)?)\b|[.,;]|$)',
    ).firstMatch(body);
    return match?.group(1)?.trim();
  }

  /// UPI narrations carry the counterparty in a slash-separated slot:
  /// UPI/P2M/<ref>/<party>[/<bank>]. The reference may be masked
  /// ("**** 6977") and is never a name. Returns null instead of inventing a
  /// party when only routing tokens remain.
  static String? _upiNarrationParty(String body) {
    final line = _re(r'\bUPI\s*/\s*[^\n]{3,200}').firstMatch(body)?.group(0);
    if (line == null) return null;
    final segments = line
        .split('/')
        .map((segment) => segment.trim())
        .where((segment) => segment.isNotEmpty)
        .toList();
    if (segments.length < 2) return null;
    var index = 1;
    if (_re(r'^(?:P2M|P2A|P2P|REV|PAY|CR|DR)$').hasMatch(segments[index])) {
      index += 1;
    }
    while (index < segments.length &&
        _re(r'^(?:[Xx*#•●·.\-]{2,}\s*)?\d{4,}$').hasMatch(segments[index])) {
      index += 1;
    }
    if (index >= segments.length) return null;
    final party = segments[index]
        .replaceFirst(
          _re(
            r'\s+\b(?:on|dated|ref(?:erence)?|refno|txn|transaction|not\s+you|call|sms\s+block|via|bal(?:ance)?|avl|available)\b[\s\S]*$',
          ),
          '',
        )
        .trim();
    if (party.isEmpty ||
        _re(
          r'^(?:upi|yono|imps|neft|rtgs|vpa|p2m|p2a|p2p|rev|pay|cr|dr)$',
        ).hasMatch(party)) {
      return null;
    }
    return party;
  }

  static bool _incomingBankTransferCandidate(String body) =>
      !_re(r'\b(?:salary|cashback|refund(?:ed)?)\b').hasMatch(body) &&
      _re(r'\bfrom\b[\s\S]{0,80}\b(?:bank|a\/?c\.?|account)\b').hasMatch(body);

  static bool _earnedIncomeCredit(String body) =>
      !_re(
        r'\b(?:refund(?:ed)?|chargeback|reversal|reversed|cashback|reward|rewards|points?|miles?|loan|personal\s+loan|credit\s+line|emi|equated\s+monthly\s+installment|instalment|investment|mutual\s+fund|shares|equity\s+shares?|stocks?|demat|portfolio|cash\s+deposit|gift|reimburse(?:ment|d)?|expense\s+claim)\b',
      ).hasMatch(body) &&
      !_re(r'\bsalary\s+advance\b').hasMatch(body) &&
      _re(
        r'\b(?:salary|wages?|payroll|pension|interest|dividend|rent|commission|consulting|business\s+(?:receipt|income)|invoice\s+paid)\b',
      ).hasMatch(body);

  static bool _loanRepayment(String body) =>
      !_feeCharge(body) &&
      (_re(
            r'\b(?:loan|personal\s+loan|home\s+loan|car\s+loan|education\s+loan|emi|equated\s+monthly\s+installment|instalment)\b[\s\S]{0,90}\b(?:paid|payment|debited|repaid|repayment|deducted|transferred)\b',
          ).hasMatch(body) ||
          // "credited ... towards the payment of EMI" — verb before keyword.
          // "received" only counts here, never keyword-first, because every
          // disbursement alert says "loan ... received/credited".
          _re(
            r'\b(?:payment|repayment|repaid|received)\b[\s\S]{0,60}\b(?:of|towards?|for)\b[\s\S]{0,20}\b(?:the\s+)?(?:loan|emi|equated\s+monthly\s+installment|instalment)\b',
          ).hasMatch(body));

  static bool _feeCharge(String body) => _re(
    r'\b(?:bank\s+charges?|service\s+charges?|processing\s+fees?|convenience\s+fees?|'
    r'late\s+fees?|annual\s+fees?|maintenance\s+fees?|finance\s+charges?|interest\s+charges?|'
    r'interest\s+(?:on\s+)?(?:loan|emi)|(?:loan|emi)\s+interest|commission|brokerage\s+fees?|'
    r'gst\s+on\s+(?:fee|charge)|sms\s*(?:alert\s*)?charges?|debit\s*card\s*(?:annual\s*fee|amc|charges?)|'
    r'consolidated\s*charges?|(?:non[- ]maintenance|amb|mab|qab|aqb)\s*charges?|'
    r'(?:cheque|nach|ecs)\s*(?:bounce|return)\s*charges?|atm\s*(?:decline|usage|transaction)\s*charges?)\b',
  ).hasMatch(body);

  static bool _investmentProceeds(String body) =>
      (_re(
        r'\b(?:redeemed?|redemption|sold|sale\s+proceeds?|withdrawn?)\b',
      ).hasMatch(body) &&
      _re(
        r'\b(?:mutual\s+fund|sip|investment|shares|equity\s+shares?|stocks?|equity|zerodha|groww|upstox|angel\s+one|dhan|demat|portfolio)\b',
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

  static TxnInstrument? _savedCardInstrument(
    List<UserCard> cards,
    String? last4,
  ) {
    if (last4 == null) return null;
    final types = cards
        .where((card) => !card.isArchived && card.last4 == last4)
        .map((card) => card.cardType?.toLowerCase())
        .where((type) => type == 'credit' || type == 'debit')
        .toSet();
    if (types.length != 1) return null;
    return types.single == 'debit'
        ? TxnInstrument.debitCard
        : TxnInstrument.creditCard;
  }

  static TxnInstrument? _explicitCardInstrument(String body) {
    if (_re(r'\bcredit\s+card\b').hasMatch(body)) {
      return TxnInstrument.creditCard;
    }
    if (_re(
      r'\bdebit\s+card\b|\b(?:atm|withdrawn|cash\s+withdrawal|block\s+dc)\b',
    ).hasMatch(body)) {
      return TxnInstrument.debitCard;
    }
    if (_re(r'\bcard\b').hasMatch(body) &&
        _re(
          r'\b(?:avl\.?\s*(?:lmt|limit)|available\s+(?:credit|limit)|credit\s+limit|outstanding|statement|minimum\s+amount\s+due|total\s+amount\s+due|amount\s+due)\b',
        ).hasMatch(body)) {
      return TxnInstrument.creditCard;
    }
    return null;
  }

  static final advisoryWarningRe = RegExp(
    r"\b(?:(?:do\s+not|don't|never)\s+share\b[\s\S]{0,60}?\b(?:otp|pin|cvv|password|passcode|details|secret|code)\b|(?:bank|sbi|union\s+bank)\s+(?:will\s+)?never\s+(?:call|ask)\s+for\b[\s\S]{0,60}?\b(?:otp|pin|cvv|password|details)|bank\s+never\s+asks\s+for\b[\s\S]{0,60}?\b(?:otp|pin|cvv|password|details))\b[^\n]*",
    caseSensitive: false,
  );

  static bool sensitive(String body) {
    final cleaned = body.replaceAll(advisoryWarningRe, '');
    return RegExp(
      r"\b(?:otp|one[-\s]?time password|verification code|security code|cvv|pin|passcode|secret code)\b|\b(?:do not|don't|never)\s+share\b|\b\d{4,8}\b[\s\S]{0,40}\bvalid\s+(?:for|till|until)\s+\d+\s*(?:minutes?|mins?|seconds?|secs?)\b",
      caseSensitive: false,
    ).hasMatch(cleaned);
  }

  static RegExp _re(String s, {bool caseSensitive = false}) =>
      RegExp(s, caseSensitive: caseSensitive);

  /// Extracts a display-safe biller name without retaining the raw SMS.
  /// Bank sender IDs are transport identifiers (for example, TNBPAY), not
  /// the provider name a person should see in a commitment list.
  static String? _cleanMandateBiller(String? name) {
    if (name == null) return null;
    var cleaned = name.trim();
    cleaned = cleaned
        .replaceFirst(RegExp(r'^ICCL\s+', caseSensitive: false), '')
        .trim();
    cleaned = cleaned
        .replaceFirst(RegExp(r'\s+AUTOPAY$', caseSensitive: false), '')
        .trim();
    cleaned = cleaned
        .replaceFirst(RegExp(r'\s+MANDATE$', caseSensitive: false), '')
        .trim();
    cleaned = cleaned
        .replaceFirst(RegExp(r'\s+ending\s+(?:in\s+)?\d+.*$', caseSensitive: false), '')
        .trim();
    if (RegExp(r'^\d{1,4}[-/.]\d{1,2}[-/.]\d{2,4}$').hasMatch(cleaned)) {
      return null;
    }
    if (RegExp(
      r'^(?:(?:the|your)\s+)?(?:upcoming|scheduled)\s+(?:mandate|debit|payment)|^(?:credit\s*card|card|account|bank|mandate)$',
      caseSensitive: false,
    ).hasMatch(cleaned)) {
      return null;
    }
    if (cleaned.toUpperCase() == 'GROWW') return 'Groww';
    if (cleaned.toUpperCase() == 'ZERODHA') return 'Zerodha';
    return cleaned.isNotEmpty ? cleaned : null;
  }

  static String? extractBillerName(String body) {
    final text = body.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (_re(r'\batal\s+pension\s+yojana\b').hasMatch(text)) {
      return 'Atal Pension Yojana';
    }
    final merchantLabelMatch = _re(
      r'\b(?:merchant|biller|payee|service\s+provider)\s*[:\-]\s*([A-Za-z0-9_][-A-Za-z0-9 .&\x27/()]{1,60})',
    ).firstMatch(body);
    if (merchantLabelMatch != null) {
      final name = merchantLabelMatch.group(1)?.trim();
      if (name != null && name.length >= 2) {
        return name;
      }
    }
    final towardsMandatePartyMatch = _re(
      r'\btowards\s+(?:(?:your|the)\s+)?([A-Za-z0-9_][-A-Za-z0-9 .&\x27/()]{1,60}?)(?=\s+(?:for\s+(?:upi\s+mandate|the\s+recurring|recurring|upi|mandate)|for|from|on|before|via|ref|txn|if\s+not|will|shall|would|is|ending)\b|[,.;]|$)',
    ).firstMatch(text);
    if (towardsMandatePartyMatch != null) {
      final cleaned = _cleanMandateBiller(towardsMandatePartyMatch.group(1));
      if (cleaned != null && cleaned.length >= 2) {
        return cleaned;
      }
    }
    final mandateTowardsMatch = _re(
      r'\b(?:created\s+towards|mandate\b[\s\S]{0,50}?\b(?:created\s+towards|towards)|subscription\s+to|subscription\s+towards|for\s+(?:the\s+)?subscription\s+to|initiated\s+by)\s+([A-Za-z0-9_][-A-Za-z0-9 .&\x27/()]{1,60}?)(?=\s+(?:from|for|on|before|is|has|was|processed|successful|completed)\b|[,.;]|$)',
    ).firstMatch(text);
    if (mandateTowardsMatch != null) {
      final name = _cleanMandateBiller(mandateTowardsMatch.group(1));
      if (name != null &&
          name.length >= 2 &&
          !_re(r'^(?:credit card|card|account|bank)$').hasMatch(name.toLowerCase())) {
        return name;
      }
    }
    final billScheduledMatch = _re(
      r'\b(?:bill\s+payment\b[\s\S]{0,40}?\bfor|payment\b[\s\S]{0,40}?\bfor)\s+([A-Za-z0-9_][-A-Za-z0-9 .&\x27/(),]{2,60}?)(?:\s+\d{5,})?\s+(?:is\s+scheduled|scheduled\s+(?:for|on)|is\s+due|due\s+on)\b',
    ).firstMatch(text);
    if (billScheduledMatch != null) {
      final name = billScheduledMatch.group(1)?.trim();
      if (name != null &&
          name.length >= 3 &&
          !_re(
            r'^(?:credit card|card|account|bank)$',
          ).hasMatch(name.toLowerCase())) {
        return name;
      }
    }

    final prefixMatch = _re(
      r'^([A-Za-z][A-Za-z0-9 .&\x27/-]{2,40}?)\s*\.{3}',
    ).firstMatch(text);
    if (prefixMatch != null) {
      final name = prefixMatch.group(1)?.trim();
      if (name != null && name.length >= 3) {
        return name;
      }
    }
    final cardMatch = _re(
      r'\bfor\s+(credit\s+card\s+\d{4})\s+bill\b',
    ).firstMatch(text);
    if (cardMatch != null) {
      return cardMatch.group(1);
    }
    final towardsCardMatch = _re(
      r'\b(?:towards|for)\s+([A-Za-z][A-Za-z0-9 .&\x27/-]{2,50}?\b(?:Credit\s+Card|Card))\b',
    ).firstMatch(text);
    if (towardsCardMatch != null) {
      final name = towardsCardMatch.group(1)?.trim();
      if (name != null && name.length >= 3) {
        return name.replaceAll(RegExp(r'\s+'), ' ');
      }
    }
    final patterns = [
      _re(
        r'\b(?:your|the)\s+([A-Za-z][A-Za-z0-9 .&\x27/-]{2,80}?)\s+(?:bill|invoice|premium|contribution)\b',
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
      r'(?:\d{4}[./-]\d{1,2}[./-]\d{1,2}|\d{1,2}[./-]\d{1,2}[./-]\d{2,4}|\b\d{1,2}(?:st|nd|rd|th)?[A-Za-z]{3,9}\d{2,4}\b|\d{1,2}(?:st|nd|rd|th)?[\s./-]+[A-Za-z]{3,9}[,\s./-]+\d{2,4}|[A-Za-z]{3,9}[\s./-]+\d{1,2}(?:st|nd|rd|th)?[,]?[\s./-]+\d{2,4})';

  static DateTime? parseDate(String raw) {
    final text = raw
        .replaceAllMapped(_re(r'(\d)(?:st|nd|rd|th)\b'), (m) => m[1]!)
        // Compact bank dates such as 17Oct26 have no separators.
        .replaceAllMapped(
          RegExp(r'^(\d{1,2})([A-Za-z]{3,9})(\d{2,4})$'),
          (m) => '${m[1]} ${m[2]} ${m[3]}',
        )
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

  static DateTime? _transactionTimestamp(
    String body,
    DateTime? parsedDate,
    DateTime receivedAt,
  ) {
    if (parsedDate == null) return null;
    final match = _re(
      r'\b(\d{1,2}[-/.]\d{1,2}[-/.]\d{2,4})\s+(\d{1,2}):(\d{2})(?::(\d{2}))?\s+IST\b',
    ).firstMatch(body);
    if (match == null) return parsedDate;
    final printedDate = parseDate(match.group(1)!);
    if (printedDate == null ||
        printedDate.year != parsedDate.year ||
        printedDate.month != parsedDate.month ||
        printedDate.day != parsedDate.day) {
      return parsedDate;
    }
    final hour = int.parse(match.group(2)!);
    final minute = int.parse(match.group(3)!);
    final second = int.parse(match.group(4) ?? '0');
    if (hour > 23 || minute > 59 || second > 59) return parsedDate;
    final timestamp = DateTime.utc(
      printedDate.year,
      printedDate.month,
      printedDate.day,
      hour,
      minute,
      second,
    ).subtract(const Duration(minutes: 330)).toLocal();
    return timestamp.isAfter(receivedAt.add(const Duration(days: 1)))
        ? parsedDate
        : timestamp;
  }

  /// Returns the month named by an explicit "next premium ... due" phrase.
  /// Month-only dates deliberately stay month-only; callers must not invent a
  /// due day from them.
  static DateTime? nextPremiumDueMonth(String body) {
    final match = _re(
      r'\bnext\s+premium\b[\s\S]{0,30}?\b(?:falls?\s+)?due\s+(?:on|in)?\s*(0?[1-9]|1[0-2])\s*[./-]\s*(20\d{2})\b|\bnext\s+premium\b[\s\S]{0,30}?\b(?:falls?\s+)?due\s+(?:on|in)?\s*([A-Za-z]{3,9})\s+(20\d{2})\b',
    ).firstMatch(body);
    if (match == null) return null;
    final numericMonth = int.tryParse(match.group(1) ?? '');
    final month = numericMonth ?? _monthNumber(match.group(3)!);
    final year = int.tryParse(match.group(2) ?? match.group(4)!);
    return month == null || year == null ? null : DateTime(year, month);
  }

  static DateTime? _nextPremiumDueDate(String body) {
    final match = _re(
      r'\bnext\s+premium\b[\s\S]{0,30}?\b(?:falls?\s+)?due\s+(?:on|in)?\s*(' +
          dateToken +
          r')',
    ).firstMatch(body);
    return match == null ? null : parseDate(match.group(1)!);
  }

  static int? _monthNumber(String value) {
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
    final normalized = value.toLowerCase();
    final index = months.indexWhere((month) => normalized.startsWith(month));
    return index < 0 ? null : index + 1;
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
    Map<String, String>? userCategoryRules,
    Map<String, String>? sharedCategoryRules,
  }) {
    final parsed = parse(
      namespace: namespace,
      sender: sender,
      body: body,
      receivedAt: receivedAt,
      cards: cards,
      ownUserName: ownUserName,
      userCategoryRules: userCategoryRules,
      sharedCategoryRules: sharedCategoryRules,
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
      ).firstMatch(text.replaceAll(RegExp(r'[,*xX\s]'), ''));
      if (match == null) return null;
      final paise =
          int.parse(match[1]!) * 100 +
          int.parse((match[2] ?? '').padRight(2, '0'));
      final value = Money.fromPaise(paise);
      return value.paise > 0 ? value : null;
    }

    final completedSignal =
        _re(
          r'\b(?:spent|debit|debited|paid|purchase|purchased|charged|withdrawn|sent|transferred|credited|received|deposited|refunded|reversed|successful|successfully|completed)\b',
        ).hasMatch(body) ||
        isMerchantReceiptOrEbill(body);
    final nonFinalSignal = _re(
      r'\b(?:pending|processing|initiated|declined|failed|failure|cancelled|canceled|unsuccessful|(?:is|was)\s+unsuccessful)\b|\b(?:will|shall|would)\s+be\b|\b(?:not|never)\s+(?:be\s+)?(?:credited|received|deposited|refunded|reversed)\b',
    ).hasMatch(body);
    final amount = !localOnly && completedSignal && !nonFinalSignal
        ? money(
            _re(
                  r'(?:₹|rs\.?|inr)\s*[:.]?\s*[*xX]*\s*([\d,]+(?:\.\d{1,2})?)',
                ).firstMatch(body)?.group(1) ??
                _re(
                  r'\b(?:payment|bill|premium|contribution|subscription)\s+of\s*(?:₹|rs\.?|inr)\s*[:.]?\s*[*xX]*\s*([\d,]+(?:\.\d{1,2})?)',
                ).firstMatch(body)?.group(1) ??
                _re(
                  r'\b(?:contribution|subscription|mandate|installment|instalment)\s+(?:amount\b)?[\s\S]{0,80}?\b(?:is|of|for|:|-)?\s*(?:₹|rs\.?|inr)\s*[:.]?\s*[*xX]*\s*([\d,]+(?:\.\d{1,2})?)',
                ).firstMatch(body)?.group(1) ??
                _re(
                  r'\b(?:contribution|subscription)\s+amount\b[\s\S]{0,50}?\b(?:₹|rs\.?|inr)\s*:?[\s]*[*xX]*\s*([\d,]+(?:\.\d{1,2})?)',
                ).firstMatch(body)?.group(1) ??
                _currencylessBankMovementAmountText(body),
          )
        : null;
    final cardLast4 =
        parsed?.cardLast4 ??
        _re(
          r'\b(?:credit\s+|debit\s+)?card\b[\s\S]{0,45}?(?:ending(?:\s+with)?\s*|x{1,4}|\*{1,4}|\.{3,}|last\s*4\s*|no\.?\s*)\D{0,5}(\d{4})\b',
        ).firstMatch(body)?.group(1) ??
        _re(
          r'\b(?:credit\s+|debit\s+|bank\s+)?card\s+(?:no\.?\s*)?(\d{4})\b',
        ).firstMatch(body)?.group(1);
    final dateMatch = _re(dateToken).firstMatch(body);
    final parsedDate = dateMatch == null
        ? null
        : parseDate(dateMatch.group(0)!);
    final occurredAt =
        !localOnly &&
            parsedDate != null &&
            !parsedDate.isAfter(receivedAt.add(const Duration(days: 1)))
        ? _transactionTimestamp(body, parsedDate, receivedAt) ?? parsedDate
        : receivedAt;
    final asbaOrIpoBlock = _re(
      r'\b(?:asba\s+application|asba\s+(?:req(?:uest)?|bid|block|lien)|towards\s+asba|for\s+asba|asba\b[\s\S]{0,50}\b(?:accepted|blocked|lien|created)|(?:blocked|lien\s+marked)\b[\s\S]{0,50}\b(?:for|towards)?\s*(?:ipo|asba|rights\s+issue)|(?:ipo\s+(?:application|bid|mandate|block|lien)))\b',
    ).hasMatch(body);
    final receiptMerchant = isMerchantReceiptOrEbill(body)
        ? extractReceiptMerchant(body)
        : null;
    final fvgMatch = _re(
      r'\b(?:fvg|fav|favouring|favoring|infvo|in\s+fav(?:ou?r)?\s+of)\s*[:.\-]?\s*([A-Za-z0-9_][A-Za-z0-9 ._&@*\x27/-]{0,80}?)(?=\s+(?:avl|avail|available|bal(?:ance)?|ref(?:erence|\s*no)?|refno|txn|transaction|if\s+not|not\s+you|call|sms\s+block|on|dated)\b|\s*\(|[.,;]|$)',
    ).firstMatch(body);
    final towardsMatchDraft = _re(
      r'\b(?:towards?|in\s+fav(?:ou?r)?\s+of)\s+([A-Za-z_][A-Za-z0-9 ._&@*\x27/-]{1,80}?)(?=\s+(?:by\s+upi|from|on|via|upi|ref(?:erence)?|refno|txn|transaction|bal(?:ance)?|avl|available|if\s+not|call|sms\s+block|umrn|nach|mandate)\b|\s*\(|[.,;]|$)',
    ).firstMatch(body);
    var merchant = localOnly
        ? null
        : (receiptMerchant ??
              _upiAccountRecipient(body) ??
              fvgMatch?.group(1)?.trim() ??
              towardsMatchDraft?.group(1)?.trim());
    if (!localOnly &&
        (merchant == null || merchant.isEmpty) &&
        asbaOrIpoBlock) {
      final ipoCompanyMatch =
          _re(
            r'\b(?:asba|ipo)\b[\s\S]{0,60}?\bfor\s+([A-Za-z0-9 ._&@*\x27/-]{2,60}?)(?=\s+(?:of\s+(?:₹|rs\.?|inr)|application|has\s+been|is\s+accepted)|[.,;]|$)',
          ).firstMatch(body) ??
          _re(
            r'\bfor\s+([A-Za-z0-9 ._&@*\x27/-]{2,60}?)\s+of\s+(?:₹|rs\.?|inr)',
          ).firstMatch(body);
      merchant = ipoCompanyMatch?.group(1)?.trim();
    }
    if (!localOnly && (merchant == null || merchant.isEmpty)) {
      final merchantMatch = _re(
        r'\b(?:at|to|for|from|by|towards?)\s+(?!(?:₹|rs\.?|inr)(?:\b|\s|\d)|\d+[\s.,]|(?:the\s+)?(?:upcoming|scheduled)\s+mandate\b)([A-Za-z_][A-Za-z0-9 ._&@*\x27/-]{1,80}?)(?=\s+(?:by\s+upi|from|on|via|upi|ref(?:erence)?|refno|txn|transaction|bal(?:ance)?|avl|available|if\s+not|call|sms\s+block|umrn|nach|mandate)\b|\s*\(|[.,;]|$)',
      ).firstMatch(body);
      merchant = merchantMatch?.group(1)?.trim();
    }
    if (merchant != null &&
        (_re(
              r'^(?:mob(?:ile)?\s*(?:bk|banking)|net\s*(?:bk|banking)|internet\s*banking|upi|imps|neft|rtgs)$',
            ).hasMatch(merchant) ||
            _re(r'^(?:rs\.?|inr|re\.?|\d+)$').hasMatch(merchant))) {
      merchant = fvgMatch?.group(1)?.trim();
    }
    if (merchant != null) {
      final cleanedMandate = _cleanMandateBiller(merchant);
      if (cleanedMandate != null) {
        merchant = cleanedMandate;
      }
      final sanitized = IndianNarrationSanitizer.sanitize(merchant);
      if (sanitized.isNotEmpty) {
        merchant = sanitized;
      }
    }
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
        : asbaOrIpoBlock
        ? TxnInstrument.upiBank
        : TxnInstrument.other;
    final entryKind = asbaOrIpoBlock
        ? TxnEntryKind.investment
        : _brokerSettlement(body, sender)
        ? TxnEntryKind.income
        : _ownAccountTransfer(body) ||
              _accountToAccountTransfer(body) ||
              _walletLoad(body) ||
              _cardCredit(body) ||
              (merchant != null &&
                  ownUserName != null &&
                  _isOwnPersonName(merchant, ownUserName)) ||
              _ownNameInFromClause(body, ownUserName) ||
              _re(
                r'\b(?:refund(?:ed)?|reversal|reversed|cashback|reward|salary\s+advance|loan\s+(?:disbursement|repayment)|emi|equated\s+monthly\s+installment|instalment|cash\s+deposit|cash\s+withdrawal)\b',
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

  static LocalSmsObservation? _parseAutoPay({
    required String body,
    required String sender,
    required DateTime receivedAt,
    String? cardLast4,
    String? accountLast4,
    String? billerName,
    DateTime? due,
    Money? amountDue,
    Money? balance,
    Money? autopayLimit,
    String? cadenceHint,
  }) {
    final biller = billerName ?? extractBillerName(body);
    final billerLower = (biller ?? '').toLowerCase();
    final isExplicitMerchant =
        biller != null &&
        biller.isNotEmpty &&
        !billerLower.contains('credit card') &&
        !billerLower.contains('card bill');
    final isCreditCard =
        !isExplicitMerchant &&
        (billerLower.contains('credit card') ||
            billerLower.contains('card') ||
            _re(r'\bcredit\s+card\b').hasMatch(body));

    final effectiveCardLast4 =
        cardLast4 ??
        _re(
          r'\b(?:credit\s+|debit\s+)?card\b[\s\S]{0,45}?(?:ending(?:\s+(?:with|in))?\s*|x{1,4}|\*{1,4}|\.{3,}|last\s*4\s*|no\.?\s*)\D{0,8}(\d{4})\b',
        ).firstMatch(body)?.group(1) ??
        _re(
          r'\b(?:credit\s+|debit\s+|bank\s+)?card\s+(?:no\.?\s*)?(\d{4})\b',
        ).firstMatch(body)?.group(1);

    Money? effectiveAmountDue = amountDue;
    if (effectiveAmountDue == null) {
      final amtMatch =
          _re(
            r'\b(?:autopay\s+(?:alert|reminder)|auto[- ]?pay|standing\s+instruction|si\s+debit|payment|bill)\s*(?:of\s+|is\s+|:\s*|-)?\s*(?:₹|rs\.?|inr)\s*(?:dr\.?|cr\.?)?\s*[:.]?\s*[*xX]*\s*([\d,]+(?:\.\d{1,2})?)',
          ).firstMatch(body) ??
          _re(
            r'\b(?:standing\s+instruction|si\s+debit)\s+(?:of\s+)?(?:₹|rs\.?|inr)\s*[:.]?\s*([\d,]+(?:\.\d{1,2})?)',
          ).firstMatch(body) ??
          _re(
            r'(?:₹|rs\.?|inr)\s*[:.]?\s*([\d,]+(?:\.\d{1,2})?)',
          ).firstMatch(body);
      if (amtMatch != null) {
        final rawText = amtMatch.group(1)?.replaceAll(RegExp(r'[,*xX\s]'), '');
        if (rawText != null) {
          final m = RegExp(r'^(\d+)(?:\.(\d{1,2}))?$').firstMatch(rawText);
          if (m != null) {
            final paise =
                int.parse(m[1]!) * 100 +
                int.parse((m[2] ?? '').padRight(2, '0'));
            effectiveAmountDue = Money.fromPaise(paise);
          }
        }
      }
    }

    DateTime? effectiveDue = due;
    DateTime? startDate;
    DateTime? endDate;

    final fromToMatch = _re(
      r'\b(?:valid\s+)?from\s+(' + dateToken + r')\s+(?:to|till|until|-)\s+(' + dateToken + r')\b',
    ).firstMatch(body);
    if (fromToMatch != null) {
      startDate = parseDate(fromToMatch.group(1)!);
      endDate = parseDate(fromToMatch.group(2)!);
    }

    if (startDate == null) {
      final startMatch = _re(
        r'\b(?:start\s+date|starting\s+(?:from|on)?|created\s+on|registered\s+on)\s*[:\-]?\s*(' + dateToken + r')\b',
      ).firstMatch(body);
      if (startMatch != null) {
        startDate = parseDate(startMatch.group(1)!);
      }
    }

    if (endDate == null) {
      final endMatch = _re(
        r'\b(?:valid\s+(?:till|to|thru|through|upto|until)|end\s+date|expiry\s+date|expires\s+on)\s*[:\-]?\s*(' + dateToken + r')\b',
      ).firstMatch(body);
      if (endMatch != null) {
        endDate = parseDate(endMatch.group(1)!);
      }
    }

    if (effectiveDue == null) {
      for (final phrase in [
        r'\b(?:mandate\s+set\s+for|set\s+for)\s*[:\-]?\s*',
        r'\b(?:will|shall|to)?\s*(?:be\s+)?(?:auto[- ]?)?(?:deducted|debited)\b[\s\S]{0,70}?\bon\s*[:\-]?\s*',
        r'\b(?:auto[- ]?deducted|auto[- ]?debited|auto[- ]?debit)\s+on\s*[:\-]?\s*',
        r'\b(?:scheduled\s+for\s+)?(?:auto[- ]?debit|auto[- ]?pay|autopay|standing\s+instruction|si\s+debit)\b[\s\S]{0,80}?\b(?:on|by)\s*[:\-]?\s*',
        r'\bdue\s*(?:date\s*)?(?:is|on|by)?\s*[:\-]?\s*',
      ]) {
        final token = _re('$phrase($dateToken)').firstMatch(body)?.group(1);
        if (token != null) {
          effectiveDue = parseDate(token);
          if (effectiveDue != null) break;
        }
      }
      effectiveDue ??= startDate;
      // A received-at timestamp is evidence of when the notice arrived, not
      // a payment date. Keep the due date unknown until the SMS states one.
    }

    final bankName = _re(r'\baxis\b').hasMatch(body) || sender.toUpperCase().contains('AXIS')
        ? 'Axis Bank'
        : _re(r'\bhdfc\b').hasMatch(body) || sender.toUpperCase().contains('HDFC')
        ? 'HDFC Bank'
        : _re(r'\bicici\b').hasMatch(body) || sender.toUpperCase().contains('ICICI')
        ? 'ICICI Bank'
        : _re(r'\bsbi\b').hasMatch(body) || sender.toUpperCase().contains('SBI')
        ? 'SBI'
        : _re(r'\bkotak\b').hasMatch(body) || sender.toUpperCase().contains('KOTAK')
        ? 'Kotak Bank'
        : null;

    final isUpi = _re(r'\bupi\b').hasMatch(body) || sender.toUpperCase().contains('UPI');
    final detectedPaymentMethod = isUpi
        ? (bankName != null ? 'UPI AutoPay ($bankName)' : 'UPI AutoPay')
        : (effectiveCardLast4 != null
            ? 'Card ending $effectiveCardLast4'
            : (bankName != null ? 'AutoPay ($bankName)' : 'AutoPay Mandate'));

    // AutoPay alone does not establish a billing cadence. The central
    // projection may learn one from explicit plan evidence or posted history.
    final effectiveCadence = cadenceHint;

    if (isCreditCard) {
      return LocalSmsObservation(
        cardLast4: effectiveCardLast4,
        accountLast4: accountLast4,
        billerName: biller,
        cadenceHint: effectiveCadence,
        dueDate: effectiveDue,
        statementDate: receivedAt,
        availableBalance: balance,
        amountDue: effectiveAmountDue,
        autopayLimit: autopayLimit,
        startDate: startDate,
        endDate: endDate,
        paymentMethod: detectedPaymentMethod,
        eventType: LocalSmsEventType.bill,
        disposition: LocalSmsDisposition.localObservation,
        reasonCodes: const ['due_date_detected', 'autopay_notice'],
        isAutopay: true,
        confidence: 0.95,
      );
    } else {
      final isSetup =
          autopayLimit != null ||
          (_re(
                r'\b(?:activation|activated|enabled|registered|created|set\s+up|maximum|max\s+limit|e[- ]?mandate)\b',
              ).hasMatch(body) &&
              _re(
                r'\b(?:auto[- ]?pay|autopay|mandate|e[- ]?mandate|e[- ]?nach|enach|standing\s+instruction|si\s+debit)\b',
              ).hasMatch(body));

      Money? effectiveAutopayLimit = autopayLimit;
      if (effectiveAutopayLimit == null && isSetup && effectiveAmountDue != null && effectiveAmountDue.paise > 0) {
        effectiveAutopayLimit = effectiveAmountDue;
      }

      final isInvestment =
          CommitmentCategory.fromText('${biller ?? ''} $body') ==
          CommitmentCategory.investment;

      return LocalSmsObservation(
        cardLast4: effectiveCardLast4,
        accountLast4: accountLast4,
        billerName: biller,
        cadenceHint: effectiveCadence ?? (isInvestment ? 'monthly' : null),
        dueDate: effectiveDue,
        statementDate: startDate ?? receivedAt,
        availableBalance: balance,
        // A mandate limit is a ceiling, never the bill amount. A printed
        // ₹0 setup amount is an activation signal, not a due amount.
        amountDue: isSetup
            ? null
            : (effectiveAmountDue != null && effectiveAmountDue.paise > 0
                ? effectiveAmountDue
                : null),
        autopayLimit: effectiveAutopayLimit,
        startDate: startDate,
        endDate: endDate,
        paymentMethod: detectedPaymentMethod,
        eventType: isSetup
            ? LocalSmsEventType.autopay
            : (isInvestment
                ? LocalSmsEventType.investment
                : LocalSmsEventType.bill),
        disposition: isSetup
            ? LocalSmsDisposition.localIgnore
            : LocalSmsDisposition.localCommitment,
        reasonCodes: [
          if (isSetup) 'autopay_setup' else 'commitment_detected',
          'mandate_notice',
          if (!isSetup) 'autopay_notice',
          if (isInvestment) 'investment_sip_mandate',
        ],
        isAutopay: true,
        confidence: 0.95,
      );
    }
  }

  /// A decline notice states its own reason: "returned due to insufficient
  /// funds", "could not be processed due to insufficient balance", "was
  /// declined". Movement verbs in the same sentence ("Rs 81,467 spent at the
  /// mall was declined") restate the attempted amount rather than a debit, so
  /// this verdict outranks them and no branch may mint a spend from the body.
  /// The compensating form ("payment failed, but your account was debited")
  /// carries no reason clause and stays reviewable.
  static bool _declinedThisPayment(String body) =>
      _re(
        r'\b(?:declined|rejected|failed|failure|unsuccessful|bounced|returned|not\s+(?:be\s+)?processed)\b'
        r'[\s\S]{0,48}\b(?:due\s+to|because\s+of|owing\s+to|on\s+account\s+of)\b'
        r'[\s\S]{0,32}\b(?:insufficient|inadequate|low\s+balance|not\s+enough)\b',
      ).hasMatch(body) ||
      _re(
        r'\b(?:insufficient|inadequate)\s+(?:funds?|balance|money|limit)\b'
        r'[\s\S]{0,48}\b(?:declined|rejected|failed|failure|unsuccessful|bounced|returned|not\s+(?:be\s+)?processed)\b',
      ).hasMatch(body) ||
      _re(
        r'\b(?:was|were|is|has\s+been|have\s+been|got)\s+(?:declined|rejected|marked\s+(?:failed|unsuccessful)|not\s+processed)\b',
      ).hasMatch(body);

  static LocalSmsObservation? parse({
    required String namespace,
    required String sender,
    required String body,
    required DateTime receivedAt,
    List<UserCard> cards = const [],
    String? ownUserName,
    SmsRuleBundle? downloadedRules,
    // Closed-loop learning: a user correction recorded by SmsLearningFeedback
    // runs BEFORE the built-in grammar's category inference (never before the
    // safety gates). Normalised pattern -> category slug. Null keeps every
    // existing behaviour byte-for-byte.
    Map<String, String>? userCategoryRules,
    Map<String, String>? sharedCategoryRules,
  }) {
    if (body.length > 20000 || sensitive(body)) return null;

    if (isInvestmentFolioAllotment(body) && !_declinedThisPayment(body)) {
      final amount = extractReceiptAmount(body);
      final schemeMatch = _re(
        r"\b(?:scheme|fund(?:\s+name)?)\s*[:\-]\s*([A-Za-z0-9_][-A-Za-z0-9 .&'/()]{2,60})",
      ).firstMatch(body);
      final underMatch = _re(
        r"\bunder\s+(?!folio\b)([A-Za-z0-9][-A-Za-z0-9 .&'/()]{2,60}?)(?=(?:\s+(?:for\s+(?:rs\.?|inr|₹)|processed|successful|completed|allotted|folio)|[.,;]|$))",
      ).firstMatch(body);
      final inFundMatch = _re(
        r"\bin\s+(?!folio\b)([A-Za-z0-9][-A-Za-z0-9 .&'/()]{2,60}?)(?=(?:\s+(?:processed|successful|completed|allotted|for\b|at\s+nav|with\s+nav|nav|on\s+\d|folio)|[.,;]|$))",
      ).firstMatch(body);
      final towardsMatch = _re(
        r"\btowards?\s+([A-Za-z0-9][-A-Za-z0-9 .&'/()]{2,60}?)(?=(?:\s+(?:processed|successful|completed|allotted|folio)|[.,;]|$))",
      ).firstMatch(body);
      var merchant =
          underMatch?.group(1)?.trim() ??
          schemeMatch?.group(1)?.trim() ??
          inFundMatch?.group(1)?.trim() ??
          towardsMatch?.group(1)?.trim();
      if (merchant != null && merchant.isNotEmpty) {
        final sanitized = IndianNarrationSanitizer.sanitize(merchant);
        if (sanitized.isNotEmpty) {
          merchant = sanitized;
        }
      }
      final folioMatch = _re(
        r'\bfolio(?:\s*no\.?|\s*number)?\s*[:#-]?\s*([A-Za-z0-9/-]+)\b',
      ).firstMatch(body)?.group(1);
      final folioLast4 = folioMatch != null && folioMatch.length >= 4
          ? folioMatch.substring(folioMatch.length - 4)
          : folioMatch;

      final key = smsSourceKey(namespace, sender, body);
      final entry = amount != null
          ? TransactionEntry(
              id: 'local-sms:$key',
              sourceKey: key,
              amount: amount,
              occurredAt: receivedAt,
              merchantName: merchant ?? 'Investment',
              categoryId: 'investments',
              categoryName: 'Investments',
              instrument: TxnInstrument.upiBank,
              instrumentKnown: true,
              entryKind: TxnEntryKind.investment,
              source: 'sms',
              status: 'active',
              rewardState: 'estimated',
              accountLast4: folioLast4,
            )
          : null;

      return LocalSmsObservation(
        eventType: LocalSmsEventType.investment,
        disposition: entry != null
            ? LocalSmsDisposition.sync
            : LocalSmsDisposition.localObservation,
        transaction: entry,
        amount: amount,
        amountDue: amount,
        billerName: merchant,
        accountLast4: folioLast4,
        reasonCodes: const ['mf_folio_unit_allotment'],
        confidence: 1.0,
      );
    }

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

    // Axio / Amazon Pay Later credit drawdown → treat as a spend transaction.
    // These messages say "availing Pay Later credit of Rs X" which contains no
    // standard movement verb, so the generic parser misses them and lands them
    // in the "Needs Review" queue. The repayment acknowledgement ("received
    // your timely repayment towards your Pay Later …") is already caught above
    // by isNonTransactionNoise → repaymentCourtesyOrLoanUpsell, so it never
    // reaches here. Bank-side AutoPay debits ("Rs X debited … towards Axio Pay
    // Later bill") come from a BANK sender and are routed through the bank
    // debit path by isBankAccountMessage; the senderText guard below therefore
    // never fires for those, preventing double-counting.
    final _payLaterDrawdownAmountRe = RegExp(
      r'\bavail(?:ing|ed)\s+(?:(?:amazon\s+)?pay\s+later\s+)?credit\s+of\s+(?:Rs\.?\s*)(\d+(?:\.\d+)?)',
      caseSensitive: false,
    );
    final senderLower = sender.toLowerCase();
    final isPayLaterDrawdownSpend =
        (senderLower.contains('axio') ||
            RegExp(
              r'\b(?:amazon\s+)?pay\s+later\b',
              caseSensitive: false,
            ).hasMatch(body)) &&
        _payLaterDrawdownAmountRe.hasMatch(body);
    if (isPayLaterDrawdownSpend && !_declinedThisPayment(body)) {
      final rawAmount = _payLaterDrawdownAmountRe
          .firstMatch(body)
          ?.group(1)
          ?.replaceAll(',', '');
      final amountVal = rawAmount != null ? double.tryParse(rawAmount) : null;
      if (amountVal != null && amountVal > 0) {
        final key = smsSourceKey(namespace, sender, body);
        return LocalSmsObservation(
          eventType: LocalSmsEventType.transaction,
          disposition: LocalSmsDisposition.sync,
          confidence: 1.0,
          reasonCodes: const ['axio_pay_later_drawdown'],
          transaction: TransactionEntry(
            id: 'local-sms:$key',
            sourceKey: key,
            amount: Money.fromRupees(amountVal),
            occurredAt: receivedAt,
            merchantName: 'Amazon Pay Later',
            instrument: TxnInstrument.other,
            instrumentKnown: true,
            entryKind: TxnEntryKind.spend,
            accountLast4: 'Amazon Pay Later',
            source: 'sms',
            status: 'active',
            rewardState: 'estimated',
          ),
        );
      }
    }

    // Safety gate: a downloaded posted-movement rule must never convert a
    // future/scheduled obligation or a failed notice into a completed spend.
    // The built-in grammar below still classifies those messages.
    final downloadedMovementBlocked =
        _hasFutureDebitWording(body) ||
        _declinedThisPayment(body) ||
        _re(
          r'\b(?:declined|failed|failure|cancelled|canceled|unsuccessful)\b',
        ).hasMatch(body);

    if (downloadedRules != null &&
        downloadedRules.rules.isNotEmpty &&
        !isMerchantReceiptOrEbill(body)) {
      for (final rule in downloadedRules.rules) {
        if (!rule.matchesSender(sender)) continue;
        if (downloadedMovementBlocked &&
            rule.family == SmsRuleFamily.postedMovement) {
          continue;
        }
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
          userCategoryRules: userCategoryRules,
          sharedCategoryRules: sharedCategoryRules,
        );
        if (obs != null) return obs;
      }
    }
    final cardLast4 =
        _re(
          r'\b(?:credit\s+|debit\s+)?card\b[\s\S]{0,45}?(?:ending(?:\s+(?:with|in))?\s*|x{1,4}|\*{1,4}|\.{3,}|last\s*4\s*|no\.?\s*)\D{0,8}(\d{4})\b',
        ).firstMatch(body)?.group(1) ??
        _re(
          r'\b(?:credit\s+|debit\s+|bank\s+)?card\s+(?:no\.?\s*)?(\d{4})\b',
        ).firstMatch(body)?.group(1);
    // Credit-card account references identify a card ledger, not a bank account.
    final destinationAccountLast4 = _re(
      r'\bto\s+your\b[\s\S]{0,70}\b(?:a\/?c\.?|account)\s*(?:no\.?|number)?\s*[*xX.\s-]*(\d{4})\b',
    ).firstMatch(body)?.group(1);
    var accountLast4 = _re(r'\bcredit\s+card\b').hasMatch(body)
        ? null
        : _ownAccountTransfer(body) &&
              _re(r'\b(?:credited|received|deposited)\b').hasMatch(body) &&
              destinationAccountLast4 != null
        ? destinationAccountLast4
        : _re(
            r'\b(?:a\/?c\.?|account)\s*(?:no\.?|number)?\s*(?:(?:ending(?:\s+with)?|last\s*4)\s*)?[*xX.\s-]*(\d{4})\b',
          ).firstMatch(body)?.group(1);
    final isInsuranceReminder = _re(
      r'\b(?:lic|insurance|policy|premium)\b',
    ).hasMatch('$sender $body');
    final policyLast4 = isInsuranceReminder
        ? _re(
            r'\b(?:policy|pol\.?)(?:\s*(?:no\.?|number|#))?\s*[:#-]?\s*(?:x{2,}|\*{2,})?(\d{4,})\b',
          ).firstMatch(body)?.group(1)
        : null;
    DateTime? due;
    for (final phrase in [
      // Some issuers list "Total Due: INR ..." before the actual
      // "Due date: 23-Sep-2026" field; keep this explicit label ahead of the
      // broader `due` matcher so the earlier amount cannot shadow the date.
      r'\bdue\s+date\s*(?:is|on|by)?\s*[:\-]?\s*',
      r'\bdue\s*(?:date\s*)?(?:is|on|by)?\s*[:\-]?\s*',
      r'\bpay\s+by\s*[:\-]?\s*',
      r'\b(?:payment|bill|amount)\s+due\s+date\b[\s\S]{0,120}?\b(?:is|on|by)\s*[:\-]?\s*',
      r'\b(?:renew(?:s|al|ing)?|expires?)\s*(?:date\s*)?(?:is|on|by)?\s*[:\-]?\s*',
      r'\b(?:will|shall|to)?\s*(?:be\s+)?(?:auto[- ]?)?(?:deducted|debited)\b[\s\S]{0,70}?\bon\s*[:\-]?\s*',
      r'\b(?:auto[- ]?deducted|auto[- ]?debited|auto[- ]?debit)\s+on\s*[:\-]?\s*',
      r'\b(?:attempted|scheduled)\s+on\s*[:\-]?\s*',
      r'\b(?:maintain|keep)\s+(?:sufficient|adequate)\s+(?:funds|balance|bal)\b[\s\S]{0,100}?\b(?:on\s+or\s+before|on|by|before)\s*[:\-]?\s*',
      r'\b(?:on\s+or\s+before|before)\s*[:\-]?\s*',
      r'\bdue\s+on\s*[:\-]?\s*',
      r'\b(?:scheduled\s+for\s+)?(?:auto[- ]?debit|auto[- ]?pay|autopay|standing\s+instruction|si\s+debit|mandate)\b[\s\S]{0,80}?\b(?:on|by)\s*[:\-]?\s*',
      r'\b(?:auto[- ]?debit|auto[- ]?pay|autopay|standing\s+instruction|si\s+debit|mandate)\b[\s\S]{0,80}?\bwill\s+be\s+(?:on|by|attempted\s+on|processed\s+on|debited\s+on)\s*[:\-]?\s*',
      r'\b(?:auto[- ]?debit|auto[- ]?pay|autopay)\b[\s\S]{0,50}?\bwill\s+be\s+attempted\s+on\s*[:\-]?\s*',
      r'\bwill\s+be\s+attempted\s+on\s*[:\-]?\s*',
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
    // Axio Pay Later bills use an ordinal relative date instead of a full
    // calendar date: "will be debited on 5th of this month". Preserve the
    // SMS's original month/year so historical imports do not drift into the
    // current billing cycle.
    if (due == null) {
      final thisMonthDay = _re(
        r'\b(?:will|shall|to)?\s*(?:be\s+)?(?:auto[- ]?)?(?:deducted|debited)\b[\s\S]{0,70}?\bon\s+(\d{1,2})(?:st|nd|rd|th)?\s+of\s+this\s+month\b',
      ).firstMatch(body);
      final day = int.tryParse(thisMonthDay?.group(1) ?? '');
      if (day != null && day >= 1 && day <= 31) {
        final candidate = DateTime(receivedAt.year, receivedAt.month, day);
        if (candidate.month == receivedAt.month) due = candidate;
      }
    }
    if (due == null && isActionableInsuranceRenewal(body)) {
      final relative = _re(
        r'\b(?:expires?|expiry|premium\s+due|renewal\s+due|due\s+for\s+renewal)\s*(?:is\s+|on\s+)?(today|tomorrow|in\s+(\d{1,2})\s+days?)\b',
      ).firstMatch(body);
      final days = switch (relative?.group(1)?.toLowerCase()) {
        'today' => 0,
        'tomorrow' => 1,
        _ => int.tryParse(relative?.group(2) ?? ''),
      };
      if (days != null) {
        due = DateTime(
          receivedAt.year,
          receivedAt.month,
          receivedAt.day + days,
        );
      }
    }
    final nextPremiumDue = _nextPremiumDueDate(body);
    final nextPremiumMonth = nextPremiumDueMonth(body);
    if (nextPremiumDue != null) {
      due = nextPremiumDue;
    } else if (nextPremiumMonth != null) {
      // A month/year reminder has no reliable day. Do not use the earlier
      // installment's date or silently turn the first of the month into a due day.
      due = null;
    }
    if (due == null && nextPremiumMonth == null) {
      final monthMatch = _re(
        r'\b(?:for\s+the\s+month\s+(?:of\s+)?|month\s+of\s+|month\s+)([A-Za-z]{3,9})\b',
      ).firstMatch(body);
      if (monthMatch != null) {
        final monName = monthMatch.group(1)!.toLowerCase();
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
        final monIdx = months.indexWhere((m) => monName.startsWith(m));
        if (monIdx >= 0) {
          final year = receivedAt.year;
          final targetMon = monIdx + 1;
          due = DateTime(
            year,
            targetMon,
            receivedAt.month == targetMon ? receivedAt.day : 1,
          );
        }
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
    final balanceText =
        _re(
          r'\b(?:(?:total|tot)\s+)?(?:avail(?:able)?|avl|current|closing|clr|new|remaining)?\.?\s*(?:bal(?:ance)?|a\/?c\s*bal(?:ance)?)\.?\s*(?:is|:|-)?\s*(?:(?:rs\.?|inr|₹)\s*){1,2}:?\s*[*xX]*\s*([\d,]+(?:\.\d{1,2})?)',
        ).firstMatch(body)?.group(1) ??
        _re(
          r'\b(?:is|of)\s*(?:(?:rs\.?|inr|₹)\s*){1,2}:?\s*([\d,]+(?:\.\d{1,2})?)\s*(?:(?:dr\.?|cr\.?)?\s*(?:total\s*)?avail(?:able)?\.?\s*bal(?:ance)?\.?|\s*as\s+avail(?:able)?\.?\s*bal(?:ance)?\.?)',
        ).firstMatch(body)?.group(1) ??
        _re(
          r'\b(?:bal|balance)\s*(?:is|:|-)?\s*(?:₹|rs\.?|inr)?\s*:?\s*[*xX]*\s*([\d,]+(?:\.\d{1,2})?)',
        ).firstMatch(body)?.group(1);
    Money? money(String? text) {
      if (text == null) return null;
      final match = RegExp(
        r'^(\d+)(?:\.(\d{1,2}))?$',
      ).firstMatch(text.replaceAll(RegExp(r'[,*xX\s]'), ''));
      if (match == null) return null;
      final paise =
          int.parse(match[1]!) * 100 +
          int.parse((match[2] ?? '').padRight(2, '0'));
      return Money.fromPaise(paise);
    }

    final balance = money(balanceText);
    final isPayLaterBill =
        _re(r'\bpay\s+later\s+bill\b').hasMatch(body) &&
        _re(
          r'\b(?:will|shall|to)\s+be\s+(?:auto[- ]?)?(?:debited|deducted)\b',
        ).hasMatch(body);
    final billerName = isPayLaterBill
        ? (sender.toLowerCase().contains('axio')
              ? 'Axio Pay Later'
              : 'Pay Later')
        : extractBillerName(body) ??
              (isInsuranceReminder ? 'Insurance policy' : null);
    final cadenceHint =
        _re(r'\b(?:as\s*presented|aspresented|as\s+and\s+when\s+presented|on\s+demand)\b').hasMatch(body)
        ? 'asPresented'
        : _re(r'\b(?:monthly|month)\b').hasMatch(body) ||
            _re(r'\b(?:for\s+the\s+month|month\s+of)\b').hasMatch(body)
        ? 'monthly'
        : _re(r'\b(?:weekly|week)\b').hasMatch(body)
        ? 'weekly'
        : _re(r'\b(?:bi[- ]?monthly)\b').hasMatch(body)
        ? 'biMonthly'
        : _re(r'\bquarterly\b').hasMatch(body)
        ? 'quarterly'
        : _re(r'\b(?:half[- ]yearly|half[- ]annual)\b').hasMatch(body)
        ? 'halfYearly'
        : _re(r'\b(?:annual|yearly)\b').hasMatch(body)
        ? 'annual'
        : null;
    final amountDue = money(
      _re(
            r'\b(?:total|full|statement|amount|premium)\s*(?:amount\s*)?due\b\s*(?:is|:|-)?\s*(?:₹|rs\.?|inr)?\s*(?:dr\.?|cr\.?)?\s*:?[\s]*[*xX]*\s*([\d,]+(?:\.\d{1,2})?)',
          ).firstMatch(body)?.group(1) ??
          _re(
            r'\b(?:bill|invoice|premium)\b[\s\S]{0,35}?\b(?:is|of|amount(?:\s+is)?)\s*(?:₹|rs\.?|inr)?\s*(?:dr\.?|cr\.?)?\s*[:.]?\s*[*xX]*\s*([\d,]+(?:\.\d{1,2})?)',
          ).firstMatch(body)?.group(1) ??
          _re(
            r'\b(?:autopay\s+(?:alert|reminder)|auto[- ]?pay|standing\s+instruction|si\s+debit)\s*(?:of\s+|is\s+|:\s*|-)?\s*(?:₹|rs\.?|inr)?\s*(?:dr\.?|cr\.?)?\s*:?[\s]*[*xX]*\s*([\d,]+(?:\.\d{1,2})?)',
          ).firstMatch(body)?.group(1) ??
          _re(
            r'\btotal\s+(?:amt|amount)\s*[:\-]?\s*(?:₹|rs\.?|inr)?\s*(?:dr\.?|cr\.?)?\s*:?[\s]*[*xX]*\s*([\d,]+(?:\.\d{1,2})?)',
          ).firstMatch(body)?.group(1) ??
          _re(
            r'\b(?:payment|bill|premium|contribution|subscription)\s+of\s*(?:₹|rs\.?|inr)\s*[:.]?\s*[*xX]*\s*([\d,]+(?:\.\d{1,2})?)',
          ).firstMatch(body)?.group(1) ??
          _re(
            r'\b(?:contribution|subscription|mandate|installment|instalment)\s+(?:amount\b)?[\s\S]{0,80}?\b(?:is|of|for|:|-)?\s*(?:₹|rs\.?|inr)\s*[:.]?\s*[*xX]*\s*([\d,]+(?:\.\d{1,2})?)',
          ).firstMatch(body)?.group(1) ??
          _re(
            r'\b(?:contribution|subscription)\s+amount\b[\s\S]{0,50}?\b(?:₹|rs\.?|inr)\s*:?[\s]*[*xX]*\s*([\d,]+(?:\.\d{1,2})?)',
          ).firstMatch(body)?.group(1),
    );
    final billAmount = money(
      _re(
            r'\b(?:bill|invoice|premium)\b[\s\S]{0,35}?\b(?:is|of|amount(?:\s+is)?)\s*(?:₹|rs\.?|inr)\s*(?:dr\.?|cr\.?)?\s*[:.]?\s*[*xX]*\s*([\d,]+(?:\.\d{1,2})?)',
          ).firstMatch(body)?.group(1) ??
          _re(
            r'\b(?:autopay\s+(?:alert|reminder)|auto[- ]?pay|standing\s+instruction|si\s+debit)\s*(?:of\s+|is\s+|:\s*|-)?\s*(?:₹|rs\.?|inr)?\s*(?:dr\.?|cr\.?)?\s*:?[\s]*[*xX]*\s*([\d,]+(?:\.\d{1,2})?)',
          ).firstMatch(body)?.group(1) ??
          _re(
            r'\b(?:payment|bill|premium|contribution|subscription)\s+of\s*(?:₹|rs\.?|inr)\s*[:.]?\s*[*xX]*\s*([\d,]+(?:\.\d{1,2})?)',
          ).firstMatch(body)?.group(1) ??
          _re(
            r'\b(?:contribution|subscription|mandate|installment|instalment)\s+(?:amount\b)?[\s\S]{0,80}?\b(?:is|of|for|:|-)?\s*(?:₹|rs\.?|inr)\s*[:.]?\s*[*xX]*\s*([\d,]+(?:\.\d{1,2})?)',
          ).firstMatch(body)?.group(1) ??
          _re(
            r'\b(?:contribution|subscription)\s+amount\b[\s\S]{0,50}?\b(?:₹|rs\.?|inr)\s*:?[\s]*[*xX]*\s*([\d,]+(?:\.\d{1,2})?)',
          ).firstMatch(body)?.group(1),
    );
    final minimumDue = money(
      _re(
        r'\b(?:minimum|min)\s*(?:amt|amount\s*)?due\b\s*(?:is|:|-)?\s*(?:₹|rs\.?|inr)?\s*(?:dr\.?|cr\.?)?\s*:?[\s]*[*xX]*\s*([\d,]+(?:\.\d{1,2})?)',
      ).firstMatch(body)?.group(1),
    );
    final autopayLimit = money(
      _re(
        r'\b(?:max(?:imum)?|mandate|si|standing\s+instruction)\s*(?:limit|amount)?\s*(?:[:\-]|\s+(?:of|is|for))?\s*(?:₹|rs\.?|inr)?\s*:?[\s]*[*xX]*\s*([\d,]+(?:\.\d{1,2})?)',
      ).firstMatch(body)?.group(1) ??
      _re(
        r'\b(?:max(?:imum)?|mandate|si|standing\s+instruction|autopay)\b[\s\S]{0,140}?\b(?:for|of|limit|amount|upto|up\s+to|is)\s*[:\-]?\s*(?:₹|rs\.?|inr)\s*[:.]?\s*[*xX]*\s*([\d,]+(?:\.\d{1,2})?)',
      ).firstMatch(body)?.group(1) ??
      _re(
        r'\b(?:upto|up\s+to)\s*(?:₹|rs\.?|inr)\s*[:.]?\s*[*xX]*\s*([\d,]+(?:\.\d{1,2})?)',
      ).firstMatch(body)?.group(1) ??
      _re(
        r'\bfor\s+(?:₹|rs\.?|inr)\s*[:.]?\s*[*xX]*\s*([\d,]+(?:\.\d{1,2})?)\s+(?:Axis|HDFC|ICICI|SBI|Kotak|Bank|VPA|UMRN)',
      ).firstMatch(body)?.group(1),
    );
    final hasAutopay = _re(
      r'\b(?:auto[- ]?pay|autopay|mandate|e[- ]?mandate|e[- ]?nach|enach|standing\s+instruction|si\s+debit)\b',
    ).hasMatch(body);
    final nonZeroDebit = _re(
      r'\b(?:spent|debited|debit|paid|purchase|purchased|charged|withdrawn|sent|transferred)\b|\b(?:txn|transaction)\s+(?:of\s+)?(?:₹|rs\.?|inr)\s*[*xX]*[1-9]',
    ).hasMatch(body);
    final autopaySetup =
        hasAutopay &&
        _re(
          r'\b(?:activation|activated|enabled|registered|created|set\s+up|maximum|max\s+limit|e[- ]?mandate)\b',
        ).hasMatch(body) &&
        !nonZeroDebit;
    final promotion = _re(
      r'\b(?:offer|promotion|promotional|campaign|eligible|cashback|reward|voucher)\b[\s\S]{0,80}\b(?:spend|card)\b|\bspend\s*(?:₹|rs\.?|inr)[\s\S]{0,50}\b(?:get|earn|cashback|reward|voucher)\b|\bbuy\s+\d+\s+get\s+\d+\b|\bget\s+(?:free|additional)\b|\brecharge\b[\s\S]{0,80}\b(?:free|offer|bonus|additional)\b',
    ).hasMatch(body);
    final failed = _re(
      r'\b(?:declined|failed|failure|cancelled|canceled|pending|processing|unsuccessful|(?:is|was)\s+unsuccessful)\b',
    ).hasMatch(body);
    final balanceOnly = _re(
      r'\b(?:available|avail|avl|current|closing|clr|new|talktime|talk\s*time|prepaid|fastag)\s*(?:balance|bal)\b|\bcredit\s+limit\b',
    ).hasMatch(body);
    final hasBillMarker =
        due != null ||
        _re(
          r'\b(?:payment|amount|minimum|total|premium)\s+due\b|\b(?:statement|bill|invoice)\b[\s\S]{0,80}\b(?:generated|ready|available|due)\b|\b(?:subscription|membership)\b[\s\S]{0,50}\b(?:renew|renewal|due|expires?)\b|\bautopay\s+(?:alert|reminder)\b|\b(?:auto[- ]?debited|auto[- ]?deducted)\b[\s\S]{0,60}?\b(?:dues?|bill)\b',
        ).hasMatch(body);
    // "No money was debited" makes the debit word a negation, not evidence
    // of movement — failure notices from banks print exactly this sentence.
    final movementBody = body.replaceAll(
      RegExp(
        r'\b(?:ignore|disregard|plz\s+ignore)\s+if\s+(?:already\s+)?paid\b',
        caseSensitive: false,
      ),
      '',
    );
    final asbaOrIpoBlock = _re(
      r'\b(?:asba\s+application|asba\s+(?:req(?:uest)?|bid|block|lien)|towards\s+asba|for\s+asba|asba\b[\s\S]{0,50}\b(?:accepted|blocked|lien|created)|(?:blocked|lien\s+marked)\b[\s\S]{0,50}\b(?:for|towards)?\s*(?:ipo|asba|rights\s+issue)|(?:ipo\s+(?:application|bid|mandate|block|lien)))\b',
    ).hasMatch(body);
    final hasCompletedMovement =
        !_re(
          r'\b(?:no\s+money\s+(?:was|is)?\s*(?:debited|deducted)|not\s+(?:debited|deducted|charged))\b',
        ).hasMatch(body) &&
        (_re(
              r'\b(?:spent|debited|debit|paid|charged|withdrawn|sent|transferred|credited|received|deposited|refunded|reversed|deducted|deduct|availing|availed)\b',
            ).hasMatch(movementBody) ||
            (!failed &&
                _re(r'\b(?:purchase|purchased)\b').hasMatch(movementBody)) ||
            asbaOrIpoBlock ||
            _re(
              r'\b(?:recharge|payment|transaction|purchase|debit|spent|paid|charged|withdrawn|sent|transferred|deducted)\b[\s\S]{0,100}\b(?:successful|successfully|completed)\b',
            ).hasMatch(movementBody) ||
            // "Txn of Rs 81,467 was declined due to insufficient balance"
            // prints its amount without any money moving, so this bare shape
            // is only movement evidence when the notice is not a failure.
            (!failed &&
                _re(
                  r'\b(?:txn|transaction)\s+(?:of\s+)?(?:₹|rs\.?|inr)\s*[*xX]*[\d,.]+\b',
                ).hasMatch(movementBody)));
    final isDueReminder =
        _re(
          r'\b(?:is\s+due\s+on|payment\s+is\s+due|bill\s+is\s+due|due\s+date\s+is|payment\s+due\s+date)\b|\b(?:payment|bill|amount)\s+(?:of\s+)?(?:₹|rs\.?|inr)?\s*[*xX]*[\d,.]+\b[\s\S]{0,80}\bis\s+due\b|\b(?:minimum|total)\s+amount\s+due\b',
        ).hasMatch(body) &&
        !_re(
          r'\b(?:debited|withdrawn|charged|deducted)\b',
        ).hasMatch(movementBody);
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
      isAutopay: isAutoPayNotice(body),
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
    final futureDebit = _hasFutureDebitWording(body);
    // A service renewal notice can carry explicit plan terms without a bank
    // debit. Preserve it as a service observation for typed facts rather than
    // leaving it in generic review or treating its price as posted spending.
    final serviceRenewal = _re(
      r'\b(?:subscription|membership)\s+(?:for|to|with)\s+[A-Za-z][A-Za-z0-9 .&-]{2,60}?\s+(?:renewed|renewal|renews|expires|monthly|yearly|annual)\b',
    ).hasMatch(body);
    if (serviceRenewal) {
      final service = _re(
        r'\b(?:subscription|membership)\s+(?:for|to|with)\s+([A-Za-z][A-Za-z0-9 .&-]{2,60}?)(?=\s+(?:renewed|renewal|renews|expires|monthly|yearly|annual)\b|[.,;]|$)',
      ).firstMatch(body)?.group(1)?.trim();
      if (service != null && service.length >= 3) {
        final nextDateToken = _re(
          r'\b(?:next\s+(?:renewal|payment)|renews?\s+on)\s*(?:is|on|:)?\s*(' +
              dateToken +
              r')',
        ).firstMatch(body)?.group(1);
        final statedAmountToken =
            _re(
              r'\b(?:monthly|quarterly|yearly|annual)\s+(?:plan\s+)?(?:payment|price|amount|charge|fee)?\s*(?:of|is|:)?\s*(?:rs\.?|inr|₹)\s*([\d,]+(?:\.\d{1,2})?)',
            ).firstMatch(body)?.group(1) ??
            _re(
              r'(?:rs\.?|inr|₹)\s*([\d,]+(?:\.\d{1,2})?)\s*(?:paid|debited|charged|renewed)',
            ).firstMatch(body)?.group(1);
        final statedAmount = statedAmountToken == null
            ? null
            : Money.fromPaise(
                (double.parse(statedAmountToken.replaceAll(',', '')) * 100)
                    .round(),
              );
        final finalAmt = statedAmount ?? amountDue ?? billAmount;
        return LocalSmsObservation(
          billerName: service,
          cadenceHint: cadenceHint,
          dueDate: nextDateToken == null ? due : parseDate(nextDateToken),
          amountDue: finalAmt,
          autopayLimit: null,
          amount: finalAmt,
          eventType: LocalSmsEventType.autopay,
          disposition: LocalSmsDisposition.localIgnore,
          reasonCodes: const ['explicit_subscription_service'],
          confidence: 0.95,
          isAutopay: true,
        );
      }
    }
    final isReceipt = isMerchantReceiptOrEbill(body);
    final receiptMerchant = isReceipt ? extractReceiptMerchant(body) : null;
    final receiptAmount = isReceipt ? extractReceiptAmount(body) : null;
    // A merchant receipt is enrichment, not an independent posted bank spend.
    // With no named instrument the bank alert (if any) remains the spend
    // source, so this row stays in review instead of double-counting.
    if (isReceipt &&
        !isPayLaterBill &&
        !_receiptHasSettlementInstrument(body)) {
      return LocalSmsObservation(
        eventType: LocalSmsEventType.unknown,
        disposition: LocalSmsDisposition.review,
        amount: receiptAmount,
        billerName: receiptMerchant,
        reasonCodes: [
          'merchant_ebill_receipt',
          if (receiptAmount != null) 'receipt_amount_extracted',
          if (receiptMerchant != null) 'receipt_merchant_extracted',
        ],
      );
    }
    // Keep month-only dates out of AutoPay's fallback date/commitment path too.
    if (nextPremiumMonth != null &&
        nextPremiumDue == null &&
        !hasCompletedMovement) {
      return observation(
        null,
        LocalSmsEventType.bill,
        LocalSmsDisposition.review,
        const ['next_premium_due_month_only'],
      );
    }
    if (!failed &&
        isAutoPayNotice(body) &&
        (!hasCompletedMovement || futureDebit || autopaySetup)) {
      final obs = _parseAutoPay(
        body: body,
        sender: sender,
        receivedAt: receivedAt,
        cardLast4: cardLast4,
        accountLast4: isInsuranceReminder
            ? policyLast4?.substring(policyLast4.length - 4)
            : accountLast4,
        billerName: billerName,
        due: due,
        amountDue: amountDue ?? billAmount,
        balance: balance,
        autopayLimit: autopayLimit,
        cadenceHint: cadenceHint,
      );
      if (obs != null) return obs;
    }
    if (!failed &&
        hasBillMarker &&
        !autopaySetup &&
        (!hasCompletedMovement || futureDebit || isDueReminder)) {
      final isInsuranceOrUtility =
          isInsuranceReminder ||
          _re(
            r'\b(?:broadband|fiber|telecom|yojana|pension|subscription|utility|electricity|power|water|gas|dth|cable)\b',
          ).hasMatch(body);
      final isCardStatement = cardLast4 != null;
      // A due date alone does not prove recurrence. Generic invoices and
      // maintenance demands are often one-off; only known recurring bill
      // families or explicit cadence wording may create a commitment.
      final isUpcomingObligation =
          isInsuranceOrUtility || (cadenceHint != null && !isCardStatement);
      // Emit credit_card_bill when the message explicitly says "credit card"
      // or "card bill". This reason code gates the CardBillEvidence path so
      // utility bills delivered by shared aggregator senders (MYTNEU/TNBPAY)
      // are never admitted into the credit-card ledger.
      final isCreditCardBill =
          cardLast4 != null ||
          _re(r'\b(?:credit\s+card|card\s+bill)\b').hasMatch(body);
      return observation(
        null,
        LocalSmsEventType.bill,
        nextPremiumMonth != null && nextPremiumDue == null
            ? LocalSmsDisposition.review
            : isUpcomingObligation
            ? LocalSmsDisposition.localCommitment
            : LocalSmsDisposition.localObservation,
        [
          if (due != null) 'due_date_detected',
          if (nextPremiumMonth != null && nextPremiumDue == null)
            'next_premium_due_month_only',
          if (isInsuranceOrUtility || isUpcomingObligation)
            'commitment_detected',
          if (isCreditCardBill) 'credit_card_bill',
        ],
      );
    }
    if (autopaySetup) {
      return observation(
        null,
        LocalSmsEventType.autopay,
        LocalSmsDisposition.localCommitment,
        ['autopay_setup', 'mandate_notice', 'commitment_detected'],
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
    // those cases reviewable instead of acknowledging them as noise. A notice
    // that names its own decline reason is the exception: the movement verb
    // printed beside it restates the attempted amount, so it is not evidence
    // that money moved.
    if ((failed && !hasCompletedMovement) || _declinedThisPayment(body)) {
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
        !hasCompletedMovement &&
        !_brokerSettlement(body, sender)) {
      return observation();
    }
    if (futureDebit) return observation();
    // An initiated broker payout is not yet money received by the bank.
    // Keep it reviewable until the message confirms a completed movement.
    if (_brokerSettlement(body, sender) &&
        !hasCompletedMovement &&
        !_re(
          r'\b(?:(?:has|have)\s+been|(?:was|were|is))\s+settled\b',
        ).hasMatch(body)) {
      return observation(
        null,
        LocalSmsEventType.investment,
        LocalSmsDisposition.review,
        const ['pending_investment_settlement'],
      );
    }
    final amount = money(
      _currencylessBankMovementAmountText(body) ??
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
    final processedCardBill = _re(
      r'\b([A-Za-z][A-Za-z ]{1,35})\s+credit\s+card\s+bill\s*[-:]?\s*of\s+(?:₹|rs\.?|inr)\s*[\d,]+(?:\.\d{1,2})?\s+has\s+been\s+successfully\s+processed\b',
    ).firstMatch(body);
    final billPayment =
        (billPaymentCandidate || processedCardBill != null) &&
        (!_re(
              r'\b(?:payment|amount|minimum)\s+due\b|\bdue\s+on\b',
            ).hasMatch(body) ||
            _re(
              r'\b(?:paid|payment)\s+(?:successfully|completed)\b|\bpayment\s+received\b',
            ).hasMatch(body));
    final cashWithdrawal = _re(
      r'\b(?:cash\s+withdrawal|withdrawn\s+from\b[\s\S]{0,50}\bcard|withdrawn\s+(?:from|at)\s+(?:an?\s+)?atm|atm\b[\s\S]{0,60}\bwithdrawn|atm\s+(?:txn|transaction|w\/d))\b',
    ).hasMatch(body);
    final loanRepayment = !cashWithdrawal && _loanRepayment(body);
    final feeCharge = !cashWithdrawal && !loanRepayment && _feeCharge(body);
    final brokerSettlement = _brokerSettlement(body, sender);
    final investmentDebit =
        asbaOrIpoBlock ||
        (!cashWithdrawal &&
            !loanRepayment &&
            !feeCharge &&
            !brokerSettlement &&
            isInvestmentMovementDescription(body));
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
    final explicitCardInstrument = _explicitCardInstrument(body);
    final savedCardInstrument = _savedCardInstrument(cards, cardLast4);
    if (!credit &&
        !cardCredit &&
        !billPayment &&
        !walletLoad &&
        !loanRepayment &&
        !feeCharge &&
        !asbaOrIpoBlock &&
        !brokerSettlement &&
        !_re(
          r'\b(?:spent|debited|debit|paid|payment|purchase|purchased|charged|withdrawn|sent|transferred|txn|transaction|deducted|deduct)\b',
        ).hasMatch(body)) {
      return observation();
    }
    if (!credit &&
        !cardCredit &&
        !billPayment &&
        !brokerSettlement &&
        _re(
          r'\b(?:credited|refund(?:ed)?|reversed|reversal)\b',
        ).hasMatch(body)) {
      return observation();
    }
    final bankDebit =
        accountShaped && !_re(r'\b(?:credit|debit)\s+card\b').hasMatch(body);
    final walletDebit = _re(
      r'\b(?:debited\s+from|paid\s+from|deducted\s+from|spent\s+from|debited\s+using)\b[\s\S]{0,35}\b([a-zA-Z0-9]+)\s+wallet\b|\b([a-zA-Z0-9]+)\s+wallet\b[\s\S]{0,35}\b(?:debited|paid|deducted)\b',
    ).firstMatch(body);
    final isWalletDebit =
        walletDebit != null ||
        _re(
          r'\bfrom\s+(?:your\s+)?wallet\b|\bwallet\s+balance\b',
        ).hasMatch(body);
    var instrument = billPayment
        ? (bankDebit ? TxnInstrument.upiBank : TxnInstrument.other)
        : credit && _re(r'\bwallet\b').hasMatch(body)
        ? TxnInstrument.wallet
        : isWalletDebit
        ? TxnInstrument.wallet
        : explicitCardInstrument ??
              savedCardInstrument ??
              (bankDebit ||
                      credit ||
                      asbaOrIpoBlock ||
                      brokerSettlement ||
                      _re(r'\bupi\b').hasMatch(body)
                  ? TxnInstrument.upiBank
                  : cardLast4 != null
                  ? TxnInstrument.other
                  : null);
    if (instrument == null) return observation();
    final instrumentKnown =
        instrument != TxnInstrument.other ||
        cardLast4 == null ||
        accountLast4 != null ||
        explicitCardInstrument != null ||
        savedCardInstrument != null;
    if (isWalletDebit) {
      instrument = TxnInstrument.wallet;
      final amazonPay = _re(
        r'\b(Amazon\s+Pay)\s+wallet\b',
      ).firstMatch(body)?.group(1);
      var rawProvider = walletDebit?.group(1) ?? walletDebit?.group(2);
      if (rawProvider != null &&
          const {
            'your',
            'the',
            'my',
            'a',
            'an',
            'our',
          }.contains(rawProvider.toLowerCase())) {
        rawProvider = null;
      }
      var walletProvider = amazonPay ?? rawProvider;
      if (walletProvider == null || walletProvider.isEmpty) {
        final senderClean = sender
            .replaceAll(RegExp(r'^[A-Za-z]{2}-|-[A-Za-z]$'), '')
            .trim();
        if (_re(r'mobikw|mbkwik').hasMatch(senderClean)) {
          walletProvider = 'MobiKwik';
        } else if (_re(r'paytm').hasMatch(senderClean)) {
          walletProvider = 'Paytm';
        } else if (_re(r'amzn|amazon').hasMatch(senderClean)) {
          walletProvider = 'Amazon Pay';
        } else if (_re(r'phonepe').hasMatch(senderClean)) {
          walletProvider = 'PhonePe';
        } else if (senderClean.isNotEmpty &&
            senderClean.length <= 12 &&
            !RegExp(r'^\d+$').hasMatch(senderClean)) {
          walletProvider = senderClean;
        } else {
          walletProvider = 'Wallet';
        }
      }
      accountLast4 = walletProvider;
    }
    var transfer =
        !isWalletDebit &&
        (billPayment ||
            cardCredit ||
            cashWithdrawal ||
            walletLoad ||
            loanRepayment ||
            _accountToAccountTransfer(body));
    var kind = brokerSettlement || investmentProceeds
        ? TxnEntryKind.income
        : transfer
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
    final fvgMatch = _re(
      r'\b(?:fvg|fav|favouring|favoring|infvo|in\s+fav(?:ou?r)?\s+of)\s*[:.\-]?\s*([A-Za-z0-9_][A-Za-z0-9 ._&@*\x27/-]{0,80}?)(?=\s+(?:avl|avail|available|bal(?:ance)?|ref(?:erence|\s*no)?|refno|txn|transaction|if\s+not|not\s+you|call|sms\s+block|on|dated)\b|\s*\(|[.,;]|$)',
    ).firstMatch(body);
    final towardsMatchParse = _re(
      r'\b(?:towards?|in\s+fav(?:ou?r)?\s+of)\s+(?!(?:₹|rs\.?|inr|re\.?)(?:\b|\s|\d)|\d+[\s.,])([A-Za-z_][A-Za-z0-9 ._&@*\x27/-]{1,80}?)(?=\s+(?:for|by\s+upi|from|on|via|upi|ref(?:erence)?|refno|txn|transaction|bal(?:ance)?|avl|available|if\s+not|call|sms\s+block|umrn|nach|mandate)\b|\s*\(|[.,;]|$)',
    ).firstMatch(body);

    var merchant =
        receiptMerchant ??
        _upiAccountRecipient(body) ??
        fvgMatch?.group(1)?.trim() ??
        _upiNarrationParty(body) ??
        towardsMatchParse?.group(1)?.trim();

    if (asbaOrIpoBlock && (merchant == null || merchant.isEmpty)) {
      final ipoCompanyMatch =
          _re(
            r'\b(?:asba|ipo)\b[\s\S]{0,60}?\bfor\s+([A-Za-z0-9 ._&@*\x27/-]{2,60}?)(?=\s+(?:of\s+(?:₹|rs\.?|inr)|application|has\s+been|is\s+accepted)|[.,;]|$)',
          ).firstMatch(body) ??
          _re(
            r'\bfor\s+([A-Za-z0-9 ._&@*\x27/-]{2,60}?)\s+of\s+(?:₹|rs\.?|inr)',
          ).firstMatch(body);
      merchant = ipoCompanyMatch?.group(1)?.trim() ?? 'IPO Application';
    }

    if ((instrument == TxnInstrument.creditCard ||
            instrument == TxnInstrument.debitCard) &&
        (merchant == null || merchant.isEmpty)) {
      final afterTimestamp = _re(
        r'\b\d{1,2}[-/]\d{1,2}[-/]\d{2,4}\s+\d{1,2}:\d{2}(?::\d{2})?\s*(?:IST\s+)?([A-Za-z_][A-Za-z0-9 ._&@*\x27/-]{1,60}?)(?=\s+(?:avl|available|limit|not\s+you|sms\s+block|call)\b|[.;]|$)',
      ).firstMatch(body);
      merchant = afterTimestamp?.group(1)?.trim();
    }

    if (merchant == null || merchant.isEmpty) {
      final merchantMatch = _re(
        r'\b(?:at|to|for|towards?)\s+(?!(?:₹|rs\.?|inr)(?:\b|\s|\d)|\d+[\s.,]|(?:a\/?c\.?|account)\b|using\s+yono\b|(?:the\s+)?(?:upcoming|scheduled)\s+mandate\b)([A-Za-z_][A-Za-z0-9 ._&@*\x27/-]{1,80}?)(?=\s+(?:for|by\s+upi|from|on|via|upi|ref(?:erence)?|refno|txn|transaction|bal(?:ance)?|avl|available|if\s+not|call|sms\s+block|umrn|nach|mandate)\b|\s*\(|[.,;]|$)',
      ).firstMatch(body);
      merchant = merchantMatch?.group(1)?.trim();
    }

    // Banking channels / currency tokens are not recipients.
    if (merchant != null &&
        (_re(
              r'^(?:mob(?:ile)?\s*(?:bk|banking)|net\s*(?:bk|banking)|internet\s*banking|upi|imps|neft|rtgs|yono|sbi|rinb|inb)$',
            ).hasMatch(merchant) ||
            _re(r'^(?:rs\.?|inr|re\.?|\d+|vpa)$').hasMatch(merchant) ||
            _re(r'^(?:a\/?c\.?|account)\b').hasMatch(merchant))) {
      merchant = fvgMatch?.group(1)?.trim();
    }
    if (isWalletDebit &&
        merchant != null &&
        _re(r'^(?:your\s+)?(?:\w+\s+)?wallet$').hasMatch(merchant)) {
      merchant = null;
    }
    if (merchant != null) {
      merchant = merchant
          .replaceFirst(RegExp(r'^vpa[/ ]\s*', caseSensitive: false), '')
          .trim();
      if (_re(r'^(?:a\/?c\.?|account)\b').hasMatch(merchant)) {
        merchant = null;
      }
    }
    if (merchant != null) {
      merchant = merchant
          .replaceFirst(RegExp(r'^ICCL\s+', caseSensitive: false), '')
          .replaceFirst(RegExp(r'\s+AUTOPAY$', caseSensitive: false), '')
          .replaceFirst(RegExp(r'\s+MANDATE$', caseSensitive: false), '')
          .trim();
      if (merchant.toUpperCase() == 'GROWW') merchant = 'Groww';
      if (merchant.toUpperCase() == 'ZERODHA') merchant = 'Zerodha';
    }
    if (merchant != null) {
      final sanitized = IndianNarrationSanitizer.sanitize(merchant);
      if (sanitized.isNotEmpty) {
        merchant = sanitized;
      }
    }
    merchant = MerchantIdentity.cleanName(merchant);
    // "declined due to insufficient balance" makes the merchant regex capture
    // the reason as the payee. A decline reason is not a merchant name.
    if (merchant != null &&
        _re(
          r'^(?:due\s+to\s+|owing\s+to\s+|because\s+of\s+)?(?:insufficient|inadequate|failed|failure|declined|rejected|blocked|expired|invalid|cancell?ed|not\s+permitted|exceeds?|over\s+limit|low\s+balance|technical\s+(?:error|issue)|network\s+(?:error|issue))\b',
        ).hasMatch(merchant)) {
      merchant = null;
    }
    final ownNameTransfer =
        merchant != null &&
        ownUserName != null &&
        _isOwnPersonName(merchant, ownUserName);
    final isInvestmentPayee = merchant != null &&
        CommitmentCategory.fromText(merchant) == CommitmentCategory.investment;
    if (isInvestmentPayee && !transfer && !brokerSettlement) {
      kind = TxnEntryKind.investment;
    }
    if (billPayment) {
      merchant = processedCardBill == null
          ? 'Credit card bill payment'
          : '${processedCardBill.group(1)!.trim()} credit card bill';
    } else if (ownNameTransfer) {
      merchant = 'Transfer between own accounts';
    } else if (brokerSettlement) {
      final detectedBroker = _detectBrokerName(body, sender);
      merchant = detectedBroker != null
          ? 'Investment return · $detectedBroker'
          : 'Investment return';
    } else if (investmentProceeds) {
      merchant = 'Investment return';
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
    } else if (feeCharge) {
      merchant = 'Bank or service fee';
    } else if (investmentDebit) {
      merchant = (asbaOrIpoBlock && merchant != null && merchant.isNotEmpty)
          ? merchant
          : (merchant ?? 'Investment');
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
      merchant ??= bankDebit ? 'Bank debit' : null;
    }
    final ownNameCredit = credit && _ownNameInFromClause(body, ownUserName);
    // An explicit VPA-to-bank credit is money received from another party.
    // Keep confirmed own-name credits as transfers, and leave ambiguous bank
    // credits in the conservative transfer bucket.
    final externalVpaCredit = credit &&
        !ownNameCredit &&
        !_ownAccountTransfer(body) &&
        !refundCredit &&
        !reversalCredit &&
        !rewardCredit &&
        !loanDisbursement &&
        !investmentProceeds &&
        !cashDeposit &&
        !giftCredit &&
        !reimbursementCredit &&
        _re(r'\bfrom\s+VPA\s+\S+@\S+', caseSensitive: false).hasMatch(body);
    if (externalVpaCredit) kind = TxnEntryKind.income;
    if (ownNameCredit) merchant = 'Transfer between own accounts';
    if (ownNameTransfer || ownNameCredit) {
      transfer = true;
      kind = TxnEntryKind.transfer;
    }
    final matching = cards
        .where(
          (c) =>
              !c.isArchived &&
              cardLast4 != null &&
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
        ? _transactionTimestamp(body, parsedDate, receivedAt) ?? parsedDate
        : receivedAt;
    final key = smsSourceKey(namespace, sender, body);
    final textForMatching = merchant != null ? '$merchant $body' : body;
    final ftMatch = FlashTextMerchantExtractor.defaultExtractor.extractFirst(
      textForMatching,
    );
    // A user correction is authoritative: it outranks both the brand catalog
    // and the layout-specific fallbacks below. Confidence for a transaction
    // observation is already 1.0, so the learned field is fully trusted.
    final userRuleSlug = userCategoryRuleSlug(
      userCategoryRules,
      merchant,
      sender,
      body,
    );
    final sharedCategorySlug =
        _sharedCategoryRuleSlug(sharedCategoryRules, merchant, sender, body);
    final categorySlug = userRuleSlug ??
        (brokerSettlement || investmentProceeds || investmentDebit || isInvestmentPayee
            ? 'investments'
            : billPayment
            ? 'bills'
            : loanRepayment
            ? 'emi'
            : feeCharge
            ? 'bills'
            : credit && _re(r'\bsalary\b').hasMatch(body)
            ? 'income'
            : sharedCategorySlug ?? ftMatch?.category);
    final resolvedCategorySlug = categorySlug;
    final categoryName = categoryDisplayName(resolvedCategorySlug);
    return observation(
      TransactionEntry(
        id: 'local-sms:$key',
        sourceKey: key,
        amount: amount,
        occurredAt: date,
        merchantName: merchant ?? ftMatch?.canonicalName,
        categoryId: resolvedCategorySlug,
        categoryName: categoryName,
        userCardId: card?.id,
        cardDisplayName: card?.cardName,
        cardLast4: cardLast4,
        accountLast4: accountLast4,
        instrument: instrument,
        instrumentKnown: instrumentKnown,
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
    Map<String, String>? userCategoryRules,
    Map<String, String>? sharedCategoryRules,
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
      final idx =
          rule.fieldMap[field] ??
          rule.fieldMap[field.replaceAll('cardLast4', 'card_last4')] ??
          rule.fieldMap[field.replaceAll('accountLast4', 'account_last4')] ??
          rule.fieldMap[field.replaceAll('amountInr', 'amount_inr')] ??
          rule.fieldMap[field.replaceAll('merchantName', 'merchant_name')];
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
      final merchant = getGroup('merchant');
      var instrument = TxnInstrument.upiBank;
      final rawInst =
          (rule.defaultFields['instrument'] ?? getGroup('instrument'))
              ?.toString()
              .toLowerCase();
      final genericIsAccount =
          const {'upibank', 'upi_bank', 'upi', 'bank'}.contains(rawInst) ||
          (rawInst == null &&
              !_re(r'\bcard\b').hasMatch(body) &&
              _re(r'\b(?:a\/?c\.?|account)\b').hasMatch(body));
      final accountLast4 =
          getGroup('accountLast4') ??
          (genericIsAccount ? getGroup('last4') : null);
      final cardLast4 =
          getGroup('cardLast4') ??
          (!genericIsAccount && accountLast4 == null
              ? getGroup('last4')
              : null);
      // Downloaded captures are a trust boundary: never retain full numbers or
      // use account digits to validate a claimed card suffix.
      if ([cardLast4, accountLast4].any(
        (suffix) => suffix != null && !RegExp(r'^\d{4}$').hasMatch(suffix),
      )) {
        return null;
      }
      final explicitCardInstrument = _explicitCardInstrument(body);
      final savedCardInstrument = _savedCardInstrument(cards, cardLast4);
      if (rawInst == 'creditcard' || rawInst == 'credit_card') {
        instrument = TxnInstrument.creditCard;
      } else if (rawInst == 'debitcard' || rawInst == 'debit_card') {
        instrument = TxnInstrument.debitCard;
      } else if (rawInst == 'wallet') {
        instrument = TxnInstrument.wallet;
      }
      var instrumentKnown = true;
      if (explicitCardInstrument != null) {
        instrument = explicitCardInstrument;
      } else if (savedCardInstrument != null) {
        instrument = savedCardInstrument;
      } else if (rawInst == null && cardLast4 != null) {
        instrument = TxnInstrument.other;
        instrumentKnown = false;
      }

      var entryKind = TxnEntryKind.spend;
      final rawKind = (rule.defaultFields['entryKind'] ?? getGroup('entryKind'))
          ?.toString()
          .toLowerCase();
      if (rawKind == 'income' || rawKind == 'credit') {
        entryKind = TxnEntryKind.income;
      } else if (rawKind == 'transfer') {
        entryKind = TxnEntryKind.transfer;
      } else if (rawKind == 'investment') {
        entryKind = TxnEntryKind.investment;
      }

      final matchingCards = cards
          .where(
            (card) =>
                !card.isArchived &&
                cardLast4 != null &&
                card.last4 == cardLast4 &&
                ((instrument == TxnInstrument.debitCard &&
                        card.cardType == 'debit') ||
                    (instrument == TxnInstrument.creditCard &&
                        card.cardType != 'debit')),
          )
          .toList();
      final matchedCardId = matchingCards.length == 1
          ? matchingCards.single.id
          : null;

      // Instrument safety: if card is claimed but last4 is missing/invalid, default away from card
      if ((instrument == TxnInstrument.creditCard ||
              instrument == TxnInstrument.debitCard) &&
          cardLast4 == null) {
        instrument = TxnInstrument.other;
        instrumentKnown = false;
      }

      // Calibrate confidence: an unassigned card cannot be auto-accepted at ultra-high confidence
      var calibratedConfidence = rule.confidence;
      if (instrument == TxnInstrument.creditCard && matchedCardId == null) {
        calibratedConfidence = calibratedConfidence.clamp(0.5, 0.90);
      }

      final key = smsSourceKey(namespace, sender, body);
      final textForMatching = merchant != null ? '$merchant $body' : body;
      final ftMatch = FlashTextMerchantExtractor.defaultExtractor.extractFirst(
        textForMatching,
      );
      final categorySlug =
          userCategoryRuleSlug(userCategoryRules, merchant, sender, body) ??
          _sharedCategoryRuleSlug(sharedCategoryRules, merchant, sender, body) ??
          ftMatch?.category;
      final categoryName = categoryDisplayName(categorySlug);
      final txn = TransactionEntry(
        id: 'local-sms:$key',
        sourceKey: key,
        userCardId: matchedCardId,
        amount: amount,
        merchantName: merchant ?? ftMatch?.canonicalName,
        categoryId: categorySlug,
        categoryName: categoryName,
        occurredAt: receivedAt,
        instrument: instrument,
        instrumentKnown: instrumentKnown,
        entryKind: entryKind,
        cardLast4: cardLast4,
        accountLast4: accountLast4,
        source: 'sms',
        status: 'active',
        rewardState: 'estimated',
      );

      return LocalSmsObservation(
        eventType: LocalSmsEventType.transaction,
        transaction: txn,
        cardLast4: cardLast4,
        accountLast4: accountLast4,
        confidence: calibratedConfidence,
        disposition: LocalSmsDisposition.sync,
        reasonCodes: ['downloaded_rule_match', rule.id],
      );
    }

    if (rule.family == SmsRuleFamily.balanceSnapshot) {
      final bal = parseMoney(
        getGroup('availableBalance') ?? getGroup('availableBalanceInr'),
      );
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
      final amt = parseMoney(
        getGroup('amountDue') ??
            getGroup('amountDueInr') ??
            getGroup('minimumDue'),
      );
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
