import 'catalogue_repository.dart';
import 'user_cards_repository.dart';

/// The category set an entry kind draws from. Refunds belong to the original
/// spend, and an unknown kind is treated as spend until the user decides.
String categoryScopeFor(TxnEntryKind kind) => switch (kind) {
  TxnEntryKind.income => 'income',
  TxnEntryKind.investment => 'investment',
  TxnEntryKind.investmentReturn => 'investment_return',
  TxnEntryKind.transfer => 'transfer',
  TxnEntryKind.spend || TxnEntryKind.refund || TxnEntryKind.unknown => 'spend',
};

/// The categories [kind] may use. A subcategory follows its parent, so a
/// custom "Index funds" under Mutual funds stays an investment category.
List<SpendCategory> categoriesForKind(
  List<SpendCategory> all,
  TxnEntryKind kind,
) {
  final scope = categoryScopeFor(kind);
  final byId = {for (final c in all) c.id: c};
  bool allowed(SpendCategory c, [int depth = 0]) {
    final parentId = c.parentCategoryId ?? c.parentUserCategoryId;
    final parent = parentId == null ? null : byId[parentId];
    if (parent != null && depth < 5) return allowed(parent, depth + 1);
    return c.entryKinds.contains(scope);
  }

  return all.where(allowed).toList();
}

/// Whether [categoryId] is still valid once the entry becomes [kind].
bool categoryFitsKind(
  List<SpendCategory> all,
  String? categoryId,
  TxnEntryKind kind,
) =>
    categoryId == null ||
    categoriesForKind(all, kind).any((c) => c.id == categoryId);
