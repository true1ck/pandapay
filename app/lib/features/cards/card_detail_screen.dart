import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/display_text.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../app/router.dart';
import 'card_actions_screen.dart';
import 'card_visual.dart';
import '../insights/lounge_access_screen.dart' show isInCurrentLoungeWindow;
import '../../data/api_exception.dart';
import '../../data/spend_reports_repository.dart';
import '../../data/user_cards_repository.dart';
import '../../main.dart' show MoneyText;

const _assumedGracePeriodDays =
    20; // matches billing_float_screen.dart's own assumption

/// C2 Card Detail — one vertically scrollable card report (ui-spec Group C,
/// implementation-plan-group-c-d.md).
/// Deep-linkable at /cards/:id. Reads [myCardsWithProductProvider] (not
/// ownedCardsWithProductProvider) deliberately — a card reached from C1's
/// archived filter must still resolve here, read-only.
class CardDetailScreen extends ConsumerWidget {
  final String userCardId;
  final int initialTabIndex;

  const CardDetailScreen({
    super.key,
    required this.userCardId,
    this.initialTabIndex = 0,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pairs = ref.watch(myCardsWithProductProvider);
    return Scaffold(
      backgroundColor: BambooInk.paper,
      appBar: AppBar(
        backgroundColor: BambooInk.paper,
        foregroundColor: BambooInk.ink900,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text(
          pairs.valueOrNull
                  ?.where((p) => p.$1.id == userCardId)
                  .map(
                    (p) => p.$1.nickname?.isNotEmpty == true
                        ? p.$1.nickname!
                        : p.$2.name,
                  )
                  .firstOrNull ??
              'Card detail',
          style: BambooFonts.heading(17, color: BambooInk.ink900),
        ),
        actions: [
          if (pairs.valueOrNull?.any((p) => p.$1.id == userCardId) ??
              false) ...[
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
                final pair = pairs.requireValue.firstWhere(
                  (p) => p.$1.id == userCardId,
                );
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) =>
                        CardActionsScreen(card: pair.$1, product: pair.$2),
                  ),
                );
              },
            ),
          ],
        ],
      ),
      body: AppBackground(
        child: Column(
          children: [
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
                  final match = owned
                      .where((p) => p.$1.id == userCardId)
                      .firstOrNull;
                  if (match == null) {
                    return const ErrorState(
                      message:
                          'This card could not be found — it may have been removed.',
                    );
                  }
                  final (userCard, product) = match;
                  final spendSummary = ref.watch(
                    cardSpendSummaryProvider,
                  )[userCard.id];
                  final sections = [
                    (
                      label: 'Rewards',
                      body: _RewardsTab(product: product, embedded: true),
                    ),
                    (
                      label: 'Spend',
                      body: _SpendSection(userCard: userCard, product: product),
                    ),
                    (
                      label: 'Caps',
                      body: _CapsTab(
                        userCard: userCard,
                        product: product,
                        embedded: true,
                      ),
                    ),
                    (
                      label: 'Milestones',
                      body: _MilestonesTab(
                        userCard: userCard,
                        product: product,
                        embedded: true,
                      ),
                    ),
                    (
                      label: 'Fees',
                      body: _FeesTab(
                        userCard: userCard,
                        product: product,
                        embedded: true,
                      ),
                    ),
                    (
                      label: 'Benefits',
                      body: _BenefitsTab(
                        userCard: userCard,
                        product: product,
                        embedded: true,
                      ),
                    ),
                    (
                      label: 'Statement',
                      body: _StatementTab(userCard: userCard, embedded: true),
                    ),
                  ];
                  final selected = initialTabIndex.clamp(
                    0,
                    sections.length - 1,
                  );
                  final ordered = [
                    ...sections.skip(selected),
                    ...sections.take(selected),
                  ];
                  return ListView(
                    key: const ValueKey('cardDetailScroll'),
                    padding: const EdgeInsets.fromLTRB(
                      AppSpace.lg,
                      AppSpace.lg,
                      AppSpace.lg,
                      AppSpace.xl,
                    ),
                    children: [
                      CardVisual(
                        product: product,
                        height: 190,
                        userCard: userCard,
                        cycleSpend: spendSummary?.cycleTotal,
                        latestSpend: spendSummary?.latestSpend,
                      ),
                      const SizedBox(height: AppSpace.lg),
                      for (final section in ordered) ...[
                        _CardDetailSection(
                          label: section.label,
                          summary: _sectionSummary(
                            section.label,
                            userCard,
                            product,
                          ),
                          body: section.body,
                        ),
                      ],
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _sectionSummary(String label, UserCard card, CardProduct product) {
  return switch (label) {
    'Rewards' =>
      '${uniqueRewardRules(product.rewardRules).length + (product.fuelRule == null ? 0 : 1)} earning rules · tap rows for details',
    'Spend' => 'This month · actual spend and effective reward rate',
    'Caps' =>
      '${uniqueCapRules(product.capRules).length} tracked caps · consumption resets by period',
    'Milestones' =>
      '${uniqueMilestoneRules(product.milestoneRules).length} milestone${uniqueMilestoneRules(product.milestoneRules).length == 1 ? '' : 's'} · progress to unlock',
    'Fees' =>
      card.annualFeeOverride?.isZero == true
          ? 'Lifetime free for you'
          : '${card.feeWaiverStates.length} waiver rule${card.feeWaiverStates.length == 1 ? '' : 's'} · annual fee below',
    'Benefits' =>
      '${uniqueCardBenefits(product.benefits).length} benefits · lounge access and protections',
    'Statement' =>
      card.statementDay == null
          ? 'Add statement day to see your billing cycle'
          : 'Cuts on day ${card.statementDay} · due day ${card.dueDay ?? 'not set'}',
    _ => '',
  };
}

Money? _effectiveAnnualFee(UserCard card, CardProduct product) =>
    card.annualFeeOverride ?? product.annualFeeInr;

class _CardDetailSection extends StatelessWidget {
  final String label;
  final String summary;
  final Widget body;

  const _CardDetailSection({
    required this.label,
    required this.summary,
    required this.body,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(
              left: AppSpace.xs,
              bottom: AppSpace.sm,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  label.toUpperCase(),
                  style: BambooFonts.ui(
                    12,
                    weight: FontWeight.w700,
                    color: BambooInk.ink500,
                  ).copyWith(letterSpacing: 1),
                ),
                const SizedBox(width: AppSpace.sm),
                Expanded(
                  child: Text(
                    summary,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: BambooFonts.ui(11.5, color: BambooInk.ink500),
                  ),
                ),
              ],
            ),
          ),
          body,
        ],
      ),
    );
  }
}

