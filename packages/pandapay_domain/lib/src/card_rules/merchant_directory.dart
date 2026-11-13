/// Merchant and payment-platform directory (plan C5).
///
/// Turns the raw merchant text a transaction arrives with (SMS, UPI QR,
/// search) into a stable merchant slug, plus that merchant's ancestors, so
/// a rule written for `swiggy` also pays at its sub-brand `instamart`. The
/// algorithm is shared with the server engine (api/src/merchant_directory.js)
/// and must stay identical to it.
library;

/// C5 step 1: lowercase, every run of characters outside `[a-z0-9]`
/// becomes one space, then trim. 'BUNDL  TECHNOLOGIES-PVT' →
/// 'bundl technologies pvt'.
String normalizeMerchantText(String value) =>
    value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();

List<String> _strings(Object? raw) => raw is List
    ? [
        for (final e in raw)
          if (e is String) e,
      ]
    : const [];

/// One `merchant_brands` row / directory entry.
class DirectoryMerchant {
  final String slug;
  final String name;

  /// "The same merchant for reward purposes" (plan C8/D6): a rule on the
  /// parent also pays here.
  final String? parentSlug;
  final String? categorySlug;
  final List<String> aliases;
  final List<String> vpaPrefixes;
  final List<String> mcc;

  /// Corporate group (C8/D6). Informational; engines ignore it.
  final String? group;
  final String? notes;
  final bool isActive;

  const DirectoryMerchant({
    required this.slug,
    required this.name,
    this.parentSlug,
    this.categorySlug,
    this.aliases = const [],
    this.vpaPrefixes = const [],
    this.mcc = const [],
    this.group,
    this.notes,
    this.isActive = true,
  });

  factory DirectoryMerchant.fromJson(Map<String, dynamic> json) =>
      DirectoryMerchant(
        slug: json['slug'] as String,
        name: (json['name'] as String?) ?? json['slug'] as String,
        parentSlug: json['parent_slug'] as String?,
        categorySlug: json['category_slug'] as String?,
        aliases: _strings(json['aliases']),
        vpaPrefixes: _strings(json['vpa_prefixes']),
        mcc: _strings(json['mcc']),
        group: json['group'] as String?,
        notes: json['notes'] as String?,
        isActive: json['is_active'] as bool? ?? true,
      );

  Map<String, dynamic> toJson() => {
    'slug': slug,
    'name': name,
    'parent_slug': parentSlug,
    'category_slug': categorySlug,
    'aliases': aliases,
    'vpa_prefixes': vpaPrefixes,
    'mcc': mcc,
    if (group != null) 'group': group,
    if (notes != null) 'notes': notes,
    if (!isActive) 'is_active': false,
  };
}

/// One `payment_platforms` row: a payment app, bank portal, merchant app or
/// network programme a rule can be restricted to.
class DirectoryPlatform {
  final String slug;
  final String name;

  /// `payment_app` / `bank_portal` / `merchant_app` / `network_program`.
  /// Kept as text so a new kind never fails the directory.
  final String? kind;
  final String? issuerSlug;
  final List<String> aliases;
  final String? notes;
  final bool isActive;

  const DirectoryPlatform({
    required this.slug,
    required this.name,
    this.kind,
    this.issuerSlug,
    this.aliases = const [],
    this.notes,
    this.isActive = true,
  });

  factory DirectoryPlatform.fromJson(Map<String, dynamic> json) =>
      DirectoryPlatform(
        slug: json['slug'] as String,
        name: (json['name'] as String?) ?? json['slug'] as String,
        kind: json['kind'] as String?,
        issuerSlug: json['issuer_slug'] as String?,
        aliases: _strings(json['aliases']),
        notes: json['notes'] as String?,
        isActive: json['is_active'] as bool? ?? true,
      );

  Map<String, dynamic> toJson() => {
    'slug': slug,
    'name': name,
    'kind': kind,
    'issuer_slug': issuerSlug,
    'aliases': aliases,
    if (notes != null) 'notes': notes,
    if (!isActive) 'is_active': false,
  };
}

