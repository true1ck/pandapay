import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../app/router.dart';
import '../../data/api_exception.dart';
import '../../data/user_cards_repository.dart';
import '../../main.dart' show MoneyText;

const _assumedGracePeriodDays = 20; // matches billing_float_screen.dart's own assumption

/// C2 Card Detail — tabbed (ui-spec Group C, implementation-plan-group-c-d.md).
/// Deep-linkable at /cards/:id. Reads [myCardsWithProductProvider] (not
/// ownedCardsWithProductProvider) deliberately — a card reached from C1's
/// archived filter must still resolve here, read-only.
class CardDetailScreen extends ConsumerWidget {
  final String userCardId;
  const CardDetailScreen({super.key, required this.userCardId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pairs = ref.watch(myCardsWithProductProvider);
    return DefaultTabController(
      length: 6,
      child: Scaffold(
        appBar: AppBar(
          title: Text(pairs.valueOrNull
                  ?.where((p) => p.$1.id == userCardId)
                  .map((p) => p.$1.nickname?.isNotEmpty == true ? p.$1.nickname! : p.$2.name)
                  .firstOrNull ??
              'Card detail'),
          actions: [
            if (pairs.valueOrNull?.any((p) => p.$1.id == userCardId) ?? false) ...[
              IconButton(
                tooltip: 'Edit',
                icon: const Icon(Icons.edit_outlined),
                onPressed: () => context.push('/cards/$userCardId/edit'),
              ),
              IconButton(
                tooltip: 'Report wrong data',
                icon: const Icon(Icons.flag_outlined),
                onPressed: () => context.push(
                  '${AppRoute.reportWrongData}?cardProductId=${pairs.requireValue.firstWhere((p) => p.$1.id == userCardId).$2.id}',
                ),
              ),
            ],
          ],
          bottom: const TabBar(
            isScrollable: true,
            tabs: [
              Tab(text: 'Rewards'),
              Tab(text: 'Caps'),
              Tab(text: 'Milestones'),
              Tab(text: 'Fees'),
              Tab(text: 'Benefits'),
              Tab(text: 'Statement'),
            ],
          ),
        ),
        body: pairs.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (err, _) => ErrorState(
            message: userFacingErrorMessage(err),
            onRetry: () => ref.invalidate(myCardsProvider),
          ),
          data: (owned) {
            final match = owned.where((p) => p.$1.id == userCardId).firstOrNull;
            if (match == null) {
              return const ErrorState(message: 'This card could not be found — it may have been removed.');
            }
            final (userCard, product) = match;
            return TabBarView(
              children: [
                _RewardsTab(product: product),
                _CapsTab(userCard: userCard, product: product),
                _MilestonesTab(userCard: userCard, product: product),
                _FeesTab(userCard: userCard),
                _BenefitsTab(product: product),
                _StatementTab(userCard: userCard),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _RewardsTab extends ConsumerWidget {
  final CardProduct product;
  const _RewardsTab({required this.product});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final categories = ref.watch(categoriesProvider).valueOrNull ?? const [];
    String categoryName(String? id) {
      if (id == null) return 'All other spends';
      for (final c in categories) {
        if (c.id == id) return c.name;
      }
      return 'Unknown category';
    }

    final rules = List<RewardRule>.from(product.rewardRules)..sort((a, b) => a.priority.compareTo(b.priority));
    if (rules.isEmpty) {
      return const EmptyState(icon: Icons.percent_outlined, title: 'No reward structure on file yet');
    }
    return ListView(
      padding: const EdgeInsets.all(AppSpace.lg),
      children: [
        if (product.verifiedAt != null)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpace.md),
            child: Text(
              'Verified ${_monthYear(product.verifiedAt!)}',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppColors.ink500),
            ),
          ),
        for (final rule in rules)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpace.sm),
            child: Container(
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(AppRadius.lg),
                border: Border.all(color: AppColors.ink100),
              ),
              padding: const EdgeInsets.all(AppSpace.lg),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(categoryName(rule.categoryId), style: Theme.of(context).textTheme.titleSmall),
                        if (rule.rail != null) ...[
                          const SizedBox(height: 2),
                          Text(_railLabel(rule.rail!), style: Theme.of(context).textTheme.bodySmall),
                        ],
                      ],
                    ),
                  ),
                  Text(_rateLabel(rule), style: Theme.of(context).textTheme.titleMedium),
                ],
              ),
            ),
          ),
      ],
    );
  }

  static String _rate(double rate) => rate == rate.roundToDouble() ? rate.toStringAsFixed(0) : rate.toString();

  static String _rateLabel(RewardRule rule) => switch (rule.unit) {
        RewardUnit.cashbackPercent || RewardUnit.discountPercent => '${_rate(rule.rate)}%',
        RewardUnit.pointsPer100 => '${_rate(rule.rate)} pts/₹100',
        RewardUnit.pointsPer150 => '${_rate(rule.rate)} pts/₹150',
        RewardUnit.pointsPer200 => '${_rate(rule.rate)} pts/₹200',
        RewardUnit.milesPer100 => '${_rate(rule.rate)} miles/₹100',
        RewardUnit.flatPoints => '${_rate(rule.rate)} pts flat',
      };

  static String _railLabel(TxnRail rail) => switch (rail) {
        TxnRail.upiQr => 'UPI QR only',
        TxnRail.swipe => 'Swipe only',
        TxnRail.online => 'Online only',
        TxnRail.contactless => 'Contactless only',
        TxnRail.atm => 'ATM only',
        TxnRail.emi => 'EMI only',
        TxnRail.unknown => '',
      };

  static String _monthYear(DateTime d) {
    const months = [
      'January', 'February', 'March', 'April', 'May', 'June',
      'July', 'August', 'September', 'October', 'November', 'December',
    ];
    return '${months[d.month - 1]} ${d.year}';
  }
}

