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
        return ListView(
          padding: const EdgeInsets.all(AppSpace.lg),
          children: [
            Container(
              padding: const EdgeInsets.all(AppSpace.lg),
              decoration: BoxDecoration(
                gradient: const LinearGradient(colors: [BambooInk.slateRaised, BambooInk.slate]),
                borderRadius: BorderRadius.circular(AppRadius.lg),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${_monthLabel(r.periodMonth)}',
                    style: BambooFonts.ui(12.5, weight: FontWeight.w700, color: BambooInk.onSlateSubtle),
                  ),
                  const SizedBox(height: AppSpace.sm),
                  Text('Rewards earned', style: BambooFonts.ui(13.5, color: BambooInk.onSlateMuted)),
                  MoneyText(
                    r.rewardsEarned,
                    confidence: Confidence.estimated,
                    style: BambooFonts.money(30, color: BambooInk.lime),
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
                color: BambooInk.paperMuted,
                borderRadius: BorderRadius.circular(AppRadius.md),
              ),
              child: Row(
                children: [
                  const Icon(Icons.info_outline_rounded, size: 16, color: BambooInk.ink500),
                  const SizedBox(width: AppSpace.sm),
                  Expanded(
                    child: Text(
                      'What a single best-overall card would have earned instead — and what a '
                      'suboptimal choice may have cost — isn\'t computed yet. Not shown as ₹0.',
                      style: BambooFonts.ui(12.5, color: BambooInk.ink500),
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
        Text(label, style: BambooFonts.ui(13.5, color: BambooInk.ink900)),
        child,
      ],
    );
  }
}