/// What this card actually did this month, and what it really paid.
///
/// Card Detail had six tabs describing the card's TERMS — its rates, caps,
/// milestones, fees, benefits and statement dates — and none describing the
/// card's PERFORMANCE. So the one question a cardholder most wants
/// answered, "is this card earning its keep?", had no home, even though
/// every figure needed to answer it was already being recorded.
///
/// Reuses the shared spend report rather than adding a per-card endpoint:
/// `GET /spend-report` already returns a per-card breakdown, so filtering
/// it here keeps one definition of "spend on this card" instead of two that
/// can drift.
class _SpendSection extends ConsumerWidget {
  final UserCard userCard;
  final CardProduct product;
  const _SpendSection({required this.userCard, required this.product});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final monthQuery = const SpendReportQuery.preset(SpendPeriod.month);
    final report = ref.watch(spendReportProvider(monthQuery));

    return report.when(
      loading: () => const _SpendDisclosure(
        trailing: 'Loading',
        details: [
          Padding(
            padding: EdgeInsets.symmetric(vertical: AppSpace.sm),
            child: SkeletonList(count: 3),
          ),
        ],
      ),
      error: (err, _) => _SpendDisclosure(
        trailing: 'Retry',
        details: [
          ErrorState(
            message: userFacingErrorMessage(err),
            onRetry: () => ref.invalidate(spendReportProvider(monthQuery)),
          ),
        ],
      ),
      data: (data) {
        if (data == null) {
          return const _SpendDisclosure(
            trailing: 'Open',
            details: [
              EmptyState(
                icon: Icons.lock_outline_rounded,
                title: 'Sign in to see this card\'s spending',
                message:
                    'Per-card reports are built from your transaction history, which lives with '
                    'your account.',
              ),
            ],
          );
        }
        final row = data.byCard
            .where((c) => c.cardId == userCard.id)
            .firstOrNull;
        if (row == null || row.total.isZero) {
          final suffix = userCard.last4 == null
              ? ''
              : ' ending ${userCard.last4}';
          return _SpendDisclosure(
            trailing: '₹0',
            details: [
              EmptyState(
                icon: Icons.show_chart_rounded,
                title: 'Nothing on ${userCard.cardName}$suffix this month',
                message:
                    'Once spend is logged against this card, you\'ll see what it earned and the '
                    'rate it really paid.',
              ),
            ],
          );
        }

        final rate = row.effectiveRatePerRupee;
        final fee = _effectiveAnnualFee(userCard, product);
        // Annualised from ONE month, and labelled as such. A month is a
        // small sample and a bad one to extrapolate from blindly, but the
        // alternative — comparing a month of rewards against a year of fee
        // — is the comparison people make in their heads anyway, and it is
        // wrong by a factor of twelve.
        final annualisedRewards = row.rewards * 12;

        return _SpendDisclosure(
          trailing: row.total.format(compact: true),
          details: [
            _SpendStatCard(
              label: 'Spent this month',
              value: row.total,
              sub: '${row.txnCount} transaction${row.txnCount == 1 ? '' : 's'}',
            ),
            const SizedBox(height: AppSpace.md),
            _SpendStatCard(
              label: 'Earned this month',
              value: row.rewards,
              sub: rate == null
                  ? null
                  : 'An effective ${(rate * 100).toStringAsFixed(2)}% on what you spent here — '
                        'this is what the card actually paid, not its headline rate.',
            ),
            if (fee != null && !fee.isZero) ...[
              const SizedBox(height: AppSpace.md),
              _SpendStatCard(
                label: 'Annual fee',
                value: fee,
                sub: annualisedRewards >= fee
                    ? 'At this month\'s pace you\'d earn about '
                          '${annualisedRewards.format(compact: true)} a year — more than the fee.'
                    : 'At this month\'s pace you\'d earn about '
                          '${annualisedRewards.format(compact: true)} a year, which is less than '
                          'the fee. One month is a small sample — check the Savings Report before '
                          'deciding.',
              ),
            ],
          ],
        );
      },
    );
  }
}