class _CapsTab extends StatelessWidget {
  final UserCard userCard;
  final CardProduct product;
  const _CapsTab({required this.userCard, required this.product});

  @override
  Widget build(BuildContext context) {
    if (product.capRules.isEmpty) {
      return const EmptyState(icon: Icons.speed_outlined, title: 'No caps on this card');
    }
    final textTheme = Theme.of(context).textTheme;
    return ListView(
      padding: const EdgeInsets.all(AppSpace.lg),
      children: [
        for (final cap in product.capRules)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpace.md),
            child: Builder(builder: (context) {
              final consumed = userCard.capConsumed[cap.id] ?? const Money.zero();
              final ratio = capRatio(consumed, cap.capValue);
              final isCount = cap.measure == CapMeasure.txnCount;
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
                    Text(cap.label, style: textTheme.titleSmall),
                    const SizedBox(height: AppSpace.sm),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(AppRadius.pill),
                      child: LinearProgressIndicator(
                        value: ratio,
                        minHeight: 8,
                        backgroundColor: AppColors.surfaceMuted,
                        color: ratio >= 0.9 ? AppColors.warning : AppColors.teal600,
                      ),
                    ),
                    const SizedBox(height: AppSpace.sm),
                    Text(
                      isCount
                          ? '${consumed.paise ~/ 100} / ${cap.capValue.paise ~/ 100} transactions'
                          : '${consumed.format()} of ${cap.capValue.format()}',
                      style: textTheme.bodySmall,
                    ),
                    const SizedBox(height: 2),
                    Text('Resets: ${_periodLabel(cap.period)}', style: textTheme.bodySmall),
                  ],
                ),
              );
            }),
          ),
      ],
    );
  }

  static String _periodLabel(CapPeriod period) => switch (period) {
        CapPeriod.statementCycle => 'each statement cycle',
        CapPeriod.calendarMonth => 'each calendar month',
        CapPeriod.quarter => 'each quarter',
        CapPeriod.halfYear => 'each half-year',
        CapPeriod.annual => 'each year',
        CapPeriod.lifetime => 'never (lifetime cap)',
      };
}

