import '../../data/catalogue_repository.dart' show SpendCategory;
import '../../data/user_cards_repository.dart' show TxnInstrument, UserCard;

enum VoiceActionType { expense, pointsRedemption, unsupported }

/// A deliberately small, editable interpretation of one voice transcript.
/// It is never persisted directly. The review sheet turns it into the same
/// transaction or points-ledger request used by the existing manual screens.
class VoiceActionDraft {
  final VoiceActionType type;
  final String transcript;
  final double? amount;
  final int? points;
  final String? merchant;
  final String? userCardId;
  final String? categoryId;
  final TxnInstrument instrument;
  final List<String> issues;

  const VoiceActionDraft({
    required this.type,
    required this.transcript,
    this.amount,
    this.points,
    this.merchant,
    this.userCardId,
    this.categoryId,
    this.instrument = TxnInstrument.creditCard,
    this.issues = const [],
  });

  bool get canSave => type != VoiceActionType.unsupported && issues.isEmpty;
}

/// Conservative local interpretation. It intentionally refuses to create a
/// card, link a card, or guess between duplicate wallet cards. Missing values
/// stay visible in the review sheet for the user to fill in.
class VoiceActionParser {
  /// Parses every spend-sized amount in a long dictation. The old [parse]
  /// method remains the single-entry API used by the review form, while this
  /// method lets one spoken note produce a reviewable list of entries.
  static List<VoiceActionDraft> parseMany(
    String raw, {
    required List<UserCard> cards,
    required List<SpendCategory> categories,
  }) {
    final transcript = raw.trim();
    if (transcript.isEmpty) {
      return [parse(transcript, cards: cards, categories: categories)];
    }

    final matches = _moneyMatches(transcript);
    if (matches.length <= 1) {
      return [parse(transcript, cards: cards, categories: categories)];
    }

    return [
      for (var index = 0; index < matches.length; index++)
        parse(
          transcript
              .substring(
                index == 0 ? 0 : matches[index - 1].end,
                index + 1 == matches.length
                    ? transcript.length
                    : matches[index + 1].start,
              )
              .trim(),
          cards: cards,
          categories: categories,
        ),
    ];
  }

  static VoiceActionDraft parse(
    String raw, {
    required List<UserCard> cards,
    required List<SpendCategory> categories,
  }) {
    final transcript = raw.trim();
    final lower = transcript.toLowerCase();
    if (transcript.isEmpty) {
      return const VoiceActionDraft(
        type: VoiceActionType.unsupported,
        transcript: '',
        issues: ['I could not hear anything. Try again.'],
      );
    }

    if (RegExp(
      r'\b(add|create|open|apply for|link)\b.{0,24}\b(card|credit|debit)\b',
      caseSensitive: false,
    ).hasMatch(lower)) {
      return VoiceActionDraft(
        type: VoiceActionType.unsupported,
        transcript: transcript,
        issues: const [
          'Cards cannot be added by voice. Add or scan a card from Wallet so its identity can be verified.',
        ],
      );
    }

    final points = _pointsAmount(lower);
    final isPoints =
        points != null &&
        RegExp(
          r'\b(redeem|redeemed|claim|claimed|used|spent|deduct|reduce|removed)\b',
        ).hasMatch(lower);
    final type = isPoints
        ? VoiceActionType.pointsRedemption
        : VoiceActionType.expense;
    final amount = type == VoiceActionType.expense ? _moneyAmount(lower) : null;
    final instrument = _instrument(lower);
    final cardMatch = _resolveCard(lower, cards);
    final merchant = _merchant(lower);
    final category = _category(lower, categories);
    final issues = <String>[];

    if (type == VoiceActionType.expense && amount == null) {
      issues.add('Add the spend amount.');
    }
    if (type == VoiceActionType.pointsRedemption && points == null) {
      issues.add('Add the number of points.');
    }
    if (cardMatch.ambiguous &&
        (type == VoiceActionType.pointsRedemption ||
            instrument == TxnInstrument.creditCard)) {
      issues.add('Choose the exact wallet card; more than one card matched.');
    } else if (cardMatch.card == null &&
        instrument == TxnInstrument.creditCard) {
      issues.add('Choose the wallet card used for this entry.');
    }

    return VoiceActionDraft(
      type: type,
      transcript: transcript,
      amount: amount,
      points: points,
      merchant: merchant,
      userCardId: cardMatch.card?.id,
      categoryId: category?.id,
      instrument: instrument,
      issues: issues,
    );
  }

