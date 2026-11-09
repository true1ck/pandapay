import '../../../data/catalogue_repository.dart' show SpendCategory;
import '../../../data/user_cards_repository.dart' show TxnInstrument, UserCard;
import '../understanding/date_grammar.dart';
import '../understanding/en_pack.dart';
import '../understanding/language_pack.dart';
import '../understanding/number_grammar.dart';
import '../understanding/tokens.dart';
import '../voice_action_parser.dart';

enum QuestionKind {
  /// Spending in a period, optionally narrowed by category, merchant, card
  /// or payment method. Several filters combine.
  spend,
  topSpends,
  moneyIn,
  compare,
  billsDue,
  capsLeft,
  pointsBalance,
  bestCard,
  unknown,
}

/// What a spoken question asks, built from the same pieces as an entry: a
/// metric, filters from the user's own data, and a period.
class VoiceQuestion {
  const VoiceQuestion({
    required this.kind,
    required this.source,
    this.period,
    this.comparePeriod,
    this.periodDefaulted = false,
    this.category,
    this.merchant,
    this.cards = const [],
    this.instrument,
    this.amount,
  });

  final QuestionKind kind;
  final String source;

  /// The period asked about, or null when the kind has no period.
  final TimeSpan? period;

  /// The period to compare it with ("this month versus last month").
  final TimeSpan? comparePeriod;

  /// No period was said, so "this month" was assumed and is shown as such.
  final bool periodDefaulted;
  final SpendCategory? category;
  final String? merchant;

  /// Cards the question names. Empty means "all cards".
  final List<UserCard> cards;
  final TxnInstrument? instrument;

  /// A purchase amount, for "which card for ₹4,500 at Croma".
  final double? amount;

  int get filterCount => [
    category != null,
    merchant != null,
    cards.isNotEmpty,
    instrument != null,
  ].where((x) => x).length;
}

/// Reads a question the same way an entry is read: find the dates and
/// numbers, score what the question is about, then resolve the names it
/// mentions against the user's own cards, categories and merchants.
class QuestionReader {
  const QuestionReader([this.pack = enPack]);

  final LanguagePack pack;

  static const _priority = [
    'bestCard',
    'bills',
    'points',
    'caps',
    'moneyIn',
    'top',
    'spend',
  ];