class _SpendDisclosure extends StatelessWidget {
  final String trailing;
  final List<Widget> details;

  const _SpendDisclosure({required this.trailing, required this.details});

  @override
  Widget build(BuildContext context) {
    return _CompactDisclosure(
      title: 'Spend',
      subtitle: 'This month · actual spend and effective reward rate',
      trailing: trailing,
      details: details,
    );
  }
}

class _SpendStatCard extends StatelessWidget {
  final String label;
  final Money value;
  final String? sub;
  const _SpendStatCard({required this.label, required this.value, this.sub});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpace.lg),
      decoration: BoxDecoration(
        color: BambooInk.paperMuted,
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: BambooFonts.ui(12.5, color: BambooInk.ink500)),
          const SizedBox(height: 2),
          MoneyText(
            value,
            confidence: Confidence.estimated,
            style: BambooFonts.money(24, color: BambooInk.ink900),
          ),
          if (sub != null) ...[
            const SizedBox(height: 6),
            Text(sub!, style: BambooFonts.ui(12, color: BambooInk.ink500)),
          ],
        ],
      ),
    );
  }
}

/// A compact summary row used throughout card detail. The first frame shows
/// the useful answer (category, rate, consumption, or status); the issuer
/// wording and constraints remain one tap away instead of making the page a
/// wall of repeated cards.
class _CompactDisclosure extends StatelessWidget {
  final String title;
  final String subtitle;
  final String trailing;
  final List<Widget> details;

  const _CompactDisclosure({
    required this.title,
    required this.subtitle,
    required this.trailing,
    required this.details,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: AppSpace.sm),
      decoration: BoxDecoration(
        color: BambooInk.glassFillOnPaper,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: BambooInk.hairlineOnPaper),
      ),
      child: Material(
        type: MaterialType.transparency,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        clipBehavior: Clip.antiAlias,
        child: Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            tilePadding: const EdgeInsets.symmetric(
              horizontal: AppSpace.lg,
              vertical: AppSpace.xs,
            ),
            childrenPadding: const EdgeInsets.fromLTRB(
              AppSpace.lg,
              0,
              AppSpace.lg,
              AppSpace.lg,
            ),
            title: Text(
              title,
              style: BambooFonts.heading(14.5, color: BambooInk.ink900),
            ),
            subtitle: Text(
              subtitle,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: BambooFonts.ui(12.5, color: BambooInk.ink500),
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  trailing,
                  style: BambooFonts.heading(15.5, color: BambooInk.ink900),
                ),
                const SizedBox(width: AppSpace.xs),
                const Icon(Icons.expand_more_rounded, color: BambooInk.ink500),
              ],
            ),
            children: details,
          ),
        ),
      ),
    );
  }
}

