import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/card_overrides_repository.dart';
import 'package:pandapay/features/overrides/manual_overrides_screen.dart';

void main() {
  testWidgets('shows the empty state when there are no overrides', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [cardOverridesProvider.overrideWith((ref) async => const [])],
        child: const MaterialApp(home: ManualOverridesScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No overrides yet'), findsOneWidget);
  });

  testWidgets('shows one tile per override with its target and card', (tester) async {
    final override = CardOverride(
      id: 'o1',
      userCardId: 'uc1',
      scope: OverrideScope.category,
      categoryId: 'cat1',
      categoryName: 'Fuel',
      isEnabled: true,
      createdAt: DateTime(2026, 1, 1),
      cardName: 'HDFC Millennia',
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [cardOverridesProvider.overrideWith((ref) async => [override])],
        child: const MaterialApp(home: ManualOverridesScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Fuel'), findsOneWidget);
    expect(find.textContaining('HDFC Millennia'), findsOneWidget);
    expect(find.text('Active'), findsOneWidget);
  });

  testWidgets('shows the loading state while overrides are fetching', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [cardOverridesProvider.overrideWith((ref) => Completer<List<CardOverride>>().future)],
        child: const MaterialApp(home: ManualOverridesScreen()),
      ),
    );

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('shows the error state with a retry action on failure', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [cardOverridesProvider.overrideWith((ref) async => throw StateError('boom'))],
        child: const MaterialApp(home: ManualOverridesScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Something went wrong'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
  });

  testWidgets('disabled override shows a Disabled pill and an Enable action', (tester) async {
    final override = CardOverride(
      id: 'o2',
      userCardId: 'uc1',
      scope: OverrideScope.merchantName,
      merchantName: 'Amazon',
      isEnabled: false,
      createdAt: DateTime(2026, 1, 1),
      cardName: 'ICICI Amazon Pay',
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [cardOverridesProvider.overrideWith((ref) async => [override])],
        child: const MaterialApp(home: ManualOverridesScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Disabled'), findsOneWidget);
    expect(find.text('Enable'), findsOneWidget);
  });

  testWidgets('tapping Delete opens a confirmation dialog before removing anything', (tester) async {
    final override = CardOverride(
      id: 'o3',
      userCardId: 'uc1',
      scope: OverrideScope.vpa,
      vpa: 'shop@upi',
      isEnabled: true,
      createdAt: DateTime(2026, 1, 1),
      cardName: 'HDFC Millennia',
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [cardOverridesProvider.overrideWith((ref) async => [override])],
        child: const MaterialApp(home: ManualOverridesScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(find.text('Delete this override?'), findsOneWidget);
    // The tile itself is still present — nothing was deleted without
    // confirming, since cardOverridesRepositoryProvider isn't overridden
    // (accessTokenProvider defaults to null, so repo is null) and no repo
    // call could have succeeded anyway.
    expect(find.text('VPA: shop@upi'), findsOneWidget);
  });
}
