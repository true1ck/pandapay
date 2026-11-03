import '../contract/enums.dart';
import '../contract/interfaces.dart';
import '../contract/rule_bundle.dart';
import 'merchant_key.dart';
import 'taxonomy_registry.dart';

/// A [CategoryInput] that also carries the AI suggestion of an AI fact
/// (precedence row 5). The contract's [CategoryInput] has no field for it, so
/// the extra value rides on a subclass and plain inputs keep working.
class ResolverInput extends CategoryInput {
  const ResolverInput({
    super.counterparty,
    required super.senderBrand,
    super.contextTokens,
    super.mcc,
    super.userRules,
    super.bundleRules,
    super.confirmedHistory,
    this.aiSuggestion,
  });

  /// The category slug the AI proposed for this merchant, or null.
  final String? aiSuggestion;
}

/// Confidence given to each precedence row.
abstract final class CategoryConfidence {
  static const double user = 1.0;
  static const double sharedRule = 0.95;
  static const double catalogueExact = 0.9;
  static const double catalogueToken = 0.8;
  static const double history = 0.85;
  static const double ai = 0.6;
  static const double fallback = 0.0;
}

/// Event types that get a category on their ledger entry. A refund inherits.
const Set<EventType> categorisedEventTypes = {
  EventType.purchase,
  EventType.subscriptionCharge,
  EventType.fee,
  EventType.emi,
  EventType.billPayment,
  EventType.atmWithdrawal,
  EventType.p2pOut,
  EventType.refund,
};

/// One category resolver for every spend, however it was parsed.
///
/// Matching is on the merchant key only, never on the message. The first hit
/// wins:
///
/// 1. the user's own rule for this merchant key (confidence 1.0)
/// 2. bundle rules with source `shared` (the contract's name for admin and
///    shared rules), highest priority first (0.95)
/// 3. bundle rules with source `catalogue`: whole-token match, longest match
///    first (0.9 when the rule key is the whole merchant key, 0.8 otherwise)
/// 4. a category the user confirmed before for this merchant key (0.85)
/// 5. the AI suggestion (0.6)
/// 6. `other`, confidence 0, source `default`
class DefaultCategoryResolver implements CategoryResolver {
  DefaultCategoryResolver({
    Iterable<MerchantAlias> aliases = const [],
    TaxonomyRegistry? registry,
  })  : registry = registry ?? TaxonomyRegistry.v1,
        keyer = MerchantKeyer(aliases);

  final TaxonomyRegistry registry;
  final MerchantKeyer keyer;

  final Expando<List<_Compiled>> _compiled = Expando<List<_Compiled>>('compiled category rules');

  /// Resolves a category for one spend. Always returns a decision; with no
  /// match it is `other`, source `default`, confidence 0.
  @override
  CategoryDecision resolve(CategoryInput input) {
    final key = keyer.keyFor(input.counterparty);
    if (key != null) {
      final ctx = _contextOf(input);

      final user = _best(_rulesOf(input.userRules), {key}, input.senderBrand, ctx, _compareUser, (s) => s == CategorySource.user);
      if (user != null) return _decide(user, CategorySource.user, CategoryConfidence.user, 'user');

      final shared = _best(_rulesOf(input.bundleRules), {key}, input.senderBrand, ctx, _comparePriorityFirst, (s) => s == CategorySource.shared);
      if (shared != null) return _decide(shared, CategorySource.shared, CategoryConfidence.sharedRule, 'shared');

      final catalogue = _best(_rulesOf(input.bundleRules), {key}, input.senderBrand, ctx, _compareLongestFirst, (s) => s == CategorySource.catalogue);
      if (catalogue != null) {
        final exact = catalogue.whole;
        return _decide(
          catalogue,
          CategorySource.catalogue,
          exact ? CategoryConfidence.catalogueExact : CategoryConfidence.catalogueToken,
          'catalogue',
        );
      }

      final confirmed = registry.canonicalSlug(input.confirmedHistory[key]);
      if (confirmed != null) {
        return CategoryDecision(
          slug: confirmed,
          source: CategorySource.historyConfirmed,
          ruleId: 'history_confirmed:$key',
          confidence: CategoryConfidence.history,
        );
      }
    }

    if (input is ResolverInput) {
      final ai = registry.canonicalSlug(input.aiSuggestion);
      if (ai != null && ai != TaxonomyRegistry.otherSlug) {
        return CategoryDecision(slug: ai, source: CategorySource.ai, confidence: CategoryConfidence.ai);
      }
    }
    return _fallback;
  }

  /// The decision for one event, or null when the event type gets no category.
  ///
  /// - only spend types get one (see [categorisedEventTypes])
  /// - a refund takes [linkedPurchase]'s decision, or runs the resolver on its
  ///   own counterparty when there is no linked purchase
  /// - `p2p_out` is `other` unless the user has a rule for the payee
  CategoryDecision? decide({
    required EventType eventType,
    required CategoryInput input,
    CategoryDecision? linkedPurchase,
  }) {
    if (!categorisedEventTypes.contains(eventType)) return null;
    if (eventType == EventType.refund && linkedPurchase != null) return linkedPurchase;
    if (eventType != EventType.p2pOut) return resolve(input);

    final keys = {
      ?keyer.keyFor(input.counterparty),
      ?keyer.personRuleKey(input.counterparty),
    };
    final user = _best(_rulesOf(input.userRules), keys, input.senderBrand, _contextOf(input), _compareUser, (s) => s == CategorySource.user);
    if (user != null) return _decide(user, CategorySource.user, CategoryConfidence.user, 'user');
    return _fallback;
  }

  static const CategoryDecision _fallback = CategoryDecision(
    slug: TaxonomyRegistry.otherSlug,
    source: CategorySource.fallback,
    confidence: CategoryConfidence.fallback,
  );

