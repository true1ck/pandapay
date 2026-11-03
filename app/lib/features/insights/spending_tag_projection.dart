import 'package:pandapay_domain/pandapay_domain.dart';

import '../../data/spend_reports_repository.dart';
import '../../data/spending_selection.dart';
import '../../data/user_cards_repository.dart';

String _categoryKey(String? categoryId, String label) =>
    '${categoryId ?? 'label'}:${SpendingSelection.normalize(label)}';

String? _categoryId(TransactionEntry entry) =>
    entry.categoryId ??
    (entry.userCategoryId == null ? null : 'custom:${entry.userCategoryId}');

/// One tag's totals and drill-down rows from the same visible snapshot.
class SpendingTagGroup {
  final TransactionTag tag;
  final Money total;
  final List<TransactionEntry> entries;
  final List<SpendBreakdownRow> categories;
  final Map<String, List<TransactionEntry>> _categoryEntries;

  const SpendingTagGroup._(
    this._categoryEntries, {
    required this.tag,
    required this.total,
    required this.entries,
    required this.categories,
  });

  List<TransactionEntry> entriesForCategory(SpendBreakdownRow category) =>
      _categoryEntries[_categoryKey(category.categoryId, category.label)] ??
      const [];
}

/// Resolves tags and accumulates totals once per visible transaction instead
/// of filtering the complete history from every sort comparison and row.
/// The caller supplies current tags, so edits remain live on every rebuild.
List<SpendingTagGroup> projectSpendingTags(
  Iterable<TransactionEntry> entries, {
  required Iterable<TransactionTag> Function(TransactionEntry) tagsFor,
  Money Function(List<TransactionEntry>)? subtotal,
}) {
  final groups = <String, _TagAccumulator>{};
  for (final entry in entries) {
    // A transaction contributes only once to a tag, even if fallback data
    // contains the same tag ID twice. Metadata follows the last observed tag.
    final tags = {for (final tag in tagsFor(entry)) tag.id: tag};
    for (final tag in tags.values) {
      final group = groups.putIfAbsent(tag.id, () => _TagAccumulator(tag));
      group.tag = tag;
      group.add(entry);
    }
  }
  final result = groups.values.map((group) => group.finish(subtotal)).toList()
    ..sort((a, b) => b.total.paise.compareTo(a.total.paise));
  return List.unmodifiable(result);
}

class _TagAccumulator {
  TransactionTag tag;
  final entries = <TransactionEntry>[];
  final categories = <String, _CategoryAccumulator>{};
  int totalPaise = 0;

  _TagAccumulator(this.tag);

  void add(TransactionEntry entry) {
    entries.add(entry);
    totalPaise += entry.amount.paise;
    final categoryId = _categoryId(entry);
    categories
        .putIfAbsent(
          _categoryKey(categoryId, entry.categoryLabel),
          () => _CategoryAccumulator(categoryId, entry.categoryLabel),
        )
        .add(entry);
  }

  SpendingTagGroup finish(Money Function(List<TransactionEntry>)? subtotal) {
    final rows =
        categories.values.map((category) => category.row(subtotal)).toList()
          ..sort((a, b) => b.total.paise.compareTo(a.total.paise));
    return SpendingTagGroup._(
      Map.unmodifiable({
        for (final category in categories.entries)
          category.key: List<TransactionEntry>.unmodifiable(
            category.value.entries,
          ),
      }),
      tag: tag,
      total: subtotal?.call(entries) ?? Money.fromPaise(totalPaise),
      entries: List.unmodifiable(entries),
      categories: List.unmodifiable(rows),
    );
  }
}

class _CategoryAccumulator {
  final String? categoryId;
  final String label;
  final entries = <TransactionEntry>[];
  int totalPaise = 0;

  _CategoryAccumulator(this.categoryId, this.label);

  void add(TransactionEntry entry) {
    entries.add(entry);
    totalPaise += entry.amount.paise;
  }

  SpendBreakdownRow row(Money Function(List<TransactionEntry>)? subtotal) =>
      SpendBreakdownRow(
        label: label,
        categoryId: categoryId,
        total: subtotal?.call(entries) ?? Money.fromPaise(totalPaise),
        txnCount: entries.length,
      );
}
