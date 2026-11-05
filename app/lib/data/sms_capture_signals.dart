/// Text signals the shared SMS capture gate (`classifySmsTriage`,
/// `SmsGateFilter`) relies on to tell real financial messages from noise.
/// Pure functions of the message text; they parse no amounts or merchants,
/// and the SMS v2 rules do all extraction.
class SmsCaptureSignals {
  const SmsCaptureSignals._();

  /// Stamped on intake and acquisition receipts so a stored decision records
  /// which capture rules produced it.
  static const version = 28;

  static const dateToken =
      r'(?:\d{4}[./-]\d{1,2}[./-]\d{1,2}|\d{1,2}[./-]\d{1,2}[./-]\d{2,4}|\b\d{1,2}(?:st|nd|rd|th)?[A-Za-z]{3,9}\d{2,4}\b|\d{1,2}(?:st|nd|rd|th)?[\s./-]+[A-Za-z]{3,9}[,\s./-]+\d{2,4}|[A-Za-z]{3,9}[\s./-]+\d{1,2}(?:st|nd|rd|th)?[,]?[\s./-]+\d{2,4})';

  static final _reCache = <String, RegExp>{};
  static RegExp _re(String s, {bool caseSensitive = false}) =>
      _reCache.putIfAbsent(
        caseSensitive ? 'c:$s' : 'i:$s',
        () => RegExp(s, caseSensitive: caseSensitive),
      );

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
      r'\bdue\s+for\s+payment\b|\b(?:total\s+)?amount\s+payable\b|\bto\s+pay\s+(?:your\s+|now\b)[\s\S]{0,20}?\bbill\b|\b(?:payment|amount|minimum|total|premium)\s+due\b|\bdue\s+date\b|\b(?:statement|bill|premium)\b[\s\S]{0,80}\b(?:generated|ready|available|due)\b',
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
  static bool isRefundProgressNotice(String body) {
    if (!_re(r'\brefund').hasMatch(body)) return false;
    if (_re(
      r'\b(?:has\s+been|have\s+been|was|is)\s+(?:successfully\s+)?credited\b|\bcredited\s+(?:to|in|into)\s+(?:your\s+)?(?:a\/?c|account|card|wallet)\b|\bcredited\s+with\b|\b(?:debited|withdrawn)\b',
    ).hasMatch(body)) {
      return false;
    }
    return _re(
      r'\b(?:initiated|processed|approved|in\s+progress|will\s+(?:be\s+)?(?:credited|reflect|refunded|processed)|(?:within|in)\s+\d+(?:\s*[-–to]+\s*\d+)?\s+(?:business\s+|working\s+)?days?|original\s+payment\s+(?:method|source|mode))\b',
    ).hasMatch(body);
  }

  /// EPFO / provident-fund passbook updates. Contributions sit in the PF
  /// account, not the bank, and a settled claim arrives as its own bank
  /// credit alert. Keyed on the sender or a UAN, which bank alerts never carry.
  static bool isProvidentFundNotice(String sender, String body) {
    final fromEpfo = _re(r'epfo|epfindia|uanmem|epf').hasMatch(sender);
    final hasUan = _re(r'\buan\b').hasMatch(body);
    if (!fromEpfo && !hasUan) return false;
    return _re(
      r'\b(?:passbook|contribution|claim|kyc|member|uan|pf\s+(?:balance|account|a\/c)|provident\s+fund|epf)\b',
    ).hasMatch(body);
  }

  static bool isNonTransactionNoise(String sender, String body) {
    if (isMerchantReceiptOrEbill(body) || isInvestmentFolioAllotment(body)) {
      return false;
    }
    if (isRefundProgressNotice(body) || isProvidentFundNotice(sender, body)) {
      return true;
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
      r'\bdue\s+for\s+payment\b|\b(?:total\s+)?amount\s+payable\b|\bto\s+pay\s+(?:your\s+|now\b)[\s\S]{0,20}?\bbill\b|\b(?:payment|amount|minimum|total|premium)\s+due\b|\bdue\s+date\b|\b(?:statement|bill|premium)\b[\s\S]{0,80}\b(?:generated|ready|available|due)\b',
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
}
