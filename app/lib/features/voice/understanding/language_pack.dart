/// One piece of evidence for what kind of entry a clause is: the words
/// [words] (adjacent, in order) add [weight] to [kind] (`spend`, `income`,
/// `refund` or `transfer`).
class Cue {
  const Cue(this.kind, this.words, this.weight);

  final String kind;
  final List<String> words;
  final double weight;
}

/// Everything that depends on the spoken language lives in a pack: word
/// tables only. The roles, scoring and solver in this folder are
/// language-neutral, so adding Hindi or Marathi later means writing a pack
/// and its tests, not changing the engine.
class LanguagePack {
  const LanguagePack({
    required this.code,
    required this.recognizerLocales,
    required this.fillers,
    required this.numberUnits,
    required this.numberTens,
    required this.hundredWords,
    required this.magnitudeWords,
    required this.magnitudeSuffixes,
    required this.ordinalSuffixes,
    required this.timeSuffixes,
    required this.currencySuffixes,
    required this.pointWords,
    required this.andWords,
    required this.halfWords,
    required this.articleWords,
    required this.currencyWords,
    required this.currencySymbols,
    required this.foreignCurrencies,
    required this.monthNames,
    required this.weekdayNames,
    required this.ordinalWords,
    required this.todayWords,
    required this.yesterdayWords,
    required this.lastWords,
    required this.thisWords,
    required this.nextWords,
    required this.pastWords,
    required this.agoWords,
    required this.unitWords,
    required this.partOfDayWords,
    required this.beforeWords,
    required this.sinceWords,
    required this.rangeStartWords,
    required this.rangeJoinWords,
    required this.monthPrepositions,
    required this.financialWords,
    required this.fyWords,
    required this.ofWords,
    required this.theWords,
    required this.timePhrases,
    required this.kindCues,
    required this.amountLeadVerbs,
    required this.amountLeadPrepositions,
    required this.objectPrepositions,
    required this.questionStarters,
    required this.correctionStrong,
    required this.correctionWeak,
    required this.correctionPhrases,
    required this.correctionConnectors,
    required this.quantityUnits,
    required this.notPlural,
    required this.pluralSuffixes,
    required this.pointsWords,
    required this.pointsRedeemVerbs,
    required this.billWords,
    required this.cardWords,
    required this.statementWords,
    required this.conjunctions,
    required this.addCardVerbs,
    required this.addCardMiddle,
    required this.addCardBlockers,
    required this.cardEndingWords,
    required this.digitConnectors,
    required this.dayPrefixWords,
    required this.percentWords,
    required this.pronouns,
    required this.categoryTerms,
    required this.instrumentWords,
    required this.determiners,
    required this.phraseStops,
  });

  /// `en`, `hi`, ...
  final String code;

  /// Recognizer locale ids in order of preference, e.g. `en_IN`, `en_US`.
  final List<String> recognizerLocales;

  /// Words that carry no meaning in a dictated sentence ("um", "like").
  final Set<String> fillers;

  /// zero..nineteen.
  final Map<String, int> numberUnits;

  /// twenty..ninety.
  final Map<String, int> numberTens;

  /// Words meaning one hundred ("hundred").
  final Set<String> hundredWords;

  /// thousand, lakh, crore, million as spoken words.
  final Map<String, double> magnitudeWords;

  /// Magnitudes glued to digits: `1.5k`, `2cr`, `3lakh`.
  final Map<String, double> magnitudeSuffixes;
  final Set<String> ordinalSuffixes;
  final Set<String> timeSuffixes;
  final Set<String> currencySuffixes;
  final Set<String> pointWords;
  final Set<String> andWords;
  final Set<String> halfWords;
  final Set<String> articleWords;

  /// Words for the home currency (rupees).
  final Set<String> currencyWords;
  final Set<String> currencySymbols;

  /// Foreign currency word or symbol -> ISO code.
  final Map<String, String> foreignCurrencies;

  /// january..december and short forms -> 1..12.
  final Map<String, int> monthNames;

  /// monday..sunday -> 1..7 (Monday is 1).
  final Map<String, int> weekdayNames;

  /// first..twentieth, thirtieth -> 1..30; "twenty first" is built from a
  /// tens word plus a single-digit ordinal.
  final Map<String, int> ordinalWords;
  final Set<String> todayWords;
  final Set<String> yesterdayWords;
  final Set<String> lastWords;
  final Set<String> thisWords;
  final Set<String> nextWords;

  /// "past" and "previous" style words that mean a rolling window.
  final Set<String> pastWords;
  final Set<String> agoWords;

  /// day, days, week, weeks, month, quarter, year -> canonical unit.
  final Map<String, String> unitWords;
  final Set<String> partOfDayWords;
  final Set<String> beforeWords;
  final Set<String> sinceWords;
  final Set<String> rangeStartWords;
  final Set<String> rangeJoinWords;
  final Set<String> monthPrepositions;
  final Set<String> financialWords;
  final Set<String> fyWords;
  final Set<String> ofWords;
  final Set<String> theWords;

  /// Fixed multi-word phrases by meaning: `allTime`, `yearToDate`,
  /// `monthToDate`.
  final Map<String, List<List<String>>> timePhrases;

  /// Evidence for spend, money in, refund and transfer.
  final List<Cue> kindCues;

  /// Verbs and nouns that introduce an amount ("spent", "salary").
  final Set<String> amountLeadVerbs;

  /// Words that introduce an amount only when they sit right before it.
  final Set<String> amountLeadPrepositions;

  /// Words after an amount that introduce what it was for ("on", "at").
  final Set<String> objectPrepositions;
  final Set<String> questionStarters;
  final Set<String> correctionStrong;
  final Set<String> correctionWeak;
  final List<List<String>> correctionPhrases;

  /// Words that may sit between a correction cue and the new value.
  final Set<String> correctionConnectors;

  /// Nouns that mean a quantity rather than money ("3 people", "2 kg").
  final Set<String> quantityUnits;

  /// Words that end in a plural suffix but are not plural nouns.
  final Set<String> notPlural;
  final List<String> pluralSuffixes;
  final Set<String> pointsWords;
  final Set<String> pointsRedeemVerbs;
  final Set<String> billWords;
  final Set<String> cardWords;
  final Set<String> statementWords;
  final Set<String> conjunctions;
  final Set<String> addCardVerbs;
  final Set<String> addCardMiddle;

  /// Words that show a sentence is logging a spend, not adding a card.
  final Set<String> addCardBlockers;
  final Set<String> cardEndingWords;
  final Set<String> digitConnectors;

  /// Words that may come before a bare ordinal day ("on the 3rd").
  final Set<String> dayPrefixWords;
  final Set<String> percentWords;
  final Set<String> pronouns;

  /// Category slug -> words and phrases that point at it.
  final Map<String, List<String>> categoryTerms;

  /// Instrument key (`cash`, `upi`, `debit`, `credit`, `wallet`) -> phrases.
  final Map<String, List<String>> instrumentWords;

  /// Words skipped at the front of an object phrase ("a", "some", "the").
  final Set<String> determiners;

  /// Words that end an object phrase ("using", "with", "and").
  final Set<String> phraseStops;
}
