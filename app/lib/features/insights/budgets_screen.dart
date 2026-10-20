import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';
import '../../data/catalogue_repository.dart' show SpendCategory;
import '../../data/spend_reports_repository.dart';
import '../../main.dart' show MoneyText;
import '../cards/card_summary.dart';
import 'spending_visuals.dart';

/// Budgets — a line the user draws for themselves, and being told when
/// they're near it.
///
/// ADVISORY, never a block. Nothing in this app declines a transaction or
/// tells someone they may not spend their own money; the whole value is in
/// noticing early enough to decide. That is also why "off pace" exists as a
/// state distinct from "over": being told on the 12th that you're spending
/// faster than the month is passing is useful, and being told on the 30th
/// that you went over is not.
class BudgetsScreen extends ConsumerWidget {
  const BudgetsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final budgets = ref.watch(budgetsProvider);
    final signedIn = ref.watch(spendReportsRepositoryProvider) != null;

    return Scaffold(
      backgroundColor: BambooInk.paper,
      appBar: AppBar(
        backgroundColor: BambooInk.paper,
        elevation: 0,
        title: Text(
          'Budgets',
          style: BambooFonts.heading(18, color: BambooInk.ink900),
        ),
      ),
      floatingActionButton: signedIn
          ? FloatingActionButton.extended(
              backgroundColor: BambooInk.slate,
              foregroundColor: BambooInk.lime,
              onPressed: () => _openEditor(context, ref),
              icon: const Icon(Icons.add_rounded),
              label: const Text('Set a budget'),
            )
          : null,
      body: AppBackground(
        child: budgets.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (err, _) => ErrorState(
            message: userFacingErrorMessage(err),
            onRetry: () => ref.invalidate(budgetsProvider),
          ),
          data: (list) {
            if (!signedIn) {
              return const EmptyState(
                icon: Icons.lock_outline_rounded,
                title: 'Sign in to set a budget',
                message:
                    'Budgets are measured against your transaction history, which lives with '
                    'your account.',
              );
            }
            if (list.isEmpty) {
              return RefreshableEmptyState(
                onRefresh: () async => ref.invalidate(budgetsProvider),
                icon: Icons.savings_outlined,
                title: 'No budgets yet',
                message:
                    'Set a monthly limit for everything, for one category, or for a single '
                    'card. PandaPay will tell you when you\'re running ahead of it — it never '
                    'blocks anything.',
              );
            }
            return RefreshIndicator(
              onRefresh: () async => ref.invalidate(budgetsProvider),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(
                  AppSpace.lg,
                  AppSpace.lg,
                  AppSpace.lg,
                  96,
                ),
                children: [
                  for (final b in list) ...[
                    _BudgetCard(budget: b),
                    const SizedBox(height: AppSpace.md),
                  ],
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Future<void> _openEditor(BuildContext context, WidgetRef ref) async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: BambooInk.paper,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.lg)),
      ),
      builder: (_) => const _BudgetEditorSheet(),
    );
    if (saved == true) ref.invalidate(budgetsProvider);
  }
}

class _BudgetCard extends ConsumerWidget {
  final BudgetStatus budget;
  const _BudgetCard({required this.budget});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Three states, three colours. Over is clay, off-pace is amber, on
    // track is jade — the same three-tier scale caps and fee waivers
    // already use, so "amber means pay attention" means the same thing on
    // every screen in the app.
    final (tone, statusLine) = switch ((budget.isOver, budget.isOffPace)) {
      (true, _) => (
        BambooInk.clay,
        'Over by ${(budget.spent - budget.amount).format(hidePaise: true)}',
      ),
      (_, true) => (
        BambooInk.amber,
        'Ahead of pace — ${(budget.consumedFraction * 100).toStringAsFixed(0)}% spent, '
            '${(budget.elapsedFraction * 100).toStringAsFixed(0)}% of the period gone',
      ),
      _ => (
        BambooChartColors.teal,
        '${budget.remaining.format(hidePaise: true)} left',
      ),
    };

