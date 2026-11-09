import 'date_grammar.dart';
import 'tokens.dart';

/// What one spoken or typed entry is. Transfers and card-bill payments are
/// recognized so they can be explained, but they are not logged by voice.
enum EntryKind { spend, moneyIn, refund, pointsRedemption, transfer, billPayment }

extension EntryKindX on EntryKind {
  bool get loggable =>
      this != EntryKind.transfer && this != EntryKind.billPayment;
}

enum UtteranceType { entries, question, addCard, empty }

/// The amount of one entry and the words it came from.
class AmountReading {
  const AmountReading({
    required this.value,
    required this.source,
    required this.tokenStart,
    required this.tokenEnd,
    this.alternative,
    this.currencyCode,
    this.weak = false,
    this.correctedFrom,
    this.correctedFromSource,
  });

  final double value;

  /// The words as said, e.g. "two fifty" or "1.5k".
  final String source;
  final int tokenStart;
  final int tokenEnd;

  /// Another plausible value ("two fifty" is also 2.50).
  final double? alternative;

  /// ISO code when the amount was said in a foreign currency, else null.
  final String? currencyCode;

  /// No number scored well; this is the best of a poor lot.
  final bool weak;

  /// Set when a spoken correction replaced an earlier amount.
  final double? correctedFrom;
  final String? correctedFromSource;

  bool get foreign => currencyCode != null;
  bool get ambiguous => alternative != null || weak;

  AmountReading corrected({
    required double from,
    required String fromSource,
    required AmountReading to,
  }) => AmountReading(
    value: to.value,
    source: to.source,
    tokenStart: to.tokenStart,
    tokenEnd: to.tokenEnd,
    alternative: to.alternative,
    currencyCode: to.currencyCode ?? currencyCode,
    weak: to.weak,
    correctedFrom: from,
    correctedFromSource: fromSource,
  );
}

/// A number or name that was heard but not used.
class Leftover {
  const Leftover({required this.text, required this.reason, this.value});

  final String text;
  final String reason;
  final double? value;
}

class EntryReading {
  const EntryReading({
    required this.tokenStart,
    required this.tokenEnd,
    required this.text,
    required this.cleanText,
    required this.kind,
    this.kindAlternative,
    this.amount,
    this.points,
    this.pointsSource,
    this.date,
    this.dateSource,
    this.dateFuture = false,
    this.dateVague = false,
    this.quantities = const [],
    this.cardDigits,
    this.leftovers = const [],
  });

  final int tokenStart;
  final int tokenEnd;

  /// The words of this entry exactly as said.
  final String text;

  /// The same words once the amount, date, quantity, card digits, fillers and
  /// correction words are taken out. Merchants and categories are read from
  /// this.
  final String cleanText;
  final EntryKind kind;

  /// The other reading when the evidence was close ("got 500 from Amazon" is
  /// money in or a refund).
  final EntryKind? kindAlternative;
  final AmountReading? amount;
  final int? points;
  final String? pointsSource;

  /// A single day. Null means "now".
  final TimeSpan? date;
  final String? dateSource;

  /// The date named is in the future.
  final bool dateFuture;

  /// A stretch of days was named where one day was needed ("last week").
  final bool dateVague;

  /// Quantities that are not money, e.g. "2 coffees".
  final List<String> quantities;
  final String? cardDigits;
  final List<Leftover> leftovers;

  bool get foreign => amount?.foreign ?? false;
}

class Understanding {
  const Understanding({
    required this.source,
    required this.tokens,
    required this.type,
    this.entries = const [],
    this.times = const [],
    this.hasSignal = false,
  });

  final String source;
  final List<Token> tokens;
  final UtteranceType type;
  final List<EntryReading> entries;

  /// Every date or period found, in order.
  final List<TimeSpan> times;

  /// The sentence contained a number, a money word or a logging verb, so it
  /// was plausibly meant as an entry.
  final bool hasSignal;
}
