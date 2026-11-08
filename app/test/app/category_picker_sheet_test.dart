import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/category_picker.dart';
import 'package:pandapay/data/catalogue_repository.dart';

const _categories = [
  SpendCategory(id: 'dining', slug: 'dining', name: 'Dining'),
  SpendCategory(id: 'groceries', slug: 'groceries', name: 'Groceries'),
  SpendCategory(id: 'travel', slug: 'travel', name: 'Travel'),
  SpendCategory(
    id: 'flights',
    slug: 'flights',
    name: 'Flights',
    parentCategoryId: 'travel',
  ),
  SpendCategory(id: 'pets', slug: 'pets', name: 'Pet care', isCustom: true),
];

Future<void> _open(WidgetTester tester, void Function(String?) done, {String? selected}) async {
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) => TextButton(
              onPressed: () async => done(
                await showCategoryBottomSheet(
                  context,
                  ref,
                  _categories,
                  selectedId: selected,
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('opens tall with a search box, grouped, and the add option pinned', (tester) async {
    await _open(tester, (_) {});
    expect(find.text('Choose a category'), findsOneWidget);
    expect(find.byKey(const Key('category-search')), findsOneWidget);
    expect(find.text('Dining'), findsOneWidget);
    expect(find.text('Your categories'), findsOneWidget);
    expect(find.text('Pet care'), findsOneWidget);
    expect(find.text('Add category or subcategory'), findsOneWidget);
    // A subcategory sits under its parent without repeating the parent's name.
    expect(find.text('Flights'), findsOneWidget);
    expect(find.text('Travel · Flights'), findsNothing);
  });

  testWidgets('typing filters the list and a subcategory then shows its parent', (tester) async {
    await _open(tester, (_) {});
    await tester.enterText(find.byKey(const Key('category-search')), 'fli');
    await tester.pumpAndSettle();
    expect(find.text('Travel · Flights'), findsOneWidget);
    expect(find.text('Dining'), findsNothing);
    await tester.enterText(find.byKey(const Key('category-search')), 'zzz');
    await tester.pumpAndSettle();
    expect(find.textContaining('No category matches'), findsOneWidget);
    expect(find.text('Add category or subcategory'), findsOneWidget, reason: 'still reachable');
  });

  testWidgets('picking a row returns its id', (tester) async {
    String? picked;
    await _open(tester, (value) => picked = value);
    await tester.tap(find.text('Groceries'));
    await tester.pumpAndSettle();
    expect(picked, 'groceries');
  });

  testWidgets('the current choice is marked', (tester) async {
    await _open(tester, (_) {}, selected: 'dining');
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
  });
}
