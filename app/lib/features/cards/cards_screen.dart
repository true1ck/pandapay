import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';
import '../../data/user_cards_repository.dart';
import '../auth/login_screen.dart';
import '../scan/scan_card_screen.dart';

/// UA-3+ (Chunk 16): the Cards tab — a signed-in user's actual wallet.
/// Signed-out shows the same login flow as More/AccountScreen (owning
/// cards requires an identity); signed-in shows the wallet with an
/// add-from-catalogue flow and archive (R4: never delete).
class CardsScreen extends ConsumerWidget {
  const CardsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sessionInit = ref.watch(sessionInitProvider);
    if (sessionInit.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    final token = ref.watch(accessTokenProvider);
    if (token == null) return const LoginScreen();

    final userCards = ref.watch(userCardsProvider);
    return userCards.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (err, _) => ErrorState(
        message: userFacingErrorMessage(err),
        onRetry: () => ref.invalidate(userCardsProvider),
      ),
      data: (cards) => Column(
        children: [
          Expanded(
            child: cards.isEmpty
                ? const EmptyState(
                    icon: Icons.wallet_outlined,
                    title: 'Your wallet is empty',
                    message: 'Add a card below to start tracking spend and rewards.',
                  )
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(AppSpace.lg, AppSpace.lg, AppSpace.lg, 0),
                    itemCount: cards.length,
                    itemBuilder: (context, index) => Padding(
                      padding: const EdgeInsets.only(bottom: AppSpace.md),
                      child: _UserCardTile(cards[index]),
                    ),
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
      ),
    );
  }
}

class _UserCardTile extends ConsumerStatefulWidget {
  final UserCard card;
  const _UserCardTile(this.card);

  @override
  ConsumerState<_UserCardTile> createState() => _UserCardTileState();
}

class _UserCardTileState extends ConsumerState<_UserCardTile> {
  bool _logging = false;

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
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(color: AppColors.teal50, borderRadius: BorderRadius.circular(AppRadius.sm)),
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
              _CardActionButton(
                icon: _logging ? null : Icons.add_card_rounded,
                loading: _logging,
                tooltip: 'Log a ${amount.format()} spend on this card',
                onPressed: _logging ? null : _logTransaction,
              ),
              const SizedBox(width: AppSpace.xs),
              _CardActionButton(
                icon: Icons.archive_outlined,
                tooltip: 'Archive (never deleted)',
                onPressed: () async {
                  await ref.read(userCardsRepositoryProvider)!.archiveCard(card.id);
                  ref.invalidate(userCardsProvider);
                },
              ),
            ],
          ),
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
    );
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

class _AddCardForm extends ConsumerStatefulWidget {
  const _AddCardForm();
  @override
  ConsumerState<_AddCardForm> createState() => _AddCardFormState();
}

class _AddCardFormState extends ConsumerState<_AddCardForm> {
  String? _selectedCardId;
  bool _adding = false;
  String? _error;

  @override
  Widget build(BuildContext context) {
    // Chunk 30 follow-up: the app shell's central scan FAB (main.dart) has
    // no Add Card form of its own — it hands a pick to this form via
    // pendingScannedCardIdProvider and switches to the Cards tab. This form
    // mounts fresh on every tab switch (it's a whole new widget subtree, not
    // just a rebuild), so the pending value must be read directly here, not
    // just watched for future changes — a plain ref.listen would miss a
    // value that was already set before this widget existed. Consumed once,
    // then cleared post-frame so it doesn't reapply or reappear later.
    final pendingScan = ref.watch(pendingScannedCardIdProvider);
    if (pendingScan != null && pendingScan != _selectedCardId) {
      _selectedCardId = pendingScan;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) ref.read(pendingScannedCardIdProvider.notifier).state = null;
      });
    }

    final catalogue = ref.watch(catalogueProvider);
    return catalogue.when(
      loading: () => const SizedBox.shrink(),
      error: (err, _) => Text(userFacingErrorMessage(err), style: Theme.of(context).textTheme.bodySmall),
      data: (cards) {
        if (cards.isEmpty) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: _selectedCardId,
                    decoration: const InputDecoration(labelText: 'Add a card'),
                    items: [
                      for (final c in cards) DropdownMenuItem(value: c.id, child: Text(c.name, overflow: TextOverflow.ellipsis)),
                    ],
                    onChanged: (value) => setState(() => _selectedCardId = value),
                  ),
                ),
                const SizedBox(width: AppSpace.sm),
                FilledButton(
                  style: FilledButton.styleFrom(minimumSize: const Size(72, 52)),
                  onPressed: _adding || _selectedCardId == null ? null : _addCard,
                  child: _adding
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : const Text('Add'),
                ),
              ],
            ),
            if (_error != null) ...[
              const SizedBox(height: AppSpace.xs),
              Text(_error!, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppColors.error)),
            ],
            // UA-4 (Chunk 30): scan-to-identify as a shortcut into the same
            // dropdown above — never replaces it. Picking a match here just
            // sets _selectedCardId, same as picking it from the dropdown by
            // hand; "Add" still has to be pressed to actually add it.
            TextButton.icon(
              onPressed: () async {
                final picked = await Navigator.of(context).push<CardProduct>(
                  MaterialPageRoute(builder: (_) => ScanCardScreen(catalogue: cards)),
                );
                if (picked != null) setState(() => _selectedCardId = picked.id);
              },
              icon: const Icon(Icons.qr_code_scanner_rounded, size: 18),
              label: const Text('Scan a QR/barcode instead'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _addCard() async {
    setState(() {
      _adding = true;
      _error = null;
    });
    try {
      await ref.read(userCardsRepositoryProvider)!.addCard(_selectedCardId!);
      ref.invalidate(userCardsProvider);
      setState(() => _selectedCardId = null);
    } catch (e) {
      setState(() => _error = userFacingErrorMessage(e));
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }
}
