import 'package:pandapay_domain/pandapay_domain.dart';

import '../../data/user_cards_repository.dart';

/// ui-spec B1.6. Only capNearlyHit and feeWaiverDeadline are implemented —
/// see this plan's Task 7 for why pointsExpiring/billDue/needsReview are a
/// stated scope reduction (no client-facing data source exists for them
/// yet): points_ledger.expires_on and user_cards.due_day are never
/// returned by GET /user-cards today, and there is no user-facing
/// needs-review-count endpoint (needs_review_items is D4/admin-only so
/// far). The enum is deliberately open to extension once those exist.
enum HomeAlertKind { capNearlyHit, feeWaiverDeadline }

class HomeAlert {
  final HomeAlertKind kind;
  final String message;
  final int priority; // lower = shown first, per ui-spec B1.6's ordering

  const HomeAlert({required this.kind, required this.message, required this.priority});
}

const _capNearlyHitThreshold = 0.9; // "nearly hit" = 90%+ of a cap consumed
const _feeWaiverDeadlineWindow = Duration(days: 7);

/// Pure — no IO, no DateTime.now() (per no_datetime_now_outside_clock,
/// [now] is threaded through by the caller from clockProvider).
///
/// Returns the FULL priority-ordered set of alerts that currently apply —
/// deliberately NOT capped to 2 here, so callers/tests can see the whole
/// ranked list. The ui-spec B1.6 "max 2 at once" constraint is enforced by
/// the caller (see _AlertsStrip in home_screen.dart), which takes the first
/// 2 after this function's priority sort.
List<HomeAlert> computeHomeAlerts({
  required List<UserCard> wallet,
  required List<CardProduct> catalogue,
  required DateTime now,
}) {
  final alerts = <HomeAlert>[];

  for (final userCard in wallet) {
    final product = catalogue.where((c) => c.id == userCard.cardProductId).firstOrNull;
    if (product == null) continue;

    for (final cap in product.capRules) {
      final consumed = userCard.capConsumed[cap.id];
      if (consumed == null || cap.capValue.isZero) continue;
      final fraction = consumed.paise / cap.capValue.paise;
      if (fraction >= _capNearlyHitThreshold) {
        alerts.add(
          HomeAlert(
            kind: HomeAlertKind.capNearlyHit,
            message: '${userCard.cardName}: ${cap.label} cap almost reached this cycle',
            priority: 0,
          ),
        );
      }
    }

    for (final waiver in userCard.feeWaiverStates) {
      if (waiver.waivedAt != null) continue; // already waived, nothing to warn about
      final daysLeft = waiver.periodEnd.difference(now);
      if (daysLeft.isNegative) continue; // window already closed, nothing actionable to show
      if (daysLeft <= _feeWaiverDeadlineWindow) {
        final remaining = waiver.thresholdSpend - waiver.qualifiedSpend;
        final remainingDisplay = remaining.isNegative ? const Money.zero() : remaining;
        alerts.add(
          HomeAlert(
            kind: HomeAlertKind.feeWaiverDeadline,
            message:
                '${userCard.cardName}: spend ${remainingDisplay.format()} more in '
                '${daysLeft.inDays}d to waive the fee',
            priority: 1,
          ),
        );
      }
    }
  }

  alerts.sort((a, b) => a.priority.compareTo(b.priority));
  return alerts;
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
