/// The words the owner-identity code needs, kept as data.
///
/// Honorifics ("Mr", "Shri"), the greeting words a service opens a message with
/// ("Dear", "Hi") and the stock words that follow a greeting but are not a name
/// ("Customer", "Sir") are language, and they differ by country. They live in the
/// signed solver pack (`rules/sms/solver/pack.json`, `params.ownerIdentity`), so
/// they change with a rules update and not an app release. The thresholds for
/// believing a learned name live there too.
///
/// A pack without the section gives [empty]: no honorific is stripped and no name
/// is learned from a greeting. The matcher still works on what the person typed.
/// Older apps ignore the section, because `params` is a free object.
library;

class OwnerVocabulary {
  const OwnerVocabulary({
    this.honorifics = const {},
    this.greetingWords = const [],
    this.notNames = const {},
    this.minSightings = 3,
    this.minSenders = 3,
    this.maxLearned = 3,
  });

  /// Nothing known: no honorifics, no greeting words.
  static const empty = OwnerVocabulary();

  /// Words that come before a name and are not part of it (upper case).
  final Set<String> honorifics;

  /// Words a message opens with before the person's name (lower case).
  final List<String> greetingWords;

  /// Words after a greeting that are not a person's name (upper case).
  final Set<String> notNames;

  /// A learned name needs this many sightings, from [minSenders] different
  /// senders, and at most [maxLearned] names are kept.
  final int minSightings;
  final int minSenders;
  final int maxLearned;

  /// Reads the `ownerIdentity` section of the pack's `params`. Anything missing
  /// or of the wrong type falls back to nothing (or the numeric default).
  factory OwnerVocabulary.fromJson(Object? json) {
    if (json is! Map) return empty;
    Set<String> upper(Object? v) => {
      if (v is List)
        for (final e in v)
          if (e is String && e.trim().isNotEmpty) e.trim().toUpperCase(),
    };
    int count(Object? v, int fallback) =>
        v is num && v >= 1 && v <= 50 ? v.toInt() : fallback;
    return OwnerVocabulary(
      honorifics: upper(json['honorifics']),
      greetingWords: [
        for (final w in upper(json['greetingWords']))
          if (RegExp(r'^[A-Z]{2,20}$').hasMatch(w)) w.toLowerCase(),
      ],
      notNames: upper(json['notNames']),
      minSightings: count(json['minSightings'], 3),
      minSenders: count(json['minSenders'], 3),
      maxLearned: count(json['maxLearned'], 3),
    );
  }

  /// The vocabulary in use in this isolate, set from the active rule bundle.
  /// Each isolate compiles its own bundle, so each installs its own.
  static OwnerVocabulary get current => _current;
  static OwnerVocabulary _current = empty;

  static void install(OwnerVocabulary vocabulary) {
    _current = vocabulary;
    _greeting = null;
  }

  /// Reads the pack's `params` and installs the section when it has one. A pack
  /// without it leaves the vocabulary as it was.
  static void installFromPackParams(Object? params) {
    if (params is Map && params.containsKey('ownerIdentity')) {
      install(OwnerVocabulary.fromJson(params['ownerIdentity']));
    }
  }

  static RegExp? _greeting;

  /// "Dear Ishaan Dattatray Rangnekar," built from the greeting words and the
  /// honorifics, or null when there are no greeting words.
  RegExp? get greetingPattern {
    if (greetingWords.isEmpty) return null;
    final cached = identical(this, _current) ? _greeting : null;
    if (cached != null) return cached;
    final greet = greetingWords.map(RegExp.escape).join('|');
    final honor = honorifics.isEmpty
        ? ''
        : '(?:(?:${honorifics.map((h) => RegExp.escape(h.toLowerCase())).join('|')})\\.?\\s+)?';
    final pattern = RegExp(
      '\\b(?:$greet)\\s+$honor'
      r'([A-Za-z]{2,20}(?:\s+[A-Za-z]{1,20}){1,3}?)\s*[,:!\-]',
      caseSensitive: false,
    );
    if (identical(this, _current)) _greeting = pattern;
    return pattern;
  }
}
