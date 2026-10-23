import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/merchant_category_rules_repository.dart';
import 'package:pandapay/features/activity/merchant_future_rule_sheet.dart';

MerchantCategoryRulePreview _preview({MerchantCategoryRule? existing}) =>
    MerchantCategoryRulePreview(
      sourceTransactionId: 'txn-1',
      displayMerchantName: 'Coffee House',
      matchBasis: MerchantRuleMatchBasis.vpa,
      categoryId: 'food',
      categoryName: 'Food',
      canCreate: true,
      existingRule: existing,
      examples: [
        MerchantRulePreviewTransaction(
          id: 'txn-2',
          occurredAt: DateTime(2026, 10, 20),
          amountLabel: '₹240.00',
          merchantName: 'Coffee House',
          currentCategoryName: 'Other',
        ),
      ],
    );

MerchantCategoryRule _rule({bool active = true, int version = 1}) =>
    MerchantCategoryRule(
      id: 'rule-1',
      displayMerchantName: 'Coffee House',
      matchBasis: MerchantRuleMatchBasis.vpa,
      categoryId: 'food',
      categoryName: 'Food',
      isActive: active,
      version: version,
    );

Future<void> _open(
  WidgetTester tester, {
  required MerchantCategoryRulePreview preview,
  required Future<MerchantCategoryRule> Function() onCreate,
  Future<MerchantCategoryRule> Function(MerchantCategoryRule rule)? onUpdate,
  bool offline = false,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => showMerchantFutureRuleSheet(
              context: context,
              preview: preview,
              onCreate: onCreate,
              onUpdate: onUpdate,
              offline: offline,
            ),
            child: const Text('Open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('is unchecked by default and Not now preserves one-time flow', (
    tester,
  ) async {
    var created = false;
    await _open(
      tester,
      preview: _preview(),
      onCreate: () async {
        created = true;
        return _rule();
      },
    );

    expect(
      find.text(
        'Future only. Existing transactions stay unchanged and can still be handled by the one-time review.',
      ),
      findsOneWidget,
    );
    expect(find.text('₹240.00 · 2026-10-20'), findsOneWidget);
    final save = tester.widget<FilledButton>(
      find.ancestor(
        of: find.text('Remember for future'),
        matching: find.byType(FilledButton),
      ),
    );
    expect(save.onPressed, isNull);
    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();
    expect(created, isFalse);
    expect(find.text('Remember for future transactions'), findsNothing);
  });

  testWidgets('requires explicit opt-in, then creates the rule', (
    tester,
  ) async {
    var created = false;
    await _open(
      tester,
      preview: _preview(),
      onCreate: () async {
        created = true;
        return _rule();
      },
    );

    await tester.drag(find.byType(ListView), const Offset(0, -360));
    await tester.pump();
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pump();
    await tester.tap(find.text('Remember for future'));
    await tester.pumpAndSettle();
    expect(created, isTrue);
    expect(find.text('Remember for future transactions'), findsNothing);
  });

  testWidgets('shows disabled and offline states without enabling action', (
    tester,
  ) async {
    await _open(
      tester,
      preview: _preview(existing: _rule(active: false)),
      onCreate: () async => _rule(),
      onUpdate: (_) async => _rule(),
      offline: true,
    );

    expect(find.text('Re-enable future rule?'), findsOneWidget);
    await tester.drag(find.byType(ListView), const Offset(0, -360));
    await tester.pump();
    expect(find.textContaining('You are offline.'), findsOneWidget);
    final checkbox = tester.widget<CheckboxListTile>(
      find.ancestor(
        of: find.text('Remember for future transactions'),
        matching: find.byType(CheckboxListTile),
      ),
    );
    expect(checkbox.onChanged, isNull);
  });
}
