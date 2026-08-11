import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/offline_banner.dart';
import '../../app/providers.dart';
import '../../app/router.dart';
import 'card_actions_screen.dart';
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
        backgroundColor: BambooInk.paper,
        appBar: AppBar(
          backgroundColor: BambooInk.paper,
          foregroundColor: BambooInk.ink900,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          title: Text(
            pairs.valueOrNull
                    ?.where((p) => p.$1.id == userCardId)
                    .map((p) => p.$1.nickname?.isNotEmpty == true ? p.$1.nickname! : p.$2.name)
                    .firstOrNull ??
                'Card detail',
            style: BambooFonts.heading(17, color: BambooInk.ink900),
          ),
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
              // Design 23 Card actions — pause / report lost / default /
              // remove. Kept off the tab bar below: those six tabs are all
              // *readings* of the card, these are the things that change it.
              IconButton(
                tooltip: 'Card actions',
                icon: const Icon(Icons.more_horiz_rounded),
                onPressed: () {
                  final pair = pairs.requireValue.firstWhere((p) => p.$1.id == userCardId);
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => CardActionsScreen(card: pair.$1, product: pair.$2),
                    ),
                  );
                },
              ),
            ],
          ],
          bottom: TabBar(
            isScrollable: true,
            labelColor: BambooInk.slate,
            unselectedLabelColor: BambooInk.ink500,
            indicatorColor: BambooInk.slate,
            labelStyle: BambooFonts.ui(13.5, weight: FontWeight.w700),
            unselectedLabelStyle: BambooFonts.ui(13.5, weight: FontWeight.w500),
            tabs: const [
              Tab(text: 'Rewards'),
              Tab(text: 'Caps'),
              Tab(text: 'Milestones'),
              Tab(text: 'Fees'),
              Tab(text: 'Benefits'),
              Tab(text: 'Statement'),
            ],
          ),
        ),
        body: AppBackground(
          child: Column(
            children: [
              OfflineBanner(gutter: AppSpace.lg, onRetry: () => ref.invalidate(myCardsProvider)),
              Expanded(
                child: pairs.when(
                  loading: () => const Padding(
                    padding: EdgeInsets.symmetric(horizontal: AppSpace.lg),
                    child: SkeletonList(count: 4),
                  ),
                  error: (err, _) => ErrorState(
                    message: userFacingErrorMessage(err),
                    onRetry: () => ref.invalidate(myCardsProvider),
                  ),
                  data: (owned) {
                    final match = owned.where((p) => p.$1.id == userCardId).firstOrNull;
                    if (match == null) {
                      return const ErrorState(
                        message: 'This card could not be found — it may have been removed.',
                      );
                    }
                    final (userCard, product) = match;
                    return TabBarView(
                      children: [
                        _RewardsTab(product: product),
                        _CapsTab(userCard: userCard, product: product),
                        _MilestonesTab(userCard: userCard, product: product),
                        _FeesTab(userCard: userCard, product: product),
                        _BenefitsTab(product: product),
                        _StatementTab(userCard: userCard),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
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

    final rules = List<RewardRule>.from(product.rewardRules)
      ..sort((a, b) => a.priority.compareTo(b.priority));
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
              style: BambooFonts.ui(12.5, color: BambooInk.ink500),
            ),
          ),
        for (final rule in rules)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpace.sm),
            child: Container(
              decoration: BoxDecoration(
                color: BambooInk.glassFillOnPaper,
                borderRadius: BorderRadius.circular(AppRadius.lg),
                border: Border.all(color: BambooInk.hairlineOnPaper),
              ),
              padding: const EdgeInsets.all(AppSpace.lg),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          categoryName(rule.categoryId),
                          style: BambooFonts.heading(14.5, color: BambooInk.ink900),
                        ),
                        if (rule.rail != null) ...[
                          const SizedBox(height: 2),
                          Text(_railLabel(rule.rail!), style: BambooFonts.ui(12.5, color: BambooInk.ink500)),
                        ],
                      ],
                    ),
                  ),
                  Text(_rateLabel(rule), style: BambooFonts.heading(17, color: BambooInk.ink900)),
                ],
              ),
            ),
          ),
      ],
    );
  }

  static String _rate(double rate) =>
      rate == rate.roundToDouble() ? rate.toStringAsFixed(0) : rate.toString();

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
    return ListView(
      padding: const EdgeInsets.all(AppSpace.lg),
      children: [
        for (final cap in product.capRules)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpace.md),
            child: Builder(
              builder: (context) {
                final consumed = userCard.capConsumed[cap.id] ?? const Money.zero();
                final ratio = capRatio(consumed, cap.capValue);
                final isCount = cap.measure == CapMeasure.txnCount;
                return Container(
                  decoration: BoxDecoration(
                    color: BambooInk.glassFillOnPaper,
                    borderRadius: BorderRadius.circular(AppRadius.lg),
                    border: Border.all(color: BambooInk.hairlineOnPaper),
                  ),
                  padding: const EdgeInsets.all(AppSpace.lg),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(cap.label, style: BambooFonts.heading(14.5, color: BambooInk.ink900)),
                      const SizedBox(height: AppSpace.sm),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(AppRadius.pill),
                        child: LinearProgressIndicator(
                          value: ratio,
                          minHeight: 8,
                          backgroundColor: BambooInk.paperMuted,
                          color: ratio >= 0.9 ? BambooInk.clay : BambooInk.jade,
                        ),
                      ),
                      const SizedBox(height: AppSpace.sm),
                      Text(
                        isCount
                            ? '${consumed.paise ~/ 100} / ${cap.capValue.paise ~/ 100} transactions'
                            : '${consumed.format()} of ${cap.capValue.format()}',
                        style: BambooFonts.ui(12.5, color: BambooInk.ink500),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Resets: ${_periodLabel(cap.period)}',
                        style: BambooFonts.ui(12.5, color: BambooInk.ink500),
                      ),
                    ],
                  ),
                );
              },
            ),
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
    return ListView(
      padding: const EdgeInsets.all(AppSpace.lg),
      children: [
        for (final milestone in product.milestoneRules)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpace.md),
            child: Builder(
              builder: (context) {
                final qualified = userCard.milestoneQualifiedSpend[milestone.id] ?? const Money.zero();
                final remainingPaise = (milestone.thresholdSpend.paise - qualified.paise).clamp(
                  0,
                  milestone.thresholdSpend.paise,
                );
                final remaining = Money.fromPaise(remainingPaise);
                final ratio = milestone.thresholdSpend.isZero
                    ? 0.0
                    : capRatio(qualified, milestone.thresholdSpend);
                final reached = remainingPaise == 0;
                final periodEnd = userCard.milestonePeriodEnd[milestone.id];
                final daysLeft = periodEnd == null ? null : daysUntil(periodEnd, DateTime.now());

                return Container(
                  decoration: BoxDecoration(
                    color: reached ? BambooInk.jade.withValues(alpha: 0.10) : BambooInk.glassFillOnPaper,
                    borderRadius: BorderRadius.circular(AppRadius.lg),
                    border: Border.all(color: reached ? BambooInk.jade : BambooInk.hairlineOnPaper),
                  ),
                  padding: const EdgeInsets.all(AppSpace.lg),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              milestone.label,
                              style: BambooFonts.heading(14.5, color: BambooInk.ink900),
                            ),
                          ),
                          if (reached)
                            const StatusPill(
                              label: 'REACHED',
                              foreground: BambooInk.onSlate,
                              background: BambooInk.jade,
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
                          backgroundColor: BambooInk.paperMuted,
                          color: BambooInk.jade,
                        ),
                      ),
                      const SizedBox(height: AppSpace.sm),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            reached ? 'Reached' : '${remaining.format()} to go',
                            style: BambooFonts.ui(12.5, weight: FontWeight.w700, color: BambooInk.ink900),
                          ),
                          Row(
                            children: [
                              Text('Reward ', style: BambooFonts.ui(12.5, color: BambooInk.ink500)),
                              MoneyText(
                                milestone.rewardValue,
                                confidence: Confidence.estimated,
                                style: BambooFonts.ui(12.5, color: BambooInk.ink500),
                              ),
                            ],
                          ),
                        ],
                      ),
                      if (!reached && daysLeft != null) ...[
                        const SizedBox(height: AppSpace.xs),
                        Text(
                          '$daysLeft days left this period',
                          style: BambooFonts.ui(12.5, color: BambooInk.ink500),
                        ),
                      ],
                    ],
                  ),
                );
              },
            ),
          ),
      ],
    );
  }
}