class _RewardsTab extends ConsumerWidget {
  final CardProduct product;
  final bool embedded;
  const _RewardsTab({required this.product, this.embedded = false});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final categories = ref.watch(categoriesProvider).valueOrNull ?? const [];
    final fuelCategory = categories.where((c) => c.slug == 'fuel').firstOrNull;
    String categoryName(String? id) {
      if (id == null) return 'All other spends';
      for (final c in categories) {
        if (c.id == id) return c.name;
      }
      return 'Unknown category';
    }

    final rules = List<RewardRule>.from(uniqueRewardRules(product.rewardRules))
      ..sort((a, b) => a.priority.compareTo(b.priority));
    final hasFuelInRules = rules.any(
      (r) =>
          (fuelCategory != null && r.categoryId == fuelCategory.id) ||
          r.categoryId == 'fuel',
    );

    if (rules.isEmpty && product.fuelRule == null) {
      return const EmptyState(
        icon: Icons.percent_outlined,
        title: 'No reward structure on file yet',
      );
    }
    final grouped = <String, List<RewardRule>>{};
    for (final rule in rules) {
      grouped.putIfAbsent(categoryName(rule.categoryId), () => []).add(rule);
    }
    if (!hasFuelInRules &&
        product.fuelRule != null &&
        product.fuelRule!.waiverPercent > 0) {
      grouped.putIfAbsent('Fuel', () => []);
    }
    String rateFor(String label, List<RewardRule> group) {
      final isFuel =
          label == 'Fuel' ||
          (fuelCategory != null && label == fuelCategory.name);
      if (isFuel && product.fuelRule != null && group.length == 1) {
        final waiver = _rate(product.fuelRule!.waiverPercent);
        return group.first.rate == 0
            ? '$waiver% waiver'
            : '${_rate(group.first.rate)}% + $waiver% waiver';
      }
      return group.length == 1 ? _rateLabel(group.first, product) : 'Multiple';
    }

    CapRule? capFor(RewardRule rule) => uniqueCapRules(product.capRules)
        .where(
          (cap) =>
              (cap.rewardRuleId != null && cap.rewardRuleId == rule.id) ||
              (cap.categoryId != null && cap.categoryId == rule.categoryId),
        )
        .firstOrNull;

