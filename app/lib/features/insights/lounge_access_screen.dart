import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';
import '../../data/user_cards_repository.dart';

/// ui-spec.md E6 Lounge Access. GET/POST /lounge-usage are new this pass
/// (Task E6) — quota comes from CardBenefit.quotaCount/quotaPeriod
/// (already parsed), usage comes from counting lounge_usage rows within
/// the current quota window.
///
/// Judgment call (flagged per the task brief): a real shared period-bounds
/// calculator (statement-cycle-aware) doesn't exist client-side yet — the
/// plan notes C2's Caps tab flagged needing one first and E6 would be its
/// second consumer. Rather than block E6 on that landing, [currentLoungeWindow]
/// below implements calendar-based bounds only (month/quarter/half-year/
/// year/lifetime) — correct for every quota period lounge benefits
/// realistically use, but NOT statement-cycle-aware. A benefit using
/// CapPeriod.statementCycle degrades to calendar-month bounds with a
/// visible note rather than silently mis-counting.
class LoungeAccessScreen extends ConsumerWidget {
  const LoungeAccessScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pairs = ref.watch(ownedCardsWithProductProvider);
    final visits = ref.watch(loungeUsageProvider);

    return pairs.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (err, _) => ErrorState(
        message: userFacingErrorMessage(err),
        onRetry: () => ref.invalidate(ownedCardsWithProductProvider),
      ),
      data: (owned) {
        return visits.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (err, _) => ErrorState(
            message: userFacingErrorMessage(err),
            onRetry: () => ref.invalidate(loungeUsageProvider),
          ),
          data: (visitList) {
            final rows = <(UserCard, CardProduct, CardBenefit)>[
              for (final (userCard, product) in owned)
                for (final b in product.benefits)
                  if (b.kind == BenefitKind.loungeDomestic || b.kind == BenefitKind.loungeInternational)
                    (userCard, product, b),
            ];
            if (rows.isEmpty) {
              return const EmptyState(
                icon: Icons.airline_seat_flat_angled_rounded,
                title: 'No lounge benefits to track',
                message: 'None of your cards have a lounge-access benefit — or you haven\'t added a card yet.',
              );
            }
            return ListView.builder(
              padding: const EdgeInsets.all(AppSpace.lg),
              itemCount: rows.length,
              itemBuilder: (context, index) {
                final (userCard, product, benefit) = rows[index];
                final windowVisits = visitList
                    .where((v) => v.userCardId == userCard.id && v.benefitId == benefit.id)
                    .where((v) => isInCurrentLoungeWindow(v.usedOn, benefit.quotaPeriod))
                    .length;
                return Padding(
                  padding: const EdgeInsets.only(bottom: AppSpace.md),
                  child: _LoungeTile(
                    userCard: userCard,
                    product: product,
                    benefit: benefit,
                    usedThisWindow: windowVisits,
                  ),
                );
              },
            );
          },
        );
      },
    );
  }
}

/// G1 (travel_mode_screen.dart) reuses these two functions for its
/// lounge-eligibility-abroad section rather than re-deriving quota-period
/// bounds a second time — made non-private so that reuse is a real import,
/// not a copy-paste.
(DateTime, DateTime) currentLoungeWindow(CapPeriod? period) {
  final now = DateTime.now();
  switch (period) {
    case CapPeriod.calendarMonth:
    case CapPeriod.statementCycle: // degraded — see class doc-comment
    case null:
      return (DateTime(now.year, now.month, 1), DateTime(now.year, now.month + 1, 1));
    case CapPeriod.quarter:
      final qStartMonth = ((now.month - 1) ~/ 3) * 3 + 1;
      return (DateTime(now.year, qStartMonth, 1), DateTime(now.year, qStartMonth + 3, 1));
    case CapPeriod.halfYear:
      final hStartMonth = now.month <= 6 ? 1 : 7;
      return (DateTime(now.year, hStartMonth, 1), DateTime(now.year, hStartMonth + 6, 1));
    case CapPeriod.annual:
      return (DateTime(now.year, 1, 1), DateTime(now.year + 1, 1, 1));
    case CapPeriod.lifetime:
      return (DateTime(2000, 1, 1), DateTime(2100, 1, 1));
  }
}