/// How a merchant slug was arrived at.
enum MerchantMatchSource {
  /// The caller passed the slug (`RecommendationContext.merchantSlug`).
  context,

  /// The UPI VPA's handle started with one of the merchant's VPA prefixes.
  vpa,

  /// One of the merchant's aliases appeared in the merchant text.
  alias,
}

/// The outcome of [MerchantDirectory.resolve].
class MerchantMatch {
  final String slug;
  final MerchantMatchSource source;

  /// The normalized VPA prefix or alias that matched.
  final String? matched;

  /// [slug] first, then its ancestors, nearest first.
  final List<String> lineage;

  const MerchantMatch({
    required this.slug,
    required this.source,
    this.matched,
    required this.lineage,
  });
}

class _Candidate {
  final String key; // normalized alias or VPA prefix
  final String slug;
  const _Candidate(this.key, this.slug);
}

/// The C5 directory with its resolver. Build once per catalogue load.
class MerchantDirectory {
  /// C5 step 4.
  static const int maxAncestorDepth = 5;

  final List<DirectoryMerchant> merchants;
  final List<DirectoryPlatform> platforms;

  /// Entries that could not be read (missing slug etc.), one line each.
  final List<String> parseWarnings;

  final Map<String, DirectoryMerchant> _bySlug;
  final List<_Candidate> _aliases;
  final List<_Candidate> _vpaPrefixes;
  final List<_Candidate> _platformAliases;

  MerchantDirectory({
    List<DirectoryMerchant> merchants = const [],
    List<DirectoryPlatform> platforms = const [],
    List<String> parseWarnings = const [],
  }) : merchants = List.unmodifiable(merchants),
       platforms = List.unmodifiable(platforms),
       parseWarnings = List.unmodifiable(parseWarnings),
       _bySlug = {for (final m in merchants) m.slug: m},
       _aliases = [
         for (final m in merchants)
           if (m.isActive)
             for (final a in m.aliases)
               _Candidate(normalizeMerchantText(a), m.slug),
       ].where((c) => c.key.isNotEmpty).toList(),
       _vpaPrefixes = [
         for (final m in merchants)
           if (m.isActive)
             for (final p in m.vpaPrefixes)
               _Candidate(normalizeMerchantText(p), m.slug),
       ].where((c) => c.key.isNotEmpty).toList(),
       _platformAliases = [
         for (final p in platforms)
           if (p.isActive)
             for (final a in p.aliases)
               _Candidate(normalizeMerchantText(a), p.slug),
       ].where((c) => c.key.isNotEmpty).toList();

  static final MerchantDirectory empty = MerchantDirectory();

  /// Reads the C5 file (`db/fixtures/merchant_directory.json`), the
  /// `merchants`/`platforms` keys of the v2 catalogue feed (C2), or a
  /// scenario file's `directory` — they share one shape. Unreadable
  /// entries are skipped and listed in [parseWarnings].
  factory MerchantDirectory.fromJson(Map<String, dynamic> json) {
    final warnings = <String>[];
    List<T> read<T>(String key, T Function(Map<String, dynamic>) parse) {
      final out = <T>[];
      for (final raw in (json[key] as List?) ?? const []) {
        try {
          out.add(parse(raw as Map<String, dynamic>));
        } on TypeError catch (e) {
          warnings.add('$key entry skipped: $e');
        }
      }
      return out;
    }

    return MerchantDirectory(
      merchants: read('merchants', DirectoryMerchant.fromJson),
      platforms: read('platforms', DirectoryPlatform.fromJson),
      parseWarnings: warnings,
    );
  }

  Map<String, dynamic> toJson() => {
    'merchants': merchants.map((m) => m.toJson()).toList(),
    'platforms': platforms.map((p) => p.toJson()).toList(),
  };

  DirectoryMerchant? merchant(String slug) => _bySlug[slug];