  CategoryDecision _decide(_Hit hit, CategorySource source, double confidence, String tier) => CategoryDecision(
        slug: hit.rule.slug,
        source: source,
        ruleId: '$tier:${hit.rule.key}${hit.rule.context.isEmpty ? '' : '+${hit.rule.context.join(',')}'}',
        confidence: confidence,
      );

  Set<String> _contextOf(CategoryInput input) => {
        for (final t in input.contextTokens) ...merchantTokens(normalizeMerchantText(t)),
      };

  List<_Compiled> _rulesOf(List<CategoryRule> rules) {
    if (rules.isEmpty) return const [];
    return _compiled[rules] ??= [
      for (final r in rules) ?_Compiled.tryCompile(r, registry),
    ];
  }

  /// The best rule among those of the tier ([inTier]) that match any of
  /// [keys], the sender and the context, by [compare] (lowest sorts first).
  _Hit? _best(
    List<_Compiled> rules,
    Set<String> keys,
    String senderBrand,
    Set<String> context,
    int Function(_Hit, _Hit) compare,
    bool Function(CategorySource) inTier,
  ) {
    final sender = senderBrand.trim().toUpperCase();
    _Hit? best;
    for (final key in keys) {
      final tokens = merchantTokens(key);
      for (final c in rules) {
        if (!inTier(c.source)) continue;
        if (!c.allowsSender(sender)) continue;
        if (!c.matches(key, tokens)) continue;
        if (c.context.isNotEmpty && !c.context.any((t) => tokens.contains(t) || context.contains(t))) continue;
        final hit = _Hit(c, c.key == key);
        if (best == null || compare(hit, best) < 0) best = hit;
      }
    }
    return best;
  }
}

// ---- ordering -------------------------------------------------------------

int _tail(_Hit a, _Hit b) {
  final byKey = a.rule.key.compareTo(b.rule.key);
  if (byKey != 0) return byKey;
  return a.rule.slug.compareTo(b.rule.slug);
}

/// User rules: a satisfied contextual rule beats a plain one, a rule for this
/// sender beats a rule for any sender, then the longer match.
int _compareUser(_Hit a, _Hit b) {
  var c = (b.rule.context.isEmpty ? 0 : 1).compareTo(a.rule.context.isEmpty ? 0 : 1);
  if (c != 0) return c;
  c = (b.rule.anySender ? 0 : 1).compareTo(a.rule.anySender ? 0 : 1);
  if (c != 0) return c;
  c = b.rule.tokens.length.compareTo(a.rule.tokens.length);
  if (c != 0) return c;
  c = (b.whole ? 1 : 0).compareTo(a.whole ? 1 : 0);
  if (c != 0) return c;
  c = b.rule.priority.compareTo(a.rule.priority);
  return c != 0 ? c : _tail(a, b);
}

/// Shared rules: by priority, then the longer match.
int _comparePriorityFirst(_Hit a, _Hit b) {
  var c = b.rule.priority.compareTo(a.rule.priority);
  if (c != 0) return c;
  c = b.rule.tokens.length.compareTo(a.rule.tokens.length);
  if (c != 0) return c;
  c = (b.whole ? 1 : 0).compareTo(a.whole ? 1 : 0);
  return c != 0 ? c : _tail(a, b);
}

/// Catalogue rules: the longest match, then priority.
int _compareLongestFirst(_Hit a, _Hit b) {
  var c = b.rule.tokens.length.compareTo(a.rule.tokens.length);
  if (c != 0) return c;
  c = b.rule.priority.compareTo(a.rule.priority);
  if (c != 0) return c;
  c = (b.whole ? 1 : 0).compareTo(a.whole ? 1 : 0);
  return c != 0 ? c : _tail(a, b);
}

class _Hit {
  const _Hit(this.rule, this.whole);
  final _Compiled rule;

  /// True when the rule key is the whole merchant key.
  final bool whole;
}

/// A category rule with its key normalised once.
class _Compiled {
  _Compiled._(this.source, this.key, this.tokens, this.match, this.slug, this.priority, this.senders, this.context);

  static _Compiled? tryCompile(CategoryRule r, TaxonomyRegistry registry) {
    final key = normalizeMerchantText(r.merchantKey);
    final slug = registry.canonicalSlug(r.category);
    if (key.isEmpty || slug == null) return null;
    return _Compiled._(
      r.source,
      key,
      merchantTokens(key),
      r.match,
      slug,
      r.priority,
      {for (final s in r.senders) s.trim().toUpperCase()},
      [
        for (final c in r.context)
          for (final t in merchantTokens(normalizeMerchantText(c))) t,
      ],
    );
  }

  final CategorySource source;
  final String key;
  final List<String> tokens;
  final CategoryMatch match;
  final String slug;
  final int priority;
  final Set<String> senders;
  final List<String> context;

  bool get anySender => senders.contains('*');

  bool allowsSender(String sender) => senders.contains('*') || senders.contains(sender);

  bool matches(String merchant, List<String> merchantTokens) {
    switch (match) {
      case CategoryMatch.exact:
        return merchant == key;
      case CategoryMatch.prefix:
        return merchant.startsWith(key);
      case CategoryMatch.contains:
        return merchant.contains(key);
      case CategoryMatch.token:
        if (tokens.length > merchantTokens.length) return false;
        for (var i = 0; i + tokens.length <= merchantTokens.length; i++) {
          var ok = true;
          for (var j = 0; j < tokens.length; j++) {
            if (merchantTokens[i + j] != tokens[j]) {
              ok = false;
              break;
            }
          }
          if (ok) return true;
        }
        return false;
    }
  }
}
