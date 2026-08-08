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
import '../auth/login_screen.dart';
import '../scan/scan_card_screen.dart';
import 'card_picker_screen.dart';

/// C1 My Cards (ui-spec Group C, implementation-plan-group-c-d.md) —
/// replaces the old flat-list CardsScreen. Card-art list, drag-to-reorder
/// priority, per-card cap-usage bar / utilization bar / next due date,
/// active/archived filter, FAB -> C3 (still the inline dropdown form below
/// until C3's real searchable picker lands — same reasoning as the plan's
/// own sequencing note).
class MyCardsScreen extends ConsumerWidget {
  const MyCardsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sessionInit = ref.watch(sessionInitProvider);
    if (sessionInit.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    final token = ref.watch(accessTokenProvider);
    if (token == null) return const LoginScreen();

    final showArchived = ref.watch(showArchivedCardsProvider);
    final myCards = ref.watch(myCardsProvider);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(AppSpace.lg, AppSpace.lg, AppSpace.lg, 0),
          child: Row(
            children: [
              Expanded(
                child: SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: false, label: Text('Active')),
                    ButtonSegment(value: true, label: Text('Archived')),
                  ],
                  selected: {showArchived},
                  onSelectionChanged: (selection) =>
                      ref.read(showArchivedCardsProvider.notifier).state = selection.first,
                ),
              ),
              const SizedBox(width: AppSpace.sm),
              IconButton(
                tooltip: 'Benefits cheat sheet',
                icon: const Icon(Icons.workspace_premium_outlined),
                onPressed: () => context.push(AppRoute.benefitsCheatSheet),
              ),
              IconButton(
                tooltip: 'Points & expiry',
                icon: const Icon(Icons.stars_outlined),
                onPressed: () => context.push(AppRoute.pointsExpiry),
              ),
            ],
          ),
        ),
        Expanded(
          child: myCards.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (err, _) => ErrorState(
              message: userFacingErrorMessage(err),
              onRetry: () => ref.invalidate(myCardsProvider),
            ),
            data: (cards) {
              if (cards.isEmpty) {
                return EmptyState(
                  icon: showArchived ? Icons.archive_outlined : Icons.wallet_outlined,
                  title: showArchived ? 'No archived cards' : 'Your wallet is empty',
                  message: showArchived
                      ? 'Cards you archive show up here — never deleted, always restorable.'
                      : 'Add a card below to start tracking spend and rewards.',
                );
              }
              // Reordering only makes sense on the active, priority-ordered
              // view — archived cards have no ranking to reorder.
              if (showArchived) {
                return ListView.builder(
                  padding: const EdgeInsets.fromLTRB(AppSpace.lg, AppSpace.lg, AppSpace.lg, 0),
                  itemCount: cards.length,
                  itemBuilder: (context, index) => Padding(
                    padding: const EdgeInsets.only(bottom: AppSpace.md),
                    child: _MyCardTile(cards[index]),
                  ),
                );
              }
              return ReorderableListView.builder(
                padding: const EdgeInsets.fromLTRB(AppSpace.lg, AppSpace.lg, AppSpace.lg, 0),
                itemCount: cards.length,
                itemBuilder: (context, index) => Padding(
                  key: ValueKey(cards[index].id),
                  padding: const EdgeInsets.only(bottom: AppSpace.md),
                  child: _MyCardTile(cards[index]),
                ),
                onReorderItem: (oldIndex, newIndex) async {
                  final reordered = List<UserCard>.from(cards);
                  final moved = reordered.removeAt(oldIndex);
                  reordered.insert(newIndex, moved);
                  // Optimistic: the repository call is fire-and-forget from
                  // the UI's perspective, but ref.invalidate afterward makes
                  // sure the server's own sort_order (the source of truth)
                  // is what's actually displayed once it round-trips, not
                  // just this client's guess forever.
                  try {
                    await ref.read(userCardsRepositoryProvider)!.reorderCards([for (final c in reordered) c.id]);
                  } catch (e) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Could not save the new order. ${userFacingErrorMessage(e)}')),
                      );
                    }
                  } finally {
                    ref.invalidate(myCardsProvider);
                  }
                },
              );
            },
          ),
        ),
        Container(
          decoration: const BoxDecoration(
            color: AppColors.surface,
            border: Border(top: BorderSide(color: AppColors.ink100)),
          ),
          padding: const EdgeInsets.all(AppSpace.lg),
          child: const _AddCardForm(),
        ),
      ],
    );
  }
}