  /// [slug] followed by its ancestors via `parent_slug`, nearest first, at
  /// most [maxAncestorDepth] ancestors, stopping at a cycle (C5 step 4). A
  /// declared parent that has no entry of its own is still included.
  List<String> lineage(String slug) {
    final out = <String>[slug];
    var current = _bySlug[slug];
    for (var depth = 0; depth < maxAncestorDepth; depth++) {
      final parent = current?.parentSlug;
      if (parent == null || parent.isEmpty || out.contains(parent)) break;
      out.add(parent);
      current = _bySlug[parent];
    }
    return out;
  }

  /// C5 resolution. A VPA match wins (step 2); otherwise the longest alias
  /// that appears in the merchant text on word boundaries (step 3). Ties go
  /// to the slug that sorts first. Null when nothing matches.
  MerchantMatch? resolve({String? merchantName, String? vpa}) {
    if (vpa != null) {
      final at = vpa.indexOf('@');
      final handle = normalizeMerchantText(
        at >= 0 ? vpa.substring(0, at) : vpa,
      );
      if (handle.isNotEmpty) {
        final best = _best(_vpaPrefixes.where((c) => handle.startsWith(c.key)));
        if (best != null) {
          return MerchantMatch(
            slug: best.slug,
            source: MerchantMatchSource.vpa,
            matched: best.key,
            lineage: lineage(best.slug),
          );
        }
      }
    }
    if (merchantName != null) {
      final text = ' ${normalizeMerchantText(merchantName)} ';
      if (text.trim().isNotEmpty) {
        final best =
            _best(_aliases.where((c) => text.contains(' ${c.key} '))) ??
            _cutShort(text.trim());
        if (best != null) {
          return MerchantMatch(
            slug: best.slug,
            source: MerchantMatchSource.alias,
            matched: best.key,
            lineage: lineage(best.slug),
          );
        }
      }
    }
    return null;
  }

  /// A bank prints merchant text in a fixed number of characters, so the last
  /// word is often cut short ("PYU*Flipkar", "Flipka"). When no alias matched
  /// as whole words, accept an alias whose LAST word is the text's last word
  /// with one to three letters missing. The text's last word must be at least
  /// [minCutWord] letters (a short stub names nothing), and any earlier words
  /// of a multi-word alias must match whole. The server's JS twin applies the
  /// same rule (api/src/merchant_directory.js).
  static const int minCutWord = 6;
  static const int maxCutLetters = 3;

  _Candidate? _cutShort(String text) {
    final words = text.split(' ');
    final last = words.last;
    if (last.length < minCutWord) return null;
    final before = ' ${words.sublist(0, words.length - 1).join(' ')} ';
    _Candidate? best;
    for (final c in _aliases) {
      final parts = c.key.split(' ');
      final tail = parts.last;
      final missing = tail.length - last.length;
      if (missing < 1 || missing > maxCutLetters || !tail.startsWith(last)) {
        continue;
      }
      final head = parts.sublist(0, parts.length - 1).join(' ');
      if (head.isNotEmpty && !before.endsWith(' $head ')) continue;
      best = _best(best == null ? [c] : [best, c]);
    }
    return best;
  }

  /// The platform whose alias appears in [text] (same word-boundary,
  /// longest-wins rule as merchants). For callers that build a
  /// `RecommendationContext`: the engine itself never infers a platform.
  String? resolvePlatform(String? text) {
    if (text == null) return null;
    final normalized = ' ${normalizeMerchantText(text)} ';
    if (normalized.trim().isEmpty) return null;
    return _best(
      _platformAliases.where((c) => normalized.contains(' ${c.key} ')),
    )?.slug;
  }

  /// Longest key wins; ties go to the slug that sorts first, then the key.
  static _Candidate? _best(Iterable<_Candidate> candidates) {
    _Candidate? best;
    for (final c in candidates) {
      if (best == null ||
          c.key.length > best.key.length ||
          (c.key.length == best.key.length &&
              (c.slug.compareTo(best.slug) < 0 ||
                  (c.slug == best.slug && c.key.compareTo(best.key) < 0)))) {
        best = c;
      }
    }
    return best;
  }
}
