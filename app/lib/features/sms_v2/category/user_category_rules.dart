import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/sms_learning_feedback.dart';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:pandapay_domain/sms_v2_category.dart';

/// A category a person chose for a merchant. Handed to [CategoryChoiceSink] so
/// the corrections service (WP-12) can record and upload the matching
/// correction.
class CategoryChoice {
  const CategoryChoice({
    required this.merchantKey,
    required this.slug,
    this.senderBrand,
    this.context = const [],
  });

  final String merchantKey;
  final String slug;

  /// Set when the rule applies to one sender only.
  final String? senderBrand;

  /// Set when the rule applies only when one of these tokens is present.
  final List<String> context;
}

/// Receives each choice after it is stored locally. WP-12's `CorrectionsService`
/// supplies one; without it the choice is local only.
typedef CategoryChoiceSink = void Function(CategoryChoice choice);

/// The user's own category rules, kept in the existing
/// `user_merchant_category_rules` table so old and new pipelines share one
/// store.
///
/// Row formats read here (the `pattern` column):
///
/// - `KEY`: a plain merchant key, any sender (a choice with no sender or
///   context is written this way).
/// - `V2|KEY|SENDERS|CONTEXT`: written by [saveChoice] for a rule limited to a
///   sender or to context tokens; the last two parts are comma lists and may be
///   empty.
/// - `CTX|MERCHANT|SENDER|TEMPLATE`: written by the old pipeline for one
///   message layout. It is read as a rule for that merchant and that sender; the
///   layout part is dropped, because v2 matches on the merchant only.
///
/// Only rows whose `source` is `user` are read: a category that was not chosen
/// by the person never becomes a user rule.
class UserCategoryRules {
  UserCategoryRules(
    this.database, {
    required this.namespace,
    MerchantKeyer? keyer,
    this.onChoice,
    TaxonomyRegistry? registry,
  })  : keyer = keyer ?? MerchantKeyer(),
        registry = registry ?? TaxonomyRegistry.v1;

  final AppDatabase database;
  final String namespace;
  final MerchantKeyer keyer;
  final TaxonomyRegistry registry;
  final CategoryChoiceSink? onChoice;

  SmsLearningFeedback get _store => SmsLearningFeedback(database, namespace: namespace);

  /// The rules as `CategoryRule`s with source `user`, for
  /// `CategoryInput.userRules`. Newer choices get a higher priority, so the
  /// latest choice wins between two rules for the same merchant.
  List<CategoryRule> load() {
    final rules = <CategoryRule>[];
    for (final row in _store.loadRuleRowsSync()) {
      if (row.source != 'user') continue;
      final slug = registry.canonicalSlug(row.categorySlug);
      if (slug == null) continue;
      final rule = _parse(row.pattern, slug, row.updatedAt);
      if (rule != null) rules.add(rule);
    }
    return rules;
  }

  /// Stores [slug] as the person's choice for [merchantKey] and tells
  /// [onChoice]. Throws [ArgumentError] when the slug is not in the taxonomy
  /// or the key is empty.
  void saveChoice({
    required String merchantKey,
    required String slug,
    String? senderBrand,
    List<String> context = const [],
  }) {
    final canonical = registry.canonicalSlug(slug);
    if (canonical == null) throw ArgumentError.value(slug, 'slug', 'not in the taxonomy');
    final key = normalizeMerchantText(merchantKey);
    if (key.isEmpty) throw ArgumentError.value(merchantKey, 'merchantKey', 'empty');
    final sender = senderBrand?.trim().toUpperCase();
    final tokens = [
      for (final c in context) ...merchantTokens(normalizeMerchantText(c)),
    ];
    final plain = (sender == null || sender.isEmpty) && tokens.isEmpty;
    _store.recordCategoryCorrection(
      merchantOrPattern: plain ? key : 'V2|$key|${sender ?? ''}|${tokens.join(',')}',
      categorySlug: canonical,
    );
    onChoice?.call(CategoryChoice(
      merchantKey: key,
      slug: canonical,
      senderBrand: sender == null || sender.isEmpty ? null : sender,
      context: tokens,
    ));
  }

  CategoryRule? _parse(String pattern, String slug, int updatedAt) {
    if (pattern.startsWith('CTX|')) {
      final parts = pattern.split('|');
      if (parts.length < 3) return null;
      final key = keyer.keyForName(parts[1]);
      if (key == null) return null;
      final sender = parts[2].trim();
      return _rule(key, slug, updatedAt, senders: [if (sender.isNotEmpty) normalizeSenderBrand(sender).brand]);
    }
    if (pattern.startsWith('V2|')) {
      final parts = pattern.split('|');
      if (parts.length < 4 || parts[1].isEmpty) return null;
      return _rule(
        parts[1],
        slug,
        updatedAt,
        senders: parts[2].isEmpty ? const [] : parts[2].split(','),
        context: parts[3].isEmpty ? const [] : parts[3].split(','),
      );
    }
    final key = normalizeMerchantText(pattern);
    if (key.isEmpty) return null;
    return _rule(key, slug, updatedAt);
  }

  CategoryRule _rule(
    String key,
    String slug,
    int updatedAt, {
    List<String> senders = const [],
    List<String> context = const [],
  }) =>
      CategoryRule(
        merchantKey: key,
        match: CategoryMatch.exact,
        senders: senders.isEmpty ? const ['*'] : senders,
        context: context,
        category: slug,
        priority: updatedAt,
        source: CategorySource.user,
      );
}