    return ListView(
      padding: embedded ? EdgeInsets.zero : const EdgeInsets.all(AppSpace.lg),
      shrinkWrap: embedded,
      physics: embedded ? const NeverScrollableScrollPhysics() : null,
      children: [
        if (product.verifiedAt != null)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpace.md),
            child: Text(
              'Verified ${_monthYear(product.verifiedAt!)}',
              style: BambooFonts.ui(12.5, color: BambooInk.ink500),
            ),
          ),
        for (final entry in grouped.entries)
          _CompactDisclosure(
            title: entry.key,
            subtitle: entry.value.isEmpty
                ? 'Surcharge waiver'
                : entry.value.length == 1
                ? _ruleSummary(entry.value.first)
                : '${entry.value.length} reward rules · expand for rails and limits',
            trailing: entry.value.isEmpty
                ? '${_rate(product.fuelRule!.waiverPercent)}% waiver'
                : rateFor(entry.key, entry.value),
            details: entry.value.isEmpty
                ? [_fuelDetail(product.fuelRule!)]
                : [
                    for (final rule in entry.value)
                      _rewardRuleDetail(rule, product, cap: capFor(rule)),
                  ],
          ),
      ],
    );
  }

  static String _ruleSummary(RewardRule rule) {
    final qualifiers = <String>[
      if (rule.rail != null && _railLabel(rule.rail!).isNotEmpty)
        _railLabel(rule.rail!),
      if (rule.merchantPattern != null) 'at ${rule.merchantPattern}',
    ];
    return qualifiers.isEmpty ? 'Base category rate' : qualifiers.join(' · ');
  }

  static Widget _rewardRuleDetail(
    RewardRule rule,
    CardProduct product, {
    CapRule? cap,
  }) => Padding(
    padding: const EdgeInsets.only(top: AppSpace.sm),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              _rateLabel(rule, product),
              style: BambooFonts.ui(
                13.5,
                weight: FontWeight.w700,
                color: BambooInk.ink900,
              ),
            ),
            if (rule.rail != null)
              Text(
                _railLabel(rule.rail!),
                style: BambooFonts.ui(12, color: BambooInk.ink500),
              ),
          ],
        ),
        if (rule.merchantPattern != null)
          Text(
            'Merchant: ${rule.merchantPattern}',
            style: BambooFonts.ui(12.5, color: BambooInk.ink500),
          ),
        if (rule.minTxn != null || rule.maxTxn != null)
          Text(
            '${rule.minTxn == null ? '' : 'From ${rule.minTxn!.format()}'}${rule.minTxn != null && rule.maxTxn != null ? ' · ' : ''}${rule.maxTxn == null ? '' : 'Up to ${rule.maxTxn!.format()} per transaction'}',
            style: BambooFonts.ui(12.5, color: BambooInk.ink500),
          ),
        if (rule.unit != RewardUnit.cashbackPercent &&
            rule.unit != RewardUnit.discountPercent &&
            rule.unit != RewardUnit.flatPoints &&
            product.pointValueInr > 0)
          Text(
            'Conversion used: ₹${product.pointValueInr.toStringAsFixed(2)} per ${rule.unit == RewardUnit.milesPer100 ? 'mile' : 'point'} · ${_effectiveValueLabel(rule, product)}',
            style: BambooFonts.ui(12.5, color: BambooInk.ink500),
          ),
        if (cap != null)
          Text(
            'Cap: ${_capValueLabel(cap)} · ${_periodLabel(cap.period)}',
            style: BambooFonts.ui(
              12.5,
              weight: FontWeight.w600,
              color: BambooInk.amber,
            ),
          ),
      ],
    ),
  );

  static Widget _fuelDetail(FuelSurchargeRule fuel) => Padding(
    padding: const EdgeInsets.only(top: AppSpace.sm),
    child: Text(
      'Surcharge waived${fuel.minTxn == null ? '' : ' above ${fuel.minTxn!.format()}'}${fuel.maxTxn == null ? '' : ' up to ${fuel.maxTxn!.format()}'}.',
      style: BambooFonts.ui(12.5, color: BambooInk.ink500),
    ),
  );

  static String _rate(double rate) =>
      rate == rate.roundToDouble() ? rate.toStringAsFixed(0) : rate.toString();

  static String _rateLabel(
    RewardRule rule,
    CardProduct product,
  ) => switch (rule.unit) {
    RewardUnit.cashbackPercent ||
    RewardUnit.discountPercent => '${_rate(rule.rate)}%',
    RewardUnit.pointsPer100 =>
      '${_rate(rule.rate)} pts/₹100 · ${_effectiveValueLabel(rule, product)}',
    RewardUnit.pointsPer150 =>
      '${_rate(rule.rate)} pts/₹150 · ${_effectiveValueLabel(rule, product)}',
    RewardUnit.pointsPer200 =>
      '${_rate(rule.rate)} pts/₹200 · ${_effectiveValueLabel(rule, product)}',
    RewardUnit.milesPer100 =>
      '${_rate(rule.rate)} miles/₹100 · ${_effectiveValueLabel(rule, product)}',
    RewardUnit.flatPoints => '${_rate(rule.rate)} pts flat',
  };

  static String _effectiveValueLabel(RewardRule rule, CardProduct product) {
    final percent =
        rule.unit.effectiveRatePerRupee(
          rule.rate,
          pointValueInr: product.pointValueInr,
        ) *
        100;
    final formatted = percent == percent.roundToDouble()
        ? percent.toStringAsFixed(0)
        : percent.toStringAsFixed(2);
    return '$formatted% value';
  }

  static String _capValueLabel(CapRule cap) => switch (cap.measure) {
    CapMeasure.rewardValue => '${cap.capValue.format()} reward value',
    CapMeasure.spendAmount => '${cap.capValue.format()} eligible spend',
    CapMeasure.txnCount =>
      '${cap.capValue.rupees.toStringAsFixed(0)} transactions',
  };

  static String _periodLabel(CapPeriod period) => switch (period) {
    CapPeriod.statementCycle => 'each statement cycle',
    CapPeriod.calendarMonth => 'each calendar month',
    CapPeriod.quarter => 'each quarter',
    CapPeriod.halfYear => 'each half-year',
    CapPeriod.annual => 'each year',
    CapPeriod.lifetime => 'lifetime',
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

class _CapsTab extends ConsumerWidget {
  final UserCard userCard;
  final CardProduct product;
  final bool embedded;
  const _CapsTab({
    required this.userCard,
    required this.product,
    this.embedded = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final categories = ref.watch(categoriesProvider).valueOrNull ?? const [];
    String categoryName(String? id) {
      if (id == null) return 'All other spends';
      return categories
              .where((c) => c.id == id)
              .map((c) => c.name)
              .firstOrNull ??
          'Card-wide';
    }

    String measureLabel(CapRule cap) => switch (cap.measure) {
      CapMeasure.rewardValue => 'reward value cap',
      CapMeasure.spendAmount => 'spend cap',
      CapMeasure.txnCount => 'transaction cap',
    };

    final caps = uniqueCapRules(product.capRules);
    if (caps.isEmpty && product.fuelRule == null) {
      return const EmptyState(
        icon: Icons.speed_outlined,
        title: 'No caps on this card',
      );
    }
    return ListView(
      padding: embedded ? EdgeInsets.zero : const EdgeInsets.all(AppSpace.lg),
      shrinkWrap: embedded,
      physics: embedded ? const NeverScrollableScrollPhysics() : null,
      children: [
        for (final cap in caps)
          Builder(
            builder: (context) {
              final consumed =
                  userCard.capConsumed[cap.id] ?? const Money.zero();
              final ratio = capRatio(consumed, cap.capValue);
              final isCount = cap.measure == CapMeasure.txnCount;
              final consumption = isCount
                  ? '${consumed.paise ~/ 100} of ${cap.capValue.paise ~/ 100} transactions'
                  : '${consumed.format()} of ${cap.capValue.format()}';
              return _CompactDisclosure(
                title: capRuleDisplayLabel(
                  cap,
                  categoryName: categoryName(cap.categoryId),
                ),
                subtitle:
                    '${categoryName(cap.categoryId)} · ${measureLabel(cap)} · resets ${_periodLabel(cap.period)}',
                trailing: consumption,
                details: [
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
                    consumption,
                    style: BambooFonts.ui(12.5, color: BambooInk.ink500),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Resets: ${_periodLabel(cap.period)}',
                    style: BambooFonts.ui(12.5, color: BambooInk.ink500),
                  ),
                  if (cap.postCapRate != null)
                    Text(
                      'After cap: ${cap.postCapRate}% ${humanizeIdentifier(cap.postCapUnit?.name, fallback: '')}',
                      style: BambooFonts.ui(12.5, color: BambooInk.ink500),
                    ),
                ],
              );
            },
          ),
        if (product.fuelRule != null) ...[
          if (caps.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpace.sm),
              child: Text(
                'Fuel surcharge waivers',
                style: BambooFonts.ui(
                  12.5,
                  weight: FontWeight.w700,
                  color: BambooInk.ink900,
                ),
              ),
            ),
          ],
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpace.md),
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
                  Text(
                    userCard.nickname?.isNotEmpty == true
                        ? userCard.nickname!
                        : product.name,
                    style: BambooFonts.heading(14.5, color: BambooInk.ink900),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${product.fuelRule!.waiverPercent.toStringAsFixed(product.fuelRule!.waiverPercent == product.fuelRule!.waiverPercent.roundToDouble() ? 0 : 2)}% surcharge waived'
                    '${product.fuelRule!.minTxn != null ? " on spends above ${product.fuelRule!.minTxn!.format()}" : ""}'
                    '${product.fuelRule!.maxTxn != null ? " up to ${product.fuelRule!.maxTxn!.format()}" : ""}',
                    style: BambooFonts.ui(12.5, color: BambooInk.ink500),
                  ),
                ],
              ),
            ),
          ),
        ],
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
  final bool embedded;
  const _MilestonesTab({
    required this.userCard,
    required this.product,
    this.embedded = false,
  });

  @override
  Widget build(BuildContext context) {
    final milestones = uniqueMilestoneRules(product.milestoneRules);
    if (milestones.isEmpty) {
      return const EmptyState(
        icon: Icons.flag_outlined,
        title: 'No milestones on this card',
      );
    }
    return ListView(
      padding: embedded ? EdgeInsets.zero : const EdgeInsets.all(AppSpace.lg),
      shrinkWrap: embedded,
      physics: embedded ? const NeverScrollableScrollPhysics() : null,
      children: [
        for (final milestone in milestones)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpace.md),
            child: Builder(
              builder: (context) {
                final qualified =
                    userCard.milestoneQualifiedSpend[milestone.id] ??
                    const Money.zero();
                final remainingPaise =
                    (milestone.thresholdSpend.paise - qualified.paise).clamp(
                      0,
                      milestone.thresholdSpend.paise,
                    );
                final remaining = Money.fromPaise(remainingPaise);
                final ratio = milestone.thresholdSpend.isZero
                    ? 0.0
                    : capRatio(qualified, milestone.thresholdSpend);
                final reached = remainingPaise == 0;
                final periodEnd = userCard.milestonePeriodEnd[milestone.id];
                final daysLeft = periodEnd == null
                    ? null
                    : daysUntil(periodEnd, DateTime.now());

                return Container(
                  decoration: BoxDecoration(
                    color: reached
                        ? BambooInk.jade.withValues(alpha: 0.10)
                        : BambooInk.glassFillOnPaper,
                    borderRadius: BorderRadius.circular(AppRadius.lg),
                    border: Border.all(
                      color: reached
                          ? BambooInk.jade
                          : BambooInk.hairlineOnPaper,
                    ),
                  ),
                  padding: const EdgeInsets.all(AppSpace.lg),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              humanizeIdentifier(milestone.label),
                              style: BambooFonts.heading(
                                14.5,
                                color: BambooInk.ink900,
                              ),
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
                            style: BambooFonts.ui(
                              12.5,
                              weight: FontWeight.w700,
                              color: BambooInk.ink900,
                            ),
                          ),
                          Row(
                            children: [
                              Text(
                                'Reward ',
                                style: BambooFonts.ui(
                                  12.5,
                                  color: BambooInk.ink500,
                                ),
                              ),
                              MoneyText(
                                milestone.rewardValue,
                                confidence: Confidence.estimated,
                                style: BambooFonts.ui(
                                  12.5,
                                  color: BambooInk.ink500,
                                ),
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
  final bool embedded;
  const _FeesTab({
    required this.userCard,
    required this.product,
    this.embedded = false,
  });

  @override
  Widget build(BuildContext context) {
    // Design 08 lists the annual fee as a required element of Card detail.
    // It was parsed (CardProduct.annualFeeInr) but never rendered anywhere —
    // this tab only ever showed fee-WAIVER progress, which is a different
    // thing and meaningless without the fee it waives.
    final effectiveFee = _effectiveAnnualFee(userCard, product);
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
                  if (effectiveFee == null)
                    Text(
                      'Not recorded for this card',
                      style: BambooFonts.ui(13.5, color: BambooInk.ink500),
                    )
                  else if (effectiveFee.isZero)
                    Text(
                      'Lifetime free',
                      style: BambooFonts.heading(20, color: BambooInk.jade),
                    )
                  else
                    MoneyText(
                      effectiveFee,
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
                    style: BambooFonts.ui(
                      15,
                      weight: FontWeight.w600,
                      color: BambooInk.ink900,
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );

    if (userCard.feeWaiverStates.isEmpty) {
      return ListView(
        padding: embedded ? EdgeInsets.zero : const EdgeInsets.all(AppSpace.lg),
        shrinkWrap: embedded,
        physics: embedded ? const NeverScrollableScrollPhysics() : null,
        children: [
          feeHeader,
          const EmptyState(
            icon: Icons.card_giftcard_outlined,
            title: 'No fee-waiver rule on this card',
          ),
        ],
      );
    }
    return ListView(
      padding: embedded ? EdgeInsets.zero : const EdgeInsets.all(AppSpace.lg),
      shrinkWrap: embedded,
      physics: embedded ? const NeverScrollableScrollPhysics() : null,
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
                    color: waived
                        ? BambooInk.jade.withValues(alpha: 0.10)
                        : BambooInk.glassFillOnPaper,
                    borderRadius: BorderRadius.circular(AppRadius.lg),
                    border: Border.all(
                      color: waived
                          ? BambooInk.jade
                          : BambooInk.hairlineOnPaper,
                    ),
                  ),
                  padding: const EdgeInsets.all(AppSpace.lg),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            'Fee waived at ',
                            style: BambooFonts.ui(
                              12.5,
                              color: BambooInk.ink500,
                            ),
                          ),
                          MoneyText(
                            fw.waivesFee,
                            confidence: Confidence.estimated,
                            style: BambooFonts.ui(
                              12.5,
                              color: BambooInk.ink500,
                            ),
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
                            color: ratio >= 0.9
                                ? BambooInk.clay
                                : BambooInk.jade,
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

class _BenefitsTab extends ConsumerWidget {
  final UserCard userCard;
  final CardProduct product;
  final bool embedded;
  const _BenefitsTab({
    required this.userCard,
    required this.product,
    this.embedded = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final benefits = [
      ...uniqueCardBenefits(product.benefits),
      if (product.fuelRule != null &&
          !uniqueCardBenefits(
            product.benefits,
          ).any((b) => b.kind == BenefitKind.fuelSurcharge))
        CardBenefit(
          id: 'fuel-${product.id}',
          kind: BenefitKind.fuelSurcharge,
          label:
              '${product.fuelRule!.waiverPercent == product.fuelRule!.waiverPercent.roundToDouble() ? product.fuelRule!.waiverPercent.toStringAsFixed(0) : product.fuelRule!.waiverPercent.toStringAsFixed(2)}% fuel surcharge waiver',
          description:
              'Fuel surcharge waived'
              '${product.fuelRule!.minTxn != null ? " on transactions above ${product.fuelRule!.minTxn!.format()}" : ""}'
              '${product.fuelRule!.maxTxn != null ? " up to ${product.fuelRule!.maxTxn!.format()}" : ""}.',
        ),
    ];
    if (benefits.isEmpty) {
      return const EmptyState(
        icon: Icons.workspace_premium_outlined,
        title: 'No benefits on file for this card',
      );
    }
    final visits = ref.watch(loungeUsageProvider).valueOrNull ?? const [];
    return ListView(
      padding: embedded ? EdgeInsets.zero : const EdgeInsets.all(AppSpace.lg),
      shrinkWrap: embedded,
      physics: embedded ? const NeverScrollableScrollPhysics() : null,
      children: [
        for (final benefit in benefits)
          Builder(
            builder: (context) {
              final isLounge =
                  benefit.kind == BenefitKind.loungeDomestic ||
                  benefit.kind == BenefitKind.loungeInternational;
              final used = isLounge
                  ? visits
                        .where(
                          (visit) =>
                              visit.userCardId == userCard.id &&
                              visit.benefitId == benefit.id,
                        )
                        .where(
                          (visit) => isInCurrentLoungeWindow(
                            visit.usedOn,
                            benefit.quotaPeriod,
                          ),
                        )
                        .length
                  : 0;
              final quota = benefit.quotaCount;
              final usage = isLounge && quota != null
                  ? '$used / $quota used'
                  : isLounge
                  ? '$used used · no fixed quota'
                  : 'Tap to view details';
              final details = <Widget>[
                if (benefit.description != null)
                  Text(
                    benefit.description!,
                    style: BambooFonts.ui(13.5, color: BambooInk.ink900),
                  ),
                if (benefit.networkProgram != null)
                  Text(
                    'Program: ${humanizeIdentifier(benefit.networkProgram)}',
                    style: BambooFonts.ui(12.5, color: BambooInk.ink500),
                  ),
                if (quota != null)
                  Text(
                    'Allowance: $quota per ${humanizeIdentifier(benefit.quotaPeriod?.name, fallback: 'period').toLowerCase()}',
                    style: BambooFonts.ui(12.5, color: BambooInk.ink500),
                  ),
                if (isLounge && quota != null) ...[
                  const SizedBox(height: AppSpace.sm),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                    child: LinearProgressIndicator(
                      value: quota == 0 ? 0 : (used / quota).clamp(0.0, 1.0),
                      minHeight: 8,
                      backgroundColor: BambooInk.paperMuted,
                      color: used >= quota ? BambooInk.clay : BambooInk.jade,
                    ),
                  ),
                  const SizedBox(height: AppSpace.xs),
                  Text(
                    used >= quota
                        ? 'No lounge visits remaining in this period'
                        : '${quota - used} lounge visit${quota - used == 1 ? '' : 's'} remaining',
                    style: BambooFonts.ui(
                      12.5,
                      color: used >= quota ? BambooInk.clay : BambooInk.ink500,
                    ),
                  ),
                ],
              ];
              return _CompactDisclosure(
                title: humanizeIdentifier(benefit.label),
                subtitle: isLounge
                    ? 'Lounge access · ${humanizeIdentifier(benefit.networkProgram, fallback: 'eligible program')}'
                    : benefit.description ?? 'Card benefit',
                trailing: usage,
                details: details,
              );
            },
          ),
      ],
    );
  }
}

class _StatementTab extends StatelessWidget {
  final UserCard userCard;
  final bool embedded;
  const _StatementTab({required this.userCard, this.embedded = false});

  @override
  Widget build(BuildContext context) {
    if (userCard.statementDay == null) {
      return const EmptyState(
        icon: Icons.receipt_long_outlined,
        title: 'Statement date not set',
        message:
            'Add a statement day from Edit Card to see your billing cycle and interest-free float here.',
      );
    }
    final float = billingCycleFloat(
      statementDay: userCard.statementDay!,
      gracePeriodDays: _assumedGracePeriodDays,
    );
    return ListView(
      padding: embedded ? EdgeInsets.zero : const EdgeInsets.all(AppSpace.lg),
      shrinkWrap: embedded,
      physics: embedded ? const NeverScrollableScrollPhysics() : null,
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
