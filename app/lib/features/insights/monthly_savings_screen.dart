import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';
import '../../data/user_cards_repository.dart' show MonthlyReport;
import '../../main.dart' show MoneyText;
import '../referrals/invite_friends_screen.dart';
import 'insights_overview.dart';

/// baseline_single_card / value_missed for the CURRENT month, computed
/// client-side from the exact same [baseRateValueFor]/[compareToOwnedCards]
/// calculator [MissedOpportunitiesScreen]'s D6 already uses — see that
/// function's doc-comment for what it can/can't detect (base-rate-only, no
/// historical cap/milestone/forex state; GET /monthly-reports' server-side
/// baseline_single_card_inr/value_missed_inr stay 0 for the same reason, so
/// this reads the raw transactions directly instead of trusting those two
/// fields). Needs 2+ owned cards to mean anything — with only one card
/// owned there's no counterfactual to compute, same "nothing to have
/// chosen instead of" case D6 already handles.
class _MonthlyExtras {
  final Money baselineSingleCard;
  final Money valueMissed;
  final bool hasCounterfactual;
  const _MonthlyExtras({
    required this.baselineSingleCard,
    required this.valueMissed,
    required this.hasCounterfactual,
  });
}

final _monthlyExtrasProvider = FutureProvider.family<_MonthlyExtras, DateTime>((ref, periodMonth) async {
  final repo = ref.watch(userCardsRepositoryProvider);
  final pairs = ref.watch(ownedCardsWithProductProvider).valueOrNull ?? const [];
  if (repo == null || pairs.length < 2) {
    return const _MonthlyExtras(
      baselineSingleCard: Money.zero(),
      valueMissed: Money.zero(),
      hasCounterfactual: false,
    );
  }

  final allProducts = [for (final (_, p) in pairs) p];
  final productsByUserCardId = {for (final (uc, p) in pairs) uc.id: p};
  final monthStart = DateTime(periodMonth.year, periodMonth.month, 1);
  final monthEnd = DateTime(periodMonth.year, periodMonth.month + 1, 1).subtract(const Duration(days: 1));
  final transactions = await repo.fetchTransactions(from: monthStart, to: monthEnd);
  final active = transactions.where((t) => t.status == 'active').toList();

  var valueMissed = const Money.zero();
  for (final txn in active) {
    final usedProduct = productsByUserCardId[txn.userCardId];
    if (usedProduct == null) continue; // card since archived/removed
    final comparison = compareToOwnedCards(
      usedCard: usedProduct,
      ownedCards: allProducts,
      amount: txn.amount,
      categoryId: txn.categoryId,
    );
    valueMissed += comparison.missedValue;
  }

  var baselineSingleCard = const Money.zero();
  for (final candidate in allProducts) {
    var total = const Money.zero();
    for (final txn in active) {
      total += baseRateValueFor(product: candidate, amount: txn.amount, categoryId: txn.categoryId);
    }
    if (total > baselineSingleCard) baselineSingleCard = total;
  }

  return _MonthlyExtras(
    baselineSingleCard: baselineSingleCard,
    valueMissed: valueMissed,
    hasCounterfactual: true,
  );
});

/// ui-spec.md E9 Monthly Savings Report. GET /monthly-reports is new this
/// pass (Task E9) — recomputes the CURRENT month on demand server-side for
/// totalSpend/rewardsEarned; baseline_single_card/value_missed come from
/// [_monthlyExtrasProvider] above instead of the server's always-0 fields
/// (see that route's doc-comment in api/src/index.js for why the server
/// leaves them at 0 — this screen fills the gap client-side using the
/// same calculator D6 Missed Opportunities already trusts).
class MonthlySavingsScreen extends ConsumerWidget {
  const MonthlySavingsScreen({super.key});
  static final _shareBoundaryKey = GlobalKey();

