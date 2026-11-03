import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:pandapay_domain/sms_v2_category.dart';

import 'confirmed_category_history.dart';
import 'user_category_rules.dart';

/// The two per-account inputs of the category resolver, loaded once per batch
/// (never per message): the user's own rules and the confirmed history.
class CategorySnapshot {
  const CategorySnapshot({this.userRules = const [], this.confirmedHistory = const {}});

  /// Loads both from the account's local database.
  factory CategorySnapshot.load(
    AppDatabase database, {
    required String namespace,
    Iterable<MerchantAlias> aliases = const [],
  }) {
    return CategorySnapshot(
      userRules: UserCategoryRules(database, namespace: namespace, keyer: MerchantKeyer(aliases)).load(),
      confirmedHistory: ConfirmedCategoryHistory(database, namespace: namespace).load(),
    );
  }

  final List<CategoryRule> userRules;
  final Map<String, String> confirmedHistory;

  /// The resolver input for one spend. [bundleRules] come from the active rule
  /// bundle; [aiSuggestion] is the category carried on an AI fact, if any.
  ResolverInput input({
    required Counterparty? counterparty,
    required String senderBrand,
    List<String> contextTokens = const [],
    List<CategoryRule> bundleRules = const [],
    String? aiSuggestion,
  }) =>
      ResolverInput(
        counterparty: counterparty,
        senderBrand: senderBrand,
        contextTokens: contextTokens,
        userRules: userRules,
        bundleRules: bundleRules,
        confirmedHistory: confirmedHistory,
        aiSuggestion: aiSuggestion,
      );
}
