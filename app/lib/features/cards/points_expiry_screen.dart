import 'package:uuid/uuid.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../app/required_field.dart';
import '../../data/local_first/pending_overlays.dart';
import '../../data/api_exception.dart';
import '../../data/user_cards_repository.dart';
import '../../main.dart' show MoneyText;
import '../insights/as_of_caption.dart';
import 'card_summary.dart';
import 'card_visual.dart';

/// C6 Points & Expiry (ui-spec Group C). Per-program balances (one program
/// == one owned card, since points aren't modeled as separate named
/// programs anywhere in the schema — a card's total_points_earned IS its
/// one program's balance), ₹ estimate (points × the card's own
/// pointValueInr), expiry dates with urgency colouring **plus icon/text**
/// (never colour alone — Cross-Cutting Requirements), manual balance
/// correction feeding reconciliation.
class PointsExpiryScreen extends ConsumerWidget {
  const PointsExpiryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pairs = ref.watch(ownedCardsWithProductProvider);
    return Scaffold(
      backgroundColor: BambooInk.paper,
      appBar: AppBar(
        backgroundColor: BambooInk.paper,
        foregroundColor: BambooInk.ink900,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text(
          'Points & expiry',
          style: BambooFonts.heading(18, color: BambooInk.ink900),
        ),
      ),
      body: AppBackground(
        child: pairs.when(skipLoadingOnReload: true, skipLoadingOnRefresh: true, 
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (err, _) => ErrorState(
            message: userFacingErrorMessage(err),
            onRetry: () => ref.invalidate(userCardsProvider),
          ),
          data: (owned) {
            if (owned.isEmpty) {
              return const EmptyState(
                icon: Icons.stars_outlined,
                title: 'No points to track yet',
                message:
                    'Add a card to see its points balance and any expiry dates here.',
              );
            }
            return ListView.builder(
              padding: const EdgeInsets.all(AppSpace.lg),
              itemCount: owned.length + 1,
              itemBuilder: (context, index) {
                // H3: "Saved data, as of last sync" while offline (zero height
                // otherwise).
                if (index == 0) return const AsOfLastSyncCaption();
                final (userCard, product) = owned[index - 1];
                return Padding(
                  padding: const EdgeInsets.only(bottom: AppSpace.md),
                  child: _ProgramCard(userCard: userCard, product: product),
                );
              },
            );
          },
        ),
      ),
    );
  }
}

class _ProgramCard extends ConsumerWidget {
  final UserCard userCard;
  final CardProduct product;
  const _ProgramCard({required this.userCard, required this.product});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ledger = ref.watch(pointsLedgerProvider(userCard.id));
    final valueEstimate = Money.fromRupees(
      userCard.totalPointsEarned * product.pointValueInr,
    );

    // Nearest expiry across every ledger row this card has, if any — most
    // rows have no expires_on (see PointsLedgerEntry's own doc-comment), so
    // this degrades to "no expiry on file" rather than fabricating one.
    final withExpiry =
        (ledger.valueOrNull ?? const <PointsLedgerEntry>[])
            .where((e) => e.expiresOn != null)
            .toList()
          ..sort((a, b) => a.expiresOn!.compareTo(b.expiresOn!));
    final nearestExpiry = withExpiry.firstOrNull;
    final daysToExpiry = nearestExpiry == null
        ? null
        : daysUntil(nearestExpiry.expiresOn!, DateTime.now());