  Future<void> _shareAsImage(BuildContext context) async {
    try {
      final boundary = _shareBoundaryKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 3);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      if (bytes == null) return;
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/pandapay_monthly_savings_report.png');
      await file.writeAsBytes(bytes.buffer.asUint8List());
      await SharePlus.instance.share(
        ShareParams(files: [XFile(file.path)], text: 'My PandaPay savings report'),
      );
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Could not share. ${userFacingErrorMessage(e)}')));
      }
    }
  }

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
            message:
                'Log a few transactions this month and your savings report will appear here — '
                'never shown as ₹0 while there\'s simply no data yet.',
          );
        }
        final extras = ref.watch(_monthlyExtrasProvider(r.periodMonth));
        final overview = ref.watch(insightsOverviewProvider(InsightsPeriod.thisMonth)).valueOrNull;
        final streakDays = ref.watch(homeSummaryProvider).valueOrNull?.streakDays ?? 0;
        return Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(AppSpace.lg, AppSpace.lg, AppSpace.lg, AppSpace.lg),
                children: [
                  // Design 32's shareable card. Only what's inside this
                  // RepaintBoundary lands in the PNG — the breakdown and the
                  // referral prompt below it are for the person reading the
                  // app, not for whoever they send this to.
                  RepaintBoundary(
                    key: _shareBoundaryKey,
                    child: _RecapCard(
                      report: r,
                      extras: extras.valueOrNull,
                      overview: overview,
                      streakDays: streakDays,
                    ),
                  ),
                  const SizedBox(height: AppSpace.lg),
                  FilledButton.icon(
                    onPressed: () => _shareAsImage(context),
                    style: FilledButton.styleFrom(
                      backgroundColor: BambooInk.slate,
                      foregroundColor: BambooInk.onSlate,
                      minimumSize: const Size.fromHeight(48),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      textStyle: BambooFonts.ui(14.5, weight: FontWeight.w700),
                    ),
                    icon: const Icon(Icons.ios_share_rounded, size: 18, color: BambooInk.lime),
                    label: const Text('Share this card'),
                  ),
                  if (overview != null && overview.byCategory.isNotEmpty) ...[
                    const SizedBox(height: AppSpace.xl),
                    _WhereItCameFrom(categories: overview.byCategory),
                  ],
                  const SizedBox(height: AppSpace.xl),
                  const _ReferralPrompt(),
                  const SizedBox(height: AppSpace.xl),
                  Text('The detail', style: BambooFonts.heading(17, color: BambooInk.ink900)),
                  const SizedBox(height: AppSpace.sm),
                  Container(
                    padding: const EdgeInsets.all(AppSpace.lg),
                    decoration: BoxDecoration(
                      color: BambooInk.glassFillOnPaper,
                      borderRadius: BorderRadius.circular(AppRadius.lg),
                      border: Border.all(color: BambooInk.hairlineOnPaper),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _StatRow(
                          label: 'Total spend',
                          child: MoneyText(
                            r.totalSpend,
                            confidence: Confidence.estimated,
                            style: BambooFonts.money(15, color: BambooInk.ink900),
                          ),
                        ),
                        const Divider(height: AppSpace.xl),
                        extras.when(
                          loading: () => const Padding(
                            padding: EdgeInsets.symmetric(vertical: AppSpace.lg),
                            child: Center(child: CircularProgressIndicator()),
                          ),
                          error: (_, _) => Text(
                            "Couldn't compute this month's baseline comparison.",
                            style: BambooFonts.ui(12.5, color: BambooInk.ink500),
                          ),
                          data: (e) {
                            if (!e.hasCounterfactual) {
                              return Container(
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
                                        'Add a second card to see what a single best-overall card would '
                                        'have earned instead, and what a suboptimal choice may have cost.',
                                        style: BambooFonts.ui(12.5, color: BambooInk.ink500),
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            }
                            return Column(
                              children: [
                                _StatRow(
                                  label: 'Single best card would\'ve earned',
                                  child: MoneyText(
                                    e.baselineSingleCard,
                                    confidence: Confidence.estimated,
                                    style: BambooFonts.money(15, color: BambooInk.ink900),
                                  ),
                                ),
                                const SizedBox(height: AppSpace.sm),
                                _StatRow(
                                  label: 'Value missed to suboptimal picks',
                                  child: MoneyText(
                                    e.valueMissed,
                                    confidence: Confidence.estimated,
                                    style: BambooFonts.money(
                                      15,
                                      color: e.valueMissed.isZero ? BambooInk.ink900 : BambooInk.clay,
                                    ),
                                  ),
                                ),
                              ],
                            );
                          },
                        ),
                      ],
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
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December',
    ];
    return '${names[d.month - 1]} ${d.year}';
  }
}

/// Design 32's shareable recap — the only part of this screen that ends up
/// in the exported PNG.
///
/// The headline is *"Panda saved me ₹X"*, which is deliberately **not** the
/// same figure as "rewards earned": it is earned minus what a single
/// best-overall card would have earned across the same month, i.e. what
/// having a wallet and choosing between it actually bought. That is the
/// claim worth sharing, and it is the one the deck makes.
///
/// When there is no counterfactual to compute — a user with one card has
/// nothing to have chosen instead of — the card falls back to reporting
/// rewards earned and drops the comparison clause entirely, rather than
/// printing "saved ₹0" onto something built to be shared.
class _RecapCard extends StatelessWidget {
  final MonthlyReport report;
  final _MonthlyExtras? extras;
  final InsightsOverview? overview;
  final int streakDays;

  const _RecapCard({
    required this.report,
    required this.extras,
    required this.overview,
    required this.streakDays,
  });