class _FeesTab extends StatelessWidget {
  final UserCard userCard;
  final CardProduct product;
  const _FeesTab({required this.userCard, required this.product});

  @override
  Widget build(BuildContext context) {
    // Design 08 lists the annual fee as a required element of Card detail.
    // It was parsed (CardProduct.annualFeeInr) but never rendered anywhere —
    // this tab only ever showed fee-WAIVER progress, which is a different
    // thing and meaningless without the fee it waives.
    final feeHeader = Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.md),
      child: Container(
        padding: const EdgeInsets.all(AppSpace.lg),
        decoration: BoxDecoration(
          color: BambooInk.glassFillOnPaper,
          borderRadius: BorderRadius.circular(AppRadius.lg),
          border: Border.all(color: BambooInk.hairlineOnPaper),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'ANNUAL FEE',
                    style: BambooFonts.ui(
                      11,
                      weight: FontWeight.w600,
                      color: BambooInk.ink500,
                    ).copyWith(letterSpacing: 1),
                  ),
                  const SizedBox(height: 4),
                  if (product.annualFeeInr == null)
                    Text('Not recorded for this card', style: BambooFonts.ui(13.5, color: BambooInk.ink500))
                  else if (product.annualFeeInr!.isZero)
                    Text('Lifetime free', style: BambooFonts.heading(20, color: BambooInk.jade))
                  else
                    MoneyText(
                      product.annualFeeInr!,
                      confidence: Confidence.confirmed,
                      style: BambooFonts.money(22, color: BambooInk.ink900),
                    ),
                ],
              ),
            ),
            if (product.joiningFeeInr != null && !product.joiningFeeInr!.isZero)
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    'JOINING',
                    style: BambooFonts.ui(
                      11,
                      weight: FontWeight.w600,
                      color: BambooInk.ink500,
                    ).copyWith(letterSpacing: 1),
                  ),
                  const SizedBox(height: 4),
                  MoneyText(
                    product.joiningFeeInr!,
                    confidence: Confidence.confirmed,
                    style: BambooFonts.ui(15, weight: FontWeight.w600, color: BambooInk.ink900),
                  ),
                ],
              ),
          ],
        ),
      ),
    );

    if (userCard.feeWaiverStates.isEmpty) {
      return ListView(
        padding: const EdgeInsets.all(AppSpace.lg),
        children: [
          feeHeader,
          const EmptyState(icon: Icons.card_giftcard_outlined, title: 'No fee-waiver rule on this card'),
        ],
      );
    }
    return ListView(
      padding: const EdgeInsets.all(AppSpace.lg),
      children: [
        feeHeader,
        for (final fw in userCard.feeWaiverStates)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpace.md),
            child: Builder(
              builder: (context) {
                final waived = fw.waivedAt != null;
                final ratio = capRatio(fw.qualifiedSpend, fw.thresholdSpend);
                return Container(
                  decoration: BoxDecoration(
                    color: waived ? BambooInk.jade.withValues(alpha: 0.10) : BambooInk.glassFillOnPaper,
                    borderRadius: BorderRadius.circular(AppRadius.lg),
                    border: Border.all(color: waived ? BambooInk.jade : BambooInk.hairlineOnPaper),
                  ),
                  padding: const EdgeInsets.all(AppSpace.lg),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text('Fee waived at ', style: BambooFonts.ui(12.5, color: BambooInk.ink500)),
                          MoneyText(
                            fw.waivesFee,
                            confidence: Confidence.estimated,
                            style: BambooFonts.ui(12.5, color: BambooInk.ink500),
                          ),
                          const Spacer(),
                          if (waived)
                            const StatusPill(
                              label: 'WAIVED',
                              foreground: BambooInk.onSlate,
                              background: BambooInk.jade,
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
                            backgroundColor: BambooInk.paperMuted,
                            color: ratio >= 0.9 ? BambooInk.clay : BambooInk.jade,
                          ),
                        ),
                        const SizedBox(height: AppSpace.sm),
                        Text(
                          '${fw.qualifiedSpend.format()} of ${fw.thresholdSpend.format()}',
                          style: BambooFonts.ui(12.5, color: BambooInk.ink500),
                        ),
                      ],
                    ],
                  ),
                );
              },
            ),
          ),
        if (userCard.anniversaryOn != null)
          Padding(
            padding: const EdgeInsets.only(top: AppSpace.sm),
            child: Text(
              'Card anniversary: ${userCard.anniversaryOn!.toLocal().toString().split(' ').first}',
              style: BambooFonts.ui(12.5, color: BambooInk.ink500),
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
      return const EmptyState(
        icon: Icons.workspace_premium_outlined,
        title: 'No benefits on file for this card',
      );
    }
    return ListView(
      padding: const EdgeInsets.all(AppSpace.lg),
      children: [
        for (final benefit in product.benefits)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpace.sm),
            child: Container(
              decoration: BoxDecoration(
                color: BambooInk.glassFillOnPaper,
                borderRadius: BorderRadius.circular(AppRadius.lg),
                border: Border.all(color: BambooInk.hairlineOnPaper),
              ),
              padding: const EdgeInsets.all(AppSpace.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(benefit.label, style: BambooFonts.heading(14.5, color: BambooInk.ink900)),
                  if (benefit.description != null) ...[
                    const SizedBox(height: 4),
                    Text(benefit.description!, style: BambooFonts.ui(13.5, color: BambooInk.ink900)),
                  ],
                  if (benefit.quotaCount != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      '${benefit.quotaCount} / period',
                      style: BambooFonts.ui(12.5, color: BambooInk.ink500),
                    ),
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
    if (userCard.statementDay == null) {
      return const EmptyState(
        icon: Icons.receipt_long_outlined,
        title: 'Statement date not set',
        message: 'Add a statement day from Edit Card to see your billing cycle and interest-free float here.',
      );
    }
    final float = billingCycleFloat(
      statementDay: userCard.statementDay!,
      gracePeriodDays: _assumedGracePeriodDays,
    );
    return ListView(
      padding: const EdgeInsets.all(AppSpace.lg),
      children: [
        Container(
          decoration: BoxDecoration(
            color: BambooInk.glassFillOnPaper,
            borderRadius: BorderRadius.circular(AppRadius.lg),
            border: Border.all(color: BambooInk.hairlineOnPaper),
          ),
          padding: const EdgeInsets.all(AppSpace.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Statement cuts on day ${userCard.statementDay}',
                style: BambooFonts.heading(14.5, color: BambooInk.ink900),
              ),
              const SizedBox(height: AppSpace.sm),
              Text(
                'Next statement in ${float.daysUntilStatement} days',
                style: BambooFonts.ui(13.5, color: BambooInk.ink900),
              ),
              const SizedBox(height: AppSpace.xs),
              Text(
                'Spending today gets up to ${float.totalInterestFreeDays} interest-free days '
                '(assumes a $_assumedGracePeriodDays-day grace period to the due date).',
                style: BambooFonts.ui(12.5, color: BambooInk.ink500),
              ),
              if (userCard.dueDay != null) ...[
                const SizedBox(height: AppSpace.sm),
                Text(
                  'Payment due on day ${userCard.dueDay}',
                  style: BambooFonts.ui(13.5, color: BambooInk.ink900),
                ),
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