    return CardSummaryPanel(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(AppRadius.lg),
            ),
            child: SizedBox(
              width: double.infinity,
              height: 124,
              child: CardVisual(product: product, showProductName: false),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(AppSpace.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  userCard.nickname?.isNotEmpty == true
                      ? userCard.nickname!
                      : product.name,
                  style: BambooFonts.heading(16, color: BambooInk.ink900),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                if (product.issuerName?.trim().isNotEmpty == true) ...[
                  const SizedBox(height: 2),
                  Text(
                    product.issuerName!,
                    style: BambooFonts.ui(12.5, color: BambooInk.ink500),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
                const SizedBox(height: AppSpace.lg),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      userCard.totalPointsEarned.toStringAsFixed(0),
                      style: BambooFonts.heading(24, color: BambooInk.ink900),
                    ),
                    const SizedBox(width: AppSpace.xs),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(
                        'points',
                        style: BambooFonts.ui(12.5, color: BambooInk.ink500),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    Text(
                      'Estimated value ',
                      style: BambooFonts.ui(12.5, color: BambooInk.ink500),
                    ),
                    MoneyText(
                      valueEstimate,
                      confidence: Confidence.estimated,
                      style: BambooFonts.ui(12.5, color: BambooInk.ink500),
                    ),
                  ],
                ),
                if (product.pointValueInr <= 0) ...[
                  const SizedBox(height: AppSpace.xs),
                  Text(
                    'No ₹/point value on file for this card — estimate unavailable.',
                    style: BambooFonts.ui(12.5, color: BambooInk.ink500),
                  ),
                ],
                if (nearestExpiry != null && daysToExpiry != null) ...[
                  const SizedBox(height: AppSpace.sm),
                  _ExpiryChip(
                    daysLeft: daysToExpiry,
                    points: nearestExpiry.deltaPoints,
                  ),
                ],
                const SizedBox(height: AppSpace.md),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    style: TextButton.styleFrom(
                      foregroundColor: BambooInk.jade,
                    ),
                    onPressed: () => _showCorrectionSheet(context, ref),
                    icon: const Icon(Icons.edit_outlined, size: 16),
                    label: const Text('Correct balance'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showCorrectionSheet(BuildContext context, WidgetRef ref) async {
    final controller = TextEditingController(
      text: userCard.totalPointsEarned.toStringAsFixed(0),
    );
    var tried = false;
    final result = await showModalBottomSheet<double>(
      context: context,
      isScrollControlled: true,
      backgroundColor: BambooInk.paper,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.lg)),
      ),
      builder: (context) => StatefulBuilder(builder: (context, setSheetState) => Padding(
        padding: EdgeInsets.only(
          left: AppSpace.lg,
          right: AppSpace.lg,
          top: AppSpace.lg,
          bottom: MediaQuery.of(context).viewInsets.bottom + AppSpace.lg,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Correct points balance',
              style: BambooFonts.heading(17, color: BambooInk.ink900),
            ),
            const SizedBox(height: AppSpace.sm),
            Text(
              'This is the starting point — we track from here.',
              style: BambooFonts.ui(13, color: BambooInk.ink500),
            ),
            const SizedBox(height: AppSpace.lg),
            TextField(
              controller: controller,
              keyboardType: TextInputType.number,
              style: BambooFonts.ui(14.5, color: BambooInk.ink900),
              decoration: InputDecoration(
                label: requiredLabel('Actual points balance'),
                errorText: requiredError(tried, controller.text) ??
                    (tried && double.tryParse(controller.text.trim()) == null
                        ? 'Enter a number'
                        : null),
                labelStyle: BambooFonts.ui(13.5, color: BambooInk.ink500),
                filled: true,
                fillColor: BambooInk.glassFillOnPaper,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: BorderSide.none,
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: const BorderSide(
                    color: BambooInk.hairlineOnPaper,
                  ),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: const BorderSide(
                    color: BambooInk.slate,
                    width: 1.5,
                  ),
                ),
              ),
              onChanged: (_) => tried ? setSheetState(() {}) : null,
              autofocus: true,
            ),
            const SizedBox(height: AppSpace.lg),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: BambooInk.slate,
                foregroundColor: BambooInk.lime,
                minimumSize: const Size.fromHeight(52),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                textStyle: BambooFonts.ui(15, weight: FontWeight.w700),
              ),
              onPressed: () {
                setSheetState(() => tried = true);
                final value = double.tryParse(controller.text.trim());
                if (value == null) return;
                Navigator.of(context).pop(value);
              },
              child: const Text('Save'),
            ),
          ],
        ),
      )),
    );
    if (result == null) return;
    try {
      // Local first: show the corrected total at once and let the command
      // outbox send it. A newer correction for the same card replaces a queued
      // one, since the latest balance is the one the person means.
      final mutationId = const Uuid().v4();
      await queueCommand(
        ref,
        kind: OverlayCommand.pointsAdjust,
        target: userCard.id,
        payload: {
          'userCardId': userCard.id,
          'newBalance': result,
          'clientMutationId': mutationId,
        },
      );
      final cache = await ref.read(responseCacheProvider.future);
      cache.financialStore.patchCard(
        ref.read(cacheNamespaceProvider),
        userCard.id,
        {'total_points_earned': result},
      );
      ref.invalidate(userCardsProvider);
      ref.invalidate(pointsLedgerProvider(userCard.id));
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(userFacingErrorMessage(e))));
      }
    }
  }
}

class _ExpiryChip extends StatelessWidget {
  final int daysLeft;
  final double points;
  const _ExpiryChip({required this.daysLeft, required this.points});

  @override
  Widget build(BuildContext context) {
    final urgent = daysLeft <= 30;
    final color = urgent ? BambooInk.amber : BambooInk.ink500;
    final label = daysLeft >= 0
        ? '${points.toStringAsFixed(0)} pts expire in $daysLeft days'
        : '${points.toStringAsFixed(0)} pts expired ${-daysLeft} days ago';
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          urgent ? Icons.warning_amber_rounded : Icons.schedule_rounded,
          size: 14,
          color: color,
        ),
        const SizedBox(width: 4),
        Flexible(
          child: Text(label, style: BambooFonts.ui(12.5, color: color)),
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