  static double? _moneyAmount(String text) {
    final match = _moneyMatches(text).firstOrNull;
    if (match == null) return null;
    final number = RegExp(
      r'[0-9][0-9,]*(?:\.[0-9]+)?',
    ).firstMatch(match.group(0)!);
    return number == null
        ? null
        : double.tryParse(number.group(0)!.replaceAll(',', ''));
  }

  static List<RegExpMatch> _moneyMatches(String text) {
    final matches = RegExp(
      r'(?:₹|rs\.?|inr)\s*[0-9][0-9,]*(?:\.[0-9]+)?'
      r'|[0-9][0-9,]*(?:\.[0-9]+)?\s*(?:rupees?|rs\.?|inr)\b'
      r'|\b(?:spent|spend(?:ing)?|paid|pay|cost|book(?:ed)?|expense|expenses)\b'
      r'[^.?!\n]{0,32}?\b[0-9][0-9,]*(?:\.[0-9]+)?\b'
      r'|\b(?:and|also|then|plus)\b\s*(?:₹|rs\.?|inr)?\s*'
      r'[0-9][0-9,]*(?:\.[0-9]+)?\b',
      caseSensitive: false,
    ).allMatches(text).toList();
    if (matches.length < 2) return matches;

    // The alternatives intentionally overlap for phrases such as
    // "spent 100 rupees". Keep the earliest/longest match for each token.
    final unique = <RegExpMatch>[];
    for (final match in matches) {
      if (unique.any(
        (existing) => match.start < existing.end && existing.start < match.end,
      )) {
        continue;
      }
      unique.add(match);
    }
    return unique;
  }

  static int? _pointsAmount(String text) {
    final match = RegExp(r'([0-9][0-9,]*)\s*points?\b').firstMatch(text);
    return match == null
        ? null
        : int.tryParse(match.group(1)!.replaceAll(',', ''));
  }

  static TxnInstrument _instrument(String text) {
    if (text.contains('credit card')) return TxnInstrument.creditCard;
    if (text.contains('debit')) return TxnInstrument.debitCard;
    if (text.contains('cash')) return TxnInstrument.cash;
    if (text.contains('upi') ||
        text.contains('bank account') ||
        text.contains('gpay') ||
        text.contains('google pay') ||
        text.contains('phonepe') ||
        text.contains('phone pe') ||
        text.contains('paytm') ||
        text.contains('amazon pay') ||
        text.contains('bhim')) {
      return TxnInstrument.upiBank;
    }
    if (text.contains('wallet')) return TxnInstrument.wallet;
    return TxnInstrument.creditCard;
  }

  static ({UserCard? card, bool ambiguous}) _resolveCard(
    String text,
    List<UserCard> cards,
  ) {
    final exact = <UserCard>[];
    for (final card in cards) {
      final aliases = <String>[
        card.cardName,
        if (card.nickname?.isNotEmpty == true) card.nickname!,
      ];
      if (card.last4 != null && text.contains(card.last4!)) exact.add(card);
      if (aliases.any((alias) => _containsPhrase(text, alias))) exact.add(card);
    }
    final unique = <String, UserCard>{
      for (final card in exact) card.id: card,
    }.values.toList();
    if (unique.length > 1) return (card: null, ambiguous: true);
    if (unique.length == 1) return (card: unique.single, ambiguous: false);

    final scored = <({UserCard card, int score})>[];
    for (final card in cards) {
      final words = _words(
        '${card.nickname ?? ''} ${card.cardName}',
      ).where((word) => word.length > 2 && !_genericCardWord(word));
      final score = words.where(text.contains).length;
      if (score >= 2) scored.add((card: card, score: score));
    }
    scored.sort((a, b) => b.score.compareTo(a.score));
    if (scored.isEmpty) return (card: null, ambiguous: false);
    final best = scored
        .where((item) => item.score == scored.first.score)
        .map((item) => item.card)
        .toList();
    if (best.length > 1) return (card: null, ambiguous: true);
    return (card: best.single, ambiguous: false);
  }

