import '../contract/enums.dart';
import '../contract/fact.dart';

/// Product rule for a bill-payment receipt that never gets a funding debit.
///
/// Some bill-pay apps send a "your bill was paid" receipt; the debit from the
/// bank or UPI is a separate message. A receipt never counts by itself. When
/// no debit arrives:
///
/// - the receipt is from an EARLIER calendar month than the current one (IST):
///   skipped silently. A bill is paid once and another app or account may have
///   paid it, so it is never counted and the user is never asked;
/// - the receipt is in the CURRENT calendar month: one review item asks the
///   user whether they paid it.
///
/// Everything here is pure and takes the clock as an argument, so tests pin
/// "now" with an injectable clock.

/// How long a receipt waits for its funding debit before the user is asked.
///
/// Equal to the `LINK-RECEIPT` join window (72 hours), so a debit that can
/// still join the receipt never meets a review item.
const Duration kReceiptWaitPeriod = Duration(days: 3);

/// India Standard Time, UTC+5:30 (no daylight saving). The calendar month of a
/// receipt and of "now" are both read on this clock.
const Duration kIstUtcOffset = Duration(hours: 5, minutes: 30);

/// Rule id stamped on the fact a user's "Yes, I paid it" creates.
const String kReceiptConfirmedRuleId = 'USER-RECEIPT-CONFIRMED';

/// The `reason` of the review item (the existing receipt mechanism).
const String kReceiptWithoutPaymentReason = 'receipt_without_payment';

/// What to do with a receipt that has no funding debit at [now].
enum ReceiptDisposition {
  /// Still inside [kReceiptWaitPeriod]: nothing yet.
  wait,

  /// From an earlier IST calendar month: skip silently, never count or ask.
  skipOldMonth,

  /// Current IST month and the wait has passed: ask the user once.
  review,
}

/// The first instant of the IST calendar month that contains [moment].
DateTime istMonthStart(DateTime moment) {
  final ist = moment.toUtc().add(kIstUtcOffset);
  return DateTime.utc(ist.year, ist.month).subtract(kIstUtcOffset);
}

/// True when [moment] falls in an IST calendar month before the one [now] is in.
bool isEarlierCalendarMonthIst(DateTime moment, DateTime now) =>
    moment.toUtc().isBefore(istMonthStart(now));

/// The decision for a receipt printed or received at [receiptAt].
ReceiptDisposition receiptDisposition({
  required DateTime receiptAt,
  required DateTime now,
  Duration wait = kReceiptWaitPeriod,
}) {
  if (isEarlierCalendarMonthIst(receiptAt, now)) {
    return ReceiptDisposition.skipOldMonth;
  }
  return now.toUtc().difference(receiptAt.toUtc()) > wait
      ? ReceiptDisposition.review
      : ReceiptDisposition.wait;
}

/// The event type a confirmed receipt counts as: a credit-card bill is a card
/// payment (an own transfer, never spending); anything else follows the
/// receipt's purpose.
EventType receiptConfirmedEventType(MovementFact receipt) =>
    switch (receipt.purpose) {
      MovementPurpose.cardPayment => EventType.cardBillPayment,
      MovementPurpose.purchase => EventType.purchase,
      MovementPurpose.investment => EventType.investment,
      MovementPurpose.emi => EventType.emi,
      _ => EventType.billPayment,
    };

/// A key shared by receipts that describe one payment, so a receipt that
/// arrives twice (or is re-processed) raises one review item: same amount,
/// same biller or card, same IST calendar month.
String receiptDedupeKey(MovementFact receipt) {
  final ist = receipt.effectiveAt.toUtc().add(kIstUtcOffset);
  final party = receipt.counterparty;
  final who = [
    (party?.name ?? receipt.instrument?.issuerSlug ?? '').toLowerCase().trim(),
    party?.accountMask ?? receipt.instrument?.maskDigits ?? '',
  ].join('/');
  final month = '${ist.year}-${ist.month.toString().padLeft(2, '0')}';
  final minor = receipt.amount(AmountRole.posted)?.minor ?? 0;
  return 'receipt:$minor:$who:$month';
}

/// How the user answers the question.
enum ReceiptAnswer {
  /// "Yes, I paid it": counts once, as the receipt's event type.
  yes,

