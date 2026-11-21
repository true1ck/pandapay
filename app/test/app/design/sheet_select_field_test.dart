import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/design/sheet_select_field.dart';

void main() {
  testWidgets('opens a bottom sheet, marks the current choice, reports a pick',
      (tester) async {
    String? picked;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SheetSelectField<String>(
            label: 'Route',
            options: const ['UPI QR', 'Swipe', 'ATM'],
            value: 'Swipe',
            onChanged: (v) => picked = v,
          ),
        ),
      ),
    );
    expect(find.text('Swipe'), findsOneWidget);
    await tester.tap(find.byType(SheetSelectField<String>));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
    await tester.tap(find.text('ATM'));
    await tester.pumpAndSettle();
    expect(picked, 'ATM');
    expect(find.byType(BottomSheet), findsNothing);
  });

  testWidgets('dismissing the sheet changes nothing', (tester) async {
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SheetSelectField<bool>(
            label: 'Type',
            options: const [false, true],
            value: false,
            optionLabel: (b) => b ? 'Bill' : 'Own',
            onChanged: (_) => calls++,
          ),
        ),
      ),
    );
    await tester.tap(find.byType(SheetSelectField<bool>));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(calls, 0);
  });
}
