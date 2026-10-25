import 'package:flutter/material.dart';

import '../../app/design/app_theme.dart';

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
      icon: Icons.restaurant_rounded,
      accent: BambooChartColors.coral,
    );
  }
  if (value.contains('fuel') || value.contains('petrol')) {
    return const SpendingVisual(
      icon: Icons.local_gas_station_rounded,
      accent: BambooChartColors.amber,
    );
  }
  if (value.contains('online') ||
      value.contains('shopping') ||
      value.contains('retail')) {
    return const SpendingVisual(
      icon: Icons.shopping_bag_rounded,
      accent: BambooChartColors.violet,
    );
  }
  if (value.contains('travel') ||
      value.contains('flight') ||
      value.contains('transport') ||
      value.contains('cab')) {
    return const SpendingVisual(
      icon: Icons.flight_takeoff_rounded,
      accent: BambooChartColors.blue,
    );
  }
  if (value.contains('grocery')) {
    return const SpendingVisual(
      icon: Icons.local_grocery_store_rounded,
      accent: BambooChartColors.teal,
    );
  }
  if (value.contains('bill') || value.contains('utility')) {
    return const SpendingVisual(
      icon: Icons.receipt_long_rounded,
      accent: BambooChartColors.cyan,
    );
  }
  if (value.contains('rent') || value.contains('home')) {
    return const SpendingVisual(
      icon: Icons.home_work_rounded,
      accent: BambooChartColors.indigo,
    );
  }
  if (value.contains('education') || value.contains('school')) {
    return const SpendingVisual(
      icon: Icons.school_rounded,
      accent: BambooChartColors.cyan,
    );
  }
  if (value.contains('health') || value.contains('medical')) {
    return const SpendingVisual(
      icon: Icons.local_hospital_rounded,
      accent: BambooChartColors.rose,
    );
  }
  if (value.contains('entertainment') || value.contains('movie')) {
    return const SpendingVisual(
      icon: Icons.movie_rounded,
      accent: BambooChartColors.pink,
    );
  }
  return const SpendingVisual(
    icon: Icons.category_rounded,
    accent: BambooChartColors.teal,
  );
}

SpendingVisual spendingInstrumentVisual(String instrument) {
  return switch (instrument.toLowerCase()) {
    'credit_card' => const SpendingVisual(
      icon: Icons.credit_card_rounded,
      accent: BambooChartColors.teal,
    ),
    'debit_card' => const SpendingVisual(
      icon: Icons.credit_card_outlined,
      accent: BambooChartColors.blue,
    ),
    'upi_bank' => const SpendingVisual(
      icon: Icons.account_balance_rounded,
      accent: BambooChartColors.violet,
    ),
    'wallet' => const SpendingVisual(
      icon: Icons.account_balance_wallet_rounded,
      accent: BambooChartColors.amber,
    ),
    _ => const SpendingVisual(
      icon: Icons.payments_rounded,
      accent: BambooChartColors.teal,
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
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: visual.surface,
      borderRadius: BorderRadius.circular(size * 0.32),
    ),
    alignment: Alignment.center,
    child: Icon(visual.icon, size: size * 0.46, color: visual.accent),
  );
}

/// A shared, column-aligned header for expandable spending breakdown rows.
///
/// The amount gets a stable trailing rail instead of participating in the
/// row's flex calculation. This keeps differently sized figures (and their
/// confidence icons) on the same right edge across adjacent cards.
class SpendingBreakdownHeader extends StatelessWidget {
  final Widget label;
  final String? percentage;
  final Widget amount;
  final Key? percentageKey;
  final Key? amountKey;
  final double maxAmountWidth;

  const SpendingBreakdownHeader({
    super.key,
    required this.label,
    required this.amount,
    this.percentage,
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
        ],
      );
    },
  );
}
