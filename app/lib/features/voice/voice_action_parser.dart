import '../../data/cached_regexp.dart';
import '../../data/catalogue_repository.dart' show SpendCategory;
import '../../data/flashtext_merchant_extractor.dart';
import '../../data/user_cards_repository.dart'
    show TransactionTag, TxnInstrument, UserCard;
import 'understanding/en_pack.dart';
import 'understanding/language_pack.dart';
import 'understanding/understanding.dart';
import 'understanding/utterance_reader.dart';
import 'voice_format.dart';

enum VoiceActionType {
  expense,
  moneyIn,
  refund,
  pointsRedemption,
  question,
  unsupported,
}

/// Why a sentence was recognized but not turned into an entry.
enum VoiceNotice { addCard, cardBillPayment, transfer, nothingFound, nothingHeard }

/// One conversion Panda made, shown so the user can see where a value came
/// from: `₹250 ← "two fifty"`.
class HeardPart {
  const HeardPart({
    required this.label,
    required this.source,
    required this.shown,
  });

  final String label;
  final String source;
  final String shown;
}

/// A second plausible reading, one tap away.
class DraftAlternative {
  const DraftAlternative({
    required this.role,
    required this.label,
    this.amount,
    this.type,
  });

  /// `amount` or `kind`.
  final String role;
  final String label;
  final double? amount;
  final VoiceActionType? type;
}

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
  final List<String> tagIds;
  final List<String> issues;

  /// Set for a past day; null means "now".
  final DateTime? occurredAt;
  final String? dateSource;
  final bool dateIsFuture;
  final bool dateIsVague;
  final List<HeardPart> heard;
  final List<DraftAlternative> alternatives;

  /// Numbers or names that were heard but not used.
  final List<String> warnings;
  final VoiceNotice? notice;

  /// Foreign currency code and amount when the sentence named one. The rupee
  /// amount is then unknown and has to be asked for.
  final String? foreignCurrency;
  final double? foreignAmount;
  final List<String> quantities;

  const VoiceActionDraft({
    required this.type,
    required this.transcript,
    this.amount,
    this.points,
    this.merchant,
    this.userCardId,
    this.categoryId,
    this.instrument = TxnInstrument.creditCard,
    this.tagIds = const [],
    this.issues = const [],
    this.occurredAt,
    this.dateSource,
    this.dateIsFuture = false,
    this.dateIsVague = false,
    this.heard = const [],
    this.alternatives = const [],
    this.warnings = const [],
    this.notice,
    this.foreignCurrency,
    this.foreignAmount,
    this.quantities = const [],
  });

  bool get canSave =>
      type != VoiceActionType.unsupported &&
      type != VoiceActionType.question &&
      issues.isEmpty;

  bool get isForeign => foreignCurrency != null;
}

/// Reads what was said with [UtteranceReader], then fills in the parts that
/// depend on the user's own data: wallet cards, categories, tags and
/// merchants. It still refuses to create a card, link a card, or guess
/// between duplicate wallet cards. Missing values stay visible in the review
/// sheet for the user to fill in.
class VoiceActionParser {
  /// Parses a dictation into one reviewable draft per entry.
  static List<VoiceActionDraft> parseMany(
    String raw, {
    required List<UserCard> cards,
    required List<SpendCategory> categories,
    List<TransactionTag> tags = const [],
    List<String> knownMerchants = const [],
    DateTime? now,
    LanguagePack pack = enPack,
  }) {
    final clock = now ?? DateTime.now();
    final u = UtteranceReader(pack).read(raw, clock);
    switch (u.type) {
      case UtteranceType.empty:
        return const [
          VoiceActionDraft(
            type: VoiceActionType.unsupported,
            transcript: '',
            notice: VoiceNotice.nothingHeard,
            issues: ['I could not hear anything. Try again.'],
          ),
        ];
      case UtteranceType.addCard:
        return [
          VoiceActionDraft(
            type: VoiceActionType.unsupported,
            transcript: u.source,
            notice: VoiceNotice.addCard,
            issues: const [
              'Cards cannot be added by voice. Add or scan a card from Wallet so its identity can be verified.',
            ],
          ),
        ];
      case UtteranceType.question:
        return [
          VoiceActionDraft(
            type: VoiceActionType.question,
            transcript: u.source,
          ),
        ];
      case UtteranceType.entries:
        if (!u.hasSignal && u.entries.every((e) => e.amount == null)) {
          return [
            VoiceActionDraft(
              type: VoiceActionType.unsupported,
              transcript: u.source,
              notice: VoiceNotice.nothingFound,
              issues: const [
                'I didn’t catch an amount or a question. Try “spent 250 on lunch” or “how much did I spend this month”.',
              ],
            ),
          ];
        }
        return [
          for (final e in u.entries)
            _draft(
              e,
              cards: cards,
              categories: categories,
              tags: tags,
              knownMerchants: knownMerchants,
              now: clock,
              pack: pack,
            ),
        ];
    }
  }

