import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pandapay/main.dart';

void main() {
  testWidgets('app shell renders Home tab and MoneyText shows a confidence badge',
      (tester) async {
    await tester.pumpWidget(const PandaPayApp());

    expect(find.text('PandaPay — Home'), findsOneWidget);
    expect(find.text('₹12,34,567.00'), findsOneWidget);
    expect(find.byIcon(Icons.hourglass_top), findsOneWidget);
  });

  testWidgets('bottom nav switches tabs', (tester) async {
    await tester.pumpWidget(const PandaPayApp());

    await tester.tap(find.byIcon(Icons.credit_card));
    await tester.pump();

    expect(find.text('PandaPay — Cards'), findsOneWidget);
  });
}
