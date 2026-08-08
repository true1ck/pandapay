import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';
import '../../main.dart' show MoneyText;

/// ui-spec.md E9 Monthly Savings Report. GET /monthly-reports is new this
/// pass (Task E9) — recomputes the CURRENT month on demand server-side;
/// see that route's doc-comment (api/src/index.js) for why
/// baseline/value-missed are 0 this pass (needs the shared D6/E9
/// historical-recompute calculator neither plan has built yet — NOT
/// silently shown as "you missed nothing").
///
/// Share-as-image (spec's "share-as-image" requirement) is NOT built this
/// pass — flagged in the final report as a scoped-down item, not silently
/// dropped.
class MonthlySavingsScreen extends ConsumerWidget {
  const MonthlySavingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final report = ref.watch(currentMonthlyReportProvider);
    return report.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (err, _) => ErrorState(
        message: userFacingErrorMessage(err),
        onRetry: () => ref.invalidate(currentMonthlyReportProvider),
      ),
      data: (r) {
        if (r == null || r.totalSpend.isZero) {
          return const EmptyState(
            icon: Icons.insights_outlined,
            title: 'Building your first report',
            message: 'Log a few transactions this month and your savings report will appear here — '
                'never shown as ₹0 while there\'s simply no data yet.',
          );
        }
        final textTheme = Theme.of(context).textTheme;
        return ListView(
          padding: const EdgeInsets.all(AppSpace.lg),
          children: [
            Container(
              padding: const EdgeInsets.all(AppSpace.lg),
              decoration: BoxDecoration(
                gradient: const LinearGradient(colors: [AppColors.navy900, AppColors.navy700]),
                borderRadius: BorderRadius.circular(AppRadius.lg),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${_monthLabel(r.periodMonth)}',
                    style: textTheme.labelLarge?.copyWith(color: Colors.white60),
                  ),
                  const SizedBox(height: AppSpace.sm),
                  Text('Rewards earned', style: textTheme.bodyMedium?.copyWith(color: Colors.white70)),
                  MoneyText(
                    r.rewardsEarned,
                    confidence: Confidence.estimated,
                    style: textTheme.displaySmall?.copyWith(color: Colors.white),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpace.lg),
            _StatRow(label: 'Total spend', child: MoneyText(r.totalSpend, confidence: Confidence.estimated)),
            const Divider(height: AppSpace.xl),
            // baseline/value-missed are honestly not-yet-computed this
            // pass — shown as an explicit "not available" note rather than
            // a fabricated ₹0, per the cross-cutting data-honesty rule.
            Container(
              padding: const EdgeInsets.all(AppSpace.md),
              decoration: BoxDecoration(
                color: AppColors.surfaceMuted,
                borderRadius: BorderRadius.circular(AppRadius.md),
              ),
              child: Row(
                children: [
                  const Icon(Icons.info_outline_rounded, size: 16, color: AppColors.ink500),
                  const SizedBox(width: AppSpace.sm),
                  Expanded(
                    child: Text(
                      'What a single best-overall card would have earned instead — and what a '
                      'suboptimal choice may have cost — isn\'t computed yet. Not shown as ₹0.',
                      style: textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  static String _monthLabel(DateTime d) {
    const names = [
      'January', 'February', 'March', 'April', 'May', 'June',
      'July', 'August', 'September', 'October', 'November', 'December',
    ];
    return '${names[d.month - 1]} ${d.year}';
  }
}

class _StatRow extends StatelessWidget {
  final String label;
  final Widget child;
  const _StatRow({required this.label, required this.child});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: Theme.of(context).textTheme.bodyMedium),
        child,
      ],
    );
  }
}