    return CardSummaryPanel(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.md,
        AppSpace.md,
        AppSpace.md,
        AppSpace.lg,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _BudgetVisualBadge(visual: _visualForBudget(budget)),
              const SizedBox(width: AppSpace.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      budget.label,
                      style: BambooFonts.heading(15, color: BambooInk.ink900),
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${budget.scope.label} · ${budget.period.label}',
                      style: BambooFonts.ui(11.5, color: BambooInk.ink500),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              CardSummaryPill(
                label: budget.period.label,
                foreground: tone,
                background: tone.withValues(alpha: 0.12),
              ),
              IconButton(
                icon: const Icon(Icons.close_rounded, size: 18),
                color: BambooInk.ink500,
                tooltip: 'Remove this budget',
                onPressed: () => _confirmDelete(context, ref),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              MoneyText(
                budget.spent,
                confidence: Confidence.estimated,
                style: BambooFonts.money(22, color: BambooInk.ink900),
              ),
              const SizedBox(width: 6),
              Text(
                'of ${budget.amount.format(hidePaise: true)}',
                style: BambooFonts.ui(13, color: BambooInk.ink500),
              ),
            ],
          ),
          const SizedBox(height: AppSpace.sm),
          // Two bars, one on top of the other: spend against the budget,
          // and a thin marker for how much of the PERIOD has passed.
          // Without the second, "60% spent" is a number nobody can act on —
          // it's alarming on day 3 and unremarkable on day 25.
          Stack(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(AppRadius.pill),
                child: LinearProgressIndicator(
                  value: budget.consumedFraction.clamp(0.0, 1.0),
                  minHeight: 8,
                  backgroundColor: BambooInk.paper,
                  color: tone,
                ),
              ),
              Positioned.fill(
                child: LayoutBuilder(
                  builder: (context, constraints) => Padding(
                    padding: EdgeInsets.only(
                      left:
                          constraints.maxWidth *
                          budget.elapsedFraction.clamp(0.0, 1.0),
                    ),
                    child: Semantics(
                      label:
                          '${(budget.elapsedFraction * 100).toStringAsFixed(0)} percent of the '
                          'period has passed',
                      child: Container(
                        width: 2,
                        color: BambooInk.ink900.withValues(alpha: 0.45),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpace.sm),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                budget.isOver
                    ? Icons.warning_amber_rounded
                    : budget.isOffPace
                    ? Icons.speed_rounded
                    : Icons.check_circle_outline_rounded,
                size: 17,
                color: tone,
              ),
              const SizedBox(width: AppSpace.xs),
              Expanded(
                child: Text(
                  statusLine,
                  style: BambooFonts.ui(
                    12.5,
                    weight: FontWeight.w600,
                    color: tone,
                  ),
                ),
              ),
            ],
          ),
          if (budget.projected != null && !budget.isOver) ...[
            const SizedBox(height: 2),
            Text(
              'On this pace: about ${budget.projected!.format(compact: true)} by the end',
              style: BambooFonts.ui(11.5, color: BambooInk.ink500),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove this budget?'),
        content: Text(
          'Your ${budget.period.label.toLowerCase()} budget for ${budget.label} will stop being '
          'tracked. Your transactions are not affected.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Keep it'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final repo = ref.read(spendReportsRepositoryProvider);
    if (repo == null) return;
    try {
      await repo.deleteBudget(budget.id);
      ref.invalidate(budgetsProvider);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(userFacingErrorMessage(e))));
      }
    }
  }
}

class _BudgetEditorSheet extends ConsumerStatefulWidget {
  const _BudgetEditorSheet();

