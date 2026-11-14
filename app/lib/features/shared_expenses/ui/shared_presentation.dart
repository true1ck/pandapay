import '../../../app/design/saved_offline.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

/// Presentation contracts only. The authenticated repository supplies accepted
/// snapshots; these widgets never infer consent, source eligibility or payment.
enum SharedLoadState { ready, loading, error, accessRevoked }

enum SharedHubTab { friends, groups, activity }

enum SharedGroupTab { expenses, balances, totals }

enum SharedContextState {
  active,
  noExpenses,
  settled,
  pendingInvite,
  pendingReview,
  pendingPayment,
  creditOwedBack,
  disputed,
  incomplete,
}

enum SharedParticipation { included, paidForOthers, notIncluded }

/// A bounded repository page, not a full-account snapshot or a truncating view.
/// A page above the agreed API cap fails so the adapter must page explicitly.
class SharedPage<T> {
  final List<T> items;
  final SharedLoadState state;
  final bool incomplete;
  final bool hasMore;
  final bool loadingMore;
  final bool hasPrevious;
  final String nextLabel;
  final String? nextCursor;
  SharedPage({
    List<T> items = const [],
    this.state = SharedLoadState.ready,
    this.incomplete = false,
    this.hasMore = false,
    this.loadingMore = false,
    this.hasPrevious = false,
    this.nextLabel = 'Load more',
    this.nextCursor,
  }) : items = List.unmodifiable(items) {
    if (items.length > 100) {
      throw ArgumentError.value(items.length, 'items', 'Page limit is 100');
    }
  }
}

/// Gross owed and owing stay visible even when a net vector is zero. A zero
/// net is never used to label the ledger settled or to authorize an offset.
class SharedBalanceSummary {
  final Money owedToYou;
  final Money youOwe;
  final Money netBalance;
  final Confidence confidence;
  final bool incomplete;
  const SharedBalanceSummary({
    required this.owedToYou,
    required this.youOwe,
    required this.netBalance,
    this.confidence = Confidence.confirmed,
    this.incomplete = false,
  });
}

/// One part of what is owed between you and one person: in a named group, or in
/// expenses you share outside any group. Shown under a friend the way
/// Splitwise does ("Sujay owes you ₹2,000.00 in non-group expenses").
class SharedBreakdownLine {
  final String contextId;

  /// The group's name; null for expenses outside any group.
  final String? groupName;

  /// Always positive; [owedToYou] says which way it goes.
  final Money amount;
  final bool owedToYou;
  const SharedBreakdownLine({
    required this.contextId,
    required this.amount,
    required this.owedToYou,
    this.groupName,
  });

  /// "Sujay owes you ₹2,000.00 in non-group expenses" or
  /// "You owe Sujay ₹500.00 in “Goa trip”".
  String sentence(String person) {
    final where = groupName == null
        ? 'in non-group expenses'
        : 'in “$groupName”';
    return owedToYou
        ? '$person owes you ${amount.format()} $where'
        : 'You owe $person ${amount.format()} $where';
  }
}

class SharedContextRow {
  final String id;
  final String title;
  final String? subtitle;
  final SharedBalanceSummary balance;
  final SharedContextState state;

  /// For a friend: what is owed between you in each group and outside groups,
  /// when it is more than one place. [balance] is then the total of these.
  final List<SharedBreakdownLine> breakdown;
  const SharedContextRow({
    required this.id,
    required this.title,
    required this.balance,
    this.subtitle,
    this.state = SharedContextState.active,
    this.breakdown = const [],
  });

  /// Never hide known obligations behind stale settled-state metadata.
  bool get canHideAsSettled =>
      state == SharedContextState.settled &&
      balance.owedToYou.isZero &&
      balance.youOwe.isZero &&
      !balance.incomplete;
}

class SharedActivityRow {
  final String id;
  final String description;
  final String occurredAtLabel;
  final String? contextLabel;
  final String? impactLabel;
  final Money? impactAmount;
  final Confidence confidence;
  const SharedActivityRow({
    required this.id,
    required this.description,
    required this.occurredAtLabel,
    this.contextLabel,
    this.impactLabel,
    this.impactAmount,
    this.confidence = Confidence.confirmed,
  });
}

class SharedExpenseRow {
  final bool proposed;
  final String? reviewLabel;
  final String totalLabel;
  final String paidLabel, payerLabel;
  final String id;
  final String title;
  final String paidBy;
  final String? occurredAtLabel;
  final Money billTotal;
  final Money yourPaid;
  final Money yourShare;
  final Confidence confidence;
  final SharedParticipation participation;
  final SharedContextState state;
  const SharedExpenseRow({
    this.proposed = false,
    this.reviewLabel,
    this.totalLabel = 'Bill total',
    this.paidLabel = 'You paid',
    this.payerLabel = 'Paid by',
    required this.id,
    required this.title,
    required this.paidBy,
    required this.billTotal,
    required this.yourPaid,
    required this.yourShare,
    this.occurredAtLabel,
    this.confidence = Confidence.confirmed,
    this.participation = SharedParticipation.included,
    this.state = SharedContextState.active,
  });
}

class SharedExpenseTotals {
  final String totalLabel;
  final String paidLabel;
  final Money billTotal;
  final Money yourPaid;
  final Money yourShare;
  final Confidence confidence;
  final String? periodLabel;
  final bool incomplete;
  const SharedExpenseTotals({
    this.totalLabel = 'Total bills',
    this.paidLabel = 'You paid',
    required this.billTotal,
    required this.yourPaid,
    required this.yourShare,
    this.confidence = Confidence.confirmed,
    this.periodLabel,
    this.incomplete = false,
  });
}

/// Shown when a change was kept on this phone because the server cannot be
/// reached: it is safe, and it goes out by itself.
const sharedSavedOfflineCopy = savedOfflineCopy;

class SharedHubPresentation {
  final SharedBalanceSummary? summary;
  final SharedPage<SharedContextRow> friends;
  final SharedPage<SharedContextRow> groups;
  final SharedPage<SharedActivityRow> activity;
  final bool offline;
  final bool hideAmounts;
  final int pendingChanges;
  const SharedHubPresentation({
    this.summary,
    required this.friends,
    required this.groups,
    required this.activity,
    this.offline = false,
    this.hideAmounts = false,
    this.pendingChanges = 0,
  });
}

class SharedGroupPresentation {
  final String id;
  final String title;
  final SharedBalanceSummary? summary;
  final SharedPage<SharedExpenseRow> expenses;
  final SharedPage<SharedContextRow> balances;
  final SharedExpenseTotals? totals;
  final SharedLoadState totalsState;
  final bool offline;
  final bool hideAmounts;

  /// A private one-to-one split with a friend rather than a named group.
  final bool direct;

  /// On a friend's page: what is owed between you in each group and outside
  /// groups, when it is more than one place (see [SharedBreakdownLine]).
  final List<SharedBreakdownLine> breakdown;
  const SharedGroupPresentation({
    required this.id,
    required this.title,
    this.summary,
    required this.expenses,
    required this.balances,
    this.totals,
    this.totalsState = SharedLoadState.ready,
    this.offline = false,
    this.hideAmounts = false,
    this.direct = false,
    this.breakdown = const [],
  });
}
