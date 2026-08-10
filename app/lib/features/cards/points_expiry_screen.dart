import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';
import '../../data/user_cards_repository.dart';
import '../../main.dart' show MoneyText;

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
        title: Text('Points & expiry', style: BambooFonts.heading(18, color: BambooInk.ink900)),
      ),
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment(0.9, -0.5),
            radius: 1.3,
            colors: [BambooInk.wash, BambooInk.paper],
            stops: [0.0, 0.6],
          ),
        ),
        child: pairs.when(
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
                message: 'Add a card to see its points balance and any expiry dates here.',
              );
            }
            return ListView.builder(
              padding: const EdgeInsets.all(AppSpace.lg),
              itemCount: owned.length,
              itemBuilder: (context, index) {
                final (userCard, product) = owned[index];
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
    final valueEstimate = Money.fromRupees(userCard.totalPointsEarned * product.pointValueInr);

    // Nearest expiry across every ledger row this card has, if any — most
    // rows have no expires_on (see PointsLedgerEntry's own doc-comment), so
    // this degrades to "no expiry on file" rather than fabricating one.
    final withExpiry = (ledger.valueOrNull ?? const <PointsLedgerEntry>[])
        .where((e) => e.expiresOn != null)
        .toList()
      ..sort((a, b) => a.expiresOn!.compareTo(b.expiresOn!));
    final nearestExpiry = withExpiry.firstOrNull;
    final daysToExpiry = nearestExpiry == null ? null : daysUntil(nearestExpiry.expiresOn!, DateTime.now());

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
          Text(
            userCard.nickname?.isNotEmpty == true ? userCard.nickname! : product.name,
            style: BambooFonts.heading(14.5, color: BambooInk.ink900),
          ),
          const SizedBox(height: AppSpace.sm),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(userCard.totalPointsEarned.toStringAsFixed(0), style: BambooFonts.heading(24, color: BambooInk.ink900)),
              const SizedBox(width: AppSpace.xs),
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text('points', style: BambooFonts.ui(12.5, color: BambooInk.ink500)),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Row(
            children: [
              Text('Estimated value ', style: BambooFonts.ui(12.5, color: BambooInk.ink500)),
              MoneyText(valueEstimate, confidence: Confidence.estimated, style: BambooFonts.ui(12.5, color: BambooInk.ink500)),
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
            _ExpiryChip(daysLeft: daysToExpiry, points: nearestExpiry.deltaPoints),
          ],
          const SizedBox(height: AppSpace.md),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              style: TextButton.styleFrom(foregroundColor: BambooInk.jade),
              onPressed: () => _showCorrectionSheet(context, ref),
              icon: const Icon(Icons.edit_outlined, size: 16),
              label: const Text('Correct balance'),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showCorrectionSheet(BuildContext context, WidgetRef ref) async {
    final controller = TextEditingController(text: userCard.totalPointsEarned.toStringAsFixed(0));
    final result = await showModalBottomSheet<double>(
      context: context,
      isScrollControlled: true,
      backgroundColor: BambooInk.paper,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.lg)),
      ),
      builder: (context) => Padding(
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
            Text('Correct points balance', style: BambooFonts.heading(17, color: BambooInk.ink900)),
            const SizedBox(height: AppSpace.sm),
            Text('This is the starting point — we track from here.', style: BambooFonts.ui(13, color: BambooInk.ink500)),
            const SizedBox(height: AppSpace.lg),
            TextField(
              controller: controller,
              keyboardType: TextInputType.number,
              style: BambooFonts.ui(14.5, color: BambooInk.ink900),
              decoration: InputDecoration(
                labelText: 'Actual points balance',
                labelStyle: BambooFonts.ui(13.5, color: BambooInk.ink500),
                filled: true,
                fillColor: BambooInk.glassFillOnPaper,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: const BorderSide(color: BambooInk.hairlineOnPaper),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: const BorderSide(color: BambooInk.slate, width: 1.5),
                ),
              ),
              autofocus: true,
            ),
            const SizedBox(height: AppSpace.lg),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: BambooInk.slate,
                foregroundColor: BambooInk.lime,
                minimumSize: const Size.fromHeight(52),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                textStyle: BambooFonts.ui(15, weight: FontWeight.w700),
              ),
              onPressed: () {
                final value = double.tryParse(controller.text.trim());
                Navigator.of(context).pop(value);
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    if (result == null) return;
    try {
      await ref.read(userCardsRepositoryProvider)!.adjustPointsBalance(userCard.id, newBalance: result);
      ref.invalidate(userCardsProvider);
      ref.invalidate(pointsLedgerProvider(userCard.id));
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(userFacingErrorMessage(e))));
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
        Icon(urgent ? Icons.warning_amber_rounded : Icons.schedule_rounded, size: 14, color: color),
        const SizedBox(width: 4),
        Flexible(child: Text(label, style: BambooFonts.ui(12.5, color: color))),
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
