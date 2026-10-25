import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';
import '../../data/user_cards_repository.dart' show UserCard;
import 'card_summary.dart';

/// Settings → "Manage deleted cards".
///
/// Removing a card anywhere in PandaPay is an archive (R4: archive, never
/// delete), so this is the one place a removed card can be brought back. It
/// reads [archivedCardsProvider] rather than [myCardsProvider] so Wallet stays
/// active-only and archived cards never reach ranking or spend totals.
class DeletedCardsScreen extends ConsumerStatefulWidget {
  const DeletedCardsScreen({super.key});

  @override
  ConsumerState<DeletedCardsScreen> createState() => _DeletedCardsScreenState();
}

class _DeletedCardsScreenState extends ConsumerState<DeletedCardsScreen> {
  final Set<String> _restoring = {};
  final Set<String> _restored = {};

  String _displayName(UserCard card) =>
      card.nickname?.isNotEmpty == true ? card.nickname! : card.cardName;

  Future<void> _restore(UserCard card) async {
    if (_restoring.contains(card.id)) return;

    final messenger = ScaffoldMessenger.of(context);
    final repo = ref.read(userCardsRepositoryProvider);
    if (repo != null && ref.read(isOnlineProvider).valueOrNull == false) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'Restoring a card needs a connection. Try again when you are online.',
          ),
        ),
      );
      return;
    }

    final local = repo == null
        ? await ref.read(localUserCardsRepositoryProvider.future)
        : null;
    if (!mounted) return;
    setState(() => _restoring.add(card.id));

    try {
      if (repo != null) {
        await repo.unarchiveCard(card.id);
      } else {
        await local!.unarchiveCard(card.id);
      }
      if (!mounted) return;

      // Publish the restored state before refreshing so the next wallet read
      // cannot replay the cached archived snapshot.
      await applyUserCardArchiveToCache(
        ref,
        userCardId: card.id,
        archived: false,
      );
      await clearUserCardsCache(ref);
      ref.invalidate(archivedCardsProvider);
      ref.invalidate(myCardsProvider);
      ref.invalidate(userCardsProvider);
      ref.invalidate(transactionsProvider);
      ref.invalidate(utilizationTransactionsProvider);
      ref.invalidate(homeSummaryProvider);
      ref.invalidate(spendReportProvider);
      ref.invalidate(budgetsProvider);
      ref.invalidate(recurringReportProvider);

      if (!mounted) return;
      setState(() => _restored.add(card.id));
      messenger.showSnackBar(
        SnackBar(content: Text('${_displayName(card)} restored to your wallet.')),
      );
    } on ApiException catch (error) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            error.errorCode == 'card_already_added'
                ? 'You already have an active card with the same issuer, type '
                      'and last four. Remove that card first.'
                : userFacingErrorMessage(error),
          ),
        ),
      );
    } on CardAlreadyAddedException catch (error) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text(error.message)));
    } catch (error) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text(userFacingErrorMessage(error))),
      );
    } finally {
      if (mounted) setState(() => _restoring.remove(card.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final archived = ref.watch(archivedCardsProvider);
    final catalogue =
        ref.watch(catalogueProvider).valueOrNull ?? const <CardProduct>[];
    final productsById = {for (final product in catalogue) product.id: product};

    return Scaffold(
      backgroundColor: BambooInk.paper,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: BambooInk.ink900,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text(
          'Deleted cards',
          style: BambooFonts.heading(19, color: BambooInk.ink900),
        ),
      ),
      body: AppBackground(
        child: archived.when(
          skipLoadingOnRefresh: true,
          loading: () => const Padding(
            padding: EdgeInsets.fromLTRB(
              AppSpace.lg,
              AppSpace.md,
              AppSpace.lg,
              0,
            ),
            child: SkeletonList(count: 3),
          ),
          error: (error, _) => ErrorState(
            message: userFacingErrorMessage(error),
            onRetry: () => ref.invalidate(archivedCardsProvider),
          ),
          data: (cards) {
            final visible = cards
                .where((card) => !_restored.contains(card.id))
                .toList();
            if (visible.isEmpty) {
              return RefreshableEmptyState(
                icon: Icons.delete_outline_rounded,
                title: 'No deleted cards',
                message:
                    'Cards you remove from your wallet show up here, ready to restore.',
                onRefresh: () async {
                  await ref.refresh(archivedCardsProvider.future);
                },
              );
            }
            return RefreshIndicator(
              onRefresh: () async {
                await ref.refresh(archivedCardsProvider.future);
              },
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(
                  AppSpace.lg,
                  AppSpace.md,
                  AppSpace.lg,
                  AppSpace.xl,
                ),
                children: [
                  _DeletedCardsIntro(count: visible.length),
                  const SizedBox(height: AppSpace.lg),
                  for (final card in visible) ...[
                    _DeletedCardTile(
                      card: card,
                      product: productsById[card.cardProductId],
                      restoring: _restoring.contains(card.id),
                      onRestore: () => _restore(card),
                    ),
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
}

class _DeletedCardsIntro extends StatelessWidget {
  final int count;

  const _DeletedCardsIntro({required this.count});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpace.lg),
      decoration: BoxDecoration(
        color: BambooInk.paperMuted,
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.restore_rounded, size: 20, color: BambooInk.jade),
          const SizedBox(width: AppSpace.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$count deleted card${count == 1 ? '' : 's'}',
                  style: BambooFonts.ui(
                    13,
                    weight: FontWeight.w700,
                    color: BambooInk.ink900,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Removing a card never deletes your transactions. Restore it '
                  'to put it back in Wallet and recommendations.',
                  style: BambooFonts.ui(
                    12.5,
                    color: BambooInk.ink500,
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DeletedCardTile extends StatelessWidget {
  final UserCard card;
  final CardProduct? product;
  final bool restoring;
  final VoidCallback onRestore;

  const _DeletedCardTile({
    required this.card,
    required this.product,
    required this.restoring,
    required this.onRestore,
  });

  String get _displayName =>
      card.nickname?.isNotEmpty == true ? card.nickname! : card.cardName;

  String _subtitle(CardProduct product) {
    final details = <String>[
      if (product.issuerName != null && product.issuerName!.isNotEmpty)
        product.issuerName!,
      if (card.last4 != null) '•••• ${card.last4}',
    ];
    return details.isEmpty ? product.name : details.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final restoreButton = _RestoreButton(
      restoring: restoring,
      onPressed: onRestore,
    );
    return CardSummaryPanel(
      padding: const EdgeInsets.all(AppSpace.md),
      child: product == null
          ? Row(
              children: [
                Container(
                  width: 88,
                  height: 56,
                  decoration: BoxDecoration(
                    color: BambooInk.paperMuted,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(
                    Icons.credit_card_rounded,
                    color: BambooInk.ink500,
                  ),
                ),
                const SizedBox(width: AppSpace.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _displayName,
                        style: BambooFonts.heading(
                          15,
                          color: BambooInk.ink900,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'No longer in the catalogue',
                        style: BambooFonts.ui(12, color: BambooInk.ink500),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: AppSpace.sm),
                restoreButton,
              ],
            )
          : CardSummaryHeader(
              product: product!,
              title: _displayName,
              subtitle: _subtitle(product!),
              visualWidth: 88,
              footer: const StatusPill(
                label: 'REMOVED',
                foreground: BambooInk.ink500,
                background: BambooInk.paperMuted,
                icon: Icons.delete_outline_rounded,
              ),
              trailing: restoreButton,
            ),
    );
  }
}

class _RestoreButton extends StatelessWidget {
  final bool restoring;
  final VoidCallback onPressed;

  const _RestoreButton({required this.restoring, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      onPressed: restoring ? null : onPressed,
      style: TextButton.styleFrom(
        foregroundColor: BambooInk.jade,
        disabledForegroundColor: BambooInk.ink500,
        minimumSize: const Size(0, 36),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        textStyle: BambooFonts.ui(13, weight: FontWeight.w700),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.pill),
        ),
      ),
      icon: restoring
          ? const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: BambooInk.jade,
              ),
            )
          : const Icon(Icons.restore_rounded, size: 17),
      label: const Text('Restore'),
    );
  }
}