  @override
  Widget build(BuildContext context) {
    final hasComparison = extras?.hasCounterfactual ?? false;
    final savedVsOneCard = hasComparison
        ? report.rewardsEarned - extras!.baselineSingleCard
        : report.rewardsEarned;
    final payments = overview?.transactionCount ?? 0;

    return Container(
      padding: const EdgeInsets.all(AppSpace.lg),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [BambooInk.slateRaised, BambooInk.slate, BambooInk.slateLow],
        ),
        borderRadius: BorderRadius.circular(28),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const PandaMark(size: 26),
              const SizedBox(width: AppSpace.sm),
              Text('PandaPay', style: BambooFonts.heading(15, color: BambooInk.onSlate)),
              const Spacer(),
              Text(
                MonthlySavingsScreen._monthLabel(report.periodMonth),
                style: BambooFonts.ui(12, weight: FontWeight.w600, color: BambooInk.onSlateMuted),
              ),
            ],
          ),
          const SizedBox(height: AppSpace.xl),
          Text(
            hasComparison ? 'Panda saved me' : 'Panda earned me',
            style: BambooFonts.ui(13, color: BambooInk.onSlateMuted),
          ),
          const SizedBox(height: AppSpace.xs),
          MoneyText(
            savedVsOneCard,
            confidence: Confidence.estimated,
            style: BambooFonts.money(44, color: BambooInk.lime),
            hidePaise: true,
          ),
          const SizedBox(height: AppSpace.sm),
          Text(
            [
              if (payments > 0) 'across $payments payment${payments == 1 ? '' : 's'}',
              if (hasComparison) 'more than paying with one card all month',
            ].join(' — '),
            style: BambooFonts.ui(12.5, color: BambooInk.onSlateSubtle, height: 1.45),
          ),
          const SizedBox(height: AppSpace.lg),
          const Divider(height: 1, color: BambooInk.slateHairline),
          const SizedBox(height: AppSpace.lg),
          Row(
            children: [
              _RecapTile(label: 'Best card', value: overview?.bestCard?.label ?? '—'),
              _RecapTile(label: 'Top category', value: overview?.bestCategory?.label ?? '—'),
              _RecapTile(
                label: 'Streak',
                value: streakDays > 0 ? '$streakDays day${streakDays == 1 ? '' : 's'}' : '—',
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _RecapTile extends StatelessWidget {
  final String label;
  final String value;
  const _RecapTile({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: BambooFonts.ui(11, color: BambooInk.onSlateMuted)),
          const SizedBox(height: 3),
          Text(
            value,
            style: BambooFonts.heading(14, color: BambooInk.onSlate),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

/// Design 32's "Where it came from" — the category split, outside the
/// shareable card because it is detail for the user rather than a claim for
/// an audience.
class _WhereItCameFrom extends StatelessWidget {
  final List<CategoryEarning> categories;
  const _WhereItCameFrom({required this.categories});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Where it came from', style: BambooFonts.heading(17, color: BambooInk.ink900)),
        const SizedBox(height: AppSpace.sm),
        for (final category in categories.take(4))
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpace.xs),
            child: Row(
              children: [
                Expanded(
                  child: Text(category.label, style: BambooFonts.ui(13.5, color: BambooInk.ink900)),
                ),
                MoneyText(
                  category.earned,
                  confidence: Confidence.confirmed,
                  style: BambooFonts.money(14, color: BambooInk.ink900),
                  hidePaise: true,
                  showConfidenceIcon: false,
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Design 32's "Invite a friend, both get ₹100 — share the recap and your
/// code travels with it."
///
/// Hidden when there is no referral payload to show (signed out, or the
/// referral row hasn't been provisioned) rather than rendering a prompt
/// that leads nowhere.
class _ReferralPrompt extends ConsumerWidget {
  const _ReferralPrompt();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final referral = ref.watch(referralsProvider).valueOrNull;
    if (referral == null) return const SizedBox.shrink();

    return Pressable(
      onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const InviteFriendsScreen())),
      semanticLabel: 'Invite a friend, both get ₹100',
      child: Container(
        decoration: BoxDecoration(
          color: BambooInk.rankBadgeBg,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: BambooInk.rankBadgeBorder),
        ),
        padding: const EdgeInsets.all(AppSpace.md),
        child: Row(
          children: [
            const Icon(Icons.card_giftcard_rounded, size: 18, color: BambooInk.rankBadgeInk),
            const SizedBox(width: AppSpace.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Invite a friend, both get ₹100',
                    style: BambooFonts.ui(13, weight: FontWeight.w700, color: BambooInk.rankBadgeInk),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Share the recap and your code travels with it.',
                    style: BambooFonts.ui(12.5, color: BambooInk.ink500),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded, size: 20, color: BambooInk.ink300),
          ],
        ),
      ),
    );
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