  @override
  ConsumerState<_BudgetEditorSheet> createState() => _BudgetEditorSheetState();
}

class _BudgetEditorSheetState extends ConsumerState<_BudgetEditorSheet> {
  final _amountController = TextEditingController();
  BudgetScope _scope = BudgetScope.overall;
  BudgetPeriod _period = BudgetPeriod.monthly;
  String? _scopeRefId;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _amountController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final categories = ref.watch(categoriesProvider).valueOrNull ??
        const <SpendCategory>[];
    final cards = ref.watch(userCardsProvider).valueOrNull ?? const [];

    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: EdgeInsets.only(
          left: AppSpace.lg,
          right: AppSpace.lg,
          top: AppSpace.lg,
          bottom: MediaQuery.of(context).viewInsets.bottom + AppSpace.lg,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _BudgetVisualBadge(visual: _visualForScope(_scope), size: 42),
                const SizedBox(width: AppSpace.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Set a budget',
                        style: BambooFonts.heading(17, color: BambooInk.ink900),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'A helpful limit, never a payment block',
                        style: BambooFonts.ui(12, color: BambooInk.ink500),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpace.md),
            DropdownButtonFormField<BudgetScope>(
              initialValue: _scope,
              decoration: const InputDecoration(
                labelText: 'Applies to',
                prefixIcon: Icon(Icons.tune_rounded),
              ),
              items: [
                for (final s in BudgetScope.values)
                  DropdownMenuItem(
                    value: s,
                    child: Row(
                      children: [
                        Icon(_iconForScope(s), size: 18),
                        const SizedBox(width: AppSpace.sm),
                        Text(s.label),
                      ],
                    ),
                  ),
              ],
              onChanged: (v) => setState(() {
                _scope = v ?? BudgetScope.overall;
                // The old target is meaningless under a new scope — clearing
                // it stops a category id being submitted as a card id.
                _scopeRefId = null;
              }),
            ),
            if (_scope == BudgetScope.category) ...[
              const SizedBox(height: AppSpace.md),
              DropdownButtonFormField<String>(
                initialValue: _scopeRefId,
                decoration: const InputDecoration(
                  labelText: 'Category',
                  prefixIcon: Icon(Icons.category_rounded),
                ),
                items: [
                  for (final c in categories)
                    DropdownMenuItem(
                      value: c.id,
                      child: Row(
                        children: [
                          Icon(
                            spendingCategoryVisual(c.name).icon,
                            size: 18,
                            color: spendingCategoryVisual(c.name).accent,
                          ),
                          const SizedBox(width: AppSpace.sm),
                          Text(
                            c.isSubcategory
                                ? '${categories.firstWhereOrNull((parent) =>
                                      parent.id == c.parentCategoryId ||
                                      parent.id == c.parentUserCategoryId,
                                    )?.name ?? ''} · ${c.name}'
                                : c.name,
                          ),
                        ],
                      ),
                    ),
                ],
                onChanged: (v) => setState(() => _scopeRefId = v),
              ),
            ],
            if (_scope == BudgetScope.card) ...[
              const SizedBox(height: AppSpace.md),
              DropdownButtonFormField<String>(
                initialValue: _scopeRefId,
                decoration: const InputDecoration(
                  labelText: 'Card',
                  prefixIcon: Icon(Icons.credit_card_rounded),
                ),
                items: [
                  for (final c in cards)
                    DropdownMenuItem(
                      value: c.id,
                      child: Row(
                        children: [
                          const Icon(Icons.credit_card_rounded, size: 18),
                          const SizedBox(width: AppSpace.sm),
                          Text(
                            c.nickname?.isNotEmpty == true
                                ? c.nickname!
                                : c.cardName,
                          ),
                        ],
                      ),
                    ),
                ],
                onChanged: (v) => setState(() => _scopeRefId = v),
              ),
            ],
            const SizedBox(height: AppSpace.md),
            DropdownButtonFormField<BudgetPeriod>(
              initialValue: _period,
              decoration: const InputDecoration(
                labelText: 'Resets',
                prefixIcon: Icon(Icons.autorenew_rounded),
              ),
              items: [
                for (final p in BudgetPeriod.values)
                  DropdownMenuItem(value: p, child: Text(p.label)),
              ],
              onChanged: (v) =>
                  setState(() => _period = v ?? BudgetPeriod.monthly),
            ),
            const SizedBox(height: AppSpace.md),
            TextField(
              controller: _amountController,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(
                labelText: 'Amount',
                prefixIcon: Icon(Icons.currency_rupee_rounded),
                prefixText: '₹ ',
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: AppSpace.sm),
              Text(_error!, style: BambooFonts.ui(12.5, color: BambooInk.clay)),
            ],
            const SizedBox(height: AppSpace.lg),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: BambooInk.slate,
                foregroundColor: BambooInk.lime,
                minimumSize: const Size.fromHeight(48),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              onPressed: _saving ? null : _save,
              child: Text(_saving ? 'Saving…' : 'Save budget'),
            ),
            const SizedBox(height: AppSpace.sm),
            Text(
              'PandaPay never blocks a payment. A budget only changes what it tells you.',
              style: BambooFonts.ui(11.5, color: BambooInk.ink500),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _save() async {
    final amount = double.tryParse(_amountController.text.trim());
    if (amount == null || amount <= 0) {
      setState(() => _error = 'Enter an amount above zero.');
      return;
    }
    if (_scope != BudgetScope.overall && _scopeRefId == null) {
      setState(
        () => _error =
            'Pick which ${_scope == BudgetScope.category ? 'category' : 'card'}.',
      );
      return;
    }
    final repo = ref.read(spendReportsRepositoryProvider);
    if (repo == null) return;

    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await repo.saveBudget(
        scope: _scope,
        scopeRefId: _scopeRefId,
        period: _period,
        amount: Money.fromRupees(amount),
      );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = userFacingErrorMessage(e);
        });
      }
    }
  }
}

SpendingVisual _visualForBudget(BudgetStatus budget) {
  return switch (budget.scope) {
    BudgetScope.overall => const SpendingVisual(
      icon: Icons.pie_chart_rounded,
      accent: BambooChartColors.teal,
    ),
    BudgetScope.category => spendingCategoryVisual(budget.label),
    BudgetScope.card => const SpendingVisual(
      icon: Icons.credit_card_rounded,
      accent: BambooChartColors.blue,
    ),
  };
}

SpendingVisual _visualForScope(BudgetScope scope) {
  return switch (scope) {
    BudgetScope.overall => const SpendingVisual(
      icon: Icons.pie_chart_rounded,
      accent: BambooChartColors.teal,
    ),
    BudgetScope.category => const SpendingVisual(
      icon: Icons.category_rounded,
      accent: BambooChartColors.teal,
    ),
    BudgetScope.card => const SpendingVisual(
      icon: Icons.credit_card_rounded,
      accent: BambooChartColors.blue,
    ),
  };
}

IconData _iconForScope(BudgetScope scope) => switch (scope) {
  BudgetScope.overall => Icons.pie_chart_rounded,
  BudgetScope.category => Icons.category_rounded,
  BudgetScope.card => Icons.credit_card_rounded,
};

class _BudgetVisualBadge extends StatelessWidget {
  final SpendingVisual visual;
  final double size;

  const _BudgetVisualBadge({required this.visual, this.size = 42});

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: visual.surface,
      borderRadius: BorderRadius.circular(size * 0.3),
    ),
    alignment: Alignment.center,
    child: Icon(visual.icon, size: size * 0.47, color: visual.accent),
  );
}
