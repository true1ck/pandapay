/// SMS pipeline v2 category resolver and taxonomy (WP-07).
///
/// Pure Dart: `TaxonomyRegistry`, `merchantKey`, `DefaultCategoryResolver` and
/// the confirmed-history builder. One resolver for every spend, matching on
/// the merchant key only.
library;

export 'src/sms_v2/category/category_resolver.dart';
export 'src/sms_v2/category/confirmed_history.dart';
export 'src/sms_v2/category/merchant_key.dart';
export 'src/sms_v2/category/taxonomy_registry.dart';
