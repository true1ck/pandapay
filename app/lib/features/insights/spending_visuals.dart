import 'package:flutter/material.dart';

import '../../app/design/app_icons.dart';
import '../../app/design/app_theme.dart';
import '../../app/design/party_avatar.dart' show TintedIconTile;

/// The shared visual language for spending categories and payment methods.
///
/// Keeping the icon and accent mapping in one place means Spending, quick-add
/// surfaces, and future spending summaries can describe the same category in
/// the same visual way instead of each screen inventing its own treatment.
class SpendingVisual {
  final IconData icon;
  final Color accent;

  const SpendingVisual({required this.icon, required this.accent});

  // A little more saturation keeps the shared icon badges readable on the
  // light cards without changing the application's semantic color tokens.
  Color get surface => accent.withValues(alpha: 0.17);
}

SpendingVisual spendingCategoryVisual(String label) {
  final value = label.toLowerCase().trim();
  if (value.contains('dining') ||
      value.contains('food') ||
      value.contains('restaurant')) {
    return const SpendingVisual(
      icon: AppIcons.dining,
      accent: BambooChartColors.coral,
    );
  }
  if (value.contains('fuel') || value.contains('petrol')) {
    return const SpendingVisual(
      icon: AppIcons.fuel,
      accent: BambooChartColors.amber,
    );
  }
  if (value.contains('online') ||
      value.contains('shopping') ||
      value.contains('retail')) {
    return const SpendingVisual(
      icon: AppIcons.shopping,
      accent: BambooChartColors.violet,
    );
  }
  if (value.contains('travel') ||
      value.contains('flight') ||
      value.contains('transport') ||
      value.contains('cab')) {
    return const SpendingVisual(
      icon: AppIcons.travel,
      accent: BambooChartColors.blue,
    );
  }
  if (value.contains('grocery')) {
    return const SpendingVisual(
      icon: AppIcons.grocery,
      accent: BambooChartColors.teal,
    );
  }
  if (value.contains('bill') || value.contains('utility')) {
    return const SpendingVisual(
      icon: AppIcons.bill,
      accent: BambooChartColors.cyan,
    );
  }
  if (value.contains('rent') || value.contains('home')) {
    return const SpendingVisual(
      icon: AppIcons.home,
      accent: BambooChartColors.indigo,
    );
  }
  if (value.contains('education') || value.contains('school')) {
    return const SpendingVisual(
      icon: AppIcons.education,
      accent: BambooChartColors.cyan,
    );
  }
  if (value.contains('health') || value.contains('medical')) {
    return const SpendingVisual(
      icon: AppIcons.health,
      accent: BambooChartColors.rose,
    );
  }
  if (value.contains('entertainment') || value.contains('movie')) {
    return const SpendingVisual(
      icon: AppIcons.entertainment,
      accent: BambooChartColors.pink,
    );
  }
  return const SpendingVisual(
    icon: AppIcons.otherCategory,
    accent: BambooChartColors.teal,
  );
}

SpendingVisual spendingInstrumentVisual(String instrument) {
  // The same icon and hue as an account's avatar (AvatarKind), so a card, a
  // bank and a wallet look alike wherever they appear.
  return switch (instrument.toLowerCase()) {
    'credit_card' => const SpendingVisual(
      icon: AppIcons.card,
      accent: BambooChartColors.indigo,
    ),
    'debit_card' => const SpendingVisual(
      icon: AppIcons.card,
      accent: BambooChartColors.indigo,
    ),
    'upi_bank' => const SpendingVisual(
      icon: AppIcons.bank,
      accent: BambooChartColors.blue,
    ),
    'wallet' => const SpendingVisual(
      icon: AppIcons.wallet,
      accent: BambooChartColors.teal,
    ),
    _ => const SpendingVisual(
      icon: AppIcons.cash,
      accent: BambooChartColors.rose,
    ),
  };
}

class SpendingVisualBadge extends StatelessWidget {
  final SpendingVisual visual;
  final double size;

  const SpendingVisualBadge({
    super.key,
    required this.visual,
    required this.size,
  });

  @override
  Widget build(BuildContext context) =>
      TintedIconTile(visual.icon, visual.accent, size: size);
}

/// A shared, column-aligned header for expandable spending breakdown rows.
///
/// The amount gets a stable trailing rail instead of participating in the
/// row's flex calculation. This keeps differently sized figures on the same
/// right edge across adjacent cards.
///
/// [trailing] is the row's expand chevron. It belongs here rather than in
/// [ExpansionTile.trailing] because a ListTile always reserves the icon width
/// plus its 16dp title gap before the text column ends — which left the amount
/// floating well short of the card's right edge.
class SpendingBreakdownHeader extends StatelessWidget {
  final Widget label;
  final String? percentage;
  final Widget amount;
  final Widget? trailing;
  final Key? percentageKey;
  final Key? amountKey;
  final double maxAmountWidth;

  const SpendingBreakdownHeader({
    super.key,
    required this.label,
    required this.amount,
    this.percentage,
    this.trailing,
    this.percentageKey,
    this.amountKey,
    this.maxAmountWidth = 112,
  });

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      // Retain useful label space on compact phones while keeping every
      // row under the same parent constraints on an identical rail.
      final amountWidth = (constraints.maxWidth * 0.42)
          .clamp(72.0, maxAmountWidth)
          .toDouble();
      return Row(
        children: [
          Expanded(child: label),
          const SizedBox(width: AppSpace.sm),
          if (percentage != null) ...[
            SizedBox(
              key: percentageKey,
              width: 32,
              child: Text(
                percentage!,
                textAlign: TextAlign.end,
                maxLines: 1,
                style: BambooFonts.ui(12, color: BambooInk.ink500),
              ),
            ),
            const SizedBox(width: AppSpace.sm),
          ],
          SizedBox(
            key: amountKey,
            width: amountWidth,
            child: Align(
              alignment: AlignmentDirectional.centerEnd,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: AlignmentDirectional.centerEnd,
                child: amount,
              ),
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: AppSpace.xs),
            trailing!,
          ],
        ],
      );
    },
  );
}
