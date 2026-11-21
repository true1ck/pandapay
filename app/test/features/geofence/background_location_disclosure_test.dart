import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/features/geofence/background_location_disclosure.dart';

Widget _host(Future<void> Function(BuildContext context) onTap) => MaterialApp(
  home: Scaffold(
    body: Builder(
      builder: (context) => Center(
        child: ElevatedButton(
          onPressed: () => onTap(context),
          child: const Text('open'),
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets('says what is collected, when, why, and how to turn it off', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host((context) async {
        await BackgroundLocationDisclosure.show(context);
      }),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text(BackgroundLocationDisclosureCopy.title), findsOneWidget);
    expect(
      find.textContaining('even when the app is closed or not in use'),
      findsOneWidget,
    );
    expect(find.textContaining('Allow all the time'), findsOneWidget);
    expect(find.text(BackgroundLocationDisclosureCopy.turnOff), findsOneWidget);
  });

  testWidgets('Continue stays disabled until the box is ticked', (
    tester,
  ) async {
    bool? result;
    await tester.pumpWidget(
      _host((context) async {
        result = await BackgroundLocationDisclosure.show(context);
      }),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final continueButton = find.widgetWithText(FilledButton, 'Continue');
    expect(tester.widget<FilledButton>(continueButton).onPressed, isNull);

    await tester.tap(find.byType(CheckboxListTile));
    await tester.pump();
    expect(tester.widget<FilledButton>(continueButton).onPressed, isNotNull);

    await tester.tap(continueButton);
    await tester.pumpAndSettle();
    expect(result, isTrue);
  });

  testWidgets('Not now resolves to false', (tester) async {
    bool? result;
    await tester.pumpWidget(
      _host((context) async {
        result = await BackgroundLocationDisclosure.show(context);
      }),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();
    expect(result, isFalse);
  });

  testWidgets('declining never reaches the permission request', (tester) async {
    final applied = <bool>[];
    await tester.pumpWidget(
      _host(
        (context) => setBackgroundAlertsWithDisclosure(
          context,
          enable: true,
          apply: (v) async => applied.add(v),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();
    expect(applied, isEmpty);
  });

  testWidgets('agreeing applies exactly once; turning off skips the sheet', (
    tester,
  ) async {
    final applied = <bool>[];
    var enable = true;
    await tester.pumpWidget(
      _host(
        (context) => setBackgroundAlertsWithDisclosure(
          context,
          enable: enable,
          apply: (v) async => applied.add(v),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Continue'));
    await tester.pumpAndSettle();
    expect(applied, [true]);

    enable = false;
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text(BackgroundLocationDisclosureCopy.title), findsNothing);
    expect(applied, [true, false]);
  });
}
