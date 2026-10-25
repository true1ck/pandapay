import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/design/app_theme.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/commitments_repository.dart';
import 'package:pandapay/features/insights/payments_due_screen.dart';

void main() {
  testWidgets('bill category and cadence chips use the app selection palette', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          paymentsDueProvider.overrideWith((ref) async => const <DuePayment>[]),
          commitmentsProvider.overrideWith((ref) async => const <Commitment>[]),
        ],
        child: const MaterialApp(
          home: Scaffold(body: BillsAndCommitmentsTab()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Add bill or policy'));
    await tester.pumpAndSettle();

    ChoiceChip chip(String label) =>
        tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, label));

    expect(chip('Utility').selected, isTrue);
    expect(chip('Utility').selectedColor, BambooInk.slate);
    expect(chip('Utility').backgroundColor, BambooInk.paperMuted);
    expect(chip('Utility').labelStyle?.color, BambooInk.onSlate);
    expect(chip('Monthly').selected, isTrue);
    expect(chip('Monthly').selectedColor, BambooInk.slate);
    expect(chip('Monthly').labelStyle?.color, BambooInk.onSlate);

    await tester.tap(find.text('EMI / Loan'));
    await tester.pumpAndSettle();

    expect(chip('EMI / Loan').selected, isTrue);
    expect(chip('EMI / Loan').selectedColor, BambooInk.slate);
    expect(chip('EMI / Loan').labelStyle?.color, BambooInk.onSlate);
    expect(chip('Utility').selected, isFalse);
    expect(chip('Utility').labelStyle?.color, BambooInk.ink900);
  });
}
