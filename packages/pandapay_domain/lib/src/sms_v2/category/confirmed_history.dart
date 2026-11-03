import '../contract/enums.dart';
import '../contract/ledger_entry.dart';
import 'merchant_key.dart';
import 'taxonomy_registry.dart';

/// Builds the merchant key to category map from ledger entries, using only
/// categories a person confirmed: `categorySource` of `user` or
/// `history_confirmed`. A category that was only assigned automatically
/// (`catalogue`, `shared`, `ai`, `mcc`, `default`) never counts, so a wrong
/// automatic guess cannot teach itself.
///
/// When a merchant key has several confirmed entries, the most recent one wins
/// (a later correction replaces an earlier choice). Entries whose destination
/// is not external, or whose category is not in [registry], are skipped.
Map<String, String> confirmedHistoryFromLedger(
  Iterable<LedgerEntry> entries, {
  TaxonomyRegistry? registry,
}) {
  final taxonomy = registry ?? TaxonomyRegistry.v1;
  final latest = <String, ({DateTime at, String slug})>{};
  for (final e in entries) {
    final source = e.categorySource;
    if (source != CategorySource.user && source != CategorySource.historyConfirmed) continue;
    final to = e.to;
    if (to is! ExternalEndpoint) continue;
    final slug = taxonomy.canonicalSlug(e.category);
    if (slug == null) continue;
    final key = normalizeMerchantText(to.counterpartyKey);
    if (key.isEmpty) continue;
    final seen = latest[key];
    if (seen == null || e.occurredAt.isAfter(seen.at)) {
      latest[key] = (at: e.occurredAt, slug: slug);
    }
  }
  return {for (final k in latest.keys) k: latest[k]!.slug};
}
