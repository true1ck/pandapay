import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/design/app_theme.dart';
import 'package:pandapay/features/shared_expenses/ui/shared_name_sheet.dart';

void main() {
  setUp(() => BambooFonts.useSystemFontsForTests = true);
  tearDown(() => BambooFonts.useSystemFontsForTests = false);

  testWidgets(
    'name sheet validates, trims and is a sheet rather than a dialog',
    (tester) async {
      String? result;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async => result = await SharedNameSheet.show(
                context,
                title: 'Add friend',
                label: 'Friend name',
                hint: 'Just the two of you.',
                action: 'Add friend',
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('Just the two of you.'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Add friend'));
      await tester.pumpAndSettle();
      expect(find.text('Enter a name.'), findsOneWidget);
      expect(result, isNull);
      await tester.enterText(find.byType(TextField), '  Rahul  ');
      await tester.tap(find.widgetWithText(FilledButton, 'Add friend'));
      await tester.pumpAndSettle();
      expect(result, 'Rahul');
    },
  );
}
