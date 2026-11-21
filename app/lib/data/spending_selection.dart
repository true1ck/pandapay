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

  /// Calendar month (device time) to keep; only its year and month are used.
  final DateTime? month;
  const SpendingSelection({
    this.payment,
    this.categories = const {},
    this.merchant,
    this.card,
    this.tagIds = const {},
    this.untagged = false,
    this.month,
  });

  bool matches(
    TransactionEntry entry, {
    Iterable<String> tags = const [],
    List<BankAccountSummary> bankAccounts = const [],
  }) {
    if (month != null) {
      final local = entry.occurredAt.toLocal();
      if (local.year != month!.year || local.month != month!.month) {
        return false;
      }
    }
    if (payment != null && effectiveInstrument(entry) != payment) return false;
    if (categories.isNotEmpty && !categoryKeys(entry).any(categories.contains))
      return false;
    if (merchant != null &&
        normalize(merchant!) != normalize(merchantName(entry))) {
      return false;
    }
    if (card != null && sourceName(entry, bankAccounts: bankAccounts) != card) {
      return false;
    }
    final ids = tags.toSet();
    if (untagged && ids.isNotEmpty) return false;
    if (tagIds.isNotEmpty && !tagIds.any(ids.contains)) return false;
    return true;
  }

  /// This selection as the parameters of a link to Activity, for what Activity
  /// can apply exactly as [matches] does. What it cannot is named in
  /// `notCarried`, so the person can be told rather than shown a list that
  /// quietly disagrees with the figure they tapped. Activity has no payment
  /// method, no source that is not a saved card, and does not match this
  /// selection's `custom:` category keys, nor a row with no merchant.
  ///
  /// [cardIdForSource] turns the source name this selection filters on into
  /// the one saved card's id, or null when it is not exactly one saved card.
  /// The month is the link's date range, not a parameter here.
  ({Map<String, List<String>> params, List<String> notCarried}) toActivityLink({
    required String? Function(String source) cardIdForSource,
  }) {
    final params = <String, List<String>>{};
    final notCarried = <String>[];
    void cannot(String what) {
      if (!notCarried.contains(what)) notCarried.add(what);
    }

    if (tagIds.isNotEmpty) params['tag'] = [...tagIds];
    if (untagged) params['untagged'] = ['true'];
    for (final key in categories) {
      if (key.startsWith('custom:')) {
        cannot('category');
      } else if (key.startsWith('label:')) {
        (params['categoryLabel'] ??= []).add(key.substring('label:'.length));
      } else {
        (params['category'] ??= []).add(key);
      }
    }
    final merchantFilter = merchant;
    if (merchantFilter != null) {
      if (normalize(merchantFilter) == normalize('Unknown merchant')) {
        cannot('merchant');
      } else {
        params['merchant'] = [merchantFilter];
      }
    }
    final source = card;
    if (source != null) {
      final id = cardIdForSource(source);
      if (id == null) {
        cannot('account');
      } else {
        params['card'] = [id];
      }
    }
    if (payment != null) cannot('payment method');
    return (params: params, notCarried: notCarried);
  }

  static String normalize(String text) =>
      text.trim().toLowerCase().split(RegExp(r'\s+')).join(' ');
  static String merchantName(TransactionEntry entry) =>
      entry.merchantName?.trim().isNotEmpty == true
      ? entry.merchantName!.trim()
      : 'Unknown merchant';
  static TxnInstrument effectiveInstrument(TransactionEntry entry) =>
      entry.instrumentKnown ? entry.instrument : TxnInstrument.other;

  /// A saved card or masked funding account, used by the Accounts breakdown.
  /// Issuer names are shown only when the observed account suffix maps to one
  /// distinct issuer; suffix-only and ambiguous matches stay generic.
  static String sourceName(
    TransactionEntry entry, {
    List<BankAccountSummary> bankAccounts = const [],
  }) {
    final savedName = entry.cardDisplayName?.trim();
    if (savedName != null && savedName.isNotEmpty) {
      return savedName;
    }

    final instrument = effectiveInstrument(entry);
    if (instrument == TxnInstrument.creditCard ||
        instrument == TxnInstrument.debitCard) {
      if (entry.userCardId != null) return instrument.label;
      return entry.cardLast4 == null
          ? '${instrument.label} (unlinked)'
          : '${instrument.label} ••${entry.cardLast4} (unlinked)';
    }
    if (entry.accountLast4 != null) {
      final suffix = entry.accountLast4!;
      final matching = bankAccounts
          .where((account) => account.accountLast4 == suffix)
          .toList();
      final issuerKeys = matching
          .map(
            (account) =>
                account.issuerSlug ??
                account.issuerName ??
                account.issuerShortName,
          )
          .whereType<String>()
          .map((issuer) => issuer.trim().toLowerCase())
          .where((issuer) => issuer.isNotEmpty)
          .toSet();
      if (issuerKeys.length == 1) {
        final name = matching
            .map((account) => account.issuerShortName ?? account.issuerName)
            .whereType<String>()
            .map((issuer) => issuer.trim())
            .firstWhere((issuer) => issuer.isNotEmpty, orElse: () => '');
        if (name.isNotEmpty) return '$name ••$suffix';
      }
      return 'Bank account ••$suffix';
    }

    return switch (instrument) {
      TxnInstrument.upiBank => 'UPI bank account',
      TxnInstrument.wallet => 'Wallet',
      TxnInstrument.cash => 'Cash',
      _ => 'Unknown source',
    };
  }

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
