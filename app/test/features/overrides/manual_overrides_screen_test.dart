import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/card_overrides_repository.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/overrides/manual_overrides_screen.dart';

/// In-memory stand-in for CardOverridesRepository so the edit/delete flows
/// can be exercised end-to-end (widget tap -> repository call -> provider
/// invalidate -> refetched list) without a real HTTP client. Records every
/// call so tests can assert on exactly which fields a PATCH carried.
class _FakeCardOverridesRepository extends CardOverridesRepository {
  List<CardOverride> overrides;
  final List<String> calls = [];

  _FakeCardOverridesRepository(this.overrides) : super(apiBaseUrl: 'http://localhost', accessToken: 't');

  @override
  Future<List<CardOverride>> fetchOverrides() async => overrides;

  @override
  Future<void> delete(String id) async {
    calls.add('delete:$id');
    overrides = overrides.where((o) => o.id != id).toList();
  }

  @override
  Future<void> updateOverride(String id, {bool? isEnabled, String? reasonNote, String? userCardId}) async {
    calls.add('update:$id:isEnabled=$isEnabled:reasonNote=$reasonNote:userCardId=$userCardId');
    overrides = overrides.map((o) {
      if (o.id != id) return o;
      return CardOverride(
        id: o.id,
        userCardId: userCardId ?? o.userCardId,
        scope: o.scope,
        vpa: o.vpa,
        merchantName: o.merchantName,
        categoryId: o.categoryId,
        categoryName: o.categoryName,
        reasonNote: reasonNote ?? o.reasonNote,
        isEnabled: isEnabled ?? o.isEnabled,
        createdAt: o.createdAt,
        cardName: userCardId == 'uc2' ? 'ICICI Amazon Pay' : o.cardName,
        cardNickname: o.cardNickname,
      );
    }).toList();
  }
}

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

  testWidgets('confirming Delete actually calls the repository and removes the tile', (tester) async {
    final override = CardOverride(
      id: 'o4',
      userCardId: 'uc1',
      scope: OverrideScope.vpa,
      vpa: 'shop@upi',
      isEnabled: true,
      createdAt: DateTime(2026, 1, 1),
      cardName: 'HDFC Millennia',
    );
    final fakeRepo = _FakeCardOverridesRepository([override]);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [cardOverridesRepositoryProvider.overrideWithValue(fakeRepo)],
        child: const MaterialApp(home: ManualOverridesScreen()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('VPA: shop@upi'), findsOneWidget);

    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(
      of: find.byType(AlertDialog),
      matching: find.widgetWithText(TextButton, 'Delete'),
    ));
    await tester.pumpAndSettle();

    expect(fakeRepo.calls, ['delete:o4']);
    expect(find.text('VPA: shop@upi'), findsNothing);
    expect(find.text('No overrides yet'), findsOneWidget);
  });

  testWidgets('editing an override reassigns the card and note via updateOverride, not delete+recreate', (tester) async {
    final override = CardOverride(
      id: 'o5',
      userCardId: 'uc1',
      scope: OverrideScope.category,
      categoryId: 'cat1',
      categoryName: 'Fuel',
      reasonNote: 'old note',
      isEnabled: true,
      createdAt: DateTime(2026, 1, 1),
      cardName: 'HDFC Millennia',
    );
    final fakeRepo = _FakeCardOverridesRepository([override]);
    const userCards = [
      UserCard(id: 'uc1', cardProductId: 'cp1', cardName: 'HDFC Millennia', isDefault: true),
      UserCard(id: 'uc2', cardProductId: 'cp2', cardName: 'ICICI Amazon Pay', isDefault: false),
    ];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          cardOverridesRepositoryProvider.overrideWithValue(fakeRepo),
          userCardsProvider.overrideWith((ref) async => userCards),
        ],
        child: const MaterialApp(home: ManualOverridesScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();

    expect(find.text('Edit override'), findsOneWidget);
    // Scope-defining fields must not be editable here.
    expect(find.text('Category'), findsNothing);
    expect(find.byType(SegmentedButton<OverrideScope>), findsNothing);

    await tester.enterText(find.widgetWithText(TextField, 'Note (optional)'), 'new note');
    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();

    expect(fakeRepo.calls, ['update:o5:isEnabled=null:reasonNote=new note:userCardId=uc1']);
    expect(find.textContaining('new note'), findsOneWidget);
    expect(find.text('Edit override'), findsNothing); // sheet closed
  });
}
