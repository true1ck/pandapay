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
}
