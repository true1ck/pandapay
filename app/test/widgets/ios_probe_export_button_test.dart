import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/widgets/ios_probe_export_button.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('pandapay/ios_history_device_probe');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));
  Future<void> pump(WidgetTester tester) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: IosProbeExportButton(
          report: () => jsonEncode({'format': 'test-report'}),
        ),
      ),
    ),
  );

  testWidgets('opens sharing with one JSON report and disables repeated taps', (
    tester,
  ) async {
    final completion = Completer<String>();
    var calls = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'shareDiagnostics');
      expect(jsonDecode(call.arguments as String)['format'], 'test-report');
      calls++;
      return completion.future;
    });
    await pump(tester);
    await tester.tap(find.text('Export diagnostics'));
    await tester.pump();
    expect(find.text('Preparing export…'), findsOneWidget);
    expect(
      tester.widget<OutlinedButton>(find.byType(OutlinedButton)).onPressed,
      isNull,
    );
    expect(calls, 1);
    completion.complete('shared');
    await tester.pumpAndSettle();
    expect(find.text('Diagnostic file shared.'), findsOneWidget);
    expect(find.text('Export diagnostics'), findsOneWidget);
  });

  testWidgets('cancel is neutral and a native failure allows retry', (
    tester,
  ) async {
    var calls = 0;
    messenger.setMockMethodCallHandler(channel, (_) async {
      calls++;
      if (calls == 1) return 'cancelled';
      if (calls == 2) throw PlatformException(code: 'export_failed');
      return 'shared';
    });
    await pump(tester);
    await tester.tap(find.text('Export diagnostics'));
    await tester.pumpAndSettle();
    expect(find.text('Diagnostic file shared.'), findsNothing);
    await tester.tap(find.text('Export diagnostics'));
    await tester.pumpAndSettle();
    expect(
      find.text('Couldn’t export diagnostics. Tap to try again.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Export diagnostics'));
    await tester.pumpAndSettle();
    expect(find.text('Diagnostic file shared.'), findsOneWidget);
    expect(calls, 3);
  });

  testWidgets('an oversized report gives an actionable error', (tester) async {
    messenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(code: 'export_too_large');
    });
    await pump(tester);
    await tester.tap(find.text('Export diagnostics'));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'This session is too large to export. Use a smaller test range.',
      ),
      findsOneWidget,
    );
    expect(
      tester.widget<OutlinedButton>(find.byType(OutlinedButton)).onPressed,
      isNotNull,
    );
  });
}