  VoiceQuestion read(
    String text, {
    required DateTime now,
    required List<UserCard> cards,
    required List<SpendCategory> categories,
    List<String> knownMerchants = const [],
  }) {
    final source = text.trim();
    final tokens = tokenize(source);
    final times = findTimeSpans(tokens, pack, now);
    final claimed = {
      for (final s in times)
        for (var k = s.startToken; k < s.endToken; k++) k,
    };
    final words = <String>[
      for (var k = 0; k < tokens.length; k++)
        if (tokens[k].isWord && !claimed.contains(k)) tokens[k].text,
    ];

    // What the question is about.
    final scores = <String, double>{};
    for (final entry in pack.questionCues.entries) {
      var s = 0.0;
      for (final phrase in entry.value) {
        for (var i = 0; i + phrase.length <= words.length; i++) {
          var ok = true;
          for (var j = 0; j < phrase.length; j++) {
            if (words[i + j] != phrase[j]) {
              ok = false;
              break;
            }
          }
          if (ok) s += phrase.length;
        }
      }
      scores[entry.key] = s;
    }
    String? best;
    var bestScore = 0.0;
    for (final key in _priority) {
      final s = scores[key] ?? 0;
      if (s > bestScore) {
        best = key;
        bestScore = s;
      }
    }
    final compare = (scores['compare'] ?? 0) >= 1;
    QuestionKind kind;
    if (best == null || bestScore < 1) {
      kind = compare ? QuestionKind.compare : QuestionKind.unknown;
    } else {
      kind = switch (best) {
        'bestCard' => QuestionKind.bestCard,
        'bills' => QuestionKind.billsDue,
        'points' => QuestionKind.pointsBalance,
        'caps' => QuestionKind.capsLeft,
        'moneyIn' => QuestionKind.moneyIn,
        'top' => QuestionKind.topSpends,
        _ => QuestionKind.spend,
      };
      if (compare && kind == QuestionKind.spend) kind = QuestionKind.compare;
    }

    // The period, or two of them when comparing.
    // A day still ahead this year is not answered as if it were last year's.
    final today = DateTime(now.year, now.month, now.day);
    final usable = times
        .where(
          (t) => !t.isFuture(today) && !(t.yearInferredBack && t.isSingleDay),
        )
        .toList();
    TimeSpan? period;
    TimeSpan? comparePeriod;
    var defaulted = false;
    final needsPeriod =
        kind == QuestionKind.spend ||
        kind == QuestionKind.topSpends ||
        kind == QuestionKind.moneyIn ||
        kind == QuestionKind.compare;
    if (needsPeriod) {
      if (kind == QuestionKind.compare) {
        if (usable.length >= 2) {
          period = usable[0];
          comparePeriod = usable[1];
        } else {
          period = _thisMonth(now);
          comparePeriod = usable.isEmpty ? null : usable.first;
          defaulted = usable.isEmpty || true;
        }
      } else if (usable.isNotEmpty) {
        period = usable.first;
      } else {
        period = _thisMonth(now);
        defaulted = true;
      }
    }

    // Names, resolved against what the user actually has.
    final lower = words.join(' ');
    VoiceQuestion make({
      SpendCategory? category,
      String? merchant,
      List<UserCard> cardMatches = const [],
      TxnInstrument? instrument,
      double? amount,
    }) => VoiceQuestion(
      kind: kind,
      source: source,
      period: period,
      comparePeriod: comparePeriod,
      periodDefaulted: defaulted,
      category: category,
      merchant: merchant,
      cards: cardMatches,
      instrument: instrument,
      amount: amount,
    );

    if (kind == QuestionKind.unknown) return make();

    // Card digits are numbers, so they are added for card matching only.
    final cardInput = [
      ...words,
      for (var k = 0; k < tokens.length; k++)
        if (tokens[k].isNumber && !claimed.contains(k)) tokens[k].text,
    ];
    final cardMatches = VoiceActionParser.matchCards(cardInput, cards);
    final onlyCard =
        kind == QuestionKind.billsDue ||
        kind == QuestionKind.capsLeft ||
        kind == QuestionKind.pointsBalance;
    if (onlyCard) {
      return make(cardMatches: cardMatches);
    }

    final cardWords = {
      for (final c in cardMatches) ...VoiceActionParser.splitWords('${c.nickname ?? ''} ${c.cardName}'),
    };
    final nameWords = [
      for (final w in words)
        if (!cardWords.contains(w) || cardMatches.isEmpty) w,
    ];
    final merchantRead = VoiceActionParser.resolveMerchant(
      nameWords.join(' '),
      nameWords,
      pack,
      knownMerchants,
      categories,
      incoming: kind == QuestionKind.moneyIn,
    );
    final merchantWords = merchantRead.name == null
        ? const <String>[]
        : VoiceActionParser.splitWords(merchantRead.name!);
    final categoryWords = [
      for (final w in nameWords)
        if (!merchantWords.contains(w)) w,
    ];
    final category = VoiceActionParser.resolveCategory(
      categoryWords,
      categories,
      pack,
      null,
    );
    final instrument = VoiceActionParser.statedInstrument(lower, pack);

    double? amount;
    if (kind == QuestionKind.bestCard) {
      for (final n in findNumbers(tokens, pack, claimed: claimed)) {
        if (n.value >= 1) {
          amount = n.value;
          break;
        }
      }
    }
    return make(
      category: category,
      merchant: merchantRead.name,
      cardMatches: kind == QuestionKind.bestCard ? const [] : cardMatches,
      instrument: instrument,
      amount: amount,
    );
  }

  TimeSpan _thisMonth(DateTime now) => TimeSpan(
    startToken: 0,
    endToken: 0,
    from: DateTime(now.year, now.month),
    to: DateTime(now.year, now.month + 1, 0),
    kind: TimeSpanKind.month,
  );
}