  /// The first entry of [raw]; kept for callers that only handle one.
  static VoiceActionDraft parse(
    String raw, {
    required List<UserCard> cards,
    required List<SpendCategory> categories,
    List<TransactionTag> tags = const [],
    List<String> knownMerchants = const [],
    DateTime? now,
    LanguagePack pack = enPack,
  }) => parseMany(
    raw,
    cards: cards,
    categories: categories,
    tags: tags,
    knownMerchants: knownMerchants,
    now: now,
    pack: pack,
  ).first;

  static VoiceActionDraft _draft(
    EntryReading e, {
    required List<UserCard> cards,
    required List<SpendCategory> categories,
    required List<TransactionTag> tags,
    required List<String> knownMerchants,
    required DateTime now,
    required LanguagePack pack,
  }) {
    if (e.kind == EntryKind.transfer) {
      return VoiceActionDraft(
        type: VoiceActionType.unsupported,
        transcript: e.text,
        notice: VoiceNotice.transfer,
        issues: const [
          'That looks like a transfer between your own accounts, so I didn’t add it as spending.',
        ],
      );
    }
    if (e.kind == EntryKind.billPayment) {
      return VoiceActionDraft(
        type: VoiceActionType.unsupported,
        transcript: e.text,
        notice: VoiceNotice.cardBillPayment,
        issues: const [
          'That looks like a card bill payment, not new spending, so I didn’t add it.',
        ],
      );
    }

    final type = switch (e.kind) {
      EntryKind.moneyIn => VoiceActionType.moneyIn,
      EntryKind.refund => VoiceActionType.refund,
      EntryKind.pointsRedemption => VoiceActionType.pointsRedemption,
      _ => VoiceActionType.expense,
    };
    final lower = e.text.toLowerCase();
    final clean = e.cleanText.toLowerCase();
    final words = _words(clean);
    final amount = e.foreign ? null : e.amount?.value;
    final instrument = _instrument(lower, pack, e.kind);
    final cardMatch = _resolveCard(lower, cards, e.cardDigits);
    final merchantRead = _merchant(
      clean,
      words,
      pack,
      knownMerchants,
      categories,
      incoming:
          e.kind == EntryKind.moneyIn || e.kind == EntryKind.refund,
    );
    final category = _category(words, categories, pack, merchantRead.slug);
    final issues = <String>[];

    if (e.foreign) {
      issues.add('Enter the rupee amount that was charged.');
    } else if (type == VoiceActionType.expense && amount == null) {
      issues.add('Add the spend amount.');
    } else if (type == VoiceActionType.moneyIn && amount == null) {
      issues.add('Add the amount received.');
    } else if (type == VoiceActionType.refund && amount == null) {
      issues.add('Add the refund amount.');
    }
    if (type == VoiceActionType.pointsRedemption && e.points == null) {
      issues.add('Add the number of points.');
    }
    final needsCard =
        type == VoiceActionType.pointsRedemption ||
        (type != VoiceActionType.moneyIn &&
            instrument == TxnInstrument.creditCard);
    if (cardMatch.ambiguous && needsCard) {
      issues.add('Choose the exact wallet card; more than one card matched.');
    } else if (cardMatch.card == null && needsCard) {
      issues.add('Choose the wallet card used for this entry.');
    }
    if (e.dateFuture) {
      issues.add('That date is in the future. Pick the day it happened.');
    }
    if (e.dateVague) {
      issues.add(
        'Pick the exact day; I heard “${e.dateSource ?? 'a stretch of days'}”.',
      );
    }

    DateTime? occurredAt;
    final d = e.date;
    if (d != null && d.isSingleDay && !e.dateFuture) {
      final today = DateTime(now.year, now.month, now.day);
      if (d.from != today) {
        occurredAt = DateTime(d.from.year, d.from.month, d.from.day, 12);
      }
    }

    final heard = <HeardPart>[];
    final amountRead = e.amount;
    if (amountRead != null) {
      if (amountRead.foreign) {
        heard.add(
          HeardPart(
            label: 'Amount',
            source: amountRead.source,
            shown: '${amountRead.currencyCode} ${_plain(amountRead.value)}',
          ),
        );
      } else {
        heard.add(
          HeardPart(
            label: 'Amount',
            source: amountRead.source,
            shown: VoiceFormat.rupees(amountRead.value),
          ),
        );
      }
      if (amountRead.correctedFrom != null) {
        heard.add(
          HeardPart(
            label: 'Corrected',
            source: amountRead.correctedFromSource ?? '',
            shown:
                '${VoiceFormat.rupees(amountRead.correctedFrom!)} → ${VoiceFormat.rupees(amountRead.value)}',
          ),
        );
      }
    }
    if (e.pointsSource != null) {
      heard.add(
        HeardPart(
          label: 'Points',
          source: e.pointsSource!,
          shown: '${e.points} points',
        ),
      );
    }
    if (d != null && e.dateSource != null && d.isSingleDay) {
      heard.add(
        HeardPart(
          label: 'Date',
          source: e.dateSource!,
          shown: VoiceFormat.day(d.from, now),
        ),
      );
    }
    for (final q in e.quantities) {
      heard.add(HeardPart(label: 'Not money', source: q, shown: q));
    }

    final alternatives = <DraftAlternative>[];
    if (amountRead != null && amountRead.alternative != null && !e.foreign) {
      alternatives.add(
        DraftAlternative(
          role: 'amount',
          label: '${VoiceFormat.rupees(amountRead.alternative!)}?',
          amount: amountRead.alternative,
        ),
      );
    }
    if (e.kindAlternative != null) {
      final altType = switch (e.kindAlternative!) {
        EntryKind.moneyIn => VoiceActionType.moneyIn,
        EntryKind.refund => VoiceActionType.refund,
        _ => VoiceActionType.expense,
      };
      alternatives.add(
        DraftAlternative(
          role: 'kind',
          label: switch (altType) {
            VoiceActionType.moneyIn => 'Money in?',
            VoiceActionType.refund => 'Refund?',
            _ => 'Spend?',
          },
          type: altType,
        ),
      );
    }
    final warnings = <String>[
      for (final l in e.leftovers) 'I also heard ${l.text} (${l.reason}).',
      if (amountRead != null && amountRead.weak)
        'I wasn’t sure ${amountRead.source} is the amount.',
    ];

    return VoiceActionDraft(
      type: type,
      transcript: e.text,
      amount: amount,
      points: e.points,
      merchant: merchantRead.name,
      userCardId: cardMatch.card?.id,
      categoryId: category?.id,
      instrument: instrument,
      tagIds: _matchingTagIds(words, tags),
      issues: issues,
      occurredAt: occurredAt,
      dateSource: e.dateSource,
      dateIsFuture: e.dateFuture,
      dateIsVague: e.dateVague,
      heard: heard,
      alternatives: alternatives,
      warnings: warnings,
      foreignCurrency: amountRead?.currencyCode,
      foreignAmount: e.foreign ? amountRead!.value : null,
      quantities: e.quantities,
    );
  }