class _MyCardTile extends ConsumerStatefulWidget {
  final UserCard card;
  const _MyCardTile(this.card);

  @override
  ConsumerState<_MyCardTile> createState() => _MyCardTileState();
}

class _MyCardTileState extends ConsumerState<_MyCardTile> {
  bool _logging = false;
  bool _archiving = false;

  Future<void> _logTransaction() async {
    setState(() => _logging = true);
    try {
      final categoryId = ref.read(_resolvedSelectedCategoryIdProvider);
      final amount = ref.read(enteredAmountProvider);
      await ref.read(userCardsRepositoryProvider)!.logTransaction(
            userCardId: widget.card.id,
            amount: amount,
            categoryId: categoryId,
          );
      ref.invalidate(myCardsProvider);
      ref.invalidate(userCardsProvider);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Logged ${amount.format()} spend.')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Failed to log spend. ${userFacingErrorMessage(e)}')));
      }
    } finally {
      if (mounted) setState(() => _logging = false);
    }
  }

  Future<void> _toggleArchive() async {
    setState(() => _archiving = true);
    try {
      final repo = ref.read(userCardsRepositoryProvider)!;
      if (widget.card.isArchived) {
        await repo.unarchiveCard(widget.card.id);
      } else {
        await repo.archiveCard(widget.card.id);
      }
      ref.invalidate(myCardsProvider);
      ref.invalidate(userCardsProvider);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Failed. ${userFacingErrorMessage(e)}')));
      }
    } finally {
      if (mounted) setState(() => _archiving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final card = widget.card;
    final amount = ref.watch(enteredAmountProvider);
    final textTheme = Theme.of(context).textTheme;
    final badges = <String>[
      if (card.totalPointsEarned > 0) '${card.totalPointsEarned.toStringAsFixed(0)} pts earned',
      for (final fw in card.feeWaiverStates)
        fw.waivedAt != null
            ? 'Fee waived (${fw.qualifiedSpend.format()} spent)'
            : '${fw.qualifiedSpend.format()} of ${fw.thresholdSpend.format()} toward fee waiver',
    ];

    final pairs = ref.watch(myCardsWithProductProvider).valueOrNull ?? const [];
    final product = pairs.where((p) => p.$1.id == card.id).map((p) => p.$2).firstOrNull;

    return Opacity(
      opacity: card.isArchived ? 0.6 : 1,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        onTap: () => context.push('/cards/${card.id}'),
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
              Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration:
                        BoxDecoration(color: AppColors.teal50, borderRadius: BorderRadius.circular(AppRadius.sm)),
                    child: const Icon(Icons.credit_card_rounded, color: AppColors.teal600, size: 20),
                  ),
                  const SizedBox(width: AppSpace.md),
                  Expanded(
                    child: Text(
                      card.nickname?.isNotEmpty == true ? card.nickname! : card.cardName,
                      style: textTheme.titleMedium,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (!card.isArchived)
                    _CardActionButton(
                      icon: _logging ? null : Icons.add_card_rounded,
                      loading: _logging,
                      tooltip: 'Log a ${amount.format()} spend on this card',
                      onPressed: _logging ? null : _logTransaction,
                    ),
                  const SizedBox(width: AppSpace.xs),
                  _CardActionButton(
                    icon: _archiving ? null : (card.isArchived ? Icons.unarchive_outlined : Icons.archive_outlined),
                    loading: _archiving,
                    tooltip: card.isArchived ? 'Restore' : 'Archive (never deleted)',
                    onPressed: _archiving ? null : _toggleArchive,
                  ),
                ],
              ),
              if (product != null && !card.isArchived) ...[
                const SizedBox(height: AppSpace.md),
                _NearestCapBar(card: card, product: product),
                if (card.creditLimit != null && !card.creditLimit!.isZero) ...[
                  const SizedBox(height: AppSpace.sm),
                  _UtilizationBar(card: card),
                ],
              ],
              if (card.dueDay != null && !card.isArchived) ...[
                const SizedBox(height: AppSpace.sm),
                Text(_nextDueDateLabel(card.dueDay!), style: textTheme.bodySmall),
              ],
              if (badges.isNotEmpty) ...[
                const SizedBox(height: AppSpace.sm),
                Wrap(
                  spacing: AppSpace.xs,
                  runSpacing: AppSpace.xs,
                  children: [
                    for (final b in badges)
                      StatusPill(label: b, foreground: AppColors.navy800, background: AppColors.surfaceMuted),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  static String _nextDueDateLabel(int dueDay) {
    final now = DateTime.now();
    var next = DateTime(now.year, now.month, dueDay);
    if (!next.isAfter(now)) next = DateTime(now.year, now.month + 1, dueDay);
    final daysLeft = next.difference(DateTime(now.year, now.month, now.day)).inDays;
    return 'Next due in $daysLeft days';
  }
}

/// The cap closest to being maxed out, across this card's own rules —
/// C1's single-bar-per-card summary (full per-cap detail lives in C2's
/// Caps tab / the existing E2 Caps & Limits screen). Reuses the same
/// capRatio/UrgencyScore shared scorer E2 already sorts by, rather than a
/// third ad hoc "which cap is worst" computation.
class _NearestCapBar extends StatelessWidget {
  final UserCard card;
  final CardProduct product;
  const _NearestCapBar({required this.card, required this.product});

  @override
  Widget build(BuildContext context) {
    if (product.capRules.isEmpty) return const SizedBox.shrink();
    CapRule? worst;
    double worstRatio = -1;
    for (final cap in product.capRules) {
      final consumed = card.capConsumed[cap.id] ?? const Money.zero();
      final ratio = capRatio(consumed, cap.capValue);
      if (ratio > worstRatio) {
        worstRatio = ratio;
        worst = cap;
      }
    }
    if (worst == null) return const SizedBox.shrink();
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(worst.label, style: textTheme.bodySmall),
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(AppRadius.pill),
          child: LinearProgressIndicator(
            value: worstRatio,
            minHeight: 6,
            backgroundColor: AppColors.surfaceMuted,
            color: worstRatio >= 0.9 ? AppColors.warning : AppColors.teal600,
          ),
        ),
      ],
    );
  }
}

class _UtilizationBar extends StatelessWidget {
  final UserCard card;
  const _UtilizationBar({required this.card});

  @override
  Widget build(BuildContext context) {
    final spendProxy = card.capConsumed.values.fold<Money>(const Money.zero(), (a, b) => a + b);
    final result = creditUtilization(spendProxy, card.creditLimit!);
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('Utilization', style: textTheme.bodySmall),
            const Spacer(),
            Text('${(result.ratio * 100).clamp(0, 999).toStringAsFixed(0)}%', style: textTheme.bodySmall),
          ],
        ),
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(AppRadius.pill),
          child: LinearProgressIndicator(
            value: result.ratio.clamp(0.0, 1.0),
            minHeight: 6,
            backgroundColor: AppColors.surfaceMuted,
            color: result.overThreshold ? AppColors.warning : AppColors.teal600,
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

class _CardActionButton extends StatelessWidget {
  final IconData? icon;
  final bool loading;
  final String tooltip;
  final VoidCallback? onPressed;

  const _CardActionButton({this.icon, this.loading = false, required this.tooltip, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        child: Container(
          width: 36,
          height: 36,
          alignment: Alignment.center,
          decoration: BoxDecoration(color: AppColors.surfaceMuted, borderRadius: BorderRadius.circular(AppRadius.sm)),
          child: loading
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : Icon(icon, size: 18, color: AppColors.navy800),
        ),
      ),
    );
  }
}

/// Reuses Home's selectedCategoryProvider (a slug) resolved to the UUID
/// reward_rules.category_id/cap_rules.category_id actually need — same
/// slug->id bridge providers.dart's rankedRecommendationsProvider already
/// does, so a logged spend is attributed to the same category Home is
/// currently showing recommendations for.
final _resolvedSelectedCategoryIdProvider = Provider<String?>((ref) {
  final categories = ref.watch(categoriesProvider).valueOrNull ?? const [];
  final selectedSlug = ref.watch(selectedCategoryProvider);
  for (final c in categories) {
    if (c.slug == selectedSlug) return c.id;
  }
  return null;
});

/// Task C-3: replaces the old inline dropdown with C3's real picker
/// (CardPickerScreen — searchable, issuer-grouped, multi-select). The scan
/// shortcut still adds immediately on a match (a scan IS an identification,
/// not a browse) — untouched from before. Picker results are added in a
/// loop; one add failing doesn't block the rest, and every failure is
/// surfaced (not silently dropped) via the snackbar's summary.
class _AddCardForm extends ConsumerStatefulWidget {
  const _AddCardForm();
  @override
  ConsumerState<_AddCardForm> createState() => _AddCardFormState();
}

class _AddCardFormState extends ConsumerState<_AddCardForm> {
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // Chunk 30's scan-FAB handoff: a pick made via the app shell's central
    // scan FAB (main.dart) lands here as a pending id — add it immediately,
    // same as the picker flow below, then clear the one-shot value.
    WidgetsBinding.instance.addPostFrameCallback((_) => _consumePendingScan());
  }

  Future<void> _consumePendingScan() async {
    final pending = ref.read(pendingScannedCardIdProvider);
    if (pending == null) return;
    ref.read(pendingScannedCardIdProvider.notifier).state = null;
    await _addCards([pending]);
  }

  Future<void> _openPicker() async {
    final catalogue = ref.read(catalogueProvider).valueOrNull;
    if (catalogue == null) return;
    final picked = await Navigator.of(context).push<List<CardProduct>>(
      MaterialPageRoute(
        builder: (_) => CardPickerScreen(onCardNotListed: () => context.push(AppRoute.requestNewCard)),
      ),
    );
    if (picked != null && picked.isNotEmpty) {
      await _addCards([for (final c in picked) c.id]);
    }
  }

  Future<void> _scan() async {
    final catalogue = ref.read(catalogueProvider).valueOrNull;
    if (catalogue == null) return;
    final picked = await Navigator.of(context).push<CardProduct>(
      MaterialPageRoute(builder: (_) => ScanCardScreen(catalogue: catalogue)),
    );
    if (picked != null) await _addCards([picked.id]);
  }

  Future<void> _addCards(List<String> cardProductIds) async {
    setState(() => _busy = true);
    final failures = <String>[];
    final repo = ref.read(userCardsRepositoryProvider)!;
    for (final id in cardProductIds) {
      try {
        await repo.addCard(id);
      } catch (e) {
        failures.add(userFacingErrorMessage(e));
      }
    }
    ref.invalidate(myCardsProvider);
    ref.invalidate(userCardsProvider);
    if (mounted) {
      setState(() => _busy = false);
      final added = cardProductIds.length - failures.length;
      if (failures.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Added $added card(s); ${failures.length} failed: ${failures.first}')),
        );
      } else if (added > 1) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Added $added cards.')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final catalogue = ref.watch(catalogueProvider);
    return catalogue.when(
      loading: () => const SizedBox.shrink(),
      error: (err, _) => Text(userFacingErrorMessage(err), style: Theme.of(context).textTheme.bodySmall),
      data: (cards) {
        if (cards.isEmpty) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            FilledButton.icon(
              onPressed: _busy ? null : _openPicker,
              icon: _busy
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.add_rounded),
              label: const Text('Add a card'),
            ),
            const SizedBox(height: AppSpace.sm),
            TextButton.icon(
              onPressed: _busy ? null : _scan,
              icon: const Icon(Icons.qr_code_scanner_rounded, size: 18),
              label: const Text('Scan a QR/barcode instead'),
            ),
          ],
        );
      },
    );
  }
}
