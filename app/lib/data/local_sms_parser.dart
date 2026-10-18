import 'package:pandapay_domain/pandapay_domain.dart';
import 'user_cards_repository.dart';
import 'local/sms_intake_repository.dart';

class LocalSmsObservation {
  final TransactionEntry? transaction;
  final String? cardLast4, accountLast4;
  final DateTime? dueDate;
  final Money? availableBalance;
  const LocalSmsObservation({
    this.transaction,
    this.cardLast4,
    this.accountLast4,
    this.dueDate,
    this.availableBalance,
  });
}

/// Versioned conservative built-in grammar. Unsupported/admin-configured
/// formats remain durable intake for server parsing; they never become guessed
/// spending. Values are local observations until server reconciliation.
class LocalSmsParser {
  static const version = 3;
  static bool sensitive(String body) => RegExp(
    r"\b(?:otp|one[-\s]?time password|verification code|security code|cvv|pin)\b|\b(?:do not|don't|never)\s+share\b|\bvalid\s+(?:for|till|until)\b",
    caseSensitive: false,
  ).hasMatch(body);
  static RegExp _re(String s) => RegExp(s, caseSensitive: false);
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

  static LocalSmsObservation? parse({
    required String namespace,
    required String sender,
    required String body,
    required DateTime receivedAt,
    List<UserCard> cards = const [],
  }) {
    if (body.length > 20000 || sensitive(body)) return null;
    final cardLast4 =
        _re(
          r'\b(?:credit\s+|debit\s+)?card\b[\s\S]{0,45}?(?:ending(?:\s+with)?\s*|x{1,4}|\*{1,4}|\.{3,}|last\s*4\s*|no\.?\s*)\D{0,5}(\d{4})\b',
        ).firstMatch(body)?.group(1) ??
        _re(
          r'\b(?:credit|debit)\s+card\s+(\d{4})\b',
        ).firstMatch(body)?.group(1);
    // Credit-card account references identify a card ledger, not a bank account.
    final accountLast4 = _re(r'\bcredit\s+card\b').hasMatch(body)
        ? null
        : _re(
            r'\b(?:a\/?c\.?|account)\s*(?:no\.?|number)?\s*(?:(?:ending(?:\s+with)?|last\s*4)\s*)?[*xX-]*\s*(\d{4})\b',
          ).firstMatch(body)?.group(1);
    DateTime? due;
    for (final phrase in [
      r'\bdue\s*(?:date\s*)?(?:is|on|by)?\s*[:\-]?\s*',
      r'\b(?:payment|bill|amount)\s+due\s+date\b[\s\S]{0,120}?\b(?:is|on|by)\s*[:\-]?\s*',
    ]) {
      final token = _re('$phrase($dateToken)').firstMatch(body)?.group(1);
      if (token != null) {
        due = parseDate(token);
        if (due != null) break;
      }
    }
    final balanceText = _re(
      r'\b(?:available|avail|avl|current|closing)\s*(?:balance|bal)\s*(?:is|:|-)?\s*(?:₹|rs\.?|inr)?\s*:?\s*([\d,]+(?:\.\d{1,2})?)',
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
    LocalSmsObservation observation([TransactionEntry? row]) =>
        LocalSmsObservation(
          transaction: row,
          cardLast4: cardLast4,
          accountLast4: accountLast4,
          dueDate: due,
          availableBalance: balance,
        );
    // Reminders and offers are observations, never purchases.
    if (due != null ||
        _re(
          r'\b(?:payment|amount|minimum)\s+due\b|\b(?:statement|bill)\b[\s\S]{0,40}\b(?:generated|ready|available)\b|\b(?:offer|cashback|reward|voucher|eligible|campaign)\b[\s\S]{0,80}\b(?:spend|card)\b|\bspend\s*(?:₹|rs\.?|inr)[\s\S]{0,50}\b(?:get|earn|cashback|reward|voucher)\b',
        ).hasMatch(body)) {
      return observation();
    }
    if (_re(
      r'\b(?:declined|failed|failure|cancelled|canceled|pending|processing|initiated)\b',
    ).hasMatch(body)) {
      return observation();
    }
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
    final billPayment = _re(
      r'\b(?:payment|paid|debited|debit|amount)\b[\s\S]{0,90}\btowards?\b[\s\S]{0,50}\b(?:your\s+)?credit\s+card\b|\bcredit\s+card\s+(?:bill|payment)\b[\s\S]{0,90}\b(?:received|credited|debited|paid)\b',
    ).hasMatch(body);
    if (!credit &&
        !billPayment &&
        !_re(
          r'\b(?:spent|debited|debit|paid|purchase|purchased|charged|withdrawn|sent|transferred)\b',
        ).hasMatch(body)) {
      return observation();
    }
    if (!credit &&
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
    final transfer =
        billPayment ||
        _re(
          r'\bfrom\b[\s\S]{0,80}\b(?:a\/?c\.?|account)\s*[*xX-]*\s*\d{4}\s+to\s+[A-Za-z]',
        ).hasMatch(body);
    final kind = transfer
        ? TxnEntryKind.transfer
        : credit
        ? TxnEntryKind.income
        : TxnEntryKind.spend;
    var merchant = _re(
      r'\b(?:at|to|for|from|by)\s+([A-Za-z_][A-Za-z0-9 ._&@*\x27/-]{1,80}?)(?=\s+(?:from|on|via|upi|ref(?:erence)?|txn|transaction|bal(?:ance)?|avl|available|if\s+not|call|sms\s+block)\b|\s*\(|[.,;]|$)',
    ).firstMatch(body)?.group(1)?.trim();
    if (billPayment) {
      merchant = 'Credit card bill payment';
    } else if (credit && _re(r'\bsalary\b').hasMatch(body)) {
      merchant = 'Salary';
    } else if (credit) {
      merchant ??= 'Money received';
    } else {
      merchant ??= bankDebit ? 'Bank transfer' : null;
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
}
