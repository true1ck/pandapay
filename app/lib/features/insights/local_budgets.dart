import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/local/financial_store.dart' show TransactionQuery;
import '../../data/local/user_budgets_store.dart';
import '../../data/local_first/budget_local.dart';
import '../../data/spend_reports_repository.dart';
import '../../data/user_cards_repository.dart' show TransactionEntry, TxnEntryKind;
import 'package:pandapay_domain/pandapay_domain.dart';

/// WP-C7: budgets created on the phone and not yet on the server, with spent
/// computed locally (marked [BudgetStatus.isEstimate]). Reads only the current
/// period's rows through the read worker (never the whole history on the UI
/// isolate). A row whose target the server already lists is dropped.
Future<List<BudgetStatus>> localBudgetsFor(
  Ref ref,
  List<BudgetStatus> server,
) async {
  final cache = await ref.read(responseCacheProvider.future);
  final store = UserBudgetsStore(
    cache.financialStore.database,
    ref.read(cacheNamespaceProvider),
  );
  final ns = ref.read(cacheNamespaceProvider);
  final now = ref.read(clockProvider).now();
  final out = <BudgetStatus>[];
  for (final entry in store.all().entries) {
    final b = entry.value;
    final scope = BudgetScope.values.firstWhere(
      (s) => s.wireValue == b['scope'],
      orElse: () => BudgetScope.overall,
    );
    final period = BudgetPeriod.values.firstWhere(
      (p) => p.wireValue == b['period'],
      orElse: () => BudgetPeriod.monthly,
    );
    final ref0 = b['scopeRefId'] as String?;
    final onServer = server.any(
      (s) =>
          s.id == entry.key ||
          (s.scope == scope &&
              (s.scopeRefId ?? '') == (ref0 ?? '') &&
              s.period == period),
    );
    if (onServer) {
      store.remove(entry.key);
      continue;
    }
    final def = BudgetDef(
      scope: scope.wireValue,
      scopeRefId: ref0,
      period: period.wireValue,
      startsOn: DateTime.tryParse('${b['startsOn']}'),
    );
    final bounds = budgetPeriodBounds(def, now);
    final snapshot = await cache.readTransactions(
      ns,
      TransactionQuery(from: bounds.start, to: bounds.end),
    );
    final spend = computeBudgetSpend(def, [
      for (final t in snapshot?.rows ?? const <TransactionEntry>[])
        BudgetTxn(
          amountPaise: t.amount.paise,
          occurredAt: t.occurredAt,
          status: t.status,
          entryKind: t.entryKind == TxnEntryKind.spend ? 'spend' : 'other',
          excludeFromSpend: t.excludeFromSpend,
          categoryId: t.categoryId,
          userCategoryId: t.userCategoryId,
          parentUserCategoryId: t.parentUserCategoryId,
          userCardId: t.userCardId,
          tagIds: [for (final tag in t.tags) tag.id],
        ),
    ], now);
    final amount = Money.fromRupees((b['amountInr'] as num).toDouble());
    final spent = Money.fromPaise(spend.spentPaise);
    out.add(
      BudgetStatus(
        id: entry.key,
        scope: scope,
        scopeRefId: ref0,
        label: (b['label'] as String?) ??
            (scope == BudgetScope.overall ? 'All spending' : 'Budget'),
        period: period,
        amount: amount,
        spent: spent,
        txnCount: spend.txnCount,
        periodStart: spend.start,
        periodEnd: spend.end,
        consumedFraction: amount.paise == 0 ? 0 : spent.paise / amount.paise,
        elapsedFraction: spend.elapsedFraction,
        projected: spend.elapsedFraction > 0.05
            ? Money.fromPaise((spent.paise / spend.elapsedFraction).round())
            : null,
        isEstimate: true,
      ),
    );
  }
  return out;
}

/// Records a budget the person just saved so it shows at once, offline too.
Future<void> rememberLocalBudget(
  WidgetRef ref, {
  required String id,
  required BudgetScope scope,
  required String? scopeRefId,
  required BudgetPeriod period,
  required double amountInr,
  String? label,
}) async {
  final cache = await ref.read(responseCacheProvider.future);
  UserBudgetsStore(
    cache.financialStore.database,
    ref.read(cacheNamespaceProvider),
  ).put(id, {
    'scope': scope.wireValue,
    'scopeRefId': scopeRefId,
    'period': period.wireValue,
    'amountInr': amountInr,
    'label': label,
    'startsOn': DateTime.now().toIso8601String(),
  });
}

Future<void> forgetLocalBudget(WidgetRef ref, String id) async {
  final cache = await ref.read(responseCacheProvider.future);
  UserBudgetsStore(
    cache.financialStore.database,
    ref.read(cacheNamespaceProvider),
  ).remove(id);
}
