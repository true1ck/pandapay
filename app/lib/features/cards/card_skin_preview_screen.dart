import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import 'card_visual.dart';

/// Developer-only catalogue QA surface for the generated card skins.
///
/// It intentionally renders the same [CardVisual] used by the product, rather
/// than a second preview implementation. This makes it useful for spotting
/// two products from one issuer that still look too similar, unreadable text,
/// or a catalogue row whose name/network data was not parsed as expected.
class CardSkinPreviewScreen extends ConsumerWidget {
  const CardSkinPreviewScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final catalogue = ref.watch(catalogueProvider);
    return Scaffold(
      backgroundColor: BambooInk.paper,
      appBar: AppBar(
        backgroundColor: BambooInk.paper,
        foregroundColor: BambooInk.ink900,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text(
          'Card skin preview',
          style: BambooFonts.heading(18, color: BambooInk.ink900),
        ),
      ),
      body: AppBackground(
        child: catalogue.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) => _PreviewMessage(
            icon: Icons.error_outline_rounded,
            title: 'Catalogue unavailable',
            message: '$error',
          ),
          data: (cards) => _CataloguePreview(cards: cards),
        ),
      ),
    );
  }
}

class _CataloguePreview extends StatelessWidget {
  final List<CardProduct> cards;

  const _CataloguePreview({required this.cards});

  @override
  Widget build(BuildContext context) {
    final groups = <String, int>{};
    var lowContrast = 0;
    for (final card in cards) {
      final spec = cardVisualSpecFor(card);
      final key =
          '${spec.family}:${spec.skin}:${spec.primary}:${spec.secondary}';
      groups[key] = (groups[key] ?? 0) + 1;
      final blended = Color.lerp(spec.primary, spec.secondary, 0.42)!;
      final foreground = blended.computeLuminance() > 0.58
          ? BambooInk.ink900
          : Colors.white;
      final lighter = math.max(
        foreground.computeLuminance(),
        blended.computeLuminance(),
      );
      final darker = math.min(
        foreground.computeLuminance(),
        blended.computeLuminance(),
      );
      final contrastRatio = (lighter + 0.05) / (darker + 0.05);
      if (contrastRatio < 4.5) {
        lowContrast++;
      }
    }
    final duplicateGroups = groups.values.where((count) => count > 1).length;

    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 900
            ? 4
            : constraints.maxWidth >= 600
            ? 3
            : 2;
        return CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpace.lg,
                  AppSpace.md,
                  AppSpace.lg,
                  AppSpace.lg,
                ),
                child: _PreviewSummary(
                  cardCount: cards.length,
                  skinCount: groups.length,
                  duplicateGroups: duplicateGroups,
                  lowContrast: lowContrast,
                ),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(
                AppSpace.lg,
                0,
                AppSpace.lg,
                AppSpace.xxxl,
              ),
              sliver: SliverGrid(
                delegate: SliverChildBuilderDelegate(
                  (context, index) => _PreviewCard(card: cards[index]),
                  childCount: cards.length,
                ),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns,
                  crossAxisSpacing: AppSpace.md,
                  mainAxisSpacing: AppSpace.lg,
                  childAspectRatio: 0.82,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _PreviewSummary extends StatelessWidget {
  final int cardCount;
  final int skinCount;
  final int duplicateGroups;
  final int lowContrast;

  const _PreviewSummary({
    required this.cardCount,
    required this.skinCount,
    required this.duplicateGroups,
    required this.lowContrast,
  });

  @override
  Widget build(BuildContext context) {
    final duplicateText = duplicateGroups == 0
        ? 'No repeated complete styles'
        : '$duplicateGroups repeated complete styles';
    final contrastText = lowContrast == 0
        ? 'Contrast looks safe'
        : '$lowContrast cards need contrast review';
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.76),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: BambooInk.hairlineOnPaper),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Catalogue visual QA',
              style: BambooFonts.heading(15, color: BambooInk.ink900),
            ),
            const SizedBox(height: AppSpace.xs),
            Text(
                  '$cardCount cards · $skinCount generated styles',
              style: BambooFonts.ui(12, color: BambooInk.ink500),
            ),
            const SizedBox(height: AppSpace.md),
            Wrap(
              spacing: AppSpace.sm,
              runSpacing: AppSpace.sm,
              children: [
                _StatusPill(
                  icon: duplicateGroups == 0
                      ? Icons.check_circle_outline
                      : Icons.info_outline,
                  label: duplicateText,
                  positive: duplicateGroups == 0,
                ),
                _StatusPill(
                  icon: lowContrast == 0
                      ? Icons.check_circle_outline
                      : Icons.contrast,
                  label: contrastText,
                  positive: lowContrast == 0,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool positive;

  const _StatusPill({
    required this.icon,
    required this.label,
    required this.positive,
  });

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
    decoration: BoxDecoration(
      color: (positive ? BambooInk.lime : BambooInk.clay).withValues(
        alpha: 0.18,
      ),
      borderRadius: BorderRadius.circular(999),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          icon,
          size: 15,
          color: positive ? BambooInk.ink900 : BambooInk.clay,
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: BambooFonts.ui(
            11,
            weight: FontWeight.w700,
            color: positive ? BambooInk.ink900 : BambooInk.clay,
          ),
        ),
      ],
    ),
  );
}

class _PreviewCard extends StatelessWidget {
  final CardProduct card;

  const _PreviewCard({required this.card});

  @override
  Widget build(BuildContext context) {
    final spec = cardVisualSpecFor(card);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CardVisual(product: card, showProductName: false),
        const SizedBox(height: AppSpace.sm),
        Text(
          card.name,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: BambooFonts.ui(
            12,
            weight: FontWeight.w700,
            color: BambooInk.ink900,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          '${card.issuerName ?? 'Unknown issuer'} · ${card.network.name}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: BambooFonts.ui(10.5, color: BambooInk.ink500),
        ),
        const SizedBox(height: 3),
        Text(
          '${spec.family} · ${spec.skin}',
          style: BambooFonts.ui(10, color: BambooInk.ink500),
        ),
      ],
    );
  }
}

class _PreviewMessage extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;

  const _PreviewMessage({
    required this.icon,
    required this.title,
    required this.message,
  });

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(AppSpace.xl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 40, color: BambooInk.ink500),
          const SizedBox(height: AppSpace.md),
          Text(title, style: BambooFonts.heading(16, color: BambooInk.ink900)),
          const SizedBox(height: AppSpace.xs),
          Text(
            message,
            textAlign: TextAlign.center,
            style: BambooFonts.ui(12, color: BambooInk.ink500),
          ),
        ],
      ),
    ),
  );
}
