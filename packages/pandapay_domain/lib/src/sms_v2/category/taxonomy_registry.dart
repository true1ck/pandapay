/// One spend category in the taxonomy.
class TaxonomyCategory {
  const TaxonomyCategory({
    required this.slug,
    required this.displayName,
    required this.iconKey,
    this.deprecatedAliases = const [],
  });

  /// Stable identifier, stored on ledger entries and in user rules. Never
  /// renamed; a retired slug stays in some category's [deprecatedAliases].
  final String slug;

  /// The name the screens show (same as `spend_categories.name`).
  final String displayName;

  /// A Material icon name, without the `Icons.` prefix and `_rounded` suffix.
  final String iconKey;

  /// Older slugs that now mean this category.
  final List<String> deprecatedAliases;
}

/// The versioned list of spend categories (taxonomy v1).
///
/// `income` and `investments` are event types, not spend categories, so they
/// are not here. A category is never renamed: it is deprecated and given an
/// alias, so stored rows and user rules keep resolving.
class TaxonomyRegistry {
  /// Builds a registry. Throws [ArgumentError] when a slug or alias is used
  /// twice, so an alias can never be ambiguous.
  factory TaxonomyRegistry({required int version, required List<TaxonomyCategory> categories}) {
    final bySlug = <String, TaxonomyCategory>{};
    final aliases = <String, String>{};
    for (final c in categories) {
      if (bySlug.containsKey(c.slug) || aliases.containsKey(c.slug)) {
        throw ArgumentError('Duplicate taxonomy slug ${c.slug}');
      }
      bySlug[c.slug] = c;
    }
    for (final c in categories) {
      for (final a in c.deprecatedAliases) {
        if (bySlug.containsKey(a) || aliases.containsKey(a)) {
          throw ArgumentError('Alias $a of ${c.slug} is already a slug or alias');
        }
        aliases[a] = c.slug;
      }
    }
    return TaxonomyRegistry._(
      version,
      List.unmodifiable(categories),
      Map.unmodifiable(bySlug),
      Map.unmodifiable(aliases),
    );
  }

  const TaxonomyRegistry._(this.version, this.categories, this._bySlug, this._aliases);

  /// The shipped registry. Bundles carry `taxonomyVersion`, which this matches.
  static final TaxonomyRegistry v1 = TaxonomyRegistry(version: 1, categories: _v1Categories);

  /// The slug of the fallback category.
  static const String otherSlug = 'other';

  final int version;
  final List<TaxonomyCategory> categories;
  final Map<String, TaxonomyCategory> _bySlug;

  /// Deprecated slug to the current slug.
  final Map<String, String> _aliases;

  /// Current slugs in display order.
  List<String> get slugs => [for (final c in categories) c.slug];

  /// Deprecated slug to current slug.
  Map<String, String> get deprecatedAliases => _aliases;

  /// True when [slug] is a current (not deprecated) slug.
  bool contains(String slug) => _bySlug.containsKey(slug);

  /// The category for [slug] or one of its deprecated aliases, or null.
  TaxonomyCategory? categoryFor(String? slug) {
    final canonical = canonicalSlug(slug);
    return canonical == null ? null : _bySlug[canonical];
  }

  /// The current slug for [slug] (lower-cased, trimmed, alias-resolved), or
  /// null when it is not in the taxonomy.
  String? canonicalSlug(String? slug) {
    if (slug == null) return null;
    final s = slug.trim().toLowerCase();
    if (_bySlug.containsKey(s)) return s;
    return _aliases[s];
  }

  /// Maps [slug] to the id of today's category row, through the category
  /// catalogue the app already loads (`GET /categories`, slug to id). Stored
  /// rows keep the ids they have. Returns null when the catalogue has no row
  /// for the slug.
  String? categoryIdForSlug(String slug, Map<String, String> idBySlug) {
    final canonical = canonicalSlug(slug);
    if (canonical == null) return null;
    final direct = idBySlug[canonical];
    if (direct != null) return direct;
    for (final alias in _bySlug[canonical]!.deprecatedAliases) {
      final viaAlias = idBySlug[alias];
      if (viaAlias != null) return viaAlias;
    }
    return null;
  }
}

const List<TaxonomyCategory> _v1Categories = [
  TaxonomyCategory(slug: 'groceries', displayName: 'Groceries', iconKey: 'local_grocery_store'),
  TaxonomyCategory(slug: 'fuel', displayName: 'Fuel', iconKey: 'local_gas_station'),
  TaxonomyCategory(slug: 'dining', displayName: 'Dining', iconKey: 'restaurant'),
  TaxonomyCategory(slug: 'online', displayName: 'Online Shopping', iconKey: 'shopping_bag'),
  TaxonomyCategory(slug: 'travel', displayName: 'Travel', iconKey: 'flight_takeoff'),
  TaxonomyCategory(slug: 'bills', displayName: 'Bills & Utilities', iconKey: 'receipt_long'),
  TaxonomyCategory(slug: 'rent', displayName: 'Rent', iconKey: 'home_work'),
  TaxonomyCategory(slug: 'insurance', displayName: 'Insurance', iconKey: 'verified_user'),
  TaxonomyCategory(slug: 'education', displayName: 'Education', iconKey: 'school'),
  TaxonomyCategory(slug: 'government', displayName: 'Government', iconKey: 'account_balance'),
  TaxonomyCategory(slug: 'wallet', displayName: 'Wallet Load', iconKey: 'account_balance_wallet'),
  TaxonomyCategory(slug: 'entertainment', displayName: 'Entertainment', iconKey: 'movie'),
  TaxonomyCategory(slug: 'health', displayName: 'Health & Pharmacy', iconKey: 'local_hospital'),
  TaxonomyCategory(slug: 'emi', displayName: 'EMI', iconKey: 'event_repeat'),
  TaxonomyCategory(slug: 'other', displayName: 'Other', iconKey: 'category'),
];