  static bool _containsPhrase(String text, String phrase) {
    final words = _words(
      phrase,
    ).where((word) => word.length > 2 && !_genericCardWord(word)).toList();
    return words.length >= 2 && words.every(text.contains);
  }

  static bool _genericCardWord(String word) => const {
    'bank',
    'credit',
    'debit',
    'card',
    'plus',
    'visa',
    'mastercard',
    'rupay',
  }.contains(word);

  static List<String> _words(String text) => text
      .toLowerCase()
      .split(RegExp(r'[^a-z0-9]+'))
      .where((word) => word.isNotEmpty)
      .toList();

  static String? _merchant(String text) {
    const known = {
      'uber': 'Uber',
      'ola': 'Ola',
      'swiggy': 'Swiggy',
      'zomato': 'Zomato',
      'amazon': 'Amazon',
      'flipkart': 'Flipkart',
      'blinkit': 'Blinkit',
      'bigbasket': 'BigBasket',
      'bookmyshow': 'BookMyShow',
    };
    for (final entry in known.entries) {
      if (_containsWord(text, entry.key)) return entry.value;
    }
    final purpose = RegExp(
      r'\bto buy(?: some)?\s+([a-z][a-z0-9 &-]{1,36}?)(?:\s+using|\s+with|\s+via|\s+by|\s+from|\s+and\b|[,.!?]|$)',
      caseSensitive: false,
    ).firstMatch(text);
    if (purpose != null) return _titleCase(purpose.group(1)!);
    final forWhat = RegExp(
      r'\b(?:on|at|for)\s+([a-z][a-z0-9 &-]{1,36}?)(?:\s+using|\s+with|\s+via|\s+by|\s+from|\s+and\b|[,.!?]|$)',
      caseSensitive: false,
    ).firstMatch(text);
    if (forWhat != null) return _titleCase(forWhat.group(1)!);
    return null;
  }

  static String _titleCase(String value) => value
      .trim()
      .split(RegExp(r'\s+'))
      .where((word) => word.isNotEmpty)
      .map(
        (word) => '${word[0].toUpperCase()}${word.substring(1).toLowerCase()}',
      )
      .join(' ');

  static bool _containsWord(String text, String value) => RegExp(
    '\\b${RegExp.escape(value)}\\b',
    caseSensitive: false,
  ).hasMatch(text);

  static SpendCategory? _category(String text, List<SpendCategory> categories) {
    final hints = <String, List<String>>{
      'travel': ['uber', 'ola', 'flight', 'train', 'hotel', 'travel', 'taxi'],
      'dining': ['restaurant', 'dining', 'food', 'zomato', 'swiggy'],
      'groceries': ['grocery', 'groceries', 'bigbasket', 'blinkit'],
      'fuel': ['fuel', 'petrol', 'diesel'],
      'online': ['online', 'amazon', 'flipkart', 'shopping'],
      'bills': ['bill', 'recharge', 'electricity', 'insurance'],
    };
    for (final entry in hints.entries) {
      if (entry.value.any(text.contains)) {
        for (final category in categories) {
          if (category.slug == entry.key) return category;
        }
      }
    }
    return null;
  }
}

extension on Iterable<RegExpMatch> {
  RegExpMatch? get firstOrNull => isEmpty ? null : first;
}
