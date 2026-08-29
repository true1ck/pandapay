import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/features/import/gmail_connect_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('explains read-only access and on-device parsing before any sign-in', (tester) async {
    tester.view.physicalSize = const Size(1200, 3200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const ProviderScope(child: MaterialApp(home: GmailConnectScreen())));
    await tester.pumpAndSettle();

    expect(find.text('Find your cards from bank emails'), findsOneWidget);
    expect(find.textContaining('never send, delete, or change'), findsOneWidget);
    expect(find.textContaining('parsed entirely on this device'), findsOneWidget);
    expect(find.textContaining('Allow'), findsOneWidget);
    expect(find.text('Not now'), findsOneWidget);
  });

  testWidgets('"Not now" pops without a token', (tester) async {
    tester.view.physicalSize = const Size(1200, 3200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    String? popped = 'sentinel';
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                popped = await Navigator.of(context).push<String>(
                  MaterialPageRoute(builder: (_) => const GmailConnectScreen()),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();

    expect(popped, isNull);
  });
}