  static String _plain(double v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(2);

  // ---- tags ---------------------------------------------------------------------

  /// Preselects every existing tag whose name appears verbatim
  /// (word-by-word, in order) in the transcript — saying "groceries at the
  /// food in office trip" attaches a "food in office" tag. Detection only
  /// preseeds the review sheet's editable tag field; it never creates tags.
  static List<String> _matchingTagIds(
    List<String> words,
    List<TransactionTag> tags,
  ) {
    if (tags.isEmpty) return const [];
    final matched = <String>[];
    for (final tag in tags) {
      final name = _words(tag.name.toLowerCase());
      if (name.isNotEmpty && _hasPhrase(words, name)) matched.add(tag.id);
    }
    return matched;
  }

  // ---- instrument and card -----------------------------------------------------------

  static TxnInstrument _instrument(
    String lower,
    LanguagePack pack,
    EntryKind kind,
  ) {
    final words = _words(lower);
    bool any(String key) =>
        (pack.instrumentWords[key] ?? const <String>[]).any(
          (phrase) => _hasPhrase(words, _words(phrase)),
        );
    if (any('credit')) return TxnInstrument.creditCard;
    if (any('debit')) return TxnInstrument.debitCard;
    if (any('cash')) return TxnInstrument.cash;
    if (any('upi')) return TxnInstrument.upiBank;
    if (any('wallet')) return TxnInstrument.wallet;
    return kind == EntryKind.moneyIn
        ? TxnInstrument.other
        : TxnInstrument.creditCard;
  }

  static ({UserCard? card, bool ambiguous}) _resolveCard(
    String text,
    List<UserCard> cards,
    String? digits,
  ) {
    final exact = <UserCard>[];
    for (final card in cards) {
      final aliases = <String>[
        card.cardName,
        if (card.nickname?.isNotEmpty == true) card.nickname!,
      ];
      final last4 = card.last4;
      if (last4 != null && (last4 == digits || text.contains(last4))) {
        exact.add(card);
      }
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

  // ---- words --------------------------------------------------------------------

  static List<String> _words(String text) => text
      .toLowerCase()
      .split(cachedRegExp(r"[^a-z0-9&]+"))
      .where((word) => word.isNotEmpty)
      .toList();

  static bool _hasPhrase(List<String> words, List<String> phrase) {
    if (phrase.isEmpty || phrase.length > words.length) return false;
    outer:
    for (var start = 0; start + phrase.length <= words.length; start++) {
      for (var i = 0; i < phrase.length; i++) {
        if (words[start + i] != phrase[i]) continue outer;
      }
      return true;
    }
    return false;
  }

  // ---- merchant -----------------------------------------------------------------

  static ({String? name, String? slug}) _merchant(
    String clean,
    List<String> words,
    LanguagePack pack,
    List<String> knownMerchants,
    List<SpendCategory> categories, {
    bool incoming = false,
  }) {
    // The user's own merchants, longest match first.
    String? own;
    for (final name in knownMerchants) {
      final nameWords = _words(name);
      if (nameWords.isEmpty || !_hasPhrase(words, nameWords)) continue;
      if (own == null || name.length > own.length) own = name;
    }
    if (own != null) return (name: own, slug: null);

    final brand = FlashTextMerchantExtractor.defaultExtractor.extractFirst(
      clean,
    );
    if (brand != null) return (name: brand.canonicalName, slug: brand.category);

    final phrase = _objectPhrase(words, pack, incoming: incoming);
    if (phrase == null) return (name: null, slug: null);
    // A bare category word ("on groceries") is the category, not a merchant.
    final phraseWords = _words(phrase);
    for (final entry in pack.categoryTerms.entries) {
      if (entry.value.any(
        (t) => _words(t).join(' ') == phraseWords.join(' '),
      )) {
        return (name: null, slug: null);
      }
    }
    for (final c in categories) {
      final names = [c.name, c.slug, ...c.matchTerms];
      if (names.any((n) => _words(n).join(' ') == phraseWords.join(' '))) {
        return (name: null, slug: null);
      }
    }
    return (name: _titleCase(phrase), slug: null);
  }

  /// What was bought or paid for: the words after "buy", "bought", "on",
  /// "at" or "for", up to the next clause word.
  static String? _objectPhrase(
    List<String> words,
    LanguagePack pack, {
    bool incoming = false,
  }) {
    const buyVerbs = {
      'buy',
      'buying',
      'bought',
      'purchase',
      'purchased',
      'ordered',
      'order',
      'booked',
      'book',
    };
    String? fromIndex(int i) {
      var j = i + 1;
      while (j < words.length && pack.determiners.contains(words[j])) {
        j++;
      }
      if (j >= words.length) return null;
      if (const {'my', 'me', 'our', 'your'}.contains(words[j])) return null;
      final out = <String>[];
      while (j < words.length &&
          out.length < 4 &&
          !pack.phraseStops.contains(words[j]) &&
          !pack.objectPrepositions.contains(words[j]) &&
          !pack.conjunctions.contains(words[j])) {
        out.add(words[j]);
        j++;
      }
      if (out.isEmpty) return null;
      final phrase = out.join(' ');
      if (phrase.length > 36) return null;
      if (_isInstrumentPhrase(out, pack)) return null;
      if (out.every(
        (w) =>
            pack.fillers.contains(w) ||
            pack.pronouns.contains(w) ||
            pack.determiners.contains(w) ||
            pack.amountLeadVerbs.contains(w),
      )) {
        return null;
      }
      return phrase;
    }

    if (incoming) {
      // "received 5000 from Rahul", "refund of 500 from Amazon"
      for (var i = 0; i < words.length; i++) {
        if (words[i] == 'from') {
          final p = fromIndex(i);
          if (p != null) return p;
        }
      }
    }
    for (var i = 0; i < words.length; i++) {
      if (buyVerbs.contains(words[i])) {
        final p = fromIndex(i);
        if (p != null) return p;
      }
    }
    for (var i = 0; i < words.length; i++) {
      if (const {'on', 'at', 'for'}.contains(words[i])) {
        final p = fromIndex(i);
        if (p != null) return p;
      }
    }
    return null;
  }

  static bool _isInstrumentPhrase(List<String> words, LanguagePack pack) {
    for (final phrases in pack.instrumentWords.values) {
      for (final phrase in phrases) {
        if (_hasPhrase(words, _words(phrase))) return true;
      }
    }
    return words.contains('card') || words.contains('cards');
  }

  static String _titleCase(String value) => value
      .trim()
      .split(cachedRegExp(r'\s+'))
      .where((word) => word.isNotEmpty)
      .map(
        (word) => '${word[0].toUpperCase()}${word.substring(1).toLowerCase()}',
      )
      .join(' ');

  // ---- category -------------------------------------------------------------------

  static SpendCategory? _category(
    List<String> words,
    List<SpendCategory> categories,
    LanguagePack pack,
    String? merchantSlug,
  ) {
    SpendCategory? bySlug(String slug) {
      for (final c in categories) {
        if (c.slug == slug) return c;
      }
      return null;
    }

    // The user's own categories and their match terms come first, longest
    // phrase wins, so a custom "Fast food" beats the built-in "food".
    SpendCategory? best;
    var bestLength = 0;
    for (final c in categories) {
      final names = <String>[c.name, if (!c.isCustom) c.slug, ...c.matchTerms];
      for (final n in names) {
        final nw = _words(n);
        if (nw.isEmpty || !_hasPhrase(words, nw)) continue;
        final length = nw.join(' ').length;
        if (length > bestLength) {
          best = c;
          bestLength = length;
        }
      }
    }
    if (best != null) return best;
    if (merchantSlug != null) {
      final c = bySlug(merchantSlug);
      if (c != null) return c;
    }
    for (final entry in pack.categoryTerms.entries) {
      if (entry.value.any((t) => _hasPhrase(words, _words(t)))) {
        final c = bySlug(entry.key);
        if (c != null) return c;
      }
    }
    return null;
  }
}