  /// "No, someone else paid it": dismissed, counts nothing.
  no,

  /// "Not sure": the item stays in review.
  notSure;

  String get wire => switch (this) {
    ReceiptAnswer.yes => 'yes',
    ReceiptAnswer.no => 'no',
    ReceiptAnswer.notSure => 'not_sure',
  };
}

/// All user-facing words of the receipt question, per locale. Strings use
/// `{amount}`, `{date}` and `{app}` placeholders. Add a locale by adding an
/// entry to [kReceiptReviewTexts]; an unknown locale falls back to English.
final class ReceiptReviewText {
  const ReceiptReviewText({
    required this.title,
    required this.cardBillQuestion,
    required this.paymentQuestion,
    required this.yes,
    required this.no,
    required this.notSure,
    required this.chooseAccountTitle,
    required this.anotherAccount,
    required this.unknownApp,
    required this.notSureSnack,
    required this.countedSnack,
    required this.dismissedSnack,
  });

  /// Section heading in the review inbox.
  final String title;

  /// The question for a credit-card bill receipt.
  final String cardBillQuestion;

  /// The question for any other bill or payment receipt.
  final String paymentQuestion;

  final String yes;
  final String no;
  final String notSure;

  /// Heading of the account picker shown after "Yes, I paid it".
  final String chooseAccountTitle;

  /// The picker entry for an account that is not in the app.
  final String anotherAccount;

  /// Used for `{app}` when the sending app is not known.
  final String unknownApp;

  final String notSureSnack;
  final String countedSnack;
  final String dismissedSnack;

  /// The filled question. [date] is already formatted for the reader.
  String question({
    required bool cardBill,
    required String amount,
    required String date,
    String? app,
  }) => (cardBill ? cardBillQuestion : paymentQuestion)
      .replaceAll('{amount}', amount)
      .replaceAll('{date}', date)
      .replaceAll('{app}', app ?? unknownApp);
}

/// The English wording (default locale).
const ReceiptReviewText kReceiptReviewTextEn = ReceiptReviewText(
  title: 'Did you pay this bill?',
  cardBillQuestion:
      'Did you pay this bill? We found a receipt for a credit card bill '
      'payment of {amount} on {date} through {app}, but no matching debit in '
      'your messages. Was this paid from one of your accounts?',
  paymentQuestion:
      'Did you pay this bill? We found a receipt for a payment of {amount} on '
      '{date} through {app}, but no matching debit in your messages. Was this '
      'paid from one of your accounts?',
  yes: 'Yes, I paid it',
  no: 'No, someone else paid it',
  notSure: 'Not sure',
  chooseAccountTitle: 'Which account paid it?',
  anotherAccount: 'Another account',
  unknownApp: 'a payment app',
  notSureSnack: 'We will keep this in your review list.',
  countedSnack: 'Saved. It is counted once as a payment.',
  dismissedSnack: 'Got it. Nothing was counted.',
);

/// Receipt-question wording by locale code.
const Map<String, ReceiptReviewText> kReceiptReviewTexts = {
  'en': kReceiptReviewTextEn,
};

/// The wording for [locale] (`en`, `en_IN`, `hi`, ...), English if unknown.
ReceiptReviewText receiptReviewText([String locale = 'en']) =>
    kReceiptReviewTexts[locale] ??
    kReceiptReviewTexts[locale.split(RegExp('[_-]')).first] ??
    kReceiptReviewTextEn;

/// `₹1,25,000` / `₹899.50`, Indian digit grouping, paise only when present.
String formatReceiptRupees(int minor) {
  final rupees = minor ~/ 100;
  final paise = minor % 100;
  final digits = rupees.toString();
  final grouped = digits.length <= 3
      ? digits
      : '${digits.substring(0, digits.length - 3).replaceAllMapped(RegExp(r'(\d)(?=(\d\d)+$)'), (m) => '${m[1]},')},${digits.substring(digits.length - 3)}';
  return paise == 0
      ? '₹$grouped'
      : '₹$grouped.${paise.toString().padLeft(2, '0')}';
}

/// `5 Nov 2026`, the IST calendar date of [moment].
String formatReceiptDate(DateTime moment) {
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  final ist = moment.toUtc().add(kIstUtcOffset);
  return '${ist.day} ${months[ist.month - 1]} ${ist.year}';
}
