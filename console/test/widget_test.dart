import 'package:flutter_test/flutter_test.dart';

import 'package:pandapay_console/main.dart';

void main() {
  testWidgets('unauthenticated session is redirected to the dead end',
      (tester) async {
    await tester.pumpWidget(const PandaPayConsoleApp());
    await tester.pumpAndSettle();

    expect(find.text('This console is internal-only.'), findsOneWidget);
  });
}