bool isInCurrentLoungeWindow(DateTime usedOn, CapPeriod? period) {
  final (start, end) = currentLoungeWindow(period);
  return !usedOn.isBefore(start) && usedOn.isBefore(end);
}

class _LoungeTile extends ConsumerWidget {
  final UserCard userCard;
  final CardProduct product;
  final CardBenefit benefit;
  final int usedThisWindow;
  const _LoungeTile({
    required this.userCard,
    required this.product,
    required this.benefit,
    required this.usedThisWindow,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final textTheme = Theme.of(context).textTheme;
    final quotaValue = benefit.quotaCount;
    final unlimited = quotaValue == null;
    final quota = quotaValue ?? 0;
    final remaining = unlimited ? null : (quota - usedThisWindow).clamp(0, quota);
    final ratio = unlimited ? 0.0 : (quota == 0 ? 0.0 : (usedThisWindow / quota).clamp(0.0, 1.0));

    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: AppColors.ink100),
      ),
      padding: const EdgeInsets.all(AppSpace.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(benefit.label, style: textTheme.titleSmall),
                    const SizedBox(height: 2),
                    Text(
                      '${userCard.nickname?.isNotEmpty == true ? userCard.nickname! : product.name}'
                      '${benefit.networkProgram != null ? " · ${benefit.networkProgram}" : ""}',
                      style: textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              TextButton.icon(
                icon: const Icon(Icons.add_rounded, size: 16),
                label: const Text('Log visit'),
                onPressed: () => _showLogVisitSheet(context, ref, userCard, benefit),
              ),
            ],
          ),
          const SizedBox(height: AppSpace.sm),
          if (unlimited)
            Text('$usedThisWindow visits logged this period · unlimited quota', style: textTheme.bodySmall)
          else ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.pill),
              child: LinearProgressIndicator(
                value: ratio,
                minHeight: 8,
                backgroundColor: AppColors.surfaceMuted,
                color: ratio >= 1.0 ? AppColors.error : AppColors.teal600,
              ),
            ),
            const SizedBox(height: AppSpace.sm),
            Row(
              children: [
                if (ratio >= 1.0) const Icon(Icons.block_rounded, size: 14, color: AppColors.error),
                if (ratio >= 1.0) const SizedBox(width: 4),
                Text(
                  '$usedThisWindow of $quota used this period ($remaining left)',
                  style: textTheme.bodySmall?.copyWith(color: ratio >= 1.0 ? AppColors.error : null),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  void _showLogVisitSheet(BuildContext context, WidgetRef ref, UserCard userCard, CardBenefit benefit) {
    final airportController = TextEditingController();
    DateTime pickedDate = DateTime.now();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => Padding(
        padding: EdgeInsets.only(
          left: AppSpace.lg,
          right: AppSpace.lg,
          top: AppSpace.lg,
          bottom: MediaQuery.of(sheetContext).viewInsets.bottom + AppSpace.lg,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Log a lounge visit', style: Theme.of(sheetContext).textTheme.titleMedium),
            const SizedBox(height: AppSpace.md),
            TextField(
              controller: airportController,
              decoration: const InputDecoration(labelText: 'Airport (optional)'),
            ),
            const SizedBox(height: AppSpace.lg),
            FilledButton(
              onPressed: () async {
                final repo = ref.read(userCardsRepositoryProvider);
                if (repo == null) return;
                try {
                  await repo.logLoungeVisit(
                    userCardId: userCard.id,
                    benefitId: benefit.id,
                    usedOn: pickedDate,
                    airport: airportController.text.trim().isEmpty ? null : airportController.text.trim(),
                  );
                  ref.invalidate(loungeUsageProvider);
                  if (sheetContext.mounted) Navigator.of(sheetContext).pop();
                } catch (e) {
                  if (sheetContext.mounted) {
                    ScaffoldMessenger.of(sheetContext)
                        .showSnackBar(SnackBar(content: Text(userFacingErrorMessage(e))));
                  }
                }
              },
              child: const Text('Log visit'),
            ),
          ],
        ),
      ),
    );
  }
}