class _MilestonesTab extends StatelessWidget {
  final UserCard userCard;
  final CardProduct product;
  const _MilestonesTab({required this.userCard, required this.product});

  @override
  Widget build(BuildContext context) {
    if (product.milestoneRules.isEmpty) {
      return const EmptyState(icon: Icons.flag_outlined, title: 'No milestones on this card');
    }
    final textTheme = Theme.of(context).textTheme;
    return ListView(
      padding: const EdgeInsets.all(AppSpace.lg),
      children: [
        for (final milestone in product.milestoneRules)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpace.md),
            child: Builder(builder: (context) {
              final qualified = userCard.milestoneQualifiedSpend[milestone.id] ?? const Money.zero();
              final remainingPaise =
                  (milestone.thresholdSpend.paise - qualified.paise).clamp(0, milestone.thresholdSpend.paise);
              final remaining = Money.fromPaise(remainingPaise);
              final ratio = milestone.thresholdSpend.isZero ? 0.0 : capRatio(qualified, milestone.thresholdSpend);
              final reached = remainingPaise == 0;
              final periodEnd = userCard.milestonePeriodEnd[milestone.id];
              final daysLeft = periodEnd == null ? null : daysUntil(periodEnd, DateTime.now());

              return Container(
                decoration: BoxDecoration(
                  color: reached ? AppColors.successBg : AppColors.surface,
                  borderRadius: BorderRadius.circular(AppRadius.lg),
                  border: Border.all(color: reached ? AppColors.success : AppColors.ink100),
                ),
                padding: const EdgeInsets.all(AppSpace.lg),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(child: Text(milestone.label, style: textTheme.titleSmall)),
                        if (reached)
                          const StatusPill(
                            label: 'REACHED',
                            foreground: Colors.white,
                            background: AppColors.success,
                            icon: Icons.check_rounded,
                          ),
                      ],
                    ),
                    const SizedBox(height: AppSpace.sm),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(AppRadius.pill),
                      child: LinearProgressIndicator(
                        value: ratio,
                        minHeight: 8,
                        backgroundColor: AppColors.surfaceMuted,
                        color: reached ? AppColors.success : AppColors.teal600,
                      ),
                    ),
                    const SizedBox(height: AppSpace.sm),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(reached ? 'Reached' : '${remaining.format()} to go', style: textTheme.labelLarge),
                        Row(children: [
                          Text('Reward ', style: textTheme.bodySmall),
                          MoneyText(milestone.rewardValue, confidence: Confidence.estimated, style: textTheme.bodySmall),
                        ]),
                      ],
                    ),
                    if (!reached && daysLeft != null) ...[
                      const SizedBox(height: AppSpace.xs),
                      Text('$daysLeft days left this period', style: textTheme.bodySmall),
                    ],
                  ],
                ),
              );
            }),
          ),
      ],
    );
  }
}

class _FeesTab extends StatelessWidget {
  final UserCard userCard;
  const _FeesTab({required this.userCard});

