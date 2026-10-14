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

  Color get surface => accent.withValues(alpha: 0.13);
}

SpendingVisual spendingCategoryVisual(String label) {
  final value = label.toLowerCase().trim();
  if (value.contains('dining') ||
      value.contains('food') ||
      value.contains('restaurant')) {
    return const SpendingVisual(
      icon: Icons.restaurant_rounded,
      accent: Color(0xFFE56B58),
    );
  }
  if (value.contains('fuel') || value.contains('petrol')) {
    return const SpendingVisual(
      icon: Icons.local_gas_station_rounded,
      accent: Color(0xFFD98A28),
    );
  }
  if (value.contains('online') ||
      value.contains('shopping') ||
      value.contains('retail')) {
    return const SpendingVisual(
      icon: Icons.shopping_bag_rounded,
      accent: Color(0xFF7359C7),
    );
  }
  if (value.contains('travel') ||
      value.contains('flight') ||
      value.contains('transport') ||
      value.contains('cab')) {
    return const SpendingVisual(
      icon: Icons.flight_takeoff_rounded,
      accent: Color(0xFF4B84C6),
    );
  }
  if (value.contains('grocery')) {
    return const SpendingVisual(
      icon: Icons.local_grocery_store_rounded,
      accent: Color(0xFF4B9A72),
    );
  }
  if (value.contains('bill') || value.contains('utility')) {
    return const SpendingVisual(
      icon: Icons.receipt_long_rounded,
      accent: Color(0xFF4A8DA5),
    );
  }
  if (value.contains('rent') || value.contains('home')) {
    return const SpendingVisual(
      icon: Icons.home_work_rounded,
      accent: Color(0xFF8C70BF),
    );
  }
  if (value.contains('education') || value.contains('school')) {
    return const SpendingVisual(
      icon: Icons.school_rounded,
      accent: Color(0xFF3F8E91),
    );
  }
  if (value.contains('health') || value.contains('medical')) {
    return const SpendingVisual(
      icon: Icons.local_hospital_rounded,
      accent: Color(0xFFD45A72),
    );
  }
  if (value.contains('entertainment') || value.contains('movie')) {
    return const SpendingVisual(
      icon: Icons.movie_rounded,
      accent: Color(0xFFB0609A),
    );
  }
  return const SpendingVisual(
    icon: Icons.category_rounded,
    accent: BambooInk.jade,
  );
}

SpendingVisual spendingInstrumentVisual(String instrument) {
  return switch (instrument.toLowerCase()) {
    'credit_card' => const SpendingVisual(
      icon: Icons.credit_card_rounded,
      accent: Color(0xFF315E48),
    ),
    'debit_card' => const SpendingVisual(
      icon: Icons.credit_card_outlined,
      accent: Color(0xFF4A8DA5),
    ),
    'upi_bank' => const SpendingVisual(
      icon: Icons.account_balance_rounded,
      accent: Color(0xFF7359C7),
    ),
    'wallet' => const SpendingVisual(
      icon: Icons.account_balance_wallet_rounded,
      accent: Color(0xFFD98A28),
    ),
    _ => const SpendingVisual(
      icon: Icons.payments_rounded,
      accent: BambooInk.jade,
    ),
  };
}
