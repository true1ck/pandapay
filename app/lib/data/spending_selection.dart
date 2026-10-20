import 'user_cards_repository.dart';

/// One predicate for filter previews and every spending breakdown. Identity
/// uses category IDs; display labels can change or be duplicated by users.
class SpendingSelection {
  final TxnInstrument? payment;
  final Set<String> categories;
  final String? merchant;
  final String? card;
  final Set<String> tagIds;
  final bool untagged;
  const SpendingSelection({
    this.payment,
    this.categories = const {},
    this.merchant,
    this.card,
    this.tagIds = const {},
    this.untagged = false,
  });

  bool matches(TransactionEntry entry, {Iterable<String> tags = const []}) {
    if (payment != null && entry.instrument != payment) return false;
    if (categories.isNotEmpty && !categoryKeys(entry).any(categories.contains))
      return false;
    if (merchant != null &&
        normalize(merchant!) != normalize(merchantName(entry))) {
      return false;
    }
    if (card != null && cardName(entry) != card) return false;
    final ids = tags.toSet();
    if (untagged && ids.isNotEmpty) return false;
    if (tagIds.isNotEmpty && !tagIds.any(ids.contains)) return false;
    return true;
  }

  static String normalize(String text) =>
      text.trim().toLowerCase().split(RegExp(r'\s+')).join(' ');
  static String merchantName(TransactionEntry entry) =>
      entry.merchantName?.trim().isNotEmpty == true
      ? entry.merchantName!.trim()
      : 'Unknown merchant';
  static String cardName(TransactionEntry entry) =>
      entry.cardDisplayName?.trim().isNotEmpty == true
      ? entry.cardDisplayName!.trim()
      : entry.instrument.label;
  static Set<String> categoryKeys(TransactionEntry entry) => {
    if (entry.categoryId != null) entry.categoryId!,
    if (entry.userCategoryId != null) 'custom:${entry.userCategoryId}',
    if (entry.parentCategoryId != null) entry.parentCategoryId!,
    if (entry.parentUserCategoryId != null)
      'custom:${entry.parentUserCategoryId}',
    // Legacy cached rows can lack IDs. Only these need a label fallback.
    if (entry.categoryId == null && entry.userCategoryId == null)
      'label:${normalize(entry.categoryLabel)}',
  };
}