  @override
  Widget build(BuildContext context) {
    if (userCard.feeWaiverStates.isEmpty) {
      return const EmptyState(icon: Icons.card_giftcard_outlined, title: 'No fee-waiver rule on this card');
    }
    final textTheme = Theme.of(context).textTheme;
    return ListView(
      padding: const EdgeInsets.all(AppSpace.lg),
      children: [
        for (final fw in userCard.feeWaiverStates)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpace.md),
            child: Builder(builder: (context) {
              final waived = fw.waivedAt != null;
              final ratio = capRatio(fw.qualifiedSpend, fw.thresholdSpend);
              return Container(
                decoration: BoxDecoration(
                  color: waived ? AppColors.successBg : AppColors.surface,
                  borderRadius: BorderRadius.circular(AppRadius.lg),
                  border: Border.all(color: waived ? AppColors.success : AppColors.ink100),
                ),
                padding: const EdgeInsets.all(AppSpace.lg),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text('Fee waived at ', style: textTheme.bodySmall),
                        MoneyText(fw.waivesFee, confidence: Confidence.estimated, style: textTheme.bodySmall),
                        const Spacer(),
                        if (waived)
                          const StatusPill(
                            label: 'WAIVED',
                            foreground: Colors.white,
                            background: AppColors.success,
                            icon: Icons.check_rounded,
                          ),
                      ],
                    ),
                    if (!waived) ...[
                      const SizedBox(height: AppSpace.sm),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(AppRadius.pill),
                        child: LinearProgressIndicator(
                          value: ratio,
                          minHeight: 8,
                          backgroundColor: AppColors.surfaceMuted,
                          color: ratio >= 0.9 ? AppColors.warning : AppColors.teal600,
                        ),
                      ),
                      const SizedBox(height: AppSpace.sm),
                      Text('${fw.qualifiedSpend.format()} of ${fw.thresholdSpend.format()}', style: textTheme.bodySmall),
                    ],
                  ],
                ),
              );
            }),
          ),
        if (userCard.anniversaryOn != null)
          Padding(
            padding: const EdgeInsets.only(top: AppSpace.sm),
            child: Text(
              'Card anniversary: ${userCard.anniversaryOn!.toLocal().toString().split(' ').first}',
              style: textTheme.bodySmall,
            ),
          ),
      ],
    );
  }
}

class _BenefitsTab extends StatelessWidget {
  final CardProduct product;
  const _BenefitsTab({required this.product});

  @override
  Widget build(BuildContext context) {
    if (product.benefits.isEmpty) {
      return const EmptyState(icon: Icons.workspace_premium_outlined, title: 'No benefits on file for this card');
    }
    final textTheme = Theme.of(context).textTheme;
    return ListView(
      padding: const EdgeInsets.all(AppSpace.lg),
      children: [
        for (final benefit in product.benefits)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpace.sm),
            child: Container(
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(AppRadius.lg),
                border: Border.all(color: AppColors.ink100),
              ),
              padding: const EdgeInsets.all(AppSpace.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(benefit.label, style: textTheme.titleSmall),
                  if (benefit.description != null) ...[
                    const SizedBox(height: 4),
                    Text(benefit.description!, style: textTheme.bodyMedium),
                  ],
                  if (benefit.quotaCount != null) ...[
                    const SizedBox(height: 4),
                    Text('${benefit.quotaCount} / period', style: textTheme.bodySmall),
                  ],
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _StatementTab extends StatelessWidget {
  final UserCard userCard;
  const _StatementTab({required this.userCard});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    if (userCard.statementDay == null) {
      return const EmptyState(
        icon: Icons.receipt_long_outlined,
        title: 'Statement date not set',
        message: 'Add a statement day from Edit Card to see your billing cycle and interest-free float here.',
      );
    }
    final float = billingCycleFloat(statementDay: userCard.statementDay!, gracePeriodDays: _assumedGracePeriodDays);
    return ListView(
      padding: const EdgeInsets.all(AppSpace.lg),
      children: [
        Container(
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(AppRadius.lg),
            border: Border.all(color: AppColors.ink100),
          ),
          padding: const EdgeInsets.all(AppSpace.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Statement cuts on day ${userCard.statementDay}', style: textTheme.titleSmall),
              const SizedBox(height: AppSpace.sm),
              Text('Next statement in ${float.daysUntilStatement} days', style: textTheme.bodyMedium),
              const SizedBox(height: AppSpace.xs),
              Text(
                'Spending today gets up to ${float.totalInterestFreeDays} interest-free days '
                '(assumes a $_assumedGracePeriodDays-day grace period to the due date).',
                style: textTheme.bodySmall,
              ),
              if (userCard.dueDay != null) ...[
                const SizedBox(height: AppSpace.sm),
                Text('Payment due on day ${userCard.dueDay}', style: textTheme.bodyMedium),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull {
    final it = iterator;
    return it.moveNext() ? it.current : null;
  }
}
